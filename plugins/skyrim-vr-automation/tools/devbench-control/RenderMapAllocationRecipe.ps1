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

function Get-RenderMapAllocationRecipe($ResolvedRegistry, [string]$RecipePath, [string]$RecipeSha256, [string]$LayoutPath, [string]$ManifestPath, [string]$ManifestSha256) {
    $capture = Read-RenderMapAllocationEvidence $RecipePath $RecipeSha256
    $recipe = $capture.data
    $expectedLayoutStatus = switch -CaseSensitive ($recipe.status) {
        'PASS_SOURCE_AND_EXACT_PDB_ALLOCATION_RECIPE' { 'PASS_EXACT_F362_PDB_LAYOUT' }
        'PASS_SOURCE_AND_EXACT_AD8_PDB_ALLOCATION_RECIPE' {
            if ($recipe.commit -cne 'ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0') { throw 'AD8 receipt marker requires exact qualified AD8 source.' }
            'PASS_EXACT_AD8_PDB_LAYOUT'
        }
        default { throw 'Unsupported allocation recipe qualification status.' }
    }
    if ($recipe.status -isnot [string] -or
        $recipe.sourceChanged -isnot [bool] -or $recipe.sourceChanged -or @($recipe.parseErrors).Count -ne 0) { throw 'Allocation recipe does not establish unchanged, parsed source/PDB evidence.' }
    $layoutCapture = Read-RenderMapAllocationEvidence $LayoutPath ([string]$recipe.layoutReceipt.sha256)
    $layout = $layoutCapture.data
    if ($layout.status -isnot [string] -or $layout.status -cne $expectedLayoutStatus -or $layout.sourceChanged -isnot [bool] -or $layout.sourceChanged -or @($layout.parseErrors).Count -ne 0) { throw 'Allocation layout is not a qualified immutable PDB receipt.' }
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
            scope='Hash-pinned owner source/paired-PDB admission formula; not heap/RSS, current artifact execution, allocation success or capture completeness.'
        }
    }
}
