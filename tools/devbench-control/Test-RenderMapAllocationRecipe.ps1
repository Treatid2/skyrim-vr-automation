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
$staticNativeRecipe = $recipe.status -cin @('PASS_SOURCE_AND_EXACT_E03_PDB_ALLOCATION_RECIPE','PASS_SOURCE_AND_EXACT_217_PDB_ALLOCATION_RECIPE')
$manifest=Get-Content -LiteralPath $BuildManifestPath -Raw | ConvertFrom-Json
$names=[ordered]@{maxShaderObservations='maximumShaderObservations';maxStageShaderObservations='maximumStageShaderObservations';maxResourceObservations='maximumResourceObservations';maxTargetViewObservations='maximumTargetViewObservations';maxTargetBindingObservations='maximumTargetBindingObservations';maxSceneObjectObservations='maximumSceneObjectObservations';maxGeometryObservations='maximumGeometryObservations';maxMaterialStateObservations='maximumMaterialStateObservations'}
$defaults=[ordered]@{};foreach($property in $recipe.defaults.PSObject.Properties){$defaults[$property.Name]=$property.Value}
$baseDelta=[long]$recipe.baseBytes-2144
$defaults.fixedCatalogueBytes=29821088+$baseDelta;$defaults.eventStorageUnitBytes=520
$limits=[ordered]@{maximumDurationMs=60000;maximumFrames=10000;maximumEvents=65536;maximumScopeDepth=64;maximumBytes=67108864}
foreach($name in $names.Keys){$limits[$names[$name]]=$recipe.limits.$name}
$registry=[pscustomobject]@{ok=$true;result=[pscustomobject]@{service='communityshaders.render-map';major=1;producerBuildId=$manifest.buildId;defaults=[pscustomobject]$defaults;limits=[pscustomobject]$limits;eventSelection=[pscustomobject]@{optional=$true};eventKinds=@('draw','eye-submitted','resource-flow')}}
$registryPath=Write-TestJson 'registry.json' $registry
if ($staticNativeRecipe) {
    $registry.result | Add-Member -NotePropertyName minor -NotePropertyValue 24
    $registry.result | Add-Member -NotePropertyName schemaRevision -NotePropertyValue 26
    $registryPath=Write-TestJson 'registry-e03.json' $registry
}
$workload=[pscustomobject]@{expectedDurationMs=1000;expectedFrames=100;expectedEvents=32768;expectedEventBytes=1;expectedScopeDepth=4;expectedObservations=[pscustomobject]@{shader=64;stageShader=2048;resource=1024;targetView=4096;targetBinding=64;sceneObject=512;geometry=1024;materialState=1024}}
$workloadPath=Write-TestJson 'workload.json' $workload
$base=@{RegistryPath=$registryPath;WorkloadPath=$workloadPath;ClientId='allocation-fixture';CommandId='allocation-fixture';HeadroomFactor=1;MaxBytes=67108864;AllocationRecipePath=$RecipePath;ExpectedAllocationRecipeSha256=(Get-FileHash $RecipePath -Algorithm SHA256).Hash;AllocationLayoutPath=$LayoutPath;ProducerBuildManifestPath=$BuildManifestPath;ExpectedProducerBuildManifestSha256=(Get-FileHash $BuildManifestPath -Algorithm SHA256).Hash;NoExit=$true;Compact=$true}
function Invoke-TestPlan([hashtable]$Changes=@{}) { $args=@{};foreach($key in $base.Keys){$args[$key]=$base[$key]};foreach($key in $Changes.Keys){if($null -eq $Changes[$key]){$args.Remove($key)}else{$args[$key]=$Changes[$key]}};$args.OutputPath=Join-Path $root ([guid]::NewGuid().ToString('N')+'.plan.json'); return (& $entry @args | ConvertFrom-Json) }
$plan=Invoke-TestPlan
Assert-RecipeTest $plan.ok 'exact recipe candidate admitted offline'
$receipt=Get-Content $plan.receiptPath -Raw | ConvertFrom-Json
Assert-RecipeTest ($receipt.fixedCatalogueBytes -eq (40981664+$baseDelta) -and $receipt.requiredStorageBytes -eq (58021024+$baseDelta) -and $receipt.byteBudgetHeadroom -eq (9087840-$baseDelta)) 'stage2048 views4096 events32768 exact accounting matches owner recipe'
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
foreach($case in @('commit','tree','buildKey','pdbGuid','pdbAge','coefficient','base','event','fraction','negative','parse','changed','layout-hash','failed-status','foreign-status','wrong-case')){
    $changed=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
    switch($case){'commit'{$changed.commit='0'*40};'tree'{$changed.tree='0'*40};'buildKey'{$changed.buildKey='sha256:'+('0'*64)};'pdbGuid'{$changed.pdbGuid=[guid]::NewGuid().ToString()};'pdbAge'{$changed.pdbAge++};'coefficient'{$changed.perCapacityBytes.maxStageShaderObservations++};'base'{$changed.baseBytes++};'event'{$changed.eventStorageUnitBytes++};'fraction'{$changed.perCapacityBytes.maxShaderObservations=1.5};'negative'{$changed.perCapacityBytes.maxShaderObservations=-1};'parse'{$changed.parseErrors=@('error')};'changed'{$changed.sourceChanged=$true};'layout-hash'{$changed.layoutReceipt.sha256='0'*64};'failed-status'{$changed.status='FAIL'};'foreign-status'{$changed.status='PASS_SOURCE_AND_EXACT_OTHER_PDB_ALLOCATION_RECIPE'};'wrong-case'{$changed.status=$changed.status.ToLowerInvariant()}}
    $path=Write-TestJson "recipe-$case.json" $changed
    $failed=Invoke-TestPlan @{AllocationRecipePath=$path;ExpectedAllocationRecipeSha256=(Get-FileHash $path -Algorithm SHA256).Hash}
    Assert-RecipeTest (-not $failed.ok -and -not $failed.receiptPublished -and $null -eq $failed.arguments) "recipe $case inconsistency fails before publication"
}
$events=$workload|ConvertTo-Json -Depth 30|ConvertFrom-Json;$events.expectedEvents=65537
$failed=Invoke-TestPlan @{WorkloadPath=(Write-TestJson 'too-many-events.json' $events)}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments -and @($failed.exceededCeilings|Where-Object bound -eq 'maxEvents').Count -eq 1) '65536 event ceiling remains absolute'
$failed=Invoke-TestPlan @{MaxBytes=(58021023+$baseDelta)}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'one byte below required storage refused'
$failed=Invoke-TestPlan @{MaxBytes=67108865}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'one byte beyond registry64MiB refused'
$minimal=Invoke-TestPlan @{MaxBytes=$null}
Assert-RecipeTest ($minimal.ok -and $minimal.arguments.maxBytes -eq (58021024+$baseDelta)) 'omitted budget selects exact required recipe accounting'
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
foreach($case in @('record-size','missing-type','duplicate-type','failed-status','mixed-status')){
    $badLayout=Get-Content $LayoutPath -Raw|ConvertFrom-Json
    if ($staticNativeRecipe) {
        switch($case) {
            'record-size' { $badLayout.calculation.pdbTypeSizes.'CSX::RenderMap::StageShaderObservationRecord'++ }
            'missing-type' { $badLayout.calculation.pdbTypeSizes.PSObject.Properties.Remove('CSX::RenderMap::StageShaderObservationRecord') }
            'duplicate-type' { $badLayout.calculation.pdbTypeSizes | Add-Member -NotePropertyName 'foreign' -NotePropertyValue 128 }
            'failed-status' { $badLayout.status='FAIL' }
            'mixed-status' { $badLayout.status='PASS_EXACT_AD8_PDB_LAYOUT' }
        }
    } else {
        switch($case){'record-size'{$badLayout.types[5].bytes++};'missing-type'{$badLayout.types=@($badLayout.types|Where-Object type -cne 'CSX::RenderMap::StageShaderObservationRecord')};'duplicate-type'{$badLayout.types+=@($badLayout.types[0])};'failed-status'{$badLayout.status='FAIL'};'mixed-status'{$badLayout.status=if($recipe.status -ceq 'PASS_SOURCE_AND_EXACT_AD8_PDB_ALLOCATION_RECIPE'){'PASS_EXACT_F362_PDB_LAYOUT'}else{'PASS_EXACT_AD8_PDB_LAYOUT'}}}
    }
    $path=Write-TestJson "layout-$case.json" $badLayout
    $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json;$badRecipe.layoutReceipt.sha256=(Get-FileHash $path -Algorithm SHA256).Hash
    $recipeFixture=Write-TestJson "layout-recipe-$case.json" $badRecipe
    $failed=Invoke-TestPlan @{AllocationLayoutPath=$path;AllocationRecipePath=$recipeFixture;ExpectedAllocationRecipeSha256=(Get-FileHash $recipeFixture -Algorithm SHA256).Hash}
    Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "PDB $case inconsistency fails before dispatch"
}
$overflow=$workload|ConvertTo-Json -Depth 30|ConvertFrom-Json;$overflow.expectedObservations.stageShader=[long]::MaxValue
if ($staticNativeRecipe) {
    foreach($case in @('schema','commit','tree','build-key','source-hash','layout-pdb','pdb-age','guid','bool','hash-budget','scope')) {
        $badLayout=Get-Content $LayoutPath -Raw|ConvertFrom-Json
        switch($case) {
            'schema' { $badLayout.schemaVersion='foreign' }
            'commit' { $badLayout.commit='0'*40 }
            'tree' { $badLayout.tree='0'*40 }
            'build-key' { $badLayout.buildKey='sha256:'+('0'*64) }
            'pdb-age' { $badLayout.pdbIdentity.age++ }
            'source-hash' { $badLayout.sourceHashes.'src/RenderMap/Collector.cpp'='0'*64 }
            'layout-pdb' { $badLayout.pdb.sha256='sha256:'+('0'*64) }
            'guid' { $badLayout.pdbIdentity.guid=[guid]::NewGuid().ToString() }
            'bool' { $badLayout.calculation.boolScalarBytes=2 }
            'hash-budget' { $badLayout.calculation.hashEntryBudgetBytes=65 }
            'scope' { $badLayout.artifactExecuted=$true }
        }
        $path=Write-TestJson "e03-layout-$case.json" $badLayout
        $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
        $badRecipe.layoutReceipt.sha256=(Get-FileHash $path -Algorithm SHA256).Hash
        $recipeFixture=Write-TestJson "e03-layout-recipe-$case.json" $badRecipe
        $failed=Invoke-TestPlan @{AllocationLayoutPath=$path;AllocationRecipePath=$recipeFixture;ExpectedAllocationRecipeSha256=(Get-FileHash $recipeFixture -Algorithm SHA256).Hash}
        Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "E03 layout $case refused after caller re-pin"
    }
    foreach($field in @('minor','schemaRevision')) {
        $changed=$registry|ConvertTo-Json -Depth 30|ConvertFrom-Json
        $changed.result.$field++
        $failed=Invoke-TestPlan @{RegistryPath=(Write-TestJson "e03-registry-$field.json" $changed)}
        Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "E03 registry $field mismatch refused"
        $changed=$registry|ConvertTo-Json -Depth 30|ConvertFrom-Json
        $changed.result.$field=[string]$changed.result.$field
        $failed=Invoke-TestPlan @{RegistryPath=(Write-TestJson "e03-registry-$field-type.json" $changed)}
        Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "E03 registry $field string refused"
    }
    foreach($case in @('native-build','issued-dll','issued-pdb','issued-manifest','return-hash','return-duplicate')) {
        $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
        switch($case) {
            'native-build' { $badRecipe.nativeBuildId='0'*64 }
            'issued-dll' { ($badRecipe.issuedArtifacts|Where-Object id -CEQ 'plugin-dll').sha256='sha256:'+('0'*64) }
            'issued-pdb' { ($badRecipe.issuedArtifacts|Where-Object id -CEQ 'plugin-pdb').sha256='sha256:'+('0'*64) }
            'issued-manifest' { ($badRecipe.issuedArtifacts|Where-Object id -CEQ 'build-manifest').sha256='sha256:'+('0'*64) }
            'return-hash' { ($badRecipe.verifiedFiles|Where-Object sha256 -CEQ ((Get-Content $LayoutPath -Raw|ConvertFrom-Json).nativeDeliverySha256)).sha256='0'*64 }
            'return-duplicate' { $badRecipe.verifiedFiles+=@($badRecipe.verifiedFiles|Where-Object sha256 -CEQ ((Get-Content $LayoutPath -Raw|ConvertFrom-Json).nativeDeliverySha256)) }
        }
        $path=Write-TestJson "e03-recipe-$case.json" $badRecipe
        $failed=Invoke-TestPlan @{AllocationRecipePath=$path;ExpectedAllocationRecipeSha256=(Get-FileHash $path -Algorithm SHA256).Hash}
        Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) "E03 recipe $case pairing mismatch refused"
    }
    # Re-pin only private fixture copies: a new hash must not waive native identity.
    foreach($case in @('schema','status','commit','build-key','dll','pdb','manifest','pdb-bytes')) {
        $badLayout=Get-Content $LayoutPath -Raw|ConvertFrom-Json
        $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
        $reference=@($badRecipe.verifiedFiles|Where-Object sha256 -CEQ $badLayout.nativeDeliverySha256)[0]
        $native=Get-Content $reference.path -Raw|ConvertFrom-Json
        switch($case) {
            'schema' { $native.schemaVersion='foreign' }
            'status' { $native.status='FAIL' }
            'commit' { $native.commit='0'*40 }
            'build-key' { $native.buildKey='sha256:'+('0'*64) }
            'dll' { ($native.files|Where-Object id -CEQ 'plugin-dll').sha256='sha256:'+('0'*64) }
            'pdb' { ($native.files|Where-Object id -CEQ 'plugin-pdb').sha256='sha256:'+('0'*64) }
            'manifest' { ($native.files|Where-Object id -CEQ 'build-manifest').sha256='sha256:'+('0'*64) }
            'pdb-bytes' { ($native.files|Where-Object id -CEQ 'plugin-pdb').bytes++ }
        }
        $nativePath=Write-TestJson "native-return-$case.json" $native
        $reference.path=$nativePath
        $reference.sha256=(Get-FileHash $nativePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $badLayout.nativeDeliverySha256=$reference.sha256
        $layoutFixture=Write-TestJson "native-layout-$case.json" $badLayout
        $badRecipe.layoutReceipt.sha256=(Get-FileHash $layoutFixture -Algorithm SHA256).Hash
        $recipeFixture=Write-TestJson "native-recipe-$case.json" $badRecipe
        $failed=Invoke-TestPlan @{AllocationLayoutPath=$layoutFixture;AllocationRecipePath=$recipeFixture;ExpectedAllocationRecipeSha256=(Get-FileHash $recipeFixture -Algorithm SHA256).Hash}
        Assert-RecipeTest (-not $failed.ok -and -not $failed.receiptPublished -and $null -eq $failed.arguments) "static native return $case refused after private re-pin"
    }
    if ($recipe.status -ceq 'PASS_SOURCE_AND_EXACT_217_PDB_ALLOCATION_RECIPE') {
        foreach($case in @('e03-source','ad8-source','e03-marker','ad8-marker')) {
            $badRecipe=$recipe|ConvertTo-Json -Depth 30|ConvertFrom-Json
            switch($case) {
                'e03-source' { $badRecipe.commit='e03bd1fd4790795f9dd205d9458f34ce96092ca8' }
                'ad8-source' { $badRecipe.commit='ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0' }
                'e03-marker' { $badRecipe.status='PASS_SOURCE_AND_EXACT_E03_PDB_ALLOCATION_RECIPE' }
                'ad8-marker' { $badRecipe.status='PASS_SOURCE_AND_EXACT_AD8_PDB_ALLOCATION_RECIPE' }
            }
            $path=Write-TestJson "217-$case.json" $badRecipe
            $failed=Invoke-TestPlan @{AllocationRecipePath=$path;ExpectedAllocationRecipeSha256=(Get-FileHash $path -Algorithm SHA256).Hash}
            Assert-RecipeTest (-not $failed.ok -and -not $failed.receiptPublished -and $null -eq $failed.arguments) "217 marker/source cross-pair $case refused"
        }
    }
}
$failed=Invoke-TestPlan @{WorkloadPath=(Write-TestJson 'overflow.json' $overflow)}
Assert-RecipeTest (-not $failed.ok -and $null -eq $failed.arguments) 'recipe multiplication overflow refused'
$late=Invoke-TestPlan @{InternalTestFailurePoint='receipt-hash'}
Assert-RecipeTest (-not $late.ok -and $late.state -eq 'plan-finalization-error' -and $late.receiptPublished -and $null -eq $late.arguments) 'published receipt finalization failure withholds dispatch arguments'
[pscustomobject]@{ok=$true;passed=$passes.Count;failed=0;scope='Synthetic registry fixtures against exact owner recipe/layout/build evidence; no native API or runtime mutation';checks=@($passes)}|ConvertTo-Json -Depth 5
