# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$WorkloadPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CommandId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1.0, 10.0)][double]$HeadroomFactor = 2.0,
    [ValidateSet('none', 'receipt-hash')][string]$InternalTestFailurePoint = 'none',
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
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [char] -or $Value -is [string]) {
        throw "$Path must be a positive integer JSON number."
    }
    $numericTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64],
        [single], [double], [decimal]
    )
    if ($Value.GetType() -notin $numericTypes) {
        throw "$Path must be a positive integer JSON number."
    }
    try { $number = [decimal]$Value }
    catch { throw "$Path must be a representable positive integer." }
    if ($number -lt 1 -or [decimal]::Truncate($number) -ne $number -or
        $number -gt [decimal][long]::MaxValue) {
        throw "$Path must be a representable positive integer."
    }
    return [long]$number
}

function Get-ScaledBound([long]$Value, [double]$Factor, [string]$Path) {
    $scaled = [decimal]$Value * [decimal]$Factor
    $ceiling = [decimal]::Ceiling($scaled)
    if ($ceiling -gt [decimal][long]::MaxValue) {
        throw "$Path exceeds the supported 64-bit capture bound."
    }
    return [long]$ceiling
}

function Assert-RegistryEnvelopeSuccess($Value, [string]$Path) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
    foreach ($name in @('ok', 'success', 'passed')) {
        $property = $Value.PSObject.Properties[$name]
        if ($property -and ($property.Value -isnot [bool] -or -not [bool]$property.Value)) {
            throw "$Path.$name does not establish a successful registry response."
        }
    }
    foreach ($name in @('failed', 'aborted')) {
        $property = $Value.PSObject.Properties[$name]
        if ($property -and ($property.Value -isnot [bool] -or [bool]$property.Value)) {
            throw "$Path.$name reports a failed registry response."
        }
    }
    foreach ($name in @('error', 'errors')) {
        $property = $Value.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and @($property.Value).Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "$Path.$name contains registry failure evidence."
        }
    }
    foreach ($name in @('status', 'resultStatus')) {
        $property = $Value.PSObject.Properties[$name]
        if (-not $property -or $null -eq $property.Value) { continue }
        $statusName = Get-Property $property.Value 'name'
        $statusValue = Get-Property $property.Value 'value'
        if (($null -ne $statusValue -and [long]$statusValue -ne 0) -or
            ([string]$statusName -match '^(?i:fail|failed|error|rejected|guard_rejected)$')) {
            throw "$Path.$name reports a failed registry response."
        }
    }
}

