# Standalone acceptance atomics helper

Python ctypes cannot call InterlockedExchange64/CompareExchange64 from kernel32
on this Windows x64 host: they are compiler intrinsics, not exported functions.
This tiny DLL provides those two documented operations for the independent
controller-protocol acceptance client. It is compiled by Build Broker from this
exact committed subtree, separately from the provider and controller tests.
It is never installed in SteamVR, packaged as a driver dependency, or executed
by Broker. Requester verifies hash/exports before loading it in its acceptance
process. Pointers must reference aligned fields in that process's mapped view.
No allocation, process access, driver factory or autonomous worker is provided.
