# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ColourCasRejectionEvidence.psm1') -Force
$script:checks=0
function Check([bool]$Good,[string]$Message) { $script:checks++; if (-not $Good) { throw $Message } }
function Obj($Value) { return $Value|ConvertTo-Json -Depth 60|ConvertFrom-Json -Depth 60 -DateKind String }
function Change($Value,[string]$Path,$Replacement) { $names=$Path.Split('.');$node=$Value;for($i=0;$i -lt $names.Count-1;$i++){$node=$node.($names[$i])};$node.($names[-1])=$Replacement }
$build='a'*64
$before=Obj @{producer=@{component='CommunityShaders';buildId=$build;sourceCommit=('b'*40);shaderCacheAbiId=('c'*64);sourceDirty=$false};requested=@{revision=5;highDynamicRangeInput=$true;autoExposure=$true};hostContext=@{valid=$false;generation=0;highDynamicRangeInput=$false;autoExposure=$false};runtimeContext=@{valid=$true;generation=2;highDynamicRangeInput=$true;autoExposure=$true};lastSuccessfulDispatch=@{frame=100;valid=$true};lastSuccessfulEyeDispatches=@(@{frame=100;valid=$true},@{frame=100;valid=$true});sourceColorContractChanged=$false}
$rejected=Obj $before;$rejected|Add-Member accepted $false;$rejected|Add-Member resultingRevision 5;$rejected|Add-Member error 'expectedRevision did not match the current request'
$after=Obj $before;$after.lastSuccessfulDispatch.frame=101
$commandArgs=@{action='set';expectedBuildId=$build;expectedRevision=0;highDynamicRangeInput=$true;autoExposure=$true}
function TestReceipt($Before=$before,$Rejected=$rejected,$After=$after,$Command=$commandArgs) { return Test-DevBenchColourCasRejectionEvidence -BeforeStatus $Before -RejectedPayload $Rejected -AfterStatus $After -RejectedArguments $Command -ExpectedBuildId $build }
$rawBefore=$rejected|ConvertTo-Json -Depth 60 -Compress
$result=TestReceipt
Check $result.ok ($result.errors -join '; ')
Check ($result.expectedNegativeObserved -and -not $result.nativeSetAccepted -and $result.unchangedRequestedAndContexts) 'negative observation is not a successful set'
Check (($rejected|ConvertTo-Json -Depth 60 -Compress) -ceq $rawBefore) 'raw error preserved'
foreach ($defect in @(@('accepted',$true),@('accepted','false'),@('resultingRevision',4),@('resultingRevision','5'),@('error','revision_mismatch'),@('producer.buildId',('d'*64)),@('producer.sourceCommit',('d'*40)),@('requested.revision',6),@('requested.autoExposure',$false),@('runtimeContext.generation',3),@('runtimeContext.valid','true'),@('hostContext.autoExposure',$true),@('sourceColorContractChanged','false'))) {
    $bad=Obj $rejected;Change $bad $defect[0] $defect[1]
    Check (-not (TestReceipt -Rejected $bad).ok) "refuse rejected $($defect[0])"
}
foreach ($defect in @(@('requested.revision',6),@('requested.revision','5'),@('runtimeContext.generation',3),@('runtimeContext.autoExposure',$false),@('producer.buildId',('d'*64)),@('producer.sourceDirty',$true))) {
    $bad=Obj $after;Change $bad $defect[0] $defect[1]
    Check (-not (TestReceipt -After $bad).ok) "refuse changed after $($defect[0])"
}
foreach ($defect in @(@('expectedRevision',5),@('expectedRevision','0'),@('expectedRevision',-1),@('expectedBuildId',('d'*64)),@('action','status'),@('autoExposure',$false),@('autoExposure','true'))) {
    $bad=@{};foreach($p in $commandArgs.GetEnumerator()){$bad[$p.Key]=$p.Value};$bad[$defect[0]]=$defect[1]
    Check (-not (TestReceipt -Command $bad).ok) "refuse arguments $($defect[0])"
}
$extra=Obj $rejected;$extra|Add-Member code 'revision_mismatch'
Check (-not (TestReceipt -Rejected $extra).ok) 'invented code is not source-bound expected rejection'
$extra=Obj $rejected;$extra.requested|Add-Member error 'failure'
Check (-not (TestReceipt -Rejected $extra).ok) 'unknown negative requested extension refuses'
$missing=Obj $before;$missing.PSObject.Properties.Remove('runtimeContext')
Check (-not (TestReceipt -Before $missing).ok) 'missing current status cannot establish unchanged context'
Check (($rejected|ConvertTo-Json -Depth 60 -Compress) -ceq $rawBefore) 'all rejection tests retain raw evidence'
[pscustomobject]@{ok=$true;checks=$script:checks;scope='synthetic pinned217 uncoded CAS rejection/unchanged-state fixtures; no transport or native-handler coverage'}|ConvertTo-Json -Compress
