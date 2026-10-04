# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RecipePath,[Parameter(Mandatory)][string]$LayoutPath,
    [Parameter(Mandatory)][string]$BuildManifestPath,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$entry=Join-Path $PSScriptRoot 'New-CSXRenderMapCapturePlan.ps1'
$root=Join-Path $FixtureRoot ('allocation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$passes=[Collections.Generic.List[string]]::new()
function Assert-RecipeTest([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
function Write-TestJson([string]$Name,$Value) { $path=Join-Path $root $Name; $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8; return $path }
$recipe=Get-Content -LiteralPath $RecipePath -Raw | ConvertFrom-Json
$manifest=Get-Content -LiteralPath $BuildManifestPath -Raw | ConvertFrom-Json
$names=[ordered]@{maxShaderObservations='maximumShaderObservations';maxStageShaderObservations='maximumStageShaderObservations';maxResourceObservations='maximumResourceObservations';maxTargetViewObservations='maximumTargetViewObservations';maxTargetBindingObservations='maximumTargetBindingObservations';maxSceneObjectObservations='maximumSceneObjectObservations';maxGeometryObservations='maximumGeometryObservations';maxMaterialStateObservations='maximumMaterialStateObservations'}
$defaults=[ordered]@{};foreach($property in $recipe.defaults.PSObject.Properties){$defaults[$property.Name]=$property.Value}
$defaults.fixedCatalogueBytes=29821088;$defaults.eventStorageUnitBytes=520
$limits=[ordered]@{maximumDurationMs=60000;maximumFrames=10000;maximumEvents=65536;maximumScopeDepth=64;maximumBytes=67108864}
foreach($name in $names.Keys){$limits[$names[$name]]=$recipe.limits.$name}
$registry=[pscustomobject]@{ok=$true;result=[pscustomobject]@{service='communityshaders.render-map';major=1;producerBuildId=$manifest.buildId;defaults=[pscustomobject]$defaults;limits=[pscustomobject]$limits;eventSelection=[pscustomobject]@{optional=$true};eventKinds=@('draw','eye-submitted','resource-flow')}}
$registryPath=Write-TestJson 'registry.json' $registry
$workload=[pscustomobject]@{expectedDurationMs=1000;expectedFrames=100;expectedEvents=32768;expectedEventBytes=1;expectedScopeDepth=4;expectedObservations=[pscustomobject]@{shader=64;stageShader=2048;resource=1024;targetView=4096;targetBinding=64;sceneObject=512;geometry=1024;materialState=1024}}
$workloadPath=Write-TestJson 'workload.json' $workload
$base=@{RegistryPath=$registryPath;WorkloadPath=$workloadPath;ClientId='allocation-fixture';CommandId='allocation-fixture';HeadroomFactor=1;MaxBytes=67108864;AllocationRecipePath=$RecipePath;ExpectedAllocationRecipeSha256=(Get-FileHash $RecipePath -Algorithm SHA256).Hash;AllocationLayoutPath=$LayoutPath;ProducerBuildManifestPath=$BuildManifestPath;ExpectedProducerBuildManifestSha256=(Get-FileHash $BuildManifestPath -Algorithm SHA256).Hash;NoExit=$true;Compact=$true}
function Invoke-TestPlan([hashtable]$Changes=@{}) { $args=@{};foreach($key in $base.Keys){$args[$key]=$base[$key]};foreach($key in $Changes.Keys){if($null -eq $Changes[$key]){$args.Remove($key)}else{$args[$key]=$Changes[$key]}};$args.OutputPath=Join-Path $root ([guid]::NewGuid().ToString('N')+'.plan.json'); return (& $entry @args | ConvertFrom-Json) }
$plan=Invoke-TestPlan
Assert-RecipeTest $plan.ok 'exact recipe candidate admitted offline'
$receipt=Get-Content $plan.receiptPath -Raw | ConvertFrom-Json
Assert-RecipeTest ($receipt.fixedCatalogueBytes -eq 40981664 -and $receipt.requiredStorageBytes -eq 58021024 -and $receipt.byteBudgetHeadroom -eq 9087840) 'stage2048 views4096 events32768 exact accounting matches owner recipe'
Assert-RecipeTest ($plan.arguments.maxBytes -eq 67108864 -and $plan.arguments.maxEvents -eq 32768) 'explicit64MiB budget retained without raising event ceiling'
Assert-RecipeTest ($receipt.allocationEvidence.sourceCommit -ceq $recipe.commit -and $receipt.allocationEvidence.pdbGuid -ceq $recipe.pdbGuid -and $receipt.allocationEvidence.producerBuildId -ceq $manifest.buildId) 'source build PDB identity retained'
Assert-RecipeTest ($receipt.catalogueStorageBasis -ceq 'exact-owner-source-and-paired-PDB-allocation-recipe') 'recipe admission separated from live allocation proof'
$selected=Invoke-TestPlan @{EventKinds=@('draw','eye-submitted')}
Assert-RecipeTest ($selected.ok -and ($selected.arguments.eventKinds -join ',') -ceq 'draw,eye-submitted' -and $selected.arguments.maxBytes -eq 67108864) 'selection stays native dependency request and receives no allocation discount'
$noRecipe=@{};foreach($field in @('AllocationRecipePath','ExpectedAllocationRecipeSha256','AllocationLayoutPath','ProducerBuildManifestPath','ExpectedProducerBuildManifestSha256')){$noRecipe[$field]=$null}
$old=Invoke-TestPlan $noRecipe
Assert-RecipeTest (-not $old.ok -and $old.state -eq 'catalogue-storage-unproven' -and $null -eq $old.arguments) 'no recipe preserves default-only guard'
foreach($field in $noRecipe.Keys){$failed=Invoke-TestPlan @{$field=$null};Assert-RecipeTest (-not $failed.ok -and -not $failed.receiptPublished -and $null -eq $failed.arguments) "missing recipe evidence $field fails without fallback"}
foreach($field in @('ExpectedAllocationRecipeSha256','ExpectedProducerBuildManifestSha256')){$failed=Invoke-TestPlan @{$field=('0'*64)};Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "wrong pinned hash $field refused"}
foreach($case in @('producer','major','fixed-cost','event-unit','default-stage','live-event-limit','live-view-limit')){
    $changed=$registry|ConvertTo-Json -Depth 30|ConvertFrom-Json
    switch($case){'producer'{$changed.result.producerBuildId='foreign'};'major'{$changed.result.major=2};'fixed-cost'{$changed.result.defaults.fixedCatalogueBytes++};'event-unit'{$changed.result.defaults.eventStorageUnitBytes++};'default-stage'{$changed.result.defaults.maxStageShaderObservations++};'live-event-limit'{$changed.result.limits.maximumEvents=32767};'live-view-limit'{$changed.result.limits.maximumTargetViewObservations=4095}}
    $failed=Invoke-TestPlan @{RegistryPath=(Write-TestJson "registry-$case.json" $changed)}
    Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "native $case mismatch or tighter limit refused"
}
foreach($case in @('commit','tree','buildKey','pdbGuid','pdbAge','coefficient','base','event','fraction','negative','parse','changed','layout-hash')){
    $changed=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
    switch($case){'commit'{$changed.commit='0'*40};'tree'{$changed.tree='0'*40};'buildKey'{$changed.buildKey='sha256:'+('0'*64)};'pdbGuid'{$changed.pdbGuid=[guid]::NewGuid().ToString()};'pdbAge'{$changed.pdbAge++};'coefficient'{$changed.perCapacityBytes.maxStageShaderObservations++};'base'{$changed.baseBytes++};'event'{$changed.eventStorageUnitBytes++};'fraction'{$changed.perCapacityBytes.maxShaderObservations=1.5};'negative'{$changed.perCapacityBytes.maxShaderObservations=-1};'parse'{$changed.parseErrors=@('error')};'changed'{$changed.sourceChanged=$true};'layout-hash'{$changed.layoutReceipt.sha256='0'*64}}
    $path=Write-TestJson "recipe-$case.json" $changed
    $failed=Invoke-TestPlan @{AllocationRecipePath=$path;ExpectedAllocationRecipeSha256=(Get-FileHash $path -Algorithm SHA256).Hash}
    Assert-RecipeTest (-not $failed.ok -and -not $failed.receiptPublished -and $null -eq $failed.arguments) "recipe $case inconsistency fails before publication"
}
$events=$workload|ConvertTo-Json -Depth 30|ConvertFrom-Json;$events.expectedEvents=65537
$failed=Invoke-TestPlan @{WorkloadPath=(Write-TestJson 'too-many-events.json' $events)}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments -and @($failed.exceededCeilings|Where-Object bound -eq 'maxEvents').Count -eq 1) '65536 event ceiling remains absolute'
$failed=Invoke-TestPlan @{MaxBytes=58021023}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'one byte below required storage refused'
$failed=Invoke-TestPlan @{MaxBytes=67108865}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'one byte beyond registry64MiB refused'
$minimal=Invoke-TestPlan @{MaxBytes=$null}
Assert-RecipeTest ($minimal.ok -and $minimal.arguments.maxBytes -eq 58021024) 'omitted budget selects exact required recipe accounting'
foreach($nativeCase in $recipe.cases){
    $caseWorkload=$workload|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $caseWorkload.expectedEvents=$nativeCase.config.maxEvents
    foreach($pair in @(@('shader','maxShaderObservations'),@('stageShader','maxStageShaderObservations'),@('resource','maxResourceObservations'),@('targetView','maxTargetViewObservations'),@('targetBinding','maxTargetBindingObservations'),@('sceneObject','maxSceneObjectObservations'),@('geometry','maxGeometryObservations'),@('materialState','maxMaterialStateObservations'))){$caseWorkload.expectedObservations.($pair[0])=$nativeCase.config.($pair[1])}
    $casePlan=Invoke-TestPlan @{WorkloadPath=(Write-TestJson ('case-'+[guid]::NewGuid().ToString('N')+'.json') $caseWorkload)}
    $caseReceipt=Get-Content $casePlan.receiptPath -Raw|ConvertFrom-Json
    Assert-RecipeTest ($casePlan.ok -and $caseReceipt.fixedCatalogueBytes -eq $nativeCase.fixedCatalogueBytes -and $caseReceipt.requiredStorageBytes -eq $nativeCase.requiredStorageBytesForRequestedEvents -and $caseReceipt.byteBudgetHeadroom -eq $nativeCase.headroomBytes) "exact owner scenario matches: $($nativeCase.label)"
}
foreach($case in @('source','dirty','artifact')){
    $badManifest=$manifest|ConvertTo-Json -Depth 30|ConvertFrom-Json
    switch($case){'source'{$badManifest.identity.source.commit='0'*40};'dirty'{$badManifest.identity.source.dirty=$true};'artifact'{$badManifest.artifact.sha256='0'*64}}
    $path=Write-TestJson "manifest-$case.json" $badManifest
    $failed=Invoke-TestPlan @{ProducerBuildManifestPath=$path;ExpectedProducerBuildManifestSha256=(Get-FileHash $path -Algorithm SHA256).Hash}
    Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "native manifest $case cannot bind recipe"
}
foreach($case in @('record-size','missing-type','duplicate-type')){
    $badLayout=Get-Content $LayoutPath -Raw|ConvertFrom-Json
    switch($case){'record-size'{$badLayout.types[5].bytes++};'missing-type'{$badLayout.types=@($badLayout.types|Where-Object type -cne 'CSX::RenderMap::StageShaderObservationRecord')};'duplicate-type'{$badLayout.types+=@($badLayout.types[0])}}
    $path=Write-TestJson "layout-$case.json" $badLayout
    $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json;$badRecipe.layoutReceipt.sha256=(Get-FileHash $path -Algorithm SHA256).Hash
    $recipeFixture=Write-TestJson "layout-recipe-$case.json" $badRecipe
    $failed=Invoke-TestPlan @{AllocationLayoutPath=$path;AllocationRecipePath=$recipeFixture;ExpectedAllocationRecipeSha256=(Get-FileHash $recipeFixture -Algorithm SHA256).Hash}
    Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "PDB $case inconsistency fails before dispatch"
}
$overflow=$workload|ConvertTo-Json -Depth 30|ConvertFrom-Json;$overflow.expectedObservations.stageShader=[long]::MaxValue
$failed=Invoke-TestPlan @{WorkloadPath=(Write-TestJson 'overflow.json' $overflow)}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'recipe multiplication overflow refused'
$late=Invoke-TestPlan @{InternalTestFailurePoint='receipt-hash'}
Assert-RecipeTest (-not $late.ok -and $late.state -eq 'plan-finalization-error' -and $late.receiptPublished -and $null -eq $late.arguments) 'published receipt finalization failure withholds dispatch arguments'
[pscustomobject]@{ok=$true;passed=$passes.Count;failed=0;scope='Synthetic registry fixtures against exact owner recipe/layout/build evidence; no native API or runtime mutation';checks=@($passes)}|ConvertTo-Json -Depth 5
