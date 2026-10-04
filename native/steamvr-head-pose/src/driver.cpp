// SPDX-License-Identifier: GPL-3.0-or-later

#include <openvr_driver.h>

#include <Windows.h>
#include <bcrypt.h>
#include <sddl.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>

#pragma comment(lib, "Bcrypt.lib")
#pragma comment(lib, "Advapi32.lib")

namespace {

constexpr char kSettingsSection[] = "driver_codex_head_pose";
constexpr char kDefaultSerial[] = "CSX-NULL-HMD-POSE-1";
constexpr char kDefaultModel[] = "CSX Synthetic Head Pose";
constexpr wchar_t kPoseMapName[] = L"Local\\CSXVRHeadPose-v2";
constexpr std::uint32_t kPoseMagic = 0x48505343;  // "CSPH" in little endian.
constexpr std::uint16_t kPoseVersion = 2;
constexpr std::uint32_t kPoseEnabled = 1U << 0U;
constexpr std::uint32_t kPoseStatusWaiting = 0;
constexpr std::uint32_t kPoseStatusApplied = 1;
constexpr std::uint32_t kPoseStatusRejected = 2;
constexpr double kPi = 3.14159265358979323846;

struct alignas(8) SharedPoseState {
    std::uint32_t magic;
    std::uint16_t version;
    std::uint16_t size;
    volatile LONG64 requestedSequence;
    volatile LONG64 appliedSequence;
    volatile LONG status;
    std::uint32_t flags;
    double positionX;
    double positionY;
    double positionZ;
    double quaternionW;
    double quaternionX;
    double quaternionY;
    double quaternionZ;
    std::uint64_t writerNonce;
    std::uint64_t acknowledgedWriterNonce;
    std::uint64_t driverInstanceNonce;
    std::uint32_t driverCreatorPid;
    std::uint32_t reserved;
    std::uint64_t driverStartedFileTimeUtc;
};

static_assert(sizeof(SharedPoseState) == 128);
static_assert(offsetof(SharedPoseState, requestedSequence) == 8);
static_assert(offsetof(SharedPoseState, appliedSequence) == 16);

std::uint64_t AtomicRead(const volatile LONG64& value)
{
    return static_cast<std::uint64_t>(InterlockedCompareExchange64(
        const_cast<volatile LONG64*>(&value), 0, 0));
}

void AtomicWrite(volatile LONG64& target, std::uint64_t value)
{
    InterlockedExchange64(&target, static_cast<LONG64>(value));
}

std::uint64_t NewNonce()
{
    std::uint64_t value = 0;
    while (value == 0) {
        if (BCryptGenRandom(
                nullptr,
                reinterpret_cast<PUCHAR>(&value),
                static_cast<ULONG>(sizeof(value)),
                BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
            return 0;
        }
    }
    return value;
}

std::uint64_t CurrentFileTimeUtc()
{
    FILETIME time{};
    GetSystemTimeAsFileTime(&time);
    ULARGE_INTEGER value{};
    value.LowPart = time.dwLowDateTime;
    value.HighPart = time.dwHighDateTime;
    return value.QuadPart;
}

struct PoseValue {
    std::array<double, 3> position{0.0, 1.68, 0.0};
    std::array<double, 4> quaternion{1.0, 0.0, 0.0, 0.0};
    bool enabled{true};
};

vr::HmdQuaternion_t Quaternion(double w, double x, double y, double z)
{
    return vr::HmdQuaternion_t{w, x, y, z};
}

std::array<double, 4> QuaternionFromEulerDegrees(double yaw, double pitch, double roll)
{
    const auto halfYaw = yaw * kPi / 360.0;
    const auto halfPitch = pitch * kPi / 360.0;
    const auto halfRoll = roll * kPi / 360.0;
    const auto cy = std::cos(halfYaw);
    const auto sy = std::sin(halfYaw);
    const auto cp = std::cos(halfPitch);
    const auto sp = std::sin(halfPitch);
    const auto cr = std::cos(halfRoll);
    const auto sr = std::sin(halfRoll);

    // Intrinsic yaw (Y), pitch (X), roll (Z).
    return {
        cy * cp * cr + sy * sp * sr,
        cy * sp * cr + sy * cp * sr,
        sy * cp * cr - cy * sp * sr,
        cy * cp * sr - sy * sp * cr,
    };
}

bool IsFinitePose(const PoseValue& pose)
{
    for (const auto value : pose.position) {
        if (!std::isfinite(value) || std::abs(value) > 1000.0) {
            return false;
        }
    }
    double normSquared = 0.0;
    for (const auto value : pose.quaternion) {
        if (!std::isfinite(value)) {
            return false;
        }
        normSquared += value * value;
    }
    return normSquared > 0.25 && normSquared < 4.0;
}

void NormalizeQuaternion(PoseValue& pose)
{
    double normSquared = 0.0;
    for (const auto value : pose.quaternion) {
        normSquared += value * value;
    }
    const auto inverseNorm = 1.0 / std::sqrt(normSquared);
    for (auto& value : pose.quaternion) {
        value *= inverseNorm;
    }
}

void Log(const std::string& message)
{
    if (auto* logger = vr::VRDriverLog()) {
        logger->Log(("codex_head_pose: " + message + "\n").c_str());
    }
}

std::string ReadStringSetting(const char* key, const char* fallback)
{
    char buffer[1024]{};
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    vr::VRSettings()->GetString(kSettingsSection, key, buffer, sizeof(buffer), &error);
    return error == vr::VRSettingsError_None && buffer[0] != '\0' ? buffer : fallback;
}

double ReadFloatSetting(const char* key, double fallback)
{
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    const auto value = vr::VRSettings()->GetFloat(kSettingsSection, key, &error);
    return error == vr::VRSettingsError_None && std::isfinite(value) ? value : fallback;
}

bool ReadBoolSetting(const char* key, bool fallback)
{
    vr::EVRSettingsError error = vr::VRSettingsError_None;
    const auto value = vr::VRSettings()->GetBool(kSettingsSection, key, &error);
    return error == vr::VRSettingsError_None ? value : fallback;
}

class SharedPoseChannel {
public:
    ~SharedPoseChannel()
    {
        if (state_) {
            UnmapViewOfFile(state_);
        }
        if (mapping_) {
            CloseHandle(mapping_);
        }
    }

    bool Initialize(const PoseValue& initialPose)
    {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:P(A;;GA;;;OW)", SDDL_REVISION_1, &descriptor, nullptr)) {
            Log("owner-only security descriptor creation failed with Win32 error " +
                std::to_string(GetLastError()));
            return false;
        }
        SECURITY_ATTRIBUTES security{};
        security.nLength = sizeof(security);
        security.lpSecurityDescriptor = descriptor;
        security.bInheritHandle = FALSE;
        mapping_ = CreateFileMappingW(
            INVALID_HANDLE_VALUE,
            &security,
            PAGE_READWRITE,
            0,
            static_cast<DWORD>(sizeof(SharedPoseState)),
            kPoseMapName);
        const auto createError = GetLastError();
        LocalFree(descriptor);
        if (!mapping_) {
            Log("CreateFileMappingW failed with Win32 error " + std::to_string(GetLastError()));
            return false;
        }
        const auto existed = createError == ERROR_ALREADY_EXISTS;
        if (existed) {
            Log("refusing a pre-existing shared pose mapping without a current driver ownership handshake");
            CloseHandle(mapping_);
            mapping_ = nullptr;
            return false;
        }
        state_ = static_cast<SharedPoseState*>(
            MapViewOfFile(mapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(SharedPoseState)));
        if (!state_) {
            Log("MapViewOfFile failed with Win32 error " + std::to_string(GetLastError()));
            return false;
        }

        const auto instanceNonce = NewNonce();
        const auto initialWriterNonce = NewNonce();
        if (instanceNonce == 0 || initialWriterNonce == 0) {
            Log("cryptographic nonce generation failed");
            return false;
        }
        std::memset(state_, 0, sizeof(SharedPoseState));
        state_->magic = kPoseMagic;
        state_->version = kPoseVersion;
        state_->size = sizeof(SharedPoseState);
        state_->driverInstanceNonce = instanceNonce;
        state_->driverCreatorPid = GetCurrentProcessId();
        state_->driverStartedFileTimeUtc = CurrentFileTimeUtc();
        AtomicWrite(state_->requestedSequence, 1);
        WritePose(initialPose);
        state_->writerNonce = initialWriterNonce;
        state_->acknowledgedWriterNonce = initialWriterNonce;
        InterlockedExchange(&state_->status, kPoseStatusApplied);
        AtomicWrite(state_->appliedSequence, 2);
        AtomicWrite(state_->requestedSequence, 2);
        return true;
    }

    bool ReadPending(PoseValue& value, std::uint64_t& sequence)
    {
        if (!state_) {
            return false;
        }
        const auto first = AtomicRead(state_->requestedSequence);
        if (first == 0 || (first & 1U) != 0 || first == AtomicRead(state_->appliedSequence)) {
            return false;
        }

        value.enabled = (state_->flags & kPoseEnabled) != 0;
        value.position = {state_->positionX, state_->positionY, state_->positionZ};
        value.quaternion = {
            state_->quaternionW,
            state_->quaternionX,
            state_->quaternionY,
            state_->quaternionZ,
        };
        const auto writerNonce = state_->writerNonce;
        MemoryBarrier();
        const auto second = AtomicRead(state_->requestedSequence);
        if (first != second || (second & 1U) != 0 || writerNonce == 0) {
            return false;
        }
        sequence = second;
        writerNonce_ = writerNonce;
        return true;
    }

    void Acknowledge(std::uint64_t sequence, bool accepted)
    {
        if (!state_) {
            return;
        }
        state_->acknowledgedWriterNonce = writerNonce_;
        InterlockedExchange(&state_->status, accepted ? kPoseStatusApplied : kPoseStatusRejected);
        AtomicWrite(state_->appliedSequence, sequence);
    }

private:
    void WritePose(const PoseValue& pose)
    {
        state_->flags = pose.enabled ? kPoseEnabled : 0;
        state_->positionX = pose.position[0];
        state_->positionY = pose.position[1];
        state_->positionZ = pose.position[2];
        state_->quaternionW = pose.quaternion[0];
        state_->quaternionX = pose.quaternion[1];
        state_->quaternionY = pose.quaternion[2];
        state_->quaternionZ = pose.quaternion[3];
    }

    HANDLE mapping_{nullptr};
    SharedPoseState* state_{nullptr};
    std::uint64_t writerNonce_{0};
};

class HeadPoseDevice final : public vr::ITrackedDeviceServerDriver {
public:
    HeadPoseDevice(std::string serial, std::string model, PoseValue initialPose) :
        serial_(std::move(serial)), model_(std::move(model)), pose_(initialPose)
    {}

