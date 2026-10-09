// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <cstdio>
#include <exception>
#include <utility>

namespace csx::probe {
// Fixed identifiers only: diagnostics contain no paths, arguments or user data.
enum class Phase {
    Init, InitErrorDescription, StandingPose, RawPose, LeftEye, RightEye,
    RenderTarget, RuntimePath, LeftRole, RightRole, CompositorInterface,
    SerialProperty, TrackingProperty, CompositorPoses, ControllerClass,
    ControllerRole, ControllerState, EventDrain, Shutdown
};
constexpr const char* Name(Phase phase) noexcept
{
    switch (phase) {
    case Phase::Init: return "VR_Init";
    case Phase::InitErrorDescription: return "InitErrorDescription";
    case Phase::StandingPose: return "StandingPose";
    case Phase::RawPose: return "RawPose";
    case Phase::LeftEye: return "LeftEye";
    case Phase::RightEye: return "RightEye";
    case Phase::RenderTarget: return "RenderTarget";
    case Phase::RuntimePath: return "RuntimePath";
    case Phase::LeftRole: return "LeftRole";
    case Phase::RightRole: return "RightRole";
    case Phase::CompositorInterface: return "CompositorInterface";
    case Phase::SerialProperty: return "SerialProperty";
    case Phase::TrackingProperty: return "TrackingProperty";
    case Phase::CompositorPoses: return "CompositorPoses";
    case Phase::ControllerClass: return "ControllerClass";
    case Phase::ControllerRole: return "ControllerRole";
    case Phase::ControllerState: return "ControllerState";
    case Phase::EventDrain: return "EventDrain";
    case Phase::Shutdown: return "VR_Shutdown";
    }
    return "Unknown";
}

class Diagnostics {
public:
    static constexpr std::uint32_t MaxRecords = 4096;
    void Enable() noexcept { enabled_ = true; }
    std::uint32_t NextCall() noexcept { return ++calls_; }
    void Record(std::uint32_t call, Phase phase, const char* state, int sample, int hand) noexcept
    {
        if (!enabled_) { return; }
        if (records_ >= MaxRecords) {
            if (!truncated_) {
                truncated_ = true;
                std::fputs("CSX_OPENVR_PROBE_PHASE_V1 truncated=true\n", stderr);
                std::fflush(stderr);
            }
            return;
        }
        // Each fixed-domain line fits192 bytes. At most4096 records plus a
        // truncation marker (<0.76MiB). No event-by-event or unbounded output.
        ++records_;
        std::fprintf(stderr, "CSX_OPENVR_PROBE_PHASE_V1 seq=%u call=%u phase=%s state=%s sample=%d hand=%d\n",
            records_, call, Name(phase), state, sample, hand);
        std::fflush(stderr); // retain the entered call even if it never returns
    }
private:
    bool enabled_{false};
    bool truncated_{false};
    std::uint32_t calls_{0};
    std::uint32_t records_{0};
};

inline Diagnostics diagnostics{};
class Scope {
public:
    Scope(Phase phase, int sample, int hand) noexcept
        : call_(diagnostics.NextCall()), phase_(phase), sample_(sample), hand_(hand),
          exceptions_(std::uncaught_exceptions())
    { diagnostics.Record(call_, phase_, "entered", sample_, hand_); }
    ~Scope() noexcept
    { diagnostics.Record(call_, phase_, std::uncaught_exceptions() == exceptions_ ? "completed" : "aborted", sample_, hand_); }
private:
    std::uint32_t call_;
    Phase phase_;
    int sample_, hand_, exceptions_;
};

template<class Function>
decltype(auto) Observe(Phase phase, Function&& function, int sample = -1, int hand = -1)
{
    Scope scope(phase, sample, hand);
    return std::forward<Function>(function)();
}
} // namespace csx::probe
