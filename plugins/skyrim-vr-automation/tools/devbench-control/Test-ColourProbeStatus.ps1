# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$script:assertions=0
function Check([bool]$Good,[string]$Message){$script:assertions++;if(-not $Good){throw $Message}}
function Copy-Fixture($Value){return $Value|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40}
$fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-colour-probe-status.v3.json') -Raw|ConvertFrom-Json -Depth 40
$query=@{action='status';expectedBuildId=$fixture.producer.buildId}
function Read-Status($Value,$Arguments=$query){return Get-DevBenchCallSemanticStatus -ToolName communityshaders.colour_pipeline_probe -Arguments $Arguments -Content @($Value)}
function Reject($Value,[string]$Message,$Arguments=$query){$read=Read-Status $Value $Arguments;Check (-not $read.ok -and $null -eq $read.qualifiedColourProbeStatus) $Message}
$before=$fixture|ConvertTo-Json -Depth 40 -Compress
$read=Read-Status $fixture
Check ($read.known -and $read.ok -and $read.completionBasis -ceq 'read-schema-only') 'exact native idle receipt qualifies without generic ok'
Check ($read.qualifiedColourProbeStatus.generation -eq 0 -and $null -eq $read.qualifiedColourProbeStatus.sceneEpoch -and $null -eq $read.qualifiedColourProbeStatus.submissionEpoch) 'zero idle generation and explicit null epochs preserved'
Check (($fixture|ConvertTo-Json -Depth 40 -Compress) -ceq $before -and -not $fixture.PSObject.Properties['ok']) 'raw payload is untouched; no synthetic ok or attribution'
Check (Test-DevBenchReadOnlyRequest -ToolName communityshaders.colour_pipeline_probe -Arguments $query) 'exact status admitted as read-only'
$resetIdle=Copy-Fixture $fixture;$resetIdle.generation=[uint64]::MaxValue
Check ((Read-Status $resetIdle).ok) 'idle generation can be retained/incremented after reset, including uint64 limit'
foreach($field in @('schemaVersion','state','generation','captureId','cpuFrame','sceneEpoch','submissionEpoch','expectedStageEyeSlots','queuedStageEyeSlots','mappedStageEyeSlots','expectedColourContractRevision','stagingPayloadBytes','maximumStagingPayloadBytes','timeoutSeconds','error','armedQpc','queryQueuedQpc','completedQpc','producer')){
    $bad=Copy-Fixture $fixture;$bad.PSObject.Properties.Remove($field);Reject $bad "missing $field refuses status"
}
foreach($field in @('generation','expectedColourContractRevision','armedQpc','queryQueuedQpc','completedQpc','stagingPayloadBytes','queuedStageEyeSlots','mappedStageEyeSlots','schemaVersion','expectedStageEyeSlots','maximumStagingPayloadBytes','timeoutSeconds')){
    foreach($value in @($null,'0',0.5,-1,$true,@(0))){$bad=Copy-Fixture $fixture;$bad.$field=$value;Reject $bad "malformed numeric $field"}
}
foreach($field in @('schemaVersion','expectedStageEyeSlots','maximumStagingPayloadBytes','timeoutSeconds')){
    $bad=Copy-Fixture $fixture;$bad.$field++;Reject $bad "foreign fixed bound $field"
}
foreach($field in @('sceneEpoch','submissionEpoch','cpuFrame')){
    foreach($value in @('0',0,@(0),$true)){ $bad=Copy-Fixture $fixture;$bad.$field=$value;Reject $bad "malformed idle attribution $field" }
}
foreach($field in @('generation','captureId','queuedStageEyeSlots','mappedStageEyeSlots','stagingPayloadBytes')){
    $bad=Copy-Fixture $fixture;$bad.state='armed';Reject $bad "armed cannot reuse empty idle ownership ($field)"
}
foreach($field in @('buildId','shaderCacheAbiId','sourceCommit')){
    foreach($value in @('foreign',$null,@($fixture.producer.$field))){$bad=Copy-Fixture $fixture;$bad.producer.$field=$value;Reject $bad "producer $field malformed"}
}
foreach($value in @('foreign',@('CommunityShaders'),$null)){$bad=Copy-Fixture $fixture;$bad.producer.component=$value;Reject $bad 'foreign or malformed producer component'}
$bad=Copy-Fixture $fixture;$bad.producer.sourceDirty='false';Reject $bad 'sourceDirty must be Boolean'
foreach($defect in @('stateCase','unknownState','arrayState','idleCapture','utf8Overflow','slotOverflow','payloadOverflow','errorText','failedNullError','failedError','outerFalse','nestedError','mutationReceipt','pageReceipt')){
    $bad=Copy-Fixture $fixture
    switch($defect){
        stateCase {$bad.state='IDLE'};unknownState {$bad.state='running'};arrayState {$bad.state=@('idle')}
        idleCapture {$bad.captureId='foreign'};utf8Overflow {$bad.captureId=('é'*65)}
        slotOverflow {$bad.queuedStageEyeSlots=11};payloadOverflow {$bad.stagingPayloadBytes=1073741825}
        errorText {$bad.error='native failure'};failedNullError {$bad.state='failed'}
        failedError {$bad.state='failed';$bad.error='capture failed'}
        outerFalse {$bad|Add-Member ok $false};nestedError {$bad.producer|Add-Member error 'failed'}
        mutationReceipt {$bad|Add-Member accepted $true};pageReceipt {$bad|Add-Member samples @()}
    }
    Reject $bad "negative $defect"
}
$owned=Copy-Fixture $fixture;$owned.captureId='fixture-owned';$owned.generation=1;$owned.expectedColourContractRevision=1;$owned.armedQpc=10;$owned.state='armed'
Check ((Read-Status $owned).ok) 'source-bound armed status is read-schema only, not arm admission'
$owned.armedQpc=0
Check ((Read-Status $owned).ok) 'native QueryQpc zero fallback remains valid telemetry, not timing quality'
$owned.state='capturing';$owned.cpuFrame=20;$owned.queuedStageEyeSlots=4;$owned.stagingPayloadBytes=1024
Check ((Read-Status $owned).ok) 'typed partial capturing status qualifies without completion/science claim'
$owned.state='readback_pending';$owned.queuedStageEyeSlots=10;$owned.mappedStageEyeSlots=2;$owned.queryQueuedQpc=20
Check ((Read-Status $owned).ok) 'typed pending partial readback status qualifies'
$bad=Copy-Fixture $owned;$bad.mappedStageEyeSlots=11;Reject $bad 'mapped stage-eye slots bounded by queued inventory'
$owned.state='complete';$owned.mappedStageEyeSlots=10;$owned.completedQpc=30
Check ((Read-Status $owned).ok -and $null -eq (Read-Status $owned).qualifiedColourProbeStatus.sceneEpoch) 'complete status does not invent unavailable source epochs'
$bad=Copy-Fixture $owned;$bad.mappedStageEyeSlots=9;Reject $bad 'complete requires ten mapped slots'
$bad=Copy-Fixture $owned;$bad.completedQpc=15;Reject $bad 'completion QPC may not precede queued QPC'
$bad=Copy-Fixture $owned;$bad.state='failed';$bad.error='native readback failure';$negative=Read-Status $bad
Check ($negative.known -and -not $negative.ok -and $null -eq $negative.qualifiedColourProbeStatus -and $bad.error -ceq 'native readback failure') 'valid owned failed status retains negative evidence and never becomes positive schema qualification'
foreach($field in @('captureId','generation','expectedRevision','metadata','stage','eye','unknown')){
    $args=$query.Clone();$args[$field]=1;Reject $fixture "status rejects foreign argument $field" $args
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.colour_pipeline_probe -Arguments $args)) 'foreign/mutation parameters cannot gain status admission'
}
$args=$query.Clone();$args.expectedBuildId='f'*64;Reject $fixture 'expected producer build must match' $args
$args=$query.Clone();$args.expectedBuildId=@($fixture.producer.buildId);Reject $fixture 'expected producer build must be a string' $args
foreach($action in @('arm','reset','read','STATUS',@('status'))){
    $args=@{action=$action};$s=Read-Status $fixture $args
    Check (-not $s.PSObject.Properties['qualifiedColourProbeStatus']) 'status adapter never qualifies another action'
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.colour_pipeline_probe -Arguments $args)) 'no arm/reset/page read admission extension'
}
foreach($content in @(@($fixture,$fixture),@([pscustomobject]@{ok=$true}),@('scalar'),@(,@($fixture)))){
    $s=Get-DevBenchCallSemanticStatus -ToolName communityshaders.colour_pipeline_probe -Arguments $query -Content $content
    Check (-not $s.ok -and $null -eq $s.qualifiedColourProbeStatus) 'foreign/multiple/scalar/nested payloads fail closed'
}
[pscustomobject]@{ok=$true;assertions=$script:assertions;scope='offline source-bound schema3 status only; no runtime, arm/reset/page read, timing or science admission'}|ConvertTo-Json -Compress