    vr::EVRInitError Activate(vr::TrackedDeviceIndex_t objectId) override
    {
        objectId_ = objectId;
        const auto properties = vr::VRProperties()->TrackedDeviceToPropertyContainer(objectId_);
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_ModelNumber_String, model_.c_str());
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_RenderModelName_String, "generic_hmd");
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_TrackingSystemName_String, "codex_head_pose");
        vr::VRProperties()->SetStringProperty(properties, vr::Prop_ManufacturerName_String, "Treatid2");
        vr::VRProperties()->SetBoolProperty(properties, vr::Prop_NeverTracked_Bool, false);
        vr::VRProperties()->SetBoolProperty(properties, vr::Prop_DeviceProvidesBatteryStatus_Bool, false);
        vr::VRProperties()->SetUint64Property(properties, vr::Prop_CurrentUniverseId_Uint64, 2);

        if (!channel_.Initialize(pose_)) {
            return vr::VRInitError_Driver_Failed;
        }
        Log("activated device " + serial_ + " with owner-only shared-memory contract Local\\CSXVRHeadPose-v2");
        return vr::VRInitError_None;
    }

    void Deactivate() override { objectId_ = vr::k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() override {}
    void* GetComponent(const char*) override { return nullptr; }

    void DebugRequest(const char*, char* response, std::uint32_t responseSize) override
    {
        if (response && responseSize > 0) {
            response[0] = '\0';
        }
    }

    vr::DriverPose_t GetPose() override
    {
        vr::DriverPose_t result{};
        result.qWorldFromDriverRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        result.qDriverFromHeadRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        result.qRotation = Quaternion(
            pose_.quaternion[0], pose_.quaternion[1], pose_.quaternion[2], pose_.quaternion[3]);
        result.vecPosition[0] = pose_.position[0];
        result.vecPosition[1] = pose_.position[1];
        result.vecPosition[2] = pose_.position[2];
        result.result = vr::TrackingResult_Running_OK;
        result.poseIsValid = pose_.enabled;
        result.deviceIsConnected = true;
        result.shouldApplyHeadModel = false;
        return result;
    }

    void RunFrame()
    {
        PoseValue candidate{};
        std::uint64_t sequence = 0;
        if (channel_.ReadPending(candidate, sequence)) {
            const auto accepted = IsFinitePose(candidate);
            if (accepted) {
                NormalizeQuaternion(candidate);
                pose_ = candidate;
            }
            channel_.Acknowledge(sequence, accepted);
            Log(std::string(accepted ? "applied" : "rejected") + " pose sequence " +
                std::to_string(sequence));
        }
        if (objectId_ != vr::k_unTrackedDeviceIndexInvalid) {
            vr::VRServerDriverHost()->TrackedDevicePoseUpdated(objectId_, GetPose(), sizeof(vr::DriverPose_t));
        }
    }

    const std::string& Serial() const { return serial_; }

private:
    vr::TrackedDeviceIndex_t objectId_{vr::k_unTrackedDeviceIndexInvalid};
    std::string serial_;
    std::string model_;
    PoseValue pose_;
    SharedPoseChannel channel_;
};

