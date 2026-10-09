// SPDX-License-Identifier: GPL-3.0-or-later
// Host-independent test: never imports OpenVR or starts a runtime.
#include "ProbePhaseDiagnostics.h"
#include <stdexcept>

int main()
{
    using namespace csx::probe;
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
