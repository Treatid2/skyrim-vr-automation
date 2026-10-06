// SPDX-License-Identifier: GPL-3.0-or-later
// Acceptance-process-local memory atomics; never installed in SteamVR.
#include <Windows.h>
extern "C" __declspec(dllexport) LONG64 ReadSequence(volatile LONG64* field)
{
    return InterlockedCompareExchange64(field, 0, 0);
}
extern "C" __declspec(dllexport) LONG64 WriteSequence(volatile LONG64* field, LONG64 value)
{
    return InterlockedExchange64(field, value);
}