// These devices supply the legacy roles/poses used by VR Tools. They have no
// command channel: all input remains neutral for the lifetime of the device.
class PassiveControllerDevice final : public vr::ITrackedDeviceServerDriver {
public:
    explicit PassiveControllerDevice(vr::ETrackedControllerRole role) : role_(role) {}

    const char* Serial() const
    {
        return role_ == vr::TrackedControllerRole_LeftHand ?
            "CSX-NULL-CONTROLLER-LEFT-1" : "CSX-NULL-CONTROLLER-RIGHT-1";
    }

    vr::EVRInitError Activate(vr::TrackedDeviceIndex_t objectId) override
    {
        const auto properties = vr::VRProperties()->TrackedDeviceToPropertyContainer(objectId);
        auto* props = vr::VRProperties();
        bool valid = true;
        const auto check = [&valid](vr::ETrackedPropertyError error) {
            valid = valid && error == vr::TrackedProp_Success;
        };
        check(props->SetInt32Property(properties, vr::Prop_ControllerRoleHint_Int32, role_));
        check(props->SetStringProperty(properties, vr::Prop_ControllerType_String, "vive_controller"));
        check(props->SetStringProperty(properties, vr::Prop_InputProfilePath_String,
            "{codex_head_pose}/input/passive_controller_profile.json"));
        check(props->SetStringProperty(properties, vr::Prop_ModelNumber_String, "CSX Passive Controller"));
        check(props->SetStringProperty(properties, vr::Prop_RenderModelName_String, "vr_controller_vive_1_5"));
        check(props->SetStringProperty(properties, vr::Prop_TrackingSystemName_String, "codex_head_pose"));
        check(props->SetStringProperty(properties, vr::Prop_ManufacturerName_String, "Treatid2"));
        check(props->SetUint64Property(properties, vr::Prop_CurrentUniverseId_Uint64, 2));
        check(props->SetBoolProperty(properties, vr::Prop_NeverTracked_Bool, false));
        check(props->SetBoolProperty(properties, vr::Prop_DeviceProvidesBatteryStatus_Bool, false));
        check(props->SetInt32Property(properties, vr::Prop_Axis0Type_Int32, vr::k_eControllerAxis_TrackPad));
        check(props->SetInt32Property(properties, vr::Prop_Axis1Type_Int32, vr::k_eControllerAxis_Trigger));
        check(props->SetUint64Property(properties, vr::Prop_SupportedButtons_Uint64,
            vr::ButtonMaskFromId(vr::k_EButton_System) |
            vr::ButtonMaskFromId(vr::k_EButton_ApplicationMenu) |
            vr::ButtonMaskFromId(vr::k_EButton_Grip) |
            vr::ButtonMaskFromId(vr::k_EButton_SteamVR_Touchpad) |
            vr::ButtonMaskFromId(vr::k_EButton_SteamVR_Trigger)));
        auto* input = vr::VRDriverInput();
        for (std::size_t i = 0; i < booleanPaths_.size(); ++i) {
            valid = (input->CreateBooleanComponent(properties, booleanPaths_[i], &booleans_[i]) ==
                vr::VRInputError_None) && valid;
        }
        for (std::size_t i = 0; i < scalarPaths_.size(); ++i) {
            valid = (input->CreateScalarComponent(properties, scalarPaths_[i], &scalars_[i],
                vr::VRScalarType_Absolute, i == 2 ? vr::VRScalarUnits_NormalizedOneSided :
                vr::VRScalarUnits_NormalizedTwoSided) == vr::VRInputError_None) && valid;
        }
        valid = (input->CreateHapticComponent(properties, "/output/haptic", &haptic_) ==
            vr::VRInputError_None) && valid;
        if (!valid || !PublishNeutralInputs()) {
            Log(std::string("failed to activate passive controller ") + Serial());
            return vr::VRInitError_Driver_Failed;
        }
        objectId_ = objectId;
        Log(std::string("activated passive controller ") + Serial());
        return vr::VRInitError_None;
    }

