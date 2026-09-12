# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$WorkloadPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CommandId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1.0, 10.0)][double]$HeadroomFactor = 2.0,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Property($Value, [string]$Name, $Default = $null) {
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Require-PositiveLong($Value, [string]$Path) {
    if ($null -eq $Value -or [long]$Value -lt 1) { throw "$Path must be a positive integer." }
    return [long]$Value
}

function Resolve-Registry($Envelope) {
    $candidate = $Envelope
    $data = Get-Property $candidate 'data'
    if ($null -ne $data) {
        $content = Get-Property $data 'content'
        if ($null -ne $content) { $candidate = $content }
    }
    $result = Get-Property $candidate 'result'
    if ($null -ne $result) { return [pscustomobject]@{ envelope = $candidate; registry = $result } }
    if ($null -ne (Get-Property $candidate 'defaults') -and $null -ne (Get-Property $candidate 'limits')) {
        return [pscustomobject]@{ envelope = $candidate; registry = $candidate }
    }
    throw 'RegistryPath does not contain a communityshaders.render_map registry result.'
}

function Write-JsonAtomic([string]$Path, $Value) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'OutputPath must have a parent directory.' }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $resolved) { throw "Refusing to overwrite an existing capture plan: $resolved" }
    $temporary = "$resolved.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -Depth 20
        Move-Item -LiteralPath $temporary -Destination $resolved
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $resolved
}

