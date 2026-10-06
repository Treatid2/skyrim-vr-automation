// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace csx::controllers {
inline constexpr wchar_t MappingName[] = L"Local\\CSXVRControllers-v1";
inline constexpr std::uint32_t Magic = 0x43585343; // "CSXC"
inline constexpr std::uint16_t Version = 1;
inline constexpr std::uint64_t ButtonMask = (1ULL << 0) | (1ULL << 1) | (1ULL << 2) |
    (1ULL << 32) | (1ULL << 33) | (1ULL << 34);
inline constexpr std::uint32_t Reset = 1;
enum Status : std::uint32_t { Waiting, Applied, Invalid, Busy, Expired, InputFailed };

struct alignas(8) Hand {
    std::array<double, 3> position{};
    std::array<double, 4> quaternion{1, 0, 0, 0}; // W, X, Y, Z
    std::uint64_t pressed{};
    std::uint64_t touched{};
    float trackpadX{}, trackpadY{}, trigger{}, grip{}, stickX{}, stickY{};
    std::array<std::uint64_t, 4> reserved{};
};
static_assert(sizeof(Hand) == 128);
static_assert(offsetof(Hand, pressed) == 56);
static_assert(offsetof(Hand, trackpadX) == 72);

struct alignas(8) Command {
    std::uint64_t ownerNonce{}, writerNonce{}, deadlineTickMs{}, driverNonce{};
    std::uint32_t flags{}, reserved{};
    std::array<Hand, 2> hands{}; // left, right
};
static_assert(sizeof(Command) == 296);

struct alignas(8) Haptic {
    std::uint64_t sequence{};
    std::uint32_t hand{}, reserved{};
    float durationSeconds{}, frequencyHz{}, amplitude{};
    std::uint32_t padding{};
    std::uint64_t tickMs{};
};
static_assert(sizeof(Haptic) == 40);
inline constexpr std::size_t HapticCapacity = 16;

struct alignas(8) Shared {
    std::uint32_t magic{};
    std::uint16_t version{}, size{};
    std::uint64_t requestedSequence{}, appliedSequence{}, acknowledgedWriterNonce{};
    std::uint64_t driverNonce{}, driverStartedFileTimeUtc{};
    std::uint32_t driverCreatorPid{}, status{};
    std::uint64_t telemetrySequence{};
    Command command{};
    std::uint64_t activeOwner{}, deadlineTickMs{}, acceptedSequence{}, expirationCount{};
    std::uint32_t inputHealthy{}, reserved{};
    std::array<Hand, 2> appliedHands{};
    std::uint64_t hapticSequence{};
    std::array<Haptic, HapticCapacity> haptics{};
};
static_assert(sizeof(Shared) == 1304);
static_assert(offsetof(Shared, command) == 64);
static_assert(offsetof(Shared, activeOwner) == 360);
static_assert(offsetof(Shared, appliedHands) == 400);
static_assert(offsetof(Shared, hapticSequence) == 656);
static_assert(offsetof(Shared, haptics) == 664);

inline std::array<Hand, 2> DefaultHands()
{
    std::array<Hand, 2> hands{};
    hands[0].position = {-0.25, 1.25, -0.35};
    hands[1].position = {0.25, 1.25, -0.35};
    return hands;
}

inline void Neutralize(Hand& hand)
{
    hand.pressed = hand.touched = 0;
    hand.trackpadX = hand.trackpadY = hand.trigger = hand.grip = hand.stickX = hand.stickY = 0;
}

inline bool ValidateAndNormalize(Hand& hand)
{
    for (auto p : hand.position) {
        if (!std::isfinite(p) || std::abs(p) > 1000) { return false; }
    }
    double norm = 0;
    for (auto q : hand.quaternion) {
        if (!std::isfinite(q)) { return false; }
        norm += q * q;
    }
    if (!(norm > 0.25 && norm < 4)) { return false; }
    if (((hand.pressed | hand.touched) & ~ButtonMask) != 0) { return false; }
    for (auto v : hand.reserved) { if (v != 0) { return false; } }
    for (auto v : {hand.trackpadX, hand.trackpadY, hand.stickX, hand.stickY}) {
        if (!std::isfinite(v) || v < -1 || v > 1) { return false; }
    }
    for (auto v : {hand.trigger, hand.grip}) {
        if (!std::isfinite(v) || v < 0 || v > 1) { return false; }
    }
    norm = std::sqrt(norm);
    for (auto& q : hand.quaternion) { q /= norm; }
    return true;
}

// Runtime-independent lease/state core; the driver owns time and publication.
class State {
public:
    std::array<Hand, 2> hands = DefaultHands();
    std::uint64_t owner{}, deadline{}, acceptedSequence{}, expirationCount{};
    bool Tick(std::uint64_t now)
    {
        if (owner != 0 && now >= deadline) {
            for (auto& hand : hands) { Neutralize(hand); }
            owner = deadline = 0;
            ++expirationCount;
            return true;
        }
        return false;
    }
    Status Apply(Command command, std::uint64_t sequence, std::uint64_t now,
        std::uint64_t driverNonce)
    {
        Tick(now);
        if (command.ownerNonce == 0 || command.writerNonce == 0 ||
            command.driverNonce != driverNonce || command.reserved != 0 ||
            (command.flags & ~Reset) != 0) { return Invalid; }
        // Validate the entire pair before acquiring a lease or moving either hand.
        for (auto& hand : command.hands) {
            if (!ValidateAndNormalize(hand)) { return Invalid; }
        }
        if (owner != 0 && owner != command.ownerNonce) { return Busy; }
        if (command.flags == Reset) {
            hands = DefaultHands();
            owner = deadline = 0;
        } else {
            if (command.deadlineTickMs <= now) { return Expired; }
            if (command.deadlineTickMs - now > 60000) { return Invalid; }
            hands = command.hands;
            owner = command.ownerNonce;
            deadline = command.deadlineTickMs;
        }
        acceptedSequence = sequence;
        return Applied;
    }
};
} // namespace csx::controllers