    void Deactivate() override { objectId_ = vr::k_unTrackedDeviceIndexInvalid; }
    void EnterStandby() override {}
    void* GetComponent(const char*) override { return nullptr; }
    void DebugRequest(const char*, char* response, std::uint32_t size) override
    {
        if (response && size > 0) { response[0] = '\0'; }
    }

    vr::DriverPose_t GetPose() override
    {
        vr::DriverPose_t pose{};
        pose.qWorldFromDriverRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        pose.qDriverFromHeadRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        pose.qRotation = Quaternion(1.0, 0.0, 0.0, 0.0);
        pose.vecPosition[0] = role_ == vr::TrackedControllerRole_LeftHand ? -0.25 : 0.25;
        pose.vecPosition[1] = 1.25;
        pose.vecPosition[2] = -0.35;
        pose.result = vr::TrackingResult_Running_OK;
        pose.deviceIsConnected = objectId_ != vr::k_unTrackedDeviceIndexInvalid;
        pose.poseIsValid = pose.deviceIsConnected && inputHealthy_;
        return pose;
    }

    void RunFrame()
    {
        if (objectId_ != vr::k_unTrackedDeviceIndexInvalid) {
            // Repeated false/zero updates never synthesize a press or touch.
            inputHealthy_ = PublishNeutralInputs();
            vr::VRServerDriverHost()->TrackedDevicePoseUpdated(objectId_, GetPose(), sizeof(vr::DriverPose_t));
        }
    }

private:
    bool PublishNeutralInputs()
    {
        bool valid = true;
        for (const auto handle : booleans_) {
            valid = (vr::VRDriverInput()->UpdateBooleanComponent(handle, false, 0.0) ==
                vr::VRInputError_None) && valid;
        }
        for (const auto handle : scalars_) {
            valid = (vr::VRDriverInput()->UpdateScalarComponent(handle, 0.0F, 0.0) ==
                vr::VRInputError_None) && valid;
        }
        return valid;
    }

