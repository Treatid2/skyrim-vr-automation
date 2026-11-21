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
# Bootstrap without executing Common or another plan-selected script. The read
# handle denies write/delete for the complete invocation, including recovery.
$selectionHandles=[Collections.Generic.List[IO.FileStream]]::new()
function Open-SelectedInput([string]$Path,[string]$Sha256){
    if(-not [IO.Path]::IsPathFullyQualified($Path) -or $Sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Exact absolute selected input and SHA256 required'}
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Selected input must be an ordinary file'}
    $handle=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $selectionHandles.Add($handle)
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($handle)).ToLowerInvariant()
    $handle.Position=0
    if($actual -cne $Sha256){throw 'Pinned artifact hash changed'}
    return $handle
}
$priorPython=[Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process')
try {
$planHandle=Open-SelectedInput $PlanPath $PlanSha256
if($planHandle.Length -gt 8388608){throw 'JSON input exceeds the eight MiB boundary'}
$reader=[IO.StreamReader]::new($planHandle,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
try{$plan=$reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -DateKind String}finally{$reader.Dispose()}
[void](Open-SelectedInput $ConfiguredPythonPath $ConfiguredPythonSha256)
if(-not [string]::Equals([IO.Path]::GetFullPath($ConfiguredPythonPath),[IO.Path]::GetFullPath($plan.python.path),[StringComparison]::OrdinalIgnoreCase) -or $ConfiguredPythonSha256 -cne $plan.python.sha256){throw 'Explicit configured Python binding differs from the selected plan'}
if(-not [string]::IsNullOrWhiteSpace($priorPython) -and -not [string]::Equals([IO.Path]::GetFullPath($priorPython),[IO.Path]::GetFullPath($ConfiguredPythonPath),[StringComparison]::OrdinalIgnoreCase)){throw 'Existing process Python configuration conflicts with explicit selected binding'}
    # Process-local binding only. All owned descendants inherit it; no user,
    # machine, service configuration or alternative interpreter is selected.
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$ConfiguredPythonPath,'Process')
    $entry=Join-Path $PSScriptRoot 'Invoke-NullHmdGripDiagnostic.ps1'
    $entryPins=@($plan.fixtureDependencies | Where-Object {[string]::Equals([IO.Path]::GetFullPath($_.path),[IO.Path]::GetFullPath($entry),[StringComparison]::OrdinalIgnoreCase)})
    if($entryPins.Count -ne 1){throw 'The fixed coordinator must have exactly one selected pin'}
    [void](Open-SelectedInput $entry $entryPins[0].sha256)
    $global:LASTEXITCODE=0
    & $entry -Live -PlanPath $PlanPath -ExpectedPlanSha256 $PlanSha256 -EvidenceDirectory $EvidenceDirectory -BoundedProcessPath $plan.boundedProcess.path -BoundedProcessSha256 $plan.boundedProcess.sha256 -SessionBudgetSeconds 240 -CleanupReserveSeconds 90 -ValidateOnly:$ValidateOnly
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
} finally {
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$priorPython,'Process')
    foreach($handle in $selectionHandles){$handle.Dispose()}
}