function Resolve-Registry($Envelope) {
    Assert-RegistryEnvelopeSuccess $Envelope 'registryEnvelope'
    $candidate = $Envelope
    $data = Get-Property $candidate 'data'
    if ($null -ne $data) {
        Assert-RegistryEnvelopeSuccess $data 'registryEnvelope.data'
        $content = Get-Property $data 'content'
        if ($null -ne $content) {
            Assert-RegistryEnvelopeSuccess $content 'registryEnvelope.data.content'
            $candidate = $content
        }
    }
    $result = Get-Property $candidate 'result'
    $registry = if ($null -ne $result) { $result } elseif (
        $null -ne (Get-Property $candidate 'defaults') -and
        $null -ne (Get-Property $candidate 'limits')) {
        $candidate
    } else { $null }
    if ($null -eq $registry) {
        throw 'RegistryPath does not contain a communityshaders.render_map registry result.'
    }
    Assert-RegistryEnvelopeSuccess $registry 'registry'
    $service = [string](Get-Property $registry 'service')
    if ($service -cne 'communityshaders.render_map') {
        throw 'Registry result is not bound to service communityshaders.render_map.'
    }
    $major = Require-PositiveLong (Get-Property $registry 'major') 'registry.major'
    $producerBuildId = [string](Get-Property $registry 'producerBuildId')
    if ([string]::IsNullOrWhiteSpace($producerBuildId)) {
        $producerBuildId = [string](Get-Property (Get-Property $candidate 'server') 'buildId')
    }
    if ([string]::IsNullOrWhiteSpace($producerBuildId)) {
        $producerBuildId = [string](Get-Property (Get-Property $Envelope 'server') 'buildId')
    }
    if ([string]::IsNullOrWhiteSpace($producerBuildId)) {
        throw 'Registry result does not identify its producer build.'
    }
    return [pscustomobject]@{
        envelope = $candidate
        registry = $registry
        service = $service
        major = $major
        producerBuildId = $producerBuildId
    }
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

$publishedReceiptPath = $null
try {
    $resolvedRegistryPath = [IO.Path]::GetFullPath($RegistryPath)
    $registryBytes = [IO.File]::ReadAllBytes($resolvedRegistryPath)
    $registrySha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($registryBytes)
    )
    $registryText = [Text.UTF8Encoding]::new($false, $true).GetString($registryBytes)
    if ($registryText.Length -gt 0 -and $registryText[0] -eq [char]0xFEFF) {
        $registryText = $registryText.Substring(1)
    }
    $registryEnvelope = $registryText | ConvertFrom-Json -Depth 30
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
    $expectedScopeDepth = Require-PositiveLong (Get-Property $workload 'expectedScopeDepth') 'workload.expectedScopeDepth'
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
        $desired = Get-ScaledBound $spec.expected $HeadroomFactor "workload bound $($spec.argument)"
        $ceiling = Require-PositiveLong (Get-Property $limits $spec.limit) "registry.limits.$($spec.limit)"
        $selected[$spec.argument] = $desired
        if ($desired -gt $ceiling) {
            $exceeded.Add([pscustomobject]@{ bound = $spec.argument; desired = $desired; ceiling = $ceiling })
        }
    }
    $fixedCatalogueBytes = Require-PositiveLong (Get-Property $defaults 'fixedCatalogueBytes') 'registry.defaults.fixedCatalogueBytes'
    $eventBytesWithHeadroom = Get-ScaledBound $expectedEventBytes $HeadroomFactor 'workload.expectedEventBytes'
    $desiredBytesDecimal = [decimal]$fixedCatalogueBytes + [decimal]$eventBytesWithHeadroom
    if ($desiredBytesDecimal -gt [decimal][long]::MaxValue) {
        throw 'registry.defaults.fixedCatalogueBytes plus the event-byte workload exceeds the supported 64-bit capture bound.'
    }
    $desiredBytes = [long]$desiredBytesDecimal
    $maximumBytes = Require-PositiveLong (Get-Property $limits 'maximumBytes') 'registry.limits.maximumBytes'
    $selected['maxBytes'] = $desiredBytes
    if ($desiredBytes -gt $maximumBytes) {
        $exceeded.Add([pscustomobject]@{ bound = 'maxBytes'; desired = $desiredBytes; ceiling = $maximumBytes })
    }

    $admissible = $exceeded.Count -eq 0
    $arguments = if ($admissible) {
        [ordered]@{
            contractMajor = [int]$resolvedRegistry.major
            clientId = $ClientId
            commandId = $CommandId
            action = 'start'
        } + $selected
    } else { $null }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        state = if ($admissible) { 'capture-plan-ready' } else { 'workload-exceeds-service-ceilings' }
        admissible = $admissible
        service = $resolvedRegistry.service
        commandId = $CommandId
        clientId = $ClientId
        producerBuildId = $resolvedRegistry.producerBuildId
        registryPath = $resolvedRegistryPath
        registrySha256 = $registrySha256
        registryContractMajor = $resolvedRegistry.major
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
    $publishedReceiptPath = Write-JsonAtomic -Path $OutputPath -Value $receipt
    if ($InternalTestFailurePoint -eq 'receipt-hash') {
        throw 'Injected receipt hash failure after immutable publication.'
    }
    $receiptSha256 = (Get-FileHash -LiteralPath $publishedReceiptPath -Algorithm SHA256).Hash
    $result = [pscustomobject][ordered]@{
        ok = $admissible
        state = $receipt.state
        receiptPath = $publishedReceiptPath
        receiptPublished = $true
        receiptSha256 = $receiptSha256
        arguments = $receipt.arguments
        exceededCeilings = @($exceeded)
        errors = if ($admissible) { @() } else { @('The stated workload plus headroom exceeds one or more live service ceilings; no start arguments were issued.') }
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        ok = $false
        state = if ($publishedReceiptPath) { 'plan-finalization-error' } else { 'plan-error' }
        receiptPath = $publishedReceiptPath
        receiptPublished = $null -ne $publishedReceiptPath
        receiptSha256 = $null
        arguments = $null
        exceededCeilings = @()
        errors = @($_.Exception.Message)
    }
}

$result | ConvertTo-Json -Depth 20 -Compress:$Compact
if (-not $result.ok -and -not $NoExit) { exit 2 }
