# SPDX-License-Identifier: GPL-3.0-or-later
# A policy adapter, not a transport. CaptureInteraction remains the call owner.
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('call')][string]$Command,
    [string]$Tool, [string]$ArgumentsJson, [string]$RuntimePath,
    [string]$ExpectedRuntimeIdentityJson,
    [switch]$RequireSuccess, [switch]$Compact, [switch]$NoExit
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($env:RACEMENU_SWEEP_DEVBENCH_SCRIPT) -or
    [string]::IsNullOrWhiteSpace($env:RACEMENU_SWEEP_DEADLINE_UTC)) {
    throw 'This adapter must be invoked by the bounded RaceMenu sweep.'
}
$remaining = ([DateTimeOffset]::Parse($env:RACEMENU_SWEEP_DEADLINE_UTC) - [DateTimeOffset]::UtcNow).TotalSeconds
if ($remaining -le 0) { throw 'Sweep call deadline expired before dispatch.' }
$budget = [Math]::Max(1, [Math]::Min(30, [Math]::Ceiling($remaining)))
& $env:RACEMENU_SWEEP_DEVBENCH_SCRIPT call -Tool $Tool -ArgumentsJson $ArgumentsJson `
    -RuntimePath $RuntimePath -ExpectedRuntimeIdentityJson $ExpectedRuntimeIdentityJson `
    -RequireSuccess:$RequireSuccess -Compact:$Compact -NoExit:$NoExit `
    -MaxTransientRetries 0 -TimeoutSeconds $budget -RequestTimeoutSeconds $budget
