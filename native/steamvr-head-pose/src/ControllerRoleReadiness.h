// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>

namespace csx::probe {
// Pure finite policy shared by production and the existing offline host target.
// Unknown roles are pending, not accepted; foreign/contradictory identity and
// input/event failures are terminal. No role hint or hardcoded device index.
enum class RoleObservation { Pending, Assigned, Rejected };
struct RoleSnapshot {
    std::uint32_t left{UINT32_MAX}, right{UINT32_MAX};
    RoleObservation observation{RoleObservation::Pending};
};
enum class RoleAdmissionState { Assigned, Rejected, Deadline, ObservationLimit };
constexpr const char* RoleAdmissionName(RoleAdmissionState state) noexcept
{
    switch (state) {
    case RoleAdmissionState::Assigned: return "assigned";
    case RoleAdmissionState::Rejected: return "rejected";
    case RoleAdmissionState::Deadline: return "deadline";
    case RoleAdmissionState::ObservationLimit: return "observation-limit";
    }
    return "unknown";
}
struct RoleAdmission {
    RoleSnapshot first{}, last{};
    RoleAdmissionState state{RoleAdmissionState::Deadline};
    unsigned observations{0};
    std::int64_t elapsedMs{0};
};
inline constexpr std::int64_t RoleReadinessBudgetMs = 3000;
inline constexpr std::int64_t ProbeQualificationDeadlineMs = 9000;
inline constexpr std::int64_t NeutralQualificationReserveMs = 2500;
inline constexpr unsigned MaxRoleObservations = 151;
inline constexpr std::int64_t RolePollIntervalMs = 20;

template<class Clock, class ObserveRoles, class Pace>
RoleAdmission AwaitControllerRoles(Clock&& now, ObserveRoles&& observe, Pace&& pace)
{
    RoleAdmission result{};
    const auto began = now(); // milliseconds since BEFORE the original VR_Init
    const auto deadline = std::min(began + RoleReadinessBudgetMs,
        ProbeQualificationDeadlineMs - NeutralQualificationReserveMs);
    for (unsigned ordinal = 0; ordinal < MaxRoleObservations; ++ordinal) {
        if (now() >= deadline) { result.elapsedMs = now() - began; return result; }
        result.last = observe(ordinal);
        ++result.observations;
        if (ordinal == 0) { result.first = result.last; }
        result.elapsedMs = now() - began;
        // A late successful observation is not an admitted pair.
        if (now() >= deadline) { return result; }
        if (result.last.observation == RoleObservation::Rejected) {
            result.state = RoleAdmissionState::Rejected; return result;
        }
        if (result.last.observation == RoleObservation::Assigned) {
            if (result.last.left == result.last.right || result.last.left == 0 || result.last.right == 0 ||
                result.last.left >= 64 || result.last.right >= 64) {
                result.state = RoleAdmissionState::Rejected; return result;
            }
            result.state = RoleAdmissionState::Assigned; return result;
        }
        if (ordinal + 1 == MaxRoleObservations) {
            result.state = RoleAdmissionState::ObservationLimit; return result;
        }
        // Pacing a predicate-driven observation loop is not a startup sleep.
        pace(std::min(RolePollIntervalMs, deadline - now()));
    }
    return result;
}
}
