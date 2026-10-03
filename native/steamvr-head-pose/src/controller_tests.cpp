// SPDX-License-Identifier: GPL-3.0-or-later
#include "controller_protocol.h"
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace csx::controllers;
void Require(bool value, const char* label)
{
    if (!value) { throw std::runtime_error(label); }
}
int main()
{
    try {
        State state;
        Command cmd{11, 22, 1500, 99, 0, 0, DefaultHands()};
        cmd.hands[0].position = {-0.4, 1.1, -0.6};
        cmd.hands[0].quaternion = {0.8, 0.8, 0, 0};
        cmd.hands[0].pressed = ButtonMask;
        cmd.hands[1].touched = ButtonMask;
        cmd.hands[0].trackpadX = -1;
        cmd.hands[0].trigger = 1;
        cmd.hands[1].grip = 0.5;
        cmd.hands[1].stickY = 1;
        Require(state.Apply(cmd, 2, 1000, 99) == Applied, "valid pair rejected");
        Require(state.owner == 11 && state.deadline == 1500, "lease not acquired");
        Require(std::abs(state.hands[0].quaternion[0] - std::sqrt(0.5)) < 1e-9, "not normalized");
        auto other = cmd;
        other.ownerNonce = 12;
        other.flags = Reset;
        Require(state.Apply(other, 4, 1100, 99) == Busy, "foreign reset stole lease");
        Require(state.hands[0].pressed == ButtonMask && state.acceptedSequence == 2, "busy mutated state");
        auto invalid = cmd;
        invalid.hands[0].position[0] = 20;
        invalid.hands[1].trigger = std::numeric_limits<float>::quiet_NaN();
        Require(state.Apply(invalid, 6, 1100, 99) == Invalid, "NaN accepted");
        Require(state.hands[0].position[0] == -0.4, "invalid second hand moved first");
        invalid = cmd;
        invalid.hands[1].touched |= 1ULL << 63;
        Require(state.Apply(invalid, 8, 1100, 99) == Invalid, "unsupported bits accepted");
        invalid = cmd;
        invalid.driverNonce = 98;
        Require(state.Apply(invalid, 10, 1100, 99) == Invalid, "stale instance accepted");
        invalid = cmd;
        invalid.deadlineTickMs = 1100;
        Require(state.Apply(invalid, 12, 1100, 99) == Expired, "expired command renewed lease");
        invalid.deadlineTickMs = 61101;
        Require(state.Apply(invalid, 14, 1100, 99) == Invalid, "unbounded lease accepted");
        Require(!state.Tick(1499) && state.hands[0].pressed == ButtonMask, "premature expiry");
        Require(state.Tick(1500), "deadline did not expire");
        Require(state.owner == 0 && state.deadline == 0 && state.expirationCount == 1, "expiry lease state");
        Require(state.hands[0].pressed == 0 && state.hands[1].touched == 0 &&
            state.hands[0].trackpadX == 0 && state.hands[0].trigger == 0 &&
            state.hands[1].grip == 0 && state.hands[1].stickY == 0, "expiry stuck input");
        Require(state.hands[0].position[0] == -0.4, "expiry moved pose");
        Require(!state.Tick(2000) && state.expirationCount == 1, "expiry counted twice");
        other.flags = 0;
        other.deadlineTickMs = 2500;
        Require(state.Apply(other, 16, 2000, 99) == Applied && state.owner == 12, "expired owner blocks takeover");
        cmd.flags = Reset;
        Require(state.Apply(cmd, 18, 2100, 99) == Busy, "former owner resets new owner");
        other.flags = Reset;
        Require(state.Apply(other, 20, 2100, 99) == Applied && state.owner == 0, "owned reset failed");
        Require(state.hands[0].position[0] == -0.25 && state.hands[1].position[0] == 0.25 &&
            state.hands[0].pressed == 0, "reset not default neutral pair");
        for (unsigned i = 0; i < 10; ++i) {
            auto bad = cmd;
            bad.flags = 0;
            bad.deadlineTickMs = 3000;
            switch (i) {
            case 0: bad.ownerNonce = 0; break;
            case 1: bad.writerNonce = 0; break;
            case 2: bad.flags = 2; break;
            case 3: bad.reserved = 1; break;
            case 4: bad.hands[0].reserved[3] = 1; break;
            case 5: bad.hands[0].position[1] = 1001; break;
            case 6: bad.hands[0].quaternion = {0, 0, 0, 0}; break;
            case 7: bad.hands[0].stickX = -1.01F; break;
            case 8: bad.hands[0].grip = -0.01F; break;
            case 9: bad.hands[1].quaternion[2] = std::numeric_limits<double>::infinity(); break;
            }
            Require(state.Apply(bad, 22 + i * 2, 2100, 99) == Invalid, "malformed input accepted");
            Require(state.owner == 0 && state.hands[0].pressed == 0 && state.acceptedSequence == 20,
                "malformed command acquired lease or changed acceptance");
        }
        std::cout << "PASS: pair validation, normalized poses, ownership, stale instance, deadline, "
            "expiry neutralization, pose retention, takeover, owned reset and malformed inputs\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
