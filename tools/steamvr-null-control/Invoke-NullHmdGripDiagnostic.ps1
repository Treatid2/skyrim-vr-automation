# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding(DefaultParameterSetName='Offline')]
param(
    [Parameter(Mandatory,ParameterSetName='Live')][switch]$Live,
    [Parameter(Mandatory,ParameterSetName='Live')][string]$PlanPath,
    [Parameter(Mandatory,ParameterSetName='Offline')]
    [ValidateSet('normal','semantic-mismatch','baseline-failure','startup-stall','assay-stall','cleanup-unknown','baseline-cleanup-unknown','publication-stall','binding-mismatch','close-unknown','abnormal-assay-exit','restore-drift','result-injected','result-instance','result-ceiling','close-errors','close-state','exit-unknown','owner-busy','deadline-active','pair-active','health-unknown','runtime-changed','close-clock-unknown','result-partial','restore-preview-rejected')][string]$OfflineCase,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][string]$BoundedProcessPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$BoundedProcessSha256,
    [ValidateRange(12,300)][int]$SessionBudgetSeconds=240,
    [ValidateRange(5,90)][int]$CleanupReserveSeconds=60
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7){throw 'PowerShell7 on Windows is required'}
. (Join-Path $PSScriptRoot 'GripLifecycle.Common.ps1')
$began=Get-GripTick
$end=$began+[uint64]($SessionBudgetSeconds*1000)
if($CleanupReserveSeconds -ge $SessionBudgetSeconds){throw 'Cleanup reserve must be less than the session budget'}
$positiveEnd=$end-[uint64]($CleanupReserveSeconds*1000)
Assert-GripFile @{path=$BoundedProcessPath;sha256=$BoundedProcessSha256}
if(-not [IO.Path]::IsPathFullyQualified($EvidenceDirectory)){throw 'Evidence root must be absolute'}
$root=[IO.Path]::GetFullPath($EvidenceDirectory)
if(Test-Path -LiteralPath $root){throw 'A new evidence root is required; no replacement or implicit retry'}
$plan=$null
if($Live){
    $plan=Read-GripJson $PlanPath; Assert-GripPlan $plan
    Assert-GripEvidenceRoot $root $plan.fixture.path
    if([IO.Path]::GetFullPath($plan.boundedProcess.path) -cne [IO.Path]::GetFullPath($BoundedProcessPath) -or $plan.boundedProcess.sha256 -cne $BoundedProcessSha256){throw 'One pinned bounded-process owner must govern all stages'}
}
[void][IO.Directory]::CreateDirectory($root)
$worker=Join-Path $PSScriptRoot 'GripLifecycle.Worker.ps1'
$pwsh=(Get-Process -Id $PID).Path
$stages=[Collections.Generic.List[object]]::new()
$firstFailure=$null
function Invoke-GripStage([string]$Stage,[uint64]$Ceiling,[int]$CapSeconds){
    Assert-GripFile @{path=$script:BoundedProcessPath;sha256=$script:BoundedProcessSha256}
    $remaining=[long]$Ceiling-[long](Get-GripTick)
    $seconds=[int][Math]::Floor(([Math]::Min($remaining,$CapSeconds*1000)-750)/1000)
    if($seconds -lt 1){return @{ok=$false;stage=$Stage;reason='reserved-common-deadline';launched=$false}}
    $phaseArgs=@('-NoProfile','-File',$script:worker,'-Stage',$Stage,'-Root',$script:root,'-DeadlineTickMs',$Ceiling.ToString(),'-PositiveDeadlineTickMs',$script:positiveEnd.ToString(),'-CommonDeadlineTickMs',$script:end.ToString())
    if($script:Live){$phaseArgs+=@('-PlanPath',$script:PlanPath)}else{$phaseArgs+=@('-OfflineCase',$script:OfflineCase,'-PlanPath',$script:BoundedProcessPath)}
    if($Stage -eq 'publication' -and $null -ne $script:firstFailure){
        $failureJson=@{stage=$script:firstFailure.stage;reason='owned worker failed or common deadline exhausted'} | ConvertTo-Json -Compress
        $phaseArgs+=@('-CoordinatorFailureBase64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($failureJson)))
    }
    # One worker's job spans startup, assay and normal stop. No detached job or
    # successful-start child transfer to an unowned lifetime is permitted.
    $raw=& $script:BoundedProcessPath -FilePath $script:pwsh -ArgumentList $phaseArgs -WorkingDirectory $PSScriptRoot -TimeoutSeconds $seconds -MaxAttempts 1 -RetryPatterns @() -TerminationGraceMilliseconds 200 -StreamDrainGraceMilliseconds 200 -NoExit -Compact
    $receipt=$raw | ConvertFrom-Json -AsHashtable -DateKind String
    $body=$null
    if($receipt.ok){$body=$receipt.attempts[-1].stdout | ConvertFrom-Json -AsHashtable -DateKind String}
    $entry=@{stage=$Stage;ok=([bool]$receipt.ok -and (Get-GripTick) -lt $Ceiling);reason=if($receipt.ok){$null}else{'owned worker failure'};ceilingTickMs=$Ceiling.ToString();receipt=$receipt;body=$body;launched=$true}
    $script:stages.Add($entry)
    return $entry
}
$active=Invoke-GripStage 'session' $positiveEnd $SessionBudgetSeconds
if(-not $active.ok){$firstFailure=@{stage='session-worker';reason=$active.reason;processFailure=$active['receipt']}}
# Always use a separate bounded recovery worker, including abrupt session exit.
# Settings recovery is outside the cancelled runtime job and inside the SAME end.
$recoveryCeiling=$end-[uint64]5000
$recovery=Invoke-GripStage 'recovery' $recoveryCeiling $CleanupReserveSeconds
if(-not $recovery.ok -and $null -eq $firstFailure){$firstFailure=@{stage='recovery-worker';reason='Recovery did not complete'}}
$publication=Invoke-GripStage 'publication' $end 10
$published=$publication.ok -and $null -ne $publication.body -and $publication.body.published
$clean=$published -and [bool]$publication.body.cleanHandoffVerified
$result=@{schemaVersion='null-grip-coordinator.1';mode=if($Live){'live-unqualified-diagnostic'}else{'offline-injected-lifecycle'};startedTickMs=$began.ToString();commonDeadlineTickMs=$end.ToString();positiveDeadlineTickMs=$positiveEnd.ToString();endedTickMs=(Get-GripTick).ToString();deadlineSatisfied=((Get-GripTick) -lt $end);stages=$stages.ToArray();coordinatorFailure=$firstFailure;published=$published;cleanHandoffVerified=$clean;resultPath=if($published){Join-Path $root 'session-result.json'}else{$null};liveQualified=$false}
# No filesystem publication in the unsupervised coordinator. Keep the final
# envelope compact; full controller/worker evidence belongs to supervised IO.
$result | ConvertTo-Json -Depth 25 -Compress
if(-not $result.deadlineSatisfied -or -not $published -or -not $clean){exit 2}