    inline static constexpr std::array<const char*, 6> booleanPaths_{
        "/input/system/click", "/input/application_menu/click", "/input/grip/click",
        "/input/trackpad/click", "/input/trackpad/touch", "/input/trigger/click"};
    inline static constexpr std::array<const char*, 3> scalarPaths_{
        "/input/trackpad/x", "/input/trackpad/y", "/input/trigger/value"};
    vr::ETrackedControllerRole role_;
    vr::TrackedDeviceIndex_t objectId_{vr::k_unTrackedDeviceIndexInvalid};
    std::array<vr::VRInputComponentHandle_t, 6> booleans_{};
    std::array<vr::VRInputComponentHandle_t, 3> scalars_{};
    vr::VRInputComponentHandle_t haptic_{};
    bool inputHealthy_{true};
};

class HeadPoseProvider final : public vr::IServerTrackedDeviceProvider {
public:
    vr::EVRInitError Init(vr::IVRDriverContext* context) override
    {
        VR_INIT_SERVER_DRIVER_CONTEXT(context);
        if (!ReadBoolSetting("enable", false)) {
            Log("disabled by driver_codex_head_pose.enable");
            return vr::VRInitError_None;
        }

        PoseValue initial{};
        initial.position = {
            ReadFloatSetting("positionX", 0.0),
            ReadFloatSetting("eyeHeightMeters", 1.68),
            ReadFloatSetting("positionZ", 0.0),
        };
        initial.quaternion = QuaternionFromEulerDegrees(
            ReadFloatSetting("yawDegrees", 0.0),
            ReadFloatSetting("pitchDegrees", 0.0),
            ReadFloatSetting("rollDegrees", 0.0));
        if (!IsFinitePose(initial)) {
            Log("initial pose settings are invalid");
            return vr::VRInitError_Driver_Failed;
        }
        NormalizeQuaternion(initial);

        device_ = std::make_unique<HeadPoseDevice>(
            ReadStringSetting("serialNumber", kDefaultSerial),
            ReadStringSetting("modelNumber", kDefaultModel),
            initial);
        if (!vr::VRServerDriverHost()->TrackedDeviceAdded(
                device_->Serial().c_str(), vr::TrackedDeviceClass_GenericTracker, device_.get())) {
            Log("TrackedDeviceAdded rejected the synthetic head-pose device");
            device_.reset();
            return vr::VRInitError_Driver_Failed;
        }
        Log("registered synthetic head-pose device at configured standing pose");
        if (ReadBoolSetting("enableControllers", false)) {
            controllers_[0] = std::make_unique<PassiveControllerDevice>(vr::TrackedControllerRole_LeftHand);
            controllers_[1] = std::make_unique<PassiveControllerDevice>(vr::TrackedControllerRole_RightHand);
            for (auto& controller : controllers_) {
                if (!vr::VRServerDriverHost()->TrackedDeviceAdded(controller->Serial(),
                        vr::TrackedDeviceClass_Controller, controller.get())) {
                    Log("passive controller registration failed; pair is unqualified");
                    // Keep accepted objects alive until runtime Cleanup, including
                    // partial admission. The application probe rejects a missing hand.
                    return vr::VRInitError_Driver_Failed;
                }
            }
            Log("registered passive left/right controller pair");
        }
        return vr::VRInitError_None;
    }

    void Cleanup() override
    {
        for (auto& controller : controllers_) { controller.reset(); }
        device_.reset();
        vr::CleanupDriverContext();
    }

    const char* const* GetInterfaceVersions() override { return vr::k_InterfaceVersions; }
    void RunFrame() override
    {
        if (device_) {
            device_->RunFrame();
        }
        for (auto& controller : controllers_) {
            if (controller) { controller->RunFrame(); }
        }
    }
    bool ShouldBlockStandbyMode() override { return false; }
    void EnterStandby() override {}
    void LeaveStandby() override {}

private:
    std::unique_ptr<HeadPoseDevice> device_;
    std::array<std::unique_ptr<PassiveControllerDevice>, 2> controllers_;
};

HeadPoseProvider g_provider;

}  // namespace

#define HMD_DLL_EXPORT extern "C" __declspec(dllexport)

HMD_DLL_EXPORT void* HmdDriverFactory(const char* interfaceName, int* returnCode)
{
    if (std::strcmp(vr::IServerTrackedDeviceProvider_Version, interfaceName) == 0) {
        return &g_provider;
    }
    if (returnCode) {
        *returnCode = vr::VRInitError_Init_InterfaceNotFound;
    }
    return nullptr;
}
