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
$raw = & $env:RACEMENU_SWEEP_DEVBENCH_SCRIPT call -Tool $Tool -ArgumentsJson $ArgumentsJson `
    -RuntimePath $RuntimePath -ExpectedRuntimeIdentityJson $ExpectedRuntimeIdentityJson `
    -RequireSuccess:$RequireSuccess -Compact:$Compact -NoExit:$NoExit `
    -MaxTransientRetries 0 -TimeoutSeconds $budget -RequestTimeoutSeconds $budget
$response = $raw | ConvertFrom-Json -Depth 100
# The installed generic semantic gate does not know Papyrus' called/returned
# contract. Qualify ONLY this sweep's exact UI methods, never generic failures.
# Observation tools have no Papyrus function/args contract. Preserve their
# upstream response without inspecting or qualifying it, including failures.
if ($Tool -cne 'papyrus') { $raw; return }
$request = $ArgumentsJson | ConvertFrom-Json -Depth 100
if ($null -eq $request -or $request -isnot [pscustomobject] -or
    -not $request.PSObject.Properties['action'] -or $request.action -isnot [string] -or
    $request.action -cne 'call' -or
    -not $request.PSObject.Properties['script'] -or $request.script -isnot [string] -or
    $request.script -cne 'UI' -or
    -not $request.PSObject.Properties['function'] -or $request.function -isnot [string] -or
    $request.function -cnotin @('InvokeIntA','InvokeFloatA','GetString') -or
    -not $request.PSObject.Properties['args'] -or $request.args -isnot [array] -or
    $request.args.Count -lt 2 -or $request.args[0] -isnot [string] -or
    $request.args[0] -cne 'RaceSex Menu' -or $request.args[1] -isnot [string]) {
    $raw; return
}
$owner = '_root.RaceSexMenuBaseInstance.RaceSexPanelsInstance.'
$allowedPaths = switch -CaseSensitive ($request.function) {
    'InvokeIntA' { ($owner + 'RefreshVRDiagnosticControls'); ($owner + 'SelectVRDiagnosticRace') }
    'InvokeFloatA' { ($owner + 'SetVRDiagnosticSlider'); ($owner + 'SelectVRDiagnosticSex') }
    'GetString' { ($owner + 'vrDiagnosticSnapshotJson'); ($owner + 'vrDiagnosticResultJson') }
    default { @() }
}
if ($null -ne $response -and $response.PSObject.Properties['ok'] -and
    $response.ok -is [bool] -and -not $response.ok -and $request.args[1] -cin $allowedPaths -and
    $response.PSObject.Properties['transportOk'] -and $response.transportOk -is [bool] -and $response.transportOk -and
    $response.PSObject.Properties['indeterminate'] -and $response.indeterminate -is [bool] -and -not $response.indeterminate -and
    $response.PSObject.Properties['semantic'] -and $null -ne $response.semantic -and
    $response.semantic.PSObject.Properties['known'] -and $response.semantic.known -is [bool] -and -not $response.semantic.known -and
    $response.PSObject.Properties['data'] -and $null -ne $response.data -and $response.data.PSObject.Properties['content'] -and
    -not [string]::IsNullOrWhiteSpace($ExpectedRuntimeIdentityJson)) {
    $content = @($response.data.content)
    if ($content.Count -eq 1 -and $null -ne $content[0] -and $content[0].PSObject.Properties['called'] -and
        $content[0].called -is [bool] -and $content[0].called -and
        $content[0].PSObject.Properties['returned'] -and
        $content[0].PSObject.Properties['returnedType'] -and
        $content[0].returnedType -is [string] -and
        -not [string]::IsNullOrWhiteSpace($content[0].returnedType) -and
        ($request.function -cne 'GetString' -or $content[0].returned -is [string])) {
        $original = $response | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
        # CaptureInteraction forwards content[0], not the enclosing wrapper.
        # Carry the unmodified envelope inside that forwarded result as well.
        $content[0] | Add-Member -NotePropertyName originalControllerEnvelope -NotePropertyValue $original -Force
        $response | Add-Member -NotePropertyName originalControllerEnvelope -NotePropertyValue $original -Force
        $response.ok = $true
        $response.errors = @()
        $response.semantic = [pscustomobject]@{
            known=$true; ok=$true; outcome='sweep-ui-papyrus-return-qualified'
            completionBasis='papyrus-return-only'; reasons=@()
        }
    }
}
$response | ConvertTo-Json -Depth 100 -Compress
