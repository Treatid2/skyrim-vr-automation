// SPDX-License-Identifier: GPL-3.0-or-later

#include <openvr.h>
#include "ProbePhaseDiagnostics.h"

#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <sstream>
#include "FailedRoleDiagnostics.h"

namespace {
using csx::probe::Observe;
using csx::probe::Phase;

void PrintPose(const char* name, const vr::TrackedDevicePose_t& pose, std::ostream& output = std::cout)
{
    const auto& matrix = pose.mDeviceToAbsoluteTracking;
    output << '"' << name << "\":{";
    output << "\"connected\":" << (pose.bDeviceIsConnected ? "true" : "false") << ',';
    output << "\"valid\":" << (pose.bPoseIsValid ? "true" : "false") << ',';
    output << "\"trackingResult\":" << static_cast<int>(pose.eTrackingResult) << ',';
    output << "\"position\":[" << matrix.m[0][3] << ',' << matrix.m[1][3] << ',' << matrix.m[2][3] << ']';
    output << '}';
}

std::string JsonEscape(const char* value)
{
    std::string escaped;
    if (!value) {
        return escaped;
    }
    for (const auto character : std::string(value)) {
        if (static_cast<unsigned char>(character) < 0x20) {
            const char digits[] = "0123456789abcdef";
            escaped += "\\u00";
            escaped.push_back(digits[(static_cast<unsigned char>(character) >> 4) & 15]);
            escaped.push_back(digits[static_cast<unsigned char>(character) & 15]);
            continue;
        }
        if (character == '\\' || character == '"') {
            escaped.push_back('\\');
        }
        escaped.push_back(character);
    }
    return escaped;
}

bool IsFiniteEyeTransform(const vr::HmdMatrix34_t& transform)
{
    for (const auto& row : transform.m) {
        for (const auto value : row) {
            if (!std::isfinite(value)) {
                return false;
            }
        }
    }
    return true;
}

bool ValidPose(const vr::TrackedDevicePose_t& pose)
{
    if (!pose.bDeviceIsConnected || !pose.bPoseIsValid ||
        pose.eTrackingResult != vr::TrackingResult_Running_OK ||
        !IsFiniteEyeTransform(pose.mDeviceToAbsoluteTracking)) { return false; }
    for (int i = 0; i < 3; ++i) {
        if (!std::isfinite(pose.vVelocity.v[i]) || !std::isfinite(pose.vAngularVelocity.v[i])) {
            return false;
        }
    }
    return true;
}

bool NeutralState(const vr::VRControllerState_t& state)
{
    if (state.ulButtonPressed != 0 || state.ulButtonTouched != 0) { return false; }
    for (const auto& axis : state.rAxis) {
        if (!std::isfinite(axis.x) || !std::isfinite(axis.y) || axis.x != 0.0F || axis.y != 0.0F) {
            return false;
        }
    }
    return true;
}

struct ControllerCheck {
    vr::TrackedDeviceIndex_t left{vr::k_unTrackedDeviceIndexInvalid};
    vr::TrackedDeviceIndex_t right{vr::k_unTrackedDeviceIndexInvalid};
    std::array<std::uint32_t, 2> packets{};
    unsigned samples{0};
    unsigned inputEvents{0};
    bool valid{false};
};

ControllerCheck CheckControllers(vr::IVRSystem* system)
{
    ControllerCheck result{};
    result.left = Observe(Phase::LeftRole, [&] { return system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand); });
    result.right = Observe(Phase::RightRole, [&] { return system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand); });
    const std::array indices{result.left, result.right};
    if (result.left == result.right || !Observe(Phase::CompositorInterface, [] { return vr::VRCompositor(); })) { return result; }
    for (const auto index : indices) {
        if (index >= vr::k_unMaxTrackedDeviceCount || index == vr::k_unTrackedDeviceIndex_Hmd) {
            return result;
        }
    }
    for (std::size_t hand = 0; hand < indices.size(); ++hand) {
        std::array<char, 128> serial{}, trackingSystem{};
        vr::ETrackedPropertyError propertyError = vr::TrackedProp_Success;
        const auto serialSize = Observe(Phase::SerialProperty, [&] { return system->GetStringTrackedDeviceProperty(indices[hand],
            vr::Prop_SerialNumber_String, serial.data(), static_cast<std::uint32_t>(serial.size()), &propertyError); }, -1, static_cast<int>(hand));
        const auto expected = hand == 0 ? "CSX-NULL-CONTROLLER-LEFT-1" : "CSX-NULL-CONTROLLER-RIGHT-1";
        if (propertyError != vr::TrackedProp_Success || serialSize > serial.size() ||
            std::string(serial.data()) != expected) { return result; }
        const auto trackingSize = Observe(Phase::TrackingProperty, [&] { return system->GetStringTrackedDeviceProperty(indices[hand],
            vr::Prop_TrackingSystemName_String, trackingSystem.data(),
            static_cast<std::uint32_t>(trackingSystem.size()), &propertyError); }, -1, static_cast<int>(hand));
        if (propertyError != vr::TrackedProp_Success || trackingSize > trackingSystem.size() ||
            std::string(trackingSystem.data()) != "codex_head_pose") { return result; }
    }
    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> game{}, render{}, standing{};
    // Observe a stable neutral pair for two seconds, including the compositor
    // arrays consumed by VR Tools. One good registration snapshot is insufficient.
    for (unsigned sample = 0; sample < 100; ++sample) {
        if (Observe(Phase::LeftRole, [&] { return system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand); }, sample) != result.left ||
            Observe(Phase::RightRole, [&] { return system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand); }, sample) != result.right ||
            Observe(Phase::CompositorPoses, [&] {
                auto* compositor = Observe(Phase::CompositorInterface, [] { return vr::VRCompositor(); }, sample);
                return compositor ? compositor->GetLastPoses(render.data(), static_cast<std::uint32_t>(render.size()),
                    game.data(), static_cast<std::uint32_t>(game.size())) : vr::VRCompositorError_RequestFailed; }, sample) != vr::VRCompositorError_None) {
            return result;
        }
        Observe(Phase::StandingPose, [&] { system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0.0F,
            standing.data(), static_cast<std::uint32_t>(standing.size())); }, sample);
        for (std::size_t hand = 0; hand < indices.size(); ++hand) {
            const auto index = indices[hand];
            vr::VRControllerState_t state{};
            const auto role = hand == 0 ? vr::TrackedControllerRole_LeftHand : vr::TrackedControllerRole_RightHand;
            if (Observe(Phase::ControllerClass, [&] { return system->GetTrackedDeviceClass(index); }, sample, static_cast<int>(hand)) != vr::TrackedDeviceClass_Controller ||
                Observe(Phase::ControllerRole, [&] { return system->GetControllerRoleForTrackedDeviceIndex(index); }, sample, static_cast<int>(hand)) != role ||
                !ValidPose(standing[index]) || !ValidPose(game[index]) || !ValidPose(render[index]) ||
                !Observe(Phase::ControllerState, [&] { return system->GetControllerState(index, &state, sizeof(state)); }, sample, static_cast<int>(hand)) || !NeutralState(state)) {
                return result;
            }
            result.packets[hand] = state.unPacketNum;
        }
        vr::VREvent_t event{};
        unsigned drained = 0;
        Observe(Phase::EventDrain, [&] {
        while (drained < 256 && system->PollNextEvent(&event, sizeof(event))) {
            ++drained;
            if ((event.trackedDeviceIndex == result.left || event.trackedDeviceIndex == result.right) &&
                (event.eventType == vr::VREvent_ButtonPress || event.eventType == vr::VREvent_ButtonUnpress ||
                 event.eventType == vr::VREvent_ButtonTouch || event.eventType == vr::VREvent_ButtonUntouch)) {
                ++result.inputEvents;
            }
        }
        }, sample);
        if (drained == 256 || result.inputEvents != 0) { return result; }
        ++result.samples;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    result.valid = true;
    return result;
}

