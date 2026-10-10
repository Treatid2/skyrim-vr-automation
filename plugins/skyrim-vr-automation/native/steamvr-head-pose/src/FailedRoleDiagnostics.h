// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "controller_protocol.h"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cstring>
#include <ostream>

namespace csx::probe {
// Pure formatting seam for host tests; caller proves snapshot stability first.
inline void PrintControllerSnapshot(std::ostream& output,
    const controllers::Shared& snapshot, bool stable, bool protocol, bool cleanup)
{
    output << "{\"available\":true,\"stable\":" << (stable ? "true" : "false")
              << ",\"protocolValid\":" << (protocol ? "true" : "false")
              << ",\"cleanupVerified\":" << (cleanup ? "true" : "false");
    if (stable && protocol) {
        output << ",\"driverCreatorPid\":" << snapshot.driverCreatorPid
                  << ",\"driverStartedFileTimeUtc\":" << snapshot.driverStartedFileTimeUtc
                  << ",\"driverNonce\":" << snapshot.driverNonce
                  << ",\"telemetrySequence\":" << snapshot.telemetrySequence
                  << ",\"inputHealthy\":" << snapshot.inputHealthy
                  << ",\"status\":" << snapshot.status
                  << ",\"appliedSequence\":" << snapshot.appliedSequence;
    }
    output << '}';
}
// Diagnostic only, never an admission predicate. No writes/commands or retry.
inline void PrintControllerChannel(std::ostream& output)
{
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, controllers::MappingName);
    if (!mapping) { output << "{\"available\":false,\"win32Error\":" << GetLastError() << '}'; return; }
    const void* view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(controllers::Shared));
    if (!view) { const auto error = GetLastError(); CloseHandle(mapping); output << "{\"available\":false,\"win32Error\":" << error << '}'; return; }
    controllers::Shared snapshot{}; bool stable = false; SIZE_T read = 0;
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        std::uint64_t before = 0, after = 0;
        const auto sequence = static_cast<const char*>(view) + offsetof(controllers::Shared, telemetrySequence);
        if (!ReadProcessMemory(GetCurrentProcess(), sequence, &before, sizeof(before), &read) || read != sizeof(before) || (before & 1)) { continue; }
        if (!ReadProcessMemory(GetCurrentProcess(), view, &snapshot, sizeof(snapshot), &read) || read != sizeof(snapshot)) { continue; }
        if (!ReadProcessMemory(GetCurrentProcess(), sequence, &after, sizeof(after), &read) || read != sizeof(after)) { continue; }
        stable = before == after && snapshot.telemetrySequence == before && !(after & 1);
        if (stable) { break; }
    }
    const bool protocol = snapshot.magic == controllers::Magic && snapshot.version == controllers::Version && snapshot.size == sizeof(snapshot);
    const bool unmapped = UnmapViewOfFile(view) != FALSE;
    const bool closed = CloseHandle(mapping) != FALSE;
    PrintControllerSnapshot(output, snapshot, stable, protocol, unmapped && closed);
}
}
