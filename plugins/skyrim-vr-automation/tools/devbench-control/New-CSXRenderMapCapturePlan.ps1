# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$WorkloadPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CommandId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1.0, 10.0)][double]$HeadroomFactor = 2.0,
    [string[]]$EventKinds,
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
        if (-not $property) { continue }
        if ($null -eq $property.Value) { throw "$Path.$name is present but has no supported registry status." }
        $statusName = if ($property.Value -is [string] -or $property.Value -is [ValueType]) {
            [string]$property.Value
        } else {
            [string](Get-Property $property.Value 'name')
        }
        $statusValue = if ($property.Value -is [string] -or $property.Value -is [ValueType]) {
            $null
        } else {
            Get-Property $property.Value 'value'
        }
        $supportedSuccessNames = @('success', 'ok', 'ready', 'completed', 'accepted', 'idle', 'available')
        if (($null -ne $statusValue -and ([string]$statusValue -notmatch '^-?\d+$' -or [long]$statusValue -ne 0)) -or
            [string]::IsNullOrWhiteSpace($statusName) -or $statusName -notin $supportedSuccessNames) {
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
            $toolProperty = $data.PSObject.Properties['tool']
            if ($toolProperty -and $toolProperty.Value -cne 'communityshaders.render_map') {
                throw 'Registry controller response is not bound to tool communityshaders.render_map.'
            }
            $contentItems = @($content)
            if ($contentItems.Count -ne 1 -or $null -eq $contentItems[0] -or
                $contentItems[0] -is [string] -or $contentItems[0] -is [ValueType]) {
                throw 'Registry controller response must contain exactly one structured registry payload.'
            }
            $candidate = $contentItems[0]
            Assert-RegistryEnvelopeSuccess $candidate 'registryEnvelope.data.content[0]'
        }
    }
    $result = Get-Property $candidate 'result'
    $registry = if ($null -ne $result) { $result } elseif (
        $null -ne (Get-Property $candidate 'defaults') -and
        $null -ne (Get-Property $candidate 'limits')) {
        $candidate
    } else { $null }
    if ($null -eq $registry) {
        throw 'RegistryPath does not contain a communityshaders.render-map registry result.'
    }
    Assert-RegistryEnvelopeSuccess $registry 'registry'
    $service = [string](Get-Property $registry 'service')
    if ($service -cne 'communityshaders.render-map') {
        throw 'Registry result is not bound to service communityshaders.render-map (tool communityshaders.render_map).'
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
    $requestedEventKinds = $null
    if ($PSBoundParameters.ContainsKey('EventKinds')) {
        $selection = Get-Property $registry 'eventSelection'
        if ((Get-Property $selection 'optional') -isnot [bool] -or -not (Get-Property $selection 'optional')) {
            throw 'Registry does not advertise optional event selection.'
        }
        if (@($EventKinds).Count -eq 0) { throw 'EventKinds must be a non-empty explicit selection.' }
        $advertisedKinds = @(Get-Property $registry 'eventKinds')
        if ($advertisedKinds.Count -eq 0 -or @($advertisedKinds | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw 'Registry eventKinds is not a non-empty string catalogue.'
        }
        $seenKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($kind in $EventKinds) {
            if ([string]::IsNullOrWhiteSpace($kind) -or $kind -cnotin $advertisedKinds -or -not $seenKinds.Add($kind)) {
                throw 'EventKinds must contain distinct exact names from registry.eventKinds; planned or unknown kinds are not selectable.'
            }
        }
        $requestedEventKinds = @($EventKinds)
    }

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
    $unprovenCatalogueBounds = [Collections.Generic.List[object]]::new()
    foreach ($spec in $specs) {
        $desired = Get-ScaledBound $spec.expected $HeadroomFactor "workload bound $($spec.argument)"
        $ceiling = Require-PositiveLong (Get-Property $limits $spec.limit) "registry.limits.$($spec.limit)"
        $selected[$spec.argument] = $desired
        if ($desired -gt $ceiling) {
            $exceeded.Add([pscustomobject]@{ bound = $spec.argument; desired = $desired; ceiling = $ceiling })
        }
        if ($spec.argument -like 'max*Observations') {
            $defaultCapacity = Require-PositiveLong (Get-Property $defaults $spec.argument) "registry.defaults.$($spec.argument)"
            if ($desired -gt $defaultCapacity) {
                $unprovenCatalogueBounds.Add([pscustomobject]@{ bound = $spec.argument; desired = $desired; defaultCapacity = $defaultCapacity })
            }
        }
    }
    $fixedCatalogueBytes = Require-PositiveLong (Get-Property $defaults 'fixedCatalogueBytes') 'registry.defaults.fixedCatalogueBytes'
    $eventStorageUnitBytes = Require-PositiveLong (Get-Property $defaults 'eventStorageUnitBytes') 'registry.defaults.eventStorageUnitBytes'
    $eventBytesWithHeadroom = Get-ScaledBound $expectedEventBytes $HeadroomFactor 'workload.expectedEventBytes'
    $requiredEventBytesDecimal = [decimal]$selected['maxEvents'] * [decimal]$eventStorageUnitBytes
    if ($requiredEventBytesDecimal -gt [decimal][long]::MaxValue) {
        throw 'registry eventStorageUnitBytes times the event count exceeds the supported 64-bit capture bound.'
    }
    $eventBytesWithHeadroom = [Math]::Max($eventBytesWithHeadroom, [long]$requiredEventBytesDecimal)
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

    $admissible = $exceeded.Count -eq 0 -and $unprovenCatalogueBounds.Count -eq 0
    $planState = if ($unprovenCatalogueBounds.Count -gt 0) { 'catalogue-storage-unproven' } elseif ($exceeded.Count -gt 0) { 'workload-exceeds-service-ceilings' } else { 'capture-plan-ready' }
    $planErrors = @()
    if ($unprovenCatalogueBounds.Count -gt 0) { $planErrors += 'Selected catalogue capacities exceed the registry defaults. The default fixedCatalogueBytes cannot prove their allocation cost; a native per-catalogue sizing recipe or a separately selected smaller workload is required. No start arguments were issued.' }
    if ($exceeded.Count -gt 0) { $planErrors += 'The stated workload plus headroom exceeds one or more live service ceilings; no start arguments were issued.' }
    $arguments = if ($admissible) {
        [ordered]@{
            contractMajor = [int]$resolvedRegistry.major
            clientId = $ClientId
            commandId = $CommandId
            action = 'start'
        } + $selected
    } else { $null }
    if ($arguments -and $null -ne $requestedEventKinds) { $arguments['eventKinds'] = $requestedEventKinds }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        state = $planState
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
        requestedEventKinds = $requestedEventKinds
        eventSelectionBasis = if ($null -ne $requestedEventKinds) { 'Exact advertised requested kinds; native dependency expansion/resolved selection must be retained from start response. Selection does not reduce catalogue allocation.' } else { 'Omitted selection retains native all-events default.' }
        rationale = 'Every count is the stated workload multiplied by explicit headroom. Byte budget is the registry default-catalogue upper bound plus the greater of workload event bytes with headroom and selected events times the native event storage unit. Default catalogue bytes qualify only capacities at or below the published defaults.'
        saturationPolicy = 'Any capture limit hit makes the evidence run incomplete unless saturation is the declared subject of the experiment.'
        fixedCatalogueBytes = $fixedCatalogueBytes
        catalogueStorageBasis = 'registry-default-catalogue-upper-bound; no extrapolation to larger capacities'
        eventStorageUnitBytes = $eventStorageUnitBytes
        selectedEventBytes = $eventBytesWithHeadroom
        selectedBounds = [pscustomobject]$selected
        exceededCeilings = @($exceeded)
        unprovenCatalogueBounds = @($unprovenCatalogueBounds)
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
        unprovenCatalogueBounds = @($unprovenCatalogueBounds)
        errors = $planErrors
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
