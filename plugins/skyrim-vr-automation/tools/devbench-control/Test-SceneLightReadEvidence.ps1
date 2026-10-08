# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([string]$NativeReceiptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
function Clone($v){$v|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40}
$argsMap=@{kind='lights';scope='scene';limit=40}
# Minimal source-derived native16dac scene receipt; not live scientific evidence.
$seed=[ordered]@{
    scope='scene';count=1;returned=1;truncated=$false;countScope='filtered-observed-subset-before-limit';playerPositionAvailable=$true
    ordering='distance-ownerFormId-path-name-type-pointer; pointer tie-break is process-local'
    lightObservation=@{source=@{source='BSShaderManager.shadowSceneNode[0]';index=0;lists=@('activeShadowLights','activeLights');available=$true;complete=$true;observedUniqueLights=1;visibleIlluminationProven=$false}
        budget=@{complete=$true;reasons=@();used=@{nodes=0;edges=0;parents=1;rendererEntries=1;uniqueLights=1;outputs=1};limits=@{nodes=4096;edges=16384;parents=32768;rendererEntries=4096;uniqueLights=512;outputs=512;depth=256;ancestors=64}}}
    lights=@(@{name='fixture';type='NiPointLight';path='world';diffuse=@(1.0,1.0,1.0);radius=10.0;fade=1.0;fadeAmount=0.0;appCulled=$false;inScene='active';position=@(0.0,1.0,2.0);distance=3.0;owner=$null
        lineageCoverage=@{available=$true;complete=$true;stoppedAfterMatch=$false;visitedNodes=1;examinedEdges=0;repeatedPointers=0;reasons=@()}})
}
$good=Clone $seed;$raw=$good|ConvertTo-Json -Depth 40 -Compress
$r=Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments $argsMap -Content @($good)
Check ($r.ok -and $r.observedSubsetComplete -and -not $r.visibleIlluminationProven -and -not $r.wholeSceneCoverageProven) 'bounded read never claims illumination/whole scene'
Check (($good|ConvertTo-Json -Depth 40 -Compress) -ceq $raw) 'raw payload unchanged'
Check (Test-DevBenchReadOnlyRequest -ToolName inspect -Arguments $argsMap) 'exact scene request read-only'
foreach($case in @('missing','extra','scope','array-scope','count-string','count-mismatch','returned-mismatch','truncated-string','truncated-contradiction','lights-over64','source-name','source-array-name','source-index','source-lists','illumination-true','source-contradiction','source-extra','budget-extra','budget-incoherent','budget-overlimit','limits-drift','budget-string','light-extra','light-type','light-vector','light-nan','light-member','light-distance','lineage-extra','lineage-incoherent','lineage-overbound','owner-extra','owner-type','owner-vector','owner-form','owner-actor')){
    $bad=Clone $seed
    switch($case){
        missing {$bad.PSObject.Properties.Remove('lightObservation')}
        extra {$bad|Add-Member error 'failure'}
        scope {$bad.scope='ref'}
        array-scope {$bad.scope=@('scene')}
        count-string {$bad.count='1'}
        count-mismatch {$bad.count=2}
        returned-mismatch {$bad.returned=0}
        truncated-string {$bad.truncated='false'}
        truncated-contradiction {$bad.truncated=$true}
        lights-over64 {$bad.lights=@($bad.lights[0])*65}
        source-name {$bad.lightObservation.source.source='foreign'}
        source-array-name {$bad.lightObservation.source.source=@('BSShaderManager.shadowSceneNode[0]')}
        source-index {$bad.lightObservation.source.index=1}
        source-lists {$bad.lightObservation.source.lists=@('activeLights')}
        illumination-true {$bad.lightObservation.source.visibleIlluminationProven=$true}
        source-contradiction {$bad.lightObservation.source.available=$false}
        source-extra {$bad.lightObservation.source|Add-Member error 'failure'}
        budget-extra {$bad.lightObservation.budget|Add-Member ok $true}
        budget-incoherent {$bad.lightObservation.budget.reasons=@('parent-budget')}
        budget-overlimit {$bad.lightObservation.budget.used.parents=32769}
        limits-drift {$bad.lightObservation.budget.limits.parents=99999}
        budget-string {$bad.lightObservation.budget.used.nodes='0'}
        light-extra {$bad.lights[0]|Add-Member error 'failure'}
        light-type {$bad.lights[0].appCulled='false'}
        light-vector {$bad.lights[0].position=@(0,1)}
        light-nan {$bad.lights[0].fade=[double]::NaN}
        light-member {$bad.lights[0].inScene=$true}
        light-distance {$bad.lights[0].distance=$null}
        lineage-extra {$bad.lights[0].lineageCoverage|Add-Member error 'failure'}
        lineage-incoherent {$bad.lights[0].lineageCoverage.available=$false}
        lineage-overbound {$bad.lights[0].lineageCoverage.visitedNodes=65}
        owner-extra {$bad.lights[0].owner=[pscustomobject]@{error='failure'}}
        owner-type {$bad.lights[0].owner='owner'}
        owner-vector {$bad.lights[0].owner=[pscustomobject]@{formId='0x00000001';formType='REFR';position=@(0,1);rotation=@(0,1,2)}}
        owner-form {$bad.lights[0].owner=[pscustomobject]@{formId='foreign';formType='REFR';position=@(0,1,2);rotation=@(0,1,2)}}
        owner-actor {$bad.lights[0].owner=[pscustomobject]@{formId='0x00000001';formType='REFR';position=@(0,1,2);rotation=@(0,1,2);actor=@{level='1';playerTeammate=$false}}}
    }
    Check (-not (Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments $argsMap -Content @($bad)).ok) "$case fails closed"
}
foreach($case in @('limited','partial-budget','partial-source','no-position','empty')){
    $p=Clone $seed
    switch($case){
        limited {$request=@{kind='lights';scope='scene';limit=1};$p.count=2;$p.lightObservation.source.observedUniqueLights=2;$p.lightObservation.budget.used.outputs=2;$p.lightObservation.budget.used.uniqueLights=2;$p.truncated=$true}
        partial-budget {$request=$argsMap;$p.lightObservation.budget.complete=$false;$p.lightObservation.budget.reasons=@('name-length-budget');$p.truncated=$true}
        partial-source {$request=$argsMap;$p.lightObservation.source.complete=$false;$p.truncated=$true}
        no-position {$request=$argsMap;$p.playerPositionAvailable=$false;$p.lights[0].distance=$null}
        empty {$request=$argsMap;$p.count=0;$p.returned=0;$p.lightObservation.source.observedUniqueLights=0;$p.lightObservation.budget.used.outputs=0;$p.lights=@()}
    }
    $r=Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments $request -Content @($p)
    Check ($r.ok -and -not $r.visibleIlluminationProven -and -not $r.wholeSceneCoverageProven) "$case schema admitted without stronger proof"
    Check ($r.observedSubsetComplete -eq (-not $p.truncated)) "$case partial distinction retained"
}
foreach($case in @('extra','ref','radius','string-limit','zero','too-large','kind-case','scope-case','key-case')){
    $a=$argsMap.Clone()
    switch($case){extra {$a.extra=1};ref {$a.scope='ref'};radius {$a.radius=2};string-limit {$a.limit='40'};zero {$a.limit=0};too-large {$a.limit=65};kind-case {$a.kind='Lights'};scope-case {$a.scope='Scene'};key-case {$a.Remove('kind');$a.Kind='lights'}}
    Check (-not (Test-DevBenchSceneLightRequest $a)) "$case request does not become read-only"
    Check (-not (Get-DevBenchSceneLightStatus -Arguments $a -Content @($good)).ok) "$case contract refuses"
}
Check (-not (Get-DevBenchSceneLightStatus -Arguments $argsMap -Content @($good,$good)).ok) 'multiple payloads refuse'
Check (-not (Get-DevBenchSceneLightStatus -Arguments $argsMap -Content @()).ok) 'empty payload refuses'
if($NativeReceiptRoot){
    $path=Join-Path $NativeReceiptRoot 'I-quiet-near-trial1-LIGHTS.json';$pin='a35db2e62e0d6b9d91363e9ae12896af947c164747ad048c41d9ec745d09ab34'
    Check ((Get-FileHash -LiteralPath $path).Hash -ieq $pin) 'original native input hash pinned'
    $native=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 80
    $r=Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments $argsMap -Content @($native.data.content)
    Check ($r.ok -and $r.observedSubsetComplete -and -not $r.visibleIlluminationProven) 'actual native read qualifies without visibility claim'
    Check ((Get-FileHash -LiteralPath $path).Hash -ieq $pin) 'immutable native input unchanged'
}
[pscustomobject]@{ok=$true;checks=$checks;scope='offline bounded scene-light schema; no visible/whole-scene proof'}|ConvertTo-Json -Compress