void PrintFailedRoleDiagnostics(vr::IVRSystem* system, std::ostream& output)
{
    // Exactly one inventory, capped by OpenVR's64-device limit. Role hints
    // remain separate from actual assignment; no qualification or extra probe.
    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> poses{};
    Observe(Phase::DiagnosticInventoryPose, [&] { system->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0.0F, poses.data(), static_cast<std::uint32_t>(poses.size())); });
    output << "{\"diagnosticOnly\":true,\"maxDevices\":" << vr::k_unMaxTrackedDeviceCount << ",\"devices\":[";
    bool comma = false;
    for (vr::TrackedDeviceIndex_t index = 0; index < vr::k_unMaxTrackedDeviceCount; ++index) {
        const auto deviceClass = Observe(Phase::ControllerClass, [&] { return system->GetTrackedDeviceClass(index); });
        if (deviceClass == vr::TrackedDeviceClass_Invalid) { continue; }
        if (comma) { output << ','; } comma = true;
        const auto assigned = Observe(Phase::ControllerRole, [&] { return system->GetControllerRoleForTrackedDeviceIndex(index); });
        vr::ETrackedPropertyError hintError = vr::TrackedProp_Success;
        const auto hint = Observe(Phase::DiagnosticRoleHint, [&] { return system->GetInt32TrackedDeviceProperty(index, vr::Prop_ControllerRoleHint_Int32, &hintError); });
        const auto connected = Observe(Phase::DiagnosticConnected, [&] { return system->IsTrackedDeviceConnected(index); });
        std::array<char, 128> serial{}, tracking{};
        vr::ETrackedPropertyError serialError = vr::TrackedProp_Success, trackingError = vr::TrackedProp_Success;
        const auto serialSize = Observe(Phase::SerialProperty, [&] { return system->GetStringTrackedDeviceProperty(index, vr::Prop_SerialNumber_String, serial.data(), static_cast<std::uint32_t>(serial.size()), &serialError); });
        const auto trackingSize = Observe(Phase::TrackingProperty, [&] { return system->GetStringTrackedDeviceProperty(index, vr::Prop_TrackingSystemName_String, tracking.data(), static_cast<std::uint32_t>(tracking.size()), &trackingError); });
        serial.back() = tracking.back() = 0;
        output << "{\"index\":" << index << ",\"deviceClass\":" << static_cast<int>(deviceClass)
                  << ",\"assignedRole\":" << static_cast<int>(assigned) << ",\"roleHint\":" << hint
                  << ",\"roleHintError\":" << static_cast<int>(hintError)
                  << ",\"connected\":" << (connected ? "true" : "false")
                  << ",\"serialError\":" << static_cast<int>(serialError) << ",\"trackingError\":" << static_cast<int>(trackingError)
                  << ",\"serial\":";
        if (serialError == vr::TrackedProp_Success && serialSize > 0 && serialSize <= serial.size()) { output << '"' << JsonEscape(serial.data()) << '"'; } else { output << "null"; }
        output << ",\"trackingSystem\":";
        if (trackingError == vr::TrackedProp_Success && trackingSize > 0 && trackingSize <= tracking.size()) { output << '"' << JsonEscape(tracking.data()) << '"'; } else { output << "null"; }
        output << ",\"finitePose\":" << (IsFiniteEyeTransform(poses[index].mDeviceToAbsoluteTracking) ? "true" : "false") << ',';
        // Invalid/nonfinite pose coordinates must not emit invalid JSON.
        if (IsFiniteEyeTransform(poses[index].mDeviceToAbsoluteTracking)) { PrintPose("standing", poses[index], output); }
        else { output << "\"standing\":null"; }
        output << '}';
    }
    output << "],\"controllerChannel\":";
    Observe(Phase::DiagnosticChannel, [&] { csx::probe::PrintControllerChannel(output); });
    output << '}';
}

}  // namespace

