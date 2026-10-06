# SPDX-License-Identifier: GPL-3.0-or-later

# An explicitly hash-pinned owner recipe is evidence, not executable code.
# Read bounded immutable bytes once; all JSON and hashes use that same capture.
function Read-RenderMapAllocationEvidence([string]$Path, [string]$ExpectedSha256) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Allocation evidence requires an explicit path and expected SHA256.' }
    $resolved = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::OpenRead($resolved)
    try {
        if ($stream.Length -gt 262144) { throw 'Allocation evidence exceeds the 256 KiB JSON bound.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes,0,$bytes.Length)
        if ($stream.Length -ne $bytes.Length) { throw 'Allocation evidence changed during bounded capture.' }
    } finally { $stream.Dispose() }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($hash -ine $ExpectedSha256) { throw "Allocation evidence SHA256 mismatch: $resolved" }
    $value = [Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -Depth 30
    return [pscustomobject]@{path=$resolved;sha256=$hash;bytes=$bytes.Length;data=$value}
}

function Convert-E03AllocationLayout($Recipe, $Layout) {
    # Project only verified fields; never rewrite the retained native receipt.
    if ($Recipe.schemaVersion -cne 'csx.writer.production-pdb-allocation.1' -or
        $Layout.schemaVersion -cne 'csx.exact-native-pdb-admission-layout.1' -or
        $Layout.status -cne 'VERIFIED_STATIC_NATIVE_PDB_LAYOUT') { throw 'Unsupported E03 PDB layout contract.' }
    foreach ($field in @('commit','tree','buildKey')) {
        if ([string]$Layout.$field -cne [string]$Recipe.$field) { throw "E03 layout identity mismatch: $field" }
    }
    if ($Layout.pdbIdentity.guid -cne $Recipe.pdbGuid -or
        (Require-PositiveLong $Layout.pdbIdentity.age 'layout.pdbIdentity.age') -ne
        (Require-PositiveLong $Recipe.pdbAge 'recipe.pdbAge')) { throw 'E03 PDB identity mismatch.' }
    foreach ($field in @('artifactExecuted','testsRun','compilerInvoked','installationPerformed','deploymentPerformed')) {
        if ($Layout.$field -isnot [bool] -or $Layout.$field) { throw "E03 layout scope mismatch: $field" }
    }
    foreach ($source in $Recipe.sourceFiles) {
        if ($source.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            (Get-Property $Layout.sourceHashes $source.path) -cne $source.sha256) { throw 'E03 source hash mismatch.' }
    }
    if (@($Recipe.sourceFiles).Count -ne 3 -or @($Layout.sourceHashes.PSObject.Properties).Count -ne 3) { throw 'E03 source closure mismatch.' }
    foreach ($field in @('hashEntryBudgetBytes','boolScalarBytes')) {
        $expected = if ($field -ceq 'boolScalarBytes') { 1 } else { 64 }
        if ((Require-PositiveLong $Recipe.$field "recipe.$field") -ne $expected -or
            (Require-PositiveLong $Layout.calculation.$field "layout.calculation.$field") -ne $expected) { throw 'E03 scalar/hash admission basis mismatch.' }
    }
    $types = [Collections.Generic.List[object]]::new()
    foreach ($property in $Layout.calculation.pdbTypeSizes.PSObject.Properties) {
        $bytes = Require-PositiveLong $property.Value "layout.type.$($property.Name)"
        if ($bytes -ne (Require-PositiveLong (Get-Property $Recipe.pdbTypeSizes $property.Name) "recipe.type.$($property.Name)")) { throw 'E03 recipe/PDB type mismatch.' }
        $types.Add([pscustomobject]@{type=$property.Name;bytes=$bytes})
    }
    if ($types.Count -ne 15 -or @($Recipe.pdbTypeSizes.PSObject.Properties).Count -ne 15) { throw 'E03 PDB type coverage mismatch.' }
    $types.Add([pscustomobject]@{type='bool';bytes=$Layout.calculation.boolScalarBytes})
    $returns = @($Recipe.verifiedFiles | Where-Object { $_.sha256 -ceq $Layout.nativeDeliverySha256 })
    if ($returns.Count -ne 1) { throw 'E03 paired native-return receipt is not uniquely pinned.' }
    $nativeCapture = Read-RenderMapAllocationEvidence $returns[0].path $Layout.nativeDeliverySha256
    $native = $nativeCapture.data
    if ($native.schemaVersion -cne 'csx.recovered-native-return.1' -or
        $native.status -cne 'VERIFIED_COMPILE_SUCCESS' -or $native.commit -cne $Recipe.commit -or
        $native.buildKey -cne $Recipe.buildKey) { throw 'E03 paired native-return identity mismatch.' }
    $sources = [ordered]@{}
    foreach ($id in @('plugin-dll','plugin-pdb','build-manifest')) {
        $files = @($native.files | Where-Object id -CEQ $id)
        $issued = @($Recipe.issuedArtifacts | Where-Object id -CEQ $id)
        if ($files.Count -ne 1 -or $issued.Count -ne 1 -or
            $files[0].sha256 -cnotmatch '^sha256:[a-f0-9]{64}$' -or
            $files[0].sha256 -cne $issued[0].sha256 -or
            (Require-PositiveLong $files[0].bytes "native.$id.bytes") -ne
            (Require-PositiveLong $issued[0].bytes "recipe.$id.bytes")) { throw 'E03 issued/native artifact pairing mismatch.' }
        $sources[$files[0].path] = [pscustomobject]@{bytes=$files[0].bytes;sha256=$files[0].sha256.Substring(7)}
        if ($id -ceq 'plugin-pdb' -and ($Layout.pdb.sha256 -cne $files[0].sha256 -or
            (Require-PositiveLong $Layout.pdb.bytes 'layout.pdb.bytes') -ne $files[0].bytes)) { throw 'E03 layout/native PDB mismatch.' }
    }
    if (@($native.files).Count -ne 3 -or @($Recipe.issuedArtifacts).Count -ne 3) { throw 'E03 native artifact coverage mismatch.' }
    return [pscustomobject]@{commit=$Layout.commit;tree=$Layout.tree;buildKey=$Layout.buildKey;
        pdbGuid=$Layout.pdbIdentity.guid;pdbAge=$Layout.pdbIdentity.age;types=@($types);
        sourceFiles=[pscustomobject]$sources;nativeReturnPath=$nativeCapture.path;nativeReturnSha256=$nativeCapture.sha256}
}

function Get-RenderMapAllocationRecipe($ResolvedRegistry, [string]$RecipePath, [string]$RecipeSha256, [string]$LayoutPath, [string]$ManifestPath, [string]$ManifestSha256) {
    $capture = Read-RenderMapAllocationEvidence $RecipePath $RecipeSha256
    $recipe = $capture.data
    $expectedLayoutStatus = switch -CaseSensitive ($recipe.status) {
        'PASS_SOURCE_AND_EXACT_PDB_ALLOCATION_RECIPE' { 'PASS_EXACT_F362_PDB_LAYOUT' }
        'PASS_SOURCE_AND_EXACT_AD8_PDB_ALLOCATION_RECIPE' {
            if ($recipe.commit -cne 'ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0') { throw 'AD8 receipt marker requires exact qualified AD8 source.' }
            'PASS_EXACT_AD8_PDB_LAYOUT'
        }
        'PASS_SOURCE_AND_EXACT_E03_PDB_ALLOCATION_RECIPE' {
            if ($recipe.commit -cne 'e03bd1fd4790795f9dd205d9458f34ce96092ca8') { throw 'E03 receipt marker requires exact qualified E03 source.' }
            'VERIFIED_STATIC_NATIVE_PDB_LAYOUT'
        }
        'PASS_SOURCE_AND_EXACT_217_PDB_ALLOCATION_RECIPE' {
            if ($recipe.commit -cne '217992d1e29e55a707d6e41c3ca111b2154904fa') { throw '217 receipt marker requires exact qualified 217 source.' }
            # The same static-native contract/identity guards apply; no parent layout is reused.
            'VERIFIED_STATIC_NATIVE_PDB_LAYOUT'
        }
        default { throw 'Unsupported allocation recipe qualification status.' }
    }
    if ($recipe.status -isnot [string] -or
        $recipe.sourceChanged -isnot [bool] -or $recipe.sourceChanged -or @($recipe.parseErrors).Count -ne 0) { throw 'Allocation recipe does not establish unchanged, parsed source/PDB evidence.' }
    $layoutCapture = Read-RenderMapAllocationEvidence $LayoutPath ([string]$recipe.layoutReceipt.sha256)
    $layout = $layoutCapture.data
    if ($expectedLayoutStatus -ceq 'VERIFIED_STATIC_NATIVE_PDB_LAYOUT') {
        $layout = Convert-E03AllocationLayout $recipe $layout
    } elseif ($layout.status -isnot [string] -or $layout.status -cne $expectedLayoutStatus -or $layout.sourceChanged -isnot [bool] -or $layout.sourceChanged -or @($layout.parseErrors).Count -ne 0) { throw 'Allocation layout is not a qualified immutable PDB receipt.' }
    foreach ($field in @('commit','tree','buildKey','pdbGuid')) {
        if ([string]::IsNullOrWhiteSpace([string]$recipe.$field) -or [string]$recipe.$field -cne [string]$layout.$field) { throw "Recipe/PDB identity mismatch: $field" }
    }
    if ($recipe.commit -cnotmatch '^[a-f0-9]{40}$' -or $recipe.tree -cnotmatch '^[a-f0-9]{40}$' -or $recipe.buildKey -cnotmatch '^sha256:[a-f0-9]{64}$' -or
        -not [guid]::TryParse([string]$recipe.pdbGuid,[ref]([guid]::Empty))) { throw 'Malformed source/build/PDB identity.' }
    $age = Require-PositiveLong $recipe.pdbAge 'recipe.pdbAge'
    if ($age -ne (Require-PositiveLong $layout.pdbAge 'layout.pdbAge')) { throw 'Recipe/PDB age mismatch.' }
    $manifestCapture = Read-RenderMapAllocationEvidence $ManifestPath $ManifestSha256
    $manifest = $manifestCapture.data
    if ($manifest.schema -cne 'community-shaders.build-provenance' -or $manifest.schemaVersion -ne 1 -or
        $manifest.identity.source.commit -cne $recipe.commit -or $manifest.identity.source.dirty -isnot [bool] -or $manifest.identity.source.dirty -or
        $manifest.buildId -cne $ResolvedRegistry.producerBuildId) { throw 'Native registry/build-manifest/source identity mismatch.' }
    if ($expectedLayoutStatus -ceq 'VERIFIED_STATIC_NATIVE_PDB_LAYOUT' -and
        $recipe.nativeBuildId -cne $manifest.buildId) { throw 'E03 native build identity mismatch.' }
    if ($expectedLayoutStatus -ceq 'VERIFIED_STATIC_NATIVE_PDB_LAYOUT') {
        if ((Require-PositiveLong (Get-Property $ResolvedRegistry.registry 'minor') 'registry.minor') -ne 24 -or
            (Require-PositiveLong (Get-Property $ResolvedRegistry.registry 'schemaRevision') 'registry.schemaRevision') -ne 26) { throw 'E03 registry API/schema identity mismatch.' }
        $nativeManifests = @($layout.sourceFiles.PSObject.Properties | Where-Object { [IO.Path]::GetFileName($_.Name) -ceq 'CSX.BuildManifest.json' })
        if ($nativeManifests.Count -ne 1 -or $nativeManifests[0].Value.sha256 -ine $manifestCapture.sha256 -or
            $nativeManifests[0].Value.bytes -ne $manifestCapture.bytes) { throw 'E03 paired native manifest differs from selected evidence.' }
    }
    $dlls = @($layout.sourceFiles.PSObject.Properties | Where-Object { [IO.Path]::GetFileName($_.Name) -ceq 'CommunityShaders.dll' })
    $pdbs = @($layout.sourceFiles.PSObject.Properties | Where-Object { [IO.Path]::GetFileName($_.Name) -ceq 'CommunityShaders.pdb' })
    if ($dlls.Count -ne 1 -or $pdbs.Count -ne 1 -or $manifest.artifact.fileName -cne 'CommunityShaders.dll' -or
        [string]$dlls[0].Value.sha256 -cne [string]$manifest.artifact.sha256 -or
        (Require-PositiveLong $dlls[0].Value.bytes 'layout.dll.bytes') -ne (Require-PositiveLong $manifest.artifact.sizeBytes 'manifest.artifact.sizeBytes') -or
        [string]$pdbs[0].Value.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Paired PDB/DLL receipt does not match the native build artifact.' }
    $types = @{}
    foreach ($type in $layout.types) {
        if ($types.ContainsKey([string]$type.type)) { throw 'Duplicate PDB type layout.' }
        $types[[string]$type.type] = Require-PositiveLong $type.bytes "layout.type.$($type.type)"
    }
    $base = [decimal]$types['CSX::RenderMap::Collector::Session'] + [decimal]$types['CSX::RenderMap::CaptureSnapshot']
    $eventUnit = [decimal]$types['CSX::RenderMap::Collector::Session::Slot'] + [decimal]$types['CSX::RenderMap::EventRecord']
    if ($base -ne (Require-PositiveLong $recipe.baseBytes 'recipe.baseBytes') -or $eventUnit -ne (Require-PositiveLong $recipe.eventStorageUnitBytes 'recipe.eventStorageUnitBytes') -or $types['bool'] -ne 1) { throw 'Recipe base/event/bool differs from paired PDB sizes.' }
    $families = [ordered]@{
        maxShaderObservations=@('ShaderObservationRecord','maximumShaderObservations',65)
        maxStageShaderObservations=@('StageShaderObservationRecord','maximumStageShaderObservations',128)
        maxResourceObservations=@('ResourceObservationRecord','maximumResourceObservations',64)
        maxTargetViewObservations=@('TargetViewObservationRecord','maximumTargetViewObservations',64)
        maxTargetBindingObservations=@('TargetBindingObservationRecord','maximumTargetBindingObservations',64)
        maxSceneObjectObservations=@('SceneObjectObservationRecord','maximumSceneObjectObservations',64)
        maxGeometryObservations=@('GeometryObservationRecord','maximumGeometryObservations',64)
        maxMaterialStateObservations=@('MaterialStateObservationRecord','maximumMaterialStateObservations',64)
    }
    $defaultCost = $base
    foreach ($name in $families.Keys) {
        $term = $families[$name]
        $coefficient = Require-PositiveLong (Get-Property $recipe.perCapacityBytes $name) "recipe.perCapacityBytes.$name"
        $recordBytes = Require-PositiveLong $types[('CSX::RenderMap::' + $term[0])] "layout.$($term[0])"
        if ([decimal]$coefficient -ne 2*[decimal]$recordBytes + [decimal]$term[2]) { throw "Recipe coefficient/PDB mismatch: $name" }
        $default = Require-PositiveLong (Get-Property $recipe.defaults $name) "recipe.defaults.$name"
        if ($default -ne (Require-PositiveLong (Get-Property $ResolvedRegistry.registry.defaults $name) "registry.defaults.$name")) { throw "Fresh registry default differs from recipe: $name" }
        $null = Require-PositiveLong (Get-Property $recipe.limits $name) "recipe.limits.$name"
        $defaultCost += [decimal]$default * $coefficient
    }
    if ($defaultCost -ne (Require-PositiveLong $ResolvedRegistry.registry.defaults.fixedCatalogueBytes 'registry.defaults.fixedCatalogueBytes') -or
        $eventUnit -ne (Require-PositiveLong $ResolvedRegistry.registry.defaults.eventStorageUnitBytes 'registry.defaults.eventStorageUnitBytes')) { throw 'Fresh native default allocation differs from recipe/PDB.' }
    foreach ($name in @('maxEvents','maxBytes')) {
        if ((Require-PositiveLong (Get-Property $recipe.defaults $name) "recipe.defaults.$name") -ne
            (Require-PositiveLong (Get-Property $ResolvedRegistry.registry.defaults $name) "registry.defaults.$name")) { throw "Fresh registry default differs from recipe: $name" }
        $null = Require-PositiveLong (Get-Property $recipe.limits $name) "recipe.limits.$name"
    }
    if ($ResolvedRegistry.major -ne 1) { throw 'Allocation recipe is supported only for render-map contract major1.' }
    return [pscustomobject]@{
        recipe=$recipe;families=$families
        evidence=[pscustomobject]@{
            recipePath=$capture.path;recipeSha256=$capture.sha256;layoutPath=$layoutCapture.path;layoutSha256=$layoutCapture.sha256
            buildManifestPath=$manifestCapture.path;buildManifestSha256=$manifestCapture.sha256
            sourceCommit=$recipe.commit;sourceTree=$recipe.tree;buildKey=$recipe.buildKey;producerBuildId=$manifest.buildId
            artifactSha256=$manifest.artifact.sha256;pdbSha256=$pdbs[0].Value.sha256;pdbGuid=$recipe.pdbGuid;pdbAge=$age
            pairedNativeReturn=if($expectedLayoutStatus -ceq 'VERIFIED_STATIC_NATIVE_PDB_LAYOUT') {
                [pscustomobject]@{path=$layout.nativeReturnPath;sha256=$layout.nativeReturnSha256}
            } else { $null }
            scope='Hash-pinned owner source/paired-PDB admission formula; not heap/RSS, current artifact execution, allocation success or capture completeness.'
        }
    }
}
