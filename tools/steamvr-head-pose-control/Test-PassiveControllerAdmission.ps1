# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-passive-controller-admission-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($fixture)).StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped OS temp.' }
New-Item -ItemType Directory -Path $fixture | Out-Null
$probe = Join-Path $fixture 'probe-fixture.exe'
$payloadPath = Join-Path $fixture 'payload.json'
$stub = Join-Path $fixture 'bounded-fixture.ps1'
[IO.File]::WriteAllText($probe, 'fixture only; never executed')
$stubText = @'
param($FilePath, [string[]]$ArgumentList, $WorkingDirectory, $MaxAttempts, $TimeoutSeconds, $TerminationGraceMilliseconds, $StreamDrainGraceMilliseconds, $RetryPatterns, $EvidenceDirectory, [switch]$NoExit, [switch]$Compact)
[pscustomobject]@{
    ok = $true
    argumentsReceived = @($ArgumentList)
    attempts = @([pscustomobject]@{exitCode=0;timedOut=$false;stdout=[IO.File]::ReadAllText((Microsoft.PowerShell.Management\Join-Path $PSScriptRoot 'payload.json'))})
} | ConvertTo-Json -Depth 15 -Compress
'@
[IO.File]::WriteAllText($stub, $stubText)
function Assert-Controller([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Join-Path {
    param([Parameter(Position=0)][string]$Path, [Parameter(Position=1)][string]$ChildPath)
    if ($ChildPath -eq 'process-control\Invoke-BoundedProcess.ps1') { return $script:stub }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}
function Get-HashOrNull([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    return $null
}
function New-Payload {
    [pscustomobject]@{
        ok=$true
        standing=[pscustomobject]@{connected=$true;valid=$true;position=@(0,1.68,0)}
        stereo=[pscustomobject]@{valid=$true;eyeSeparationMeters=0.064}
        controllers=[pscustomobject]@{required=$true;valid=$true;leftIndex=1;rightIndex=2;neutralSamples=100;inputEvents=0}
    }
}
try {
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    foreach ($lane in @('head', 'null')) {
        $entry = if ($lane -eq 'head') { Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1' } else { Join-Path $repositoryRoot 'tools\steamvr-null-control\Invoke-SteamVRNullControl.ps1' }
        $parseErrors = $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$parseErrors)
        Assert-Controller (@($parseErrors).Count -eq 0) "$lane entry point parses"
        $functionNames = @('Test-PassiveControllerProbeObservation', $(if ($lane -eq 'head') { 'Invoke-PoseProbe' } else { 'Get-ApplicationHeadPose' }))
        foreach ($name in $functionNames) {
            $node = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true))[0]
            # AST extraction loses the declaration-file automatic variable;
            # bind it to the original entry-point directory, not this fixture.
            $declarationRoot = (Split-Path -Parent $entry).Replace("'", "''")
            Invoke-Expression ($node.Extent.Text.Replace('$PSScriptRoot', "'$declarationRoot'"))
        }
        foreach ($case in @('valid','missing','head-only','invalid','same-index','hmd-index','sentinel-index','out-of-range','short-sample','input-event','string-bool','string-index','fraction-index','missing-field')) {
            $payload = New-Payload
            switch ($case) {
                missing {$payload.PSObject.Properties.Remove('controllers')}
                head-only {$payload.controllers.required=$false}
                invalid {$payload.controllers.valid=$false}
                same-index {$payload.controllers.rightIndex=1}
                hmd-index {$payload.controllers.leftIndex=0}
                sentinel-index {$payload.controllers.rightIndex=4294967295}
                out-of-range {$payload.controllers.rightIndex=64}
                short-sample {$payload.controllers.neutralSamples=99}
                input-event {$payload.controllers.inputEvents=1}
                string-bool {$payload.controllers.valid='true'}
                string-index {$payload.controllers.rightIndex='2'}
                fraction-index {$payload.controllers.rightIndex=2.5}
                missing-field {$payload.controllers.PSObject.Properties.Remove('inputEvents')}
            }
            $expected = $case -eq 'valid'
            Assert-Controller ((Test-PassiveControllerProbeObservation $payload) -eq $expected) "$lane rejects incomplete/malformed/non-neutral controller proof: $case"
            [IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 10))
            $PoseProbePath=$probe; $InstallRoot=$fixture; $HeadPoseDriverRoot=$fixture
            $OpenVRPathsPath=$null; $EvidenceDirectory=$null; $ProbeTimeoutSeconds=10
            $MinimumEyeHeightMeters=1.0; $MaximumEyeHeightMeters=2.5; $RequireControllers=$true
            if ($lane -eq 'head') { $observation = Invoke-PoseProbe }
            else { $observation=Get-ApplicationHeadPose -Contract @{poseProbeRelativePath='probe-fixture.exe';minimumQualifiedEyeHeightMeters=1.0;maximumQualifiedEyeHeightMeters=2.5} }
            if (-not $observation.available) { throw "Fixture probe failed: $($observation | ConvertTo-Json -Depth 10 -Compress)" }
            $run = if ($lane -eq 'head') { $observation.boundedRun } else { $observation.boundedProcess }
            Assert-Controller ($observation.qualified -eq $expected) "$lane production probe function enforces controller gate: $case"
            Assert-Controller (@($run.argumentsReceived).Count -eq 1 -and $run.argumentsReceived[0] -ceq '--require-controllers') "$lane dispatches exact required-controller option"
        }
    }
    $RequireControllers=$false
    $legacy=New-Payload; $legacy.PSObject.Properties.Remove('controllers')
    [IO.File]::WriteAllText($payloadPath, ($legacy | ConvertTo-Json -Depth 10))
    $headOnly=Invoke-PoseProbe
    Assert-Controller ($headOnly.qualified -and @($headOnly.boundedRun.argumentsReceived).Count -eq 0) 'explicit standalone head-only probe preserves legacy diagnostics'
    $nullAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'tools\steamvr-null-control\Invoke-SteamVRNullControl.ps1'), [ref]$tokens, [ref]$parseErrors)
    $contractNode=@($nullAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RuntimeInputContract'}, $true))[0]
    Invoke-Expression $contractNode.Extent.Text
    $runtime=[pscustomobject]@{active=$true;headPoseReady=$true;controllersReady=$false}
    $contract=Get-RuntimeInputContract -BaseContract @{replayReady=$true} -Effective @{active=$true;controllerInactivitySuppressed=$true} -Runtime $runtime -ExternalDrivers @{errors=@();conflicts=@()}
    Assert-Controller (-not $contract.measurementReady -and -not $contract.controllerPresenceReady -and -not $contract.replayReady -and $contract.measurementBlockers -contains 'passive-controller-pair-not-qualified') 'head-only runtime cannot admit measurement or replay'
    $runtime.controllersReady=$true
    $contract=Get-RuntimeInputContract -BaseContract @{replayReady=$true} -Effective @{active=$true;controllerInactivitySuppressed=$true} -Runtime $runtime -ExternalDrivers @{errors=@();conflicts=@()}
    Assert-Controller ($contract.measurementReady -and $contract.controllerPresenceReady -and $contract.controllerInput -eq 'passive-neutral' -and -not $contract.replayReady) 'qualified passive pair does not imply interactive replay'
    $contract=Get-RuntimeInputContract -BaseContract @{} -Effective @{active=$true;controllerInactivitySuppressed=$false} -Runtime $runtime -ExternalDrivers @{errors=@();conflicts=@()}
    Assert-Controller (-not $contract.measurementReady -and $contract.controllerPresenceReady -and $contract.measurementBlockers -contains 'controller-inactivity-timeout-not-suppressed') 'positive or historical undeclared timeout cannot admit measurement despite a qualified pair'
    [pscustomobject]@{ok=$true;passed=$passed;scope='fixture-only; no SteamVR or Skyrim launched'} | ConvertTo-Json -Compress
}
finally {
    # The unique fixture was validated beneath the exact OS temporary root.
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