int main(int argc, char** argv)
{
    bool requireControllers = false;
    bool diagnosticPhases = false;
    bool diagnosticFailedRoles = false;
    bool validArguments = true;
    for (int i = 1; i < argc; ++i) {
        const std::string argument{argv[i]};
        if (argument == "--require-controllers" && !requireControllers) { requireControllers = true; }
        else if (argument == "--diagnostic-phases" && !diagnosticPhases) { diagnosticPhases = true; }
        else if (argument == "--diagnostic-failed-roles" && !diagnosticFailedRoles) { diagnosticFailedRoles = true; }
        else { validArguments = false; }
    }
    if (!validArguments) {
        std::cout << "{\"ok\":false,\"state\":\"invalid-arguments\"}\n";
        return 4;
    }
    if (diagnosticPhases) { csx::probe::diagnostics.Enable(); }
    vr::EVRInitError error = vr::VRInitError_None;
    auto* system = Observe(Phase::Init, [&] { return vr::VR_Init(&error, vr::VRApplication_Background); });
    if (error != vr::VRInitError_None || !system) {
        std::cout << "{\"ok\":false,\"state\":\"openvr-init-failed\",\"errorCode\":"
                  << static_cast<int>(error) << ",\"error\":\""
                  << Observe(Phase::InitErrorDescription, [&] { return vr::VR_GetVRInitErrorAsEnglishDescription(error); }) << "\"}\n";
        return 2;
    }

    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> standing{};
    std::array<vr::TrackedDevicePose_t, vr::k_unMaxTrackedDeviceCount> raw{};
    Observe(Phase::StandingPose, [&] { system->GetDeviceToAbsoluteTrackingPose(
        vr::TrackingUniverseStanding, 0.0F, standing.data(), static_cast<std::uint32_t>(standing.size())); });
    Observe(Phase::RawPose, [&] { system->GetDeviceToAbsoluteTrackingPose(
        vr::TrackingUniverseRawAndUncalibrated, 0.0F, raw.data(), static_cast<std::uint32_t>(raw.size())); });
    const auto leftEye = Observe(Phase::LeftEye, [&] { return system->GetEyeToHeadTransform(vr::Eye_Left); });
    const auto rightEye = Observe(Phase::RightEye, [&] { return system->GetEyeToHeadTransform(vr::Eye_Right); });
    const auto dx = static_cast<double>(leftEye.m[0][3] - rightEye.m[0][3]);
    const auto dy = static_cast<double>(leftEye.m[1][3] - rightEye.m[1][3]);
    const auto dz = static_cast<double>(leftEye.m[2][3] - rightEye.m[2][3]);
    const auto eyeSeparation = std::sqrt(dx * dx + dy * dy + dz * dz);
    std::uint32_t renderWidth = 0;
    std::uint32_t renderHeight = 0;
    Observe(Phase::RenderTarget, [&] { system->GetRecommendedRenderTargetSize(&renderWidth, &renderHeight); });
    std::array<char, 4096> runtimePath{};
    std::uint32_t requiredRuntimePath = 0;
    const auto runtimePathAvailable = Observe(Phase::RuntimePath, [&] { return vr::VR_GetRuntimePath(
        runtimePath.data(), static_cast<std::uint32_t>(runtimePath.size()), &requiredRuntimePath); });
    const auto stereoValid = IsFiniteEyeTransform(leftEye) && IsFiniteEyeTransform(rightEye) &&
        eyeSeparation >= 0.01 && eyeSeparation <= 0.20 && renderWidth > 0 && renderHeight > 0 &&
        runtimePathAvailable && requiredRuntimePath > 1 && requiredRuntimePath <= runtimePath.size();
    const auto controllers = requireControllers ? CheckControllers(system) : ControllerCheck{};
    const auto qualified = stereoValid && (!requireControllers ||
        (ValidPose(standing[vr::k_unTrackedDeviceIndex_Hmd]) && controllers.valid));

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "{\"ok\":" << (qualified ? "true" : "false")
              << ",\"state\":\"pose-observed\",\"hmdIndex\":0,";
    PrintPose("standing", standing[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << ',';
    PrintPose("raw", raw[vr::k_unTrackedDeviceIndex_Hmd]);
    std::cout << ",\"stereo\":{";
    std::cout << "\"valid\":" << (stereoValid ? "true" : "false") << ',';
    std::cout << "\"leftEyeTranslation\":[" << leftEye.m[0][3] << ',' << leftEye.m[1][3] << ',' << leftEye.m[2][3] << "],";
    std::cout << "\"rightEyeTranslation\":[" << rightEye.m[0][3] << ',' << rightEye.m[1][3] << ',' << rightEye.m[2][3] << "],";
    std::cout << "\"eyeSeparationMeters\":" << eyeSeparation << ',';
    std::cout << "\"recommendedRenderTarget\":[" << renderWidth << ',' << renderHeight << "]},";
    std::cout << "\"runtimePath\":\"" << JsonEscape(runtimePath.data()) << "\"";
    std::cout << ",\"controllers\":{\"required\":" << (requireControllers ? "true" : "false")
              << ",\"valid\":" << (controllers.valid ? "true" : "false")
              << ",\"leftIndex\":" << controllers.left << ",\"rightIndex\":" << controllers.right
              << ",\"neutralSamples\":" << controllers.samples << ",\"inputEvents\":" << controllers.inputEvents
              << ",\"packetNumbers\":[" << controllers.packets[0] << ',' << controllers.packets[1] << "]}";
    if (diagnosticFailedRoles && requireControllers && !controllers.valid) {
        std::cout << ",\"failedRoleDiagnostics\":";
        try {
            std::ostringstream diagnostics;
            diagnostics << std::fixed << std::setprecision(6);
            PrintFailedRoleDiagnostics(system, diagnostics);
            const auto text = diagnostics.str();
            if (text.size() > 262144) { std::cout << "{\"diagnosticOnly\":true,\"error\":\"byte-budget-exceeded\"}"; }
            else { std::cout << text; }
        } catch (...) {
            std::cout << "{\"diagnosticOnly\":true,\"error\":\"collector-failed\"}";
        }
    }
    std::cout << "}\n";
    Observe(Phase::Shutdown, [] { vr::VR_Shutdown(); });
    return qualified ? 0 : 3;
}