try {
    $registryEnvelope = Get-Content -LiteralPath ([IO.Path]::GetFullPath($RegistryPath)) -Raw | ConvertFrom-Json -Depth 30
    $workload = Get-Content -LiteralPath ([IO.Path]::GetFullPath($WorkloadPath)) -Raw | ConvertFrom-Json -Depth 20
    $resolvedRegistry = Resolve-Registry $registryEnvelope
    $registry = $resolvedRegistry.registry
    $defaults = Get-Property $registry 'defaults'
    $limits = Get-Property $registry 'limits'
    if ($null -eq $defaults -or $null -eq $limits) { throw 'Registry result must publish defaults and limits.' }

    $expectedDurationMs = Require-PositiveLong (Get-Property $workload 'expectedDurationMs') 'workload.expectedDurationMs'
    $expectedFrames = Require-PositiveLong (Get-Property $workload 'expectedFrames') 'workload.expectedFrames'
    $expectedEvents = Require-PositiveLong (Get-Property $workload 'expectedEvents') 'workload.expectedEvents'
    $expectedEventBytes = Require-PositiveLong (Get-Property $workload 'expectedEventBytes') 'workload.expectedEventBytes'
    $expectedScopeDepth = Require-PositiveLong (Get-Property $workload 'expectedScopeDepth' 1) 'workload.expectedScopeDepth'
    $observations = Get-Property $workload 'expectedObservations'
    if ($null -eq $observations) { throw 'workload.expectedObservations is required.' }

    $specs = @(
        [pscustomobject]@{ argument = 'maxDurationMs'; expected = $expectedDurationMs; limit = 'maximumDurationMs' },
        [pscustomobject]@{ argument = 'maxFrames'; expected = $expectedFrames; limit = 'maximumFrames' },
        [pscustomobject]@{ argument = 'maxEvents'; expected = $expectedEvents; limit = 'maximumEvents' },
        [pscustomobject]@{ argument = 'maxScopeDepth'; expected = $expectedScopeDepth; limit = 'maximumScopeDepth' },
        [pscustomobject]@{ argument = 'maxGeometryObservations'; expected = (Require-PositiveLong (Get-Property $observations 'geometry') 'workload.expectedObservations.geometry'); limit = 'maximumGeometryObservations' },
        [pscustomobject]@{ argument = 'maxMaterialStateObservations'; expected = (Require-PositiveLong (Get-Property $observations 'materialState') 'workload.expectedObservations.materialState'); limit = 'maximumMaterialStateObservations' },
        [pscustomobject]@{ argument = 'maxResourceObservations'; expected = (Require-PositiveLong (Get-Property $observations 'resource') 'workload.expectedObservations.resource'); limit = 'maximumResourceObservations' },
        [pscustomobject]@{ argument = 'maxSceneObjectObservations'; expected = (Require-PositiveLong (Get-Property $observations 'sceneObject') 'workload.expectedObservations.sceneObject'); limit = 'maximumSceneObjectObservations' },
        [pscustomobject]@{ argument = 'maxShaderObservations'; expected = (Require-PositiveLong (Get-Property $observations 'shader') 'workload.expectedObservations.shader'); limit = 'maximumShaderObservations' },
        [pscustomobject]@{ argument = 'maxStageShaderObservations'; expected = (Require-PositiveLong (Get-Property $observations 'stageShader') 'workload.expectedObservations.stageShader'); limit = 'maximumStageShaderObservations' },
        [pscustomobject]@{ argument = 'maxTargetBindingObservations'; expected = (Require-PositiveLong (Get-Property $observations 'targetBinding') 'workload.expectedObservations.targetBinding'); limit = 'maximumTargetBindingObservations' },
        [pscustomobject]@{ argument = 'maxTargetViewObservations'; expected = (Require-PositiveLong (Get-Property $observations 'targetView') 'workload.expectedObservations.targetView'); limit = 'maximumTargetViewObservations' }
    )

    $selected = [ordered]@{}
    $exceeded = [Collections.Generic.List[object]]::new()
    foreach ($spec in $specs) {
        $desired = [long][Math]::Ceiling([double]$spec.expected * $HeadroomFactor)
        $ceiling = Require-PositiveLong (Get-Property $limits $spec.limit) "registry.limits.$($spec.limit)"
        $selected[$spec.argument] = $desired
        if ($desired -gt $ceiling) {
            $exceeded.Add([pscustomobject]@{ bound = $spec.argument; desired = $desired; ceiling = $ceiling })
        }
    }
    $fixedCatalogueBytes = Require-PositiveLong (Get-Property $defaults 'fixedCatalogueBytes') 'registry.defaults.fixedCatalogueBytes'
    $desiredBytes = [long]($fixedCatalogueBytes + [Math]::Ceiling([double]$expectedEventBytes * $HeadroomFactor))
    $maximumBytes = Require-PositiveLong (Get-Property $limits 'maximumBytes') 'registry.limits.maximumBytes'
    $selected['maxBytes'] = $desiredBytes
    if ($desiredBytes -gt $maximumBytes) {
        $exceeded.Add([pscustomobject]@{ bound = 'maxBytes'; desired = $desiredBytes; ceiling = $maximumBytes })
    }

    $admissible = $exceeded.Count -eq 0
    $arguments = if ($admissible) {
        [ordered]@{
            contractMajor = [int](Get-Property $registry 'major' 1)
            clientId = $ClientId
            commandId = $CommandId
            action = 'start'
        } + $selected
    } else { $null }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        state = if ($admissible) { 'capture-plan-ready' } else { 'workload-exceeds-service-ceilings' }
        admissible = $admissible
        service = 'communityshaders.render_map'
        commandId = $CommandId
        clientId = $ClientId
        producerBuildId = Get-Property (Get-Property $resolvedRegistry.envelope 'server') 'buildId'
        workload = $workload
        headroomFactor = $HeadroomFactor
        rationale = 'Every bound is the stated workload multiplied by explicit headroom; maxBytes additionally includes the registry fixedCatalogueBytes allocation.'
        saturationPolicy = 'Any capture limit hit makes the evidence run incomplete unless saturation is the declared subject of the experiment.'
        fixedCatalogueBytes = $fixedCatalogueBytes
        selectedBounds = [pscustomobject]$selected
        exceededCeilings = @($exceeded)
        arguments = if ($arguments) { [pscustomobject]$arguments } else { $null }
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $written = Write-JsonAtomic -Path $OutputPath -Value $receipt
    $result = [pscustomobject][ordered]@{
        ok = $admissible
        state = $receipt.state
        receiptPath = $written
        receiptSha256 = (Get-FileHash -LiteralPath $written -Algorithm SHA256).Hash
        arguments = $receipt.arguments
        exceededCeilings = @($exceeded)
        errors = if ($admissible) { @() } else { @('The stated workload plus headroom exceeds one or more live service ceilings; no start arguments were issued.') }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; state = 'plan-error'; receiptPath = $null; arguments = $null; exceededCeilings = @(); errors = @($_.Exception.Message) }
}

$result | ConvertTo-Json -Depth 20 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
