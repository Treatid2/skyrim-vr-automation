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
$request = $ArgumentsJson | ConvertFrom-Json
$owner = '_root.RaceSexMenuBaseInstance.RaceSexPanelsInstance.'
$allowedPaths = switch -CaseSensitive ($request.function) {
    'InvokeIntA' { ($owner + 'RefreshVRDiagnosticControls'); ($owner + 'SelectVRDiagnosticRace') }
    'InvokeFloatA' { ($owner + 'SetVRDiagnosticSlider'); ($owner + 'SelectVRDiagnosticSex') }
    'GetString' { ($owner + 'vrDiagnosticSnapshotJson'); ($owner + 'vrDiagnosticResultJson') }
    default { @() }
}
if (-not $response.ok -and $Tool -ceq 'papyrus' -and
    $request.action -ceq 'call' -and $request.script -ceq 'UI' -and
    $request.function -cin @('InvokeIntA','InvokeFloatA','GetString') -and
    @($request.args).Count -ge 2 -and $request.args[0] -ceq 'RaceSex Menu' -and
    $request.args[1] -cin $allowedPaths -and
    $response.PSObject.Properties['transportOk'] -and $response.transportOk -eq $true -and
    $response.PSObject.Properties['indeterminate'] -and $response.indeterminate -eq $false -and
    $response.PSObject.Properties['semantic'] -and $response.semantic.known -eq $false -and
    -not [string]::IsNullOrWhiteSpace($ExpectedRuntimeIdentityJson)) {
    $content = @($response.data.content)
    if ($content.Count -eq 1 -and $content[0].PSObject.Properties['called'] -and
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
