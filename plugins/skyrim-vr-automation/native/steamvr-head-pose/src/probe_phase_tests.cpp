// SPDX-License-Identifier: GPL-3.0-or-later
// Host-independent test: never imports OpenVR or starts a runtime.
#include "ProbePhaseDiagnostics.h"
#include "FailedRoleDiagnostics.h"
#include "ControllerRoleReadiness.h"
#include <sstream>
#include <stdexcept>

int main()
{
    using namespace csx::probe;
    // Exact production readiness policy, synthetic clock/callbacks only.
    // No OpenVR dependency, native mapping or runtime.
    for (const unsigned becomesReady : {0U, 1U, 10U, 149U, 150U, 200U}) {
        std::int64_t clock = 0;
        unsigned calls = 0;
        const auto result = AwaitControllerRoles([&] { return clock; }, [&](unsigned ordinal) {
            ++calls;
            return ordinal >= becomesReady ? RoleSnapshot{2, 3, RoleObservation::Assigned} : RoleSnapshot{};
        }, [&](std::int64_t ms) { if (ms <= 0 || ms > 20) { throw std::runtime_error("pace"); } clock += ms; });
        const bool expected = becomesReady < 150;
        if ((result.state == RoleAdmissionState::Assigned) != expected || calls > MaxRoleObservations) { return 11; }
        if (becomesReady > 0 && result.first.left != UINT32_MAX) { return 12; }
        if (result.elapsedMs > RoleReadinessBudgetMs) { return 13; }
    }
    {
        std::int64_t clock = 6400;
        const auto late = AwaitControllerRoles([&] { return clock; }, [&](unsigned) {
            clock += 100; return RoleSnapshot{2, 3, RoleObservation::Assigned};
        }, [](std::int64_t) {});
        if (late.state != RoleAdmissionState::Deadline || late.observations != 1) { return 14; }
        unsigned calls = 0; clock = 6500;
        const auto refused = AwaitControllerRoles([&] { return clock; }, [&](unsigned) { ++calls; return RoleSnapshot{}; }, [](std::int64_t) {});
        if (calls != 0 || refused.state != RoleAdmissionState::Deadline) { return 15; }
    }
    {
        unsigned calls = 0;
        const auto rejected = AwaitControllerRoles([] { return 0LL; }, [&](unsigned) { ++calls; return RoleSnapshot{2, 3, RoleObservation::Rejected}; }, [](std::int64_t) {});
        if (rejected.state != RoleAdmissionState::Rejected || calls != 1) { return 16; }
        const auto noClockProgress = AwaitControllerRoles([] { return 0LL; }, [](unsigned) { return RoleSnapshot{}; }, [](std::int64_t) {});
        if (noClockProgress.state != RoleAdmissionState::ObservationLimit || noClockProgress.observations != MaxRoleObservations) { return 17; }
        bool threw = false;
        try { AwaitControllerRoles([] { return 0LL; }, [](unsigned) -> RoleSnapshot { throw std::runtime_error("snapshot"); }, [](std::int64_t) {}); }
        catch (const std::runtime_error&) { threw = true; }
        if (!threw) { return 18; }
    }
    for (const auto pair : {RoleSnapshot{2, 2, RoleObservation::Assigned}, RoleSnapshot{0, 3, RoleObservation::Assigned},
        RoleSnapshot{2, UINT32_MAX, RoleObservation::Assigned}, RoleSnapshot{64, 3, RoleObservation::Assigned}}) {
        const auto result = AwaitControllerRoles([] { return 0LL; }, [&](unsigned) { return pair; }, [](std::int64_t) {});
        if (result.state != RoleAdmissionState::Rejected || result.observations != 1) { return 19; }
    }
    // New formatting cases execute no OpenVR call or live shared mapping.
    csx::controllers::Shared snapshot{};
    snapshot.driverCreatorPid = 123;
    snapshot.driverNonce = 456;
    snapshot.inputHealthy = 1;
    snapshot.telemetrySequence = 2;
    for (const auto stable : {false, true}) {
        for (const auto protocol : {false, true}) {
            std::ostringstream output;
            PrintControllerSnapshot(output, snapshot, stable, protocol, true);
            const auto text = output.str();
            const auto found = text.find("\"driverCreatorPid\":123") != std::string::npos;
            if (found != (stable && protocol)) { return 6; }
            if (text.find("\"cleanupVerified\":true") == std::string::npos || text.back() != '}') { return 7; }
            if (text.find("ownerNonce") != std::string::npos || text.find("writerNonce") != std::string::npos) { return 8; }
        }
    }
    std::ostringstream cleanupFailed;
    PrintControllerSnapshot(cleanupFailed, snapshot, true, true, false);
    if (cleanupFailed.str().find("\"cleanupVerified\":false") == std::string::npos) { return 9; }
    if (std::string(Name(Phase::DiagnosticRoleHint)) != "DiagnosticRoleHint" ||
        std::string(Name(Phase::DiagnosticChannel)) != "DiagnosticChannel") { return 10; }
    int called = 0;
    if (Observe(Phase::Init, [&] { ++called; return 17; }) != 17 || called != 1) { return 1; }
    Observe(Phase::Shutdown, [&] { ++called; });
    if (called != 2) { return 2; }
    diagnostics.Enable();
    if (Observe(Phase::StandingPose, [&] { ++called; return 23; }, 0, 1) != 23 || called != 3) { return 3; }
    try {
        Observe(Phase::ControllerState, [] { throw std::runtime_error("synthetic"); }, 1, 0);
        return 4;
    } catch (const std::runtime_error&) { }
    Observe(Phase::CompositorPoses, [] { Observe(Phase::CompositorInterface, [] {}, 2); }, 2);
    // Explicit saturation is bounded, does not suppress the caller's result,
    // and emits one coverage-loss marker rather than unbounded records.
    for (unsigned i = 0; i < Diagnostics::MaxRecords; ++i) {
        if (Observe(Phase::LeftRole, [] { return 31; }, 99, 0) != 31) { return 5; }
    }
    return 0;
}
