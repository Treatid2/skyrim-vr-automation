# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$PlanSha256,
    [Parameter(Mandatory)][string]$ConfiguredPythonPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ConfiguredPythonSha256,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [switch]$ValidateOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell7 on Windows is required'}
. (Join-Path $PSScriptRoot 'GripLifecycle.Common.ps1')
Assert-GripFile @{path=$PlanPath;sha256=$PlanSha256}
Assert-GripFile @{path=$ConfiguredPythonPath;sha256=$ConfiguredPythonSha256}
$plan=Read-GripJson $PlanPath
if(-not [string]::Equals([IO.Path]::GetFullPath($ConfiguredPythonPath),[IO.Path]::GetFullPath($plan.python.path),[StringComparison]::OrdinalIgnoreCase) -or $ConfiguredPythonSha256 -cne $plan.python.sha256){throw 'Explicit configured Python binding differs from the selected plan'}
$priorPython=[Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process')
if(-not [string]::IsNullOrWhiteSpace($priorPython) -and -not [string]::Equals([IO.Path]::GetFullPath($priorPython),[IO.Path]::GetFullPath($ConfiguredPythonPath),[StringComparison]::OrdinalIgnoreCase)){throw 'Existing process Python configuration conflicts with explicit selected binding'}
try {
    # Process-local binding only. All owned descendants inherit it; no user,
    # machine, service configuration or alternative interpreter is selected.
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$ConfiguredPythonPath,'Process')
    Assert-GripPlan $plan
    if(-not [IO.Path]::IsPathFullyQualified($EvidenceDirectory)){throw 'Evidence root must be absolute'}
    Assert-GripEvidenceRoot $EvidenceDirectory $plan.fixture.path
    if(Test-Path -LiteralPath $EvidenceDirectory){throw 'A new evidence root is required; no replacement or implicit retry'}
    $entry=Join-Path $PSScriptRoot 'Invoke-NullHmdGripDiagnostic.ps1'
    $entryPins=@($plan.fixtureDependencies | Where-Object {[string]::Equals([IO.Path]::GetFullPath($_.path),[IO.Path]::GetFullPath($entry),[StringComparison]::OrdinalIgnoreCase)})
    if($entryPins.Count -ne 1){throw 'The fixed coordinator must have exactly one selected pin'}
    Assert-GripFile $entryPins[0]
    if($ValidateOnly){
        @{ok=$true;scope='read-only selected execution envelope';pythonBindingVerified=$true;coordinatorPinned=$true;evidenceRootCreated=$false;runtimeInvoked=$false} | ConvertTo-Json -Compress
        return
    }
    $global:LASTEXITCODE=0
    & $entry -Live -PlanPath $PlanPath -EvidenceDirectory $EvidenceDirectory -BoundedProcessPath $plan.boundedProcess.path -BoundedProcessSha256 $plan.boundedProcess.sha256 -SessionBudgetSeconds 240 -CleanupReserveSeconds 90
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
} finally {
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$priorPython,'Process')
}
