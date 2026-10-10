cmake_minimum_required(VERSION 3.24)

project(csx_steamvr_head_pose LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "The CSX SteamVR head-pose provider currently supports Windows only.")
endif()

set(CSX_OPENVR_SDK_ROOT "" CACHE PATH "Path to a pinned OpenVR SDK checkout")
if(CSX_OPENVR_SDK_ROOT)
  set(_openvr_root "${CSX_OPENVR_SDK_ROOT}")
else()
  include(FetchContent)
  FetchContent_Declare(
    openvr
    GIT_REPOSITORY https://github.com/ValveSoftware/openvr.git
    GIT_TAG 0924064316de3effbcd1acf1e309182a2deb1c05
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR _csx_header_only
  )
  FetchContent_MakeAvailable(openvr)
  set(_openvr_root "${openvr_SOURCE_DIR}")
endif()
set(_openvr_include "${_openvr_root}/headers")

if(NOT EXISTS "${_openvr_include}/openvr_driver.h")
  message(FATAL_ERROR "openvr_driver.h was not found under ${_openvr_include}")
endif()

add_library(driver_codex_head_pose SHARED src/driver.cpp)
target_compile_features(driver_codex_head_pose PRIVATE cxx_std_20)
target_include_directories(driver_codex_head_pose PRIVATE "${_openvr_include}")
target_compile_definitions(driver_codex_head_pose PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)

if(MSVC)
  target_compile_options(driver_codex_head_pose PRIVATE /W4 /permissive- /EHsc)
endif()

set_target_properties(driver_codex_head_pose PROPERTIES
  PREFIX ""
  OUTPUT_NAME "driver_codex_head_pose"
)

find_library(_openvr_api_library NAMES openvr_api PATHS "${_openvr_root}/lib/win64" NO_DEFAULT_PATH REQUIRED)
find_file(_openvr_api_dll NAMES openvr_api.dll PATHS "${_openvr_root}/bin/win64" NO_DEFAULT_PATH REQUIRED)
add_executable(csx_openvr_pose_probe src/probe.cpp)
target_compile_features(csx_openvr_pose_probe PRIVATE cxx_std_20)
target_include_directories(csx_openvr_pose_probe PRIVATE "${_openvr_include}")
target_link_libraries(csx_openvr_pose_probe PRIVATE "${_openvr_api_library}")
if(MSVC)
  target_compile_options(csx_openvr_pose_probe PRIVATE /W4 /permissive- /EHsc)
endif()

add_executable(csx_controller_tests EXCLUDE_FROM_ALL src/controller_tests.cpp)
add_executable(csx_probe_phase_tests EXCLUDE_FROM_ALL src/probe_phase_tests.cpp)
target_compile_features(csx_probe_phase_tests PRIVATE cxx_std_20)
if(MSVC)
  target_compile_options(csx_probe_phase_tests PRIVATE /W4 /permissive- /EHsc)
endif()
target_compile_features(csx_controller_tests PRIVATE cxx_std_20)
if(MSVC)
  target_compile_options(csx_controller_tests PRIVATE /W4 /permissive- /EHsc)
endif()

set(_package_root "${CMAKE_BINARY_DIR}/package/codex_head_pose")
add_custom_command(TARGET driver_codex_head_pose POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_package_root}/bin/win64"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_package_root}/resources/settings"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_package_root}/resources/input"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "$<TARGET_FILE:driver_codex_head_pose>"
          "${_package_root}/bin/win64/driver_codex_head_pose.dll"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/driver.vrdrivermanifest"
          "${_package_root}/driver.vrdrivermanifest"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/resources/settings/default.vrsettings"
          "${_package_root}/resources/settings/default.vrsettings"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/resources/input/passive_controller_profile.json"
          "${_package_root}/resources/input/passive_controller_profile.json"
  VERBATIM
)

add_custom_command(TARGET csx_openvr_pose_probe POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_package_root}/tools"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${_package_root}/licenses"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "$<TARGET_FILE:csx_openvr_pose_probe>"
          "${_package_root}/tools/csx_openvr_pose_probe.exe"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${_openvr_api_dll}"
          "${_package_root}/tools/openvr_api.dll"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${_openvr_root}/LICENSE"
          "${_package_root}/licenses/OpenVR-LICENSE.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/licenses/VMT-LICENSE.txt"
          "${_package_root}/licenses/VMT-LICENSE.txt"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/THIRD-PARTY.md"
          "${_package_root}/licenses/THIRD-PARTY.md"
  VERBATIM
)

message(STATUS "CSX SteamVR head-pose package: ${_package_root}")
