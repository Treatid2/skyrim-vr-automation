# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\devbench-control\DevBenchControl.psm1') -Force

function Invoke-CocMcpRequest {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Payload,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint `
        -Headers $Headers -Body ($Payload | ConvertTo-Json -Depth 50 -Compress) `
        -TimeoutSec $TimeoutSeconds
    return [pscustomobject]@{
        response = $response
        json = $response.Content | ConvertFrom-Json -Depth 80
    }
}

function Open-CocMcpSession {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    $baseHeaders = @{
        Accept = 'application/json, text/event-stream'
        'Content-Type' = 'application/json'
    }
    $initialize = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $baseHeaders -TimeoutSeconds $TimeoutSeconds -Payload @{
            jsonrpc = '2.0'
            id = [DateTime]::UtcNow.Ticks
            method = 'initialize'
            params = @{
                protocolVersion = '2025-03-26'
                capabilities = @{}
                clientInfo = @{ name = 'CocStabilityControl'; version = '1.0' }
            }
        }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) {
        [string]$sessionHeader[0]
    } else {
        [string]$sessionHeader
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'DevBench did not return an MCP session ID.'
    }

    $headers = @{
        Accept = 'application/json, text/event-stream'
        'Content-Type' = 'application/json'
        'Mcp-Session-Id' = $sessionId
    }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint `
        -Headers $headers -TimeoutSec $TimeoutSeconds `
        -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' |
        Out-Null
    return [pscustomobject]@{ id = $sessionId; headers = $headers }
}

function Invoke-CocMcpTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [pscustomobject]$Session,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    if ($null -eq $Session) {
        $Session = Open-CocMcpSession -Endpoint $Endpoint `
            -TimeoutSeconds $TimeoutSeconds
    }

    $call = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $Session.headers -TimeoutSeconds $TimeoutSeconds -Payload @{
            jsonrpc = '2.0'
            id = [DateTime]::UtcNow.Ticks
            method = 'tools/call'
            params = @{ name = $Tool; arguments = $Arguments }
        }
    if ($call.json.PSObject.Properties['error']) {
        throw "DevBench tools/call failed: $($call.json.error | ConvertTo-Json -Compress)"
    }
    if ($call.json.result.PSObject.Properties['isError'] -and
        [bool]$call.json.result.isError) {
        $message = (@($call.json.result.content) | ForEach-Object text) -join "`n"
        throw "DevBench tool '$Tool' failed: $message"
    }

    $content = [Collections.Generic.List[object]]::new()
    foreach ($item in @($call.json.result.content)) {
        if ($item.type -eq 'text') {
            try { $content.Add(($item.text | ConvertFrom-Json -Depth 80)) }
            catch { $content.Add([string]$item.text) }
        } else {
            $content.Add($item)
        }
    }
    return [pscustomobject][ordered]@{
        tool = $Tool
        sessionId = $Session.id
        content = @($content)
        value = @($content | Select-Object -First 1)[0]
        rawResult = $call.json.result
    }
}

function New-CocMeasuredScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProtocolConfig,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$OwnerId
    )

    $startCell = [string]$ProtocolConfig.startCellEditorId
    $interiorCell = [string]$ProtocolConfig.interiorCellEditorId
    if ($startCell -ne 'WindhelmExterior01' -or
        $interiorCell -ne 'WhiterunDragonsreach') {
        throw 'The protocol config does not describe the fixed COC route.'
    }
    $transitionCount = [int]$ProtocolConfig.transitionCount
    if ($transitionCount -ne 20) { throw 'The measured COC run must contain 20 transitions.' }

    $qualification = $ProtocolConfig.qualification
    if ($null -eq $qualification -or
        [string]$qualification.milestone -ne 'strict' -or
        [int]$qualification.timeoutMs -ne 30000) {
        throw 'The measured COC run requires strict qualification with a 30-second maximum deadline.'
    }
    $requiredPreparationEvents = @(
        'request_queued', 'admission_check', 'early_exit',
        'shader_cache_busy_wait', 'sss_raymarch_prewarm', 'ssgi_prewarm',
        'dlss_preparation', 'fsr_preparation', 'fsr4_preparation',
        'd3d_object_creation', 'total_preparation', 'request_to_prepared',
        'prepared_to_creator'
    )
    $telemetryContract = Get-CocPropertyValue -Value $ProtocolConfig `
        -Name 'telemetry'
    $preparationContract = if ($null -ne $telemetryContract) {
        Get-CocPropertyValue -Value $telemetryContract -Name 'preparation'
    } else { $null }
    $requiredPublicationFields = @(
        'current', 'currentGeneration', 'completedGeneration',
        'publishedGeneration', 'expectedWidth', 'expectedHeight',
        'publishedWidth', 'publishedHeight', 'complete',
        'deferredSetupAcknowledged', 'deviceMatches', 'contextMatches'
    )
    $publicationFields = if ($null -ne $telemetryContract) {
        @(Get-CocPropertyValue -Value $telemetryContract `
                -Name 'resourcePublicationFields')
    } else { @() }
    if ($null -eq $preparationContract -or
        [string]$preparationContract.source -ne 'status.preparation' -or
        [string]$preparationContract.capturePoint -ne 'post_wait_status' -or
        @($preparationContract.eventNames).Count -ne
            $requiredPreparationEvents.Count -or
        @($requiredPreparationEvents | Where-Object {
                $_ -notin @($preparationContract.eventNames)
            }).Count -ne 0 -or
        $publicationFields.Count -ne $requiredPublicationFields.Count -or
        @($requiredPublicationFields | Where-Object {
                $_ -notin $publicationFields
            }).Count -ne 0) {
        throw 'The measured COC run requires the complete publication and post-wait preparation telemetry contract.'
    }

    $foveation = [ordered]@{
        foveatedVendorDispatch = [bool]$ProtocolConfig.foveation.foveatedVendorDispatch
        foveatedCenterArea = [double]$ProtocolConfig.foveation.foveatedCenterArea
        peripheryTAAEnable = [bool]$ProtocolConfig.foveation.peripheryTAAEnable
        peripheryTAACenterArea = [double]$ProtocolConfig.foveation.peripheryTAACenterArea
        peripheryTAAOuterScale = [double]$ProtocolConfig.foveation.peripheryTAAOuterScale
    }
    $steps = [Collections.Generic.List[object]]::new()
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'
        label = 'stress-reset'
        args = @{ action = 'reset'; expectedBuildId = $ExpectedBuildId }
    })
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'
        label = 'stress-start'
        args = @{ action = 'start'; expectedBuildId = $ExpectedBuildId }
    })

    for ($ordinal = 1; $ordinal -le $transitionCount; $ordinal++) {
        $cell = if (($ordinal % 2) -eq 1) { $interiorCell } else { $startCell }
        $transitionId = [uint64]$ordinal
        $dispatch = [ordered]@{
            action = 'qualification_dispatch'
            transitionId = $transitionId
            ownerId = $OwnerId
            expectedBuildId = $ExpectedBuildId
            cocCellEditorId = $cell
        }
        if ($ordinal -eq 1) { $dispatch.startPerformanceTelemetry = $true }

        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-qualification-status"
            args = [ordered]@{
                action = 'qualification_status'
                expectedBuildId = $ExpectedBuildId
            }
        })

        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-begin"
            args = [ordered]@{
                action = 'qualification_begin'
                transitionId = $transitionId
                ownerId = $OwnerId
                expectedBuildId = $ExpectedBuildId
            }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-dispatch"
            args = $dispatch
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-wait"
            args = [ordered]@{
                action = 'qualification_wait'
                transitionId = $transitionId
                ownerId = $OwnerId
                expectedBuildId = $ExpectedBuildId
                expectedCellEditorId = $cell
                foveation = $foveation
                milestone = 'strict'
                timeoutMs = [int]$qualification.timeoutMs
            }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-status"
            args = [ordered]@{
                action = 'status'
                expectedBuildId = $ExpectedBuildId
            }
        })
    }
    return [ordered]@{
        action = 'run'
        async = $true
        continueOnError = $false
        steps = @($steps)
    }
}

function Test-CocBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Results,
        [Parameter(Mandatory)][string]$ExpectedCell
    )

    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($name in @('state', 'scene', 'upscaling', 'renderscale', 'image')) {
        if (-not $Results.ContainsKey($name) -or $null -eq $Results[$name]) {
            $reasons.Add("baseline '$name' is incomplete")
        }
    }
    if ($reasons.Count -gt 0) {
        return [pscustomobject]@{ acceptable = $false; reasons = @($reasons) }
    }

    $state = $Results.state.value
    $scene = $Results.scene.value
    $upscaling = $Results.upscaling.value
    $renderScale = $Results.renderscale.value
    $actualCell = if ($scene.cell -is [string]) {
        [string]$scene.cell
    } else {
        [string]$scene.cell.editorId
    }
    if (-not [bool]$state.playerLoaded) { $reasons.Add('the player is not loaded') }
    if (-not [string]::Equals(
        $actualCell, $ExpectedCell, [StringComparison]::OrdinalIgnoreCase
    )) { $reasons.Add("the exact cell is '$actualCell'") }

    $stability = Test-DevBenchUpscalingStable `
        -UpscalingSnapshot $upscaling -RenderScaleStatus $renderScale
    foreach ($reason in @($stability.reasons)) { $reasons.Add([string]$reason) }
    $status = if ($renderScale.PSObject.Properties['status']) {
        $renderScale.status
    } else {
        $renderScale
    }
    $diagnostics = @(
        @{ name = 'stress'; property = 'session' },
        @{ name = 'CPU telemetry'; property = 'cpuPerformance' },
        @{ name = 'GPU telemetry'; property = 'gpuPerformance' }
    )
    foreach ($diagnostic in $diagnostics) {
        $property = $status.PSObject.Properties[$diagnostic.property]
        $activeProperty = if ($property -and $property.Value) {
            $property.Value.PSObject.Properties['active']
        } else {
            $null
        }
        if (-not $activeProperty) {
            $reasons.Add("$($diagnostic.name) ownership status is unavailable")
            continue
        }
        $diagnostic.active = [bool]$activeProperty.Value
        if ($diagnostic.active) {
            $reasons.Add("an unowned $($diagnostic.name) session is already active")
        }
    }
    return [pscustomobject][ordered]@{
        acceptable = $reasons.Count -eq 0
        reasons = @($reasons | Select-Object -Unique)
        actualCell = $actualCell
        stability = $stability
        resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $renderScale
        preparation = Get-DevBenchRenderScalePreparationTelemetry -Response $renderScale
    }
}

function Get-CocPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $null
    }
    $property = $Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-CocPathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $current = $Value
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $current = Get-CocPropertyValue -Value $current -Name $segment
    }
    return $current
}

function ConvertTo-CocNumber {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            return $null
        }
        return $number
    }
    catch {
        return $null
    }
}

function ConvertTo-CocBoolean {
    [CmdletBinding()]
    param($Value)

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse($Value, [ref]$parsed)) { return $parsed }
    }
    return $null
}

function Get-CocFirstNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Paths
    )

    foreach ($path in $Paths) {
        $number = ConvertTo-CocNumber (Get-CocPathValue -Value $Value -Path $path)
        if ($null -ne $number) { return $number }
    }
    return $null
}

function Get-CocTimingSummary {
    [CmdletBinding()]
    param([object[]]$Values)

    $numbers = @($Values | ForEach-Object { ConvertTo-CocNumber $_ } |
        Where-Object { $null -ne $_ } | Sort-Object)
    if ($numbers.Count -eq 0) {
        return [pscustomobject]@{ count = 0; median = $null; p95 = $null; max = $null }
    }
    $middle = [int][Math]::Floor(($numbers.Count - 1) / 2)
    $median = if (($numbers.Count % 2) -eq 1) {
        $numbers[$middle]
    } else {
        ($numbers[$middle] + $numbers[$middle + 1]) / 2.0
    }
    $p95 = $numbers[[int][Math]::Ceiling($numbers.Count * 0.95) - 1]
    return [pscustomobject]@{
        count = $numbers.Count
        median = [Math]::Round($median, 3)
        p95 = [Math]::Round($p95, 3)
        max = [Math]::Round($numbers[-1], 3)
    }
}

function Get-CocNumberTotal {
    [CmdletBinding()]
    param([object[]]$Values)

    $numbers = @($Values | ForEach-Object { ConvertTo-CocNumber $_ } |
        Where-Object { $null -ne $_ })
    if ($numbers.Count -eq 0) { return $null }
    return [Math]::Round((($numbers | Measure-Object -Sum).Sum), 3)
}

function Get-CocScenarioRecordPayload {
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][string]$Label
    )

    $record = @($Records | Where-Object {
            [string](Get-CocPropertyValue -Value $_ -Name 'label') -ceq $Label
        } | Select-Object -First 1)[0]
    if ($null -eq $record) { return $null }
    $payload = Get-CocPropertyValue -Value $record -Name 'result'
    if ($null -eq $payload) {
        $payload = Get-CocPropertyValue -Value $record -Name 'value'
    }
    return $payload
}

function Get-CocQualificationAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)]$ProtocolConfig
    )

    $records = @(Get-CocPropertyValue -Value $Scenario -Name 'results')
    if ($records.Count -eq 0) {
        return [pscustomobject]@{
            available = $false
            reason = 'The scenario transcript has no result records.'
        }
    }

    $transitions = [Collections.Generic.List[object]]::new()
    for ($ordinal = 1; $ordinal -le [int]$ProtocolConfig.transitionCount; $ordinal++) {
        $prefix = "coc-$($ordinal.ToString('D2'))"
        $receipt = Get-CocScenarioRecordPayload -Records $records `
            -Label "$prefix-wait"
        $statusReceipt = Get-CocScenarioRecordPayload -Records $records `
            -Label "$prefix-status"
        $cell = if (($ordinal % 2) -eq 1) {
            [string]$ProtocolConfig.interiorCellEditorId
        } else {
            [string]$ProtocolConfig.startCellEditorId
        }
        if ($null -eq $receipt) {
            $transitions.Add([pscustomobject][ordered]@{
                ordinal = $ordinal; destination = $cell; receiptPresent = $false
                presentationElapsedMs = $null; presentationElapsedFrames = $null
                cleanupElapsedMs = $null; cleanupElapsedFrames = $null
                strictElapsedMs = $null; strictElapsedFrames = $null
                cleanupTailMs = $null; cleanupTailFrames = $null
                resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $null
                preparation = Get-DevBenchRenderScalePreparationTelemetry -Response $statusReceipt
            })
            continue
        }

        $presentationMs = Get-CocFirstNumber $receipt @('presentationElapsedMs')
        $presentationFrames = Get-CocFirstNumber $receipt @('presentationElapsedFrames')
        $cleanupMs = Get-CocFirstNumber $receipt @('cleanupElapsedMs')
        $cleanupFrames = Get-CocFirstNumber $receipt @('cleanupElapsedFrames')
        $strictMs = Get-CocFirstNumber $receipt @('strictElapsedMs')
        $strictFrames = Get-CocFirstNumber $receipt @('strictElapsedFrames')
        $tailMs = if ($null -ne $strictMs -and $null -ne $presentationMs) {
            [Math]::Round($strictMs - $presentationMs, 3)
        } else { $null }
        $tailFrames = if ($null -ne $strictFrames -and $null -ne $presentationFrames) {
            [Math]::Round($strictFrames - $presentationFrames, 3)
        } else { $null }
        $observation = Get-CocPropertyValue -Value $receipt -Name 'observation'
        $transitionEpoch = Get-CocPathValue -Value $observation `
            -Path 'physical.stable.transitionEpoch'
        if ($null -eq $transitionEpoch) {
            $transitionEpoch = Get-CocPathValue -Value $observation `
                -Path 'upscalingSnapshot.stable.transitionEpoch'
        }
        $preparation = if ($null -ne $transitionEpoch) {
            Get-DevBenchRenderScalePreparationTelemetry -Response $statusReceipt `
                -TransitionEpoch $transitionEpoch
        } else {
            Get-DevBenchRenderScalePreparationTelemetry -Response $statusReceipt
        }
        $transitions.Add([pscustomobject][ordered]@{
            ordinal = $ordinal
            destination = $cell
            receiptPresent = $true
            transitionId = Get-CocPropertyValue -Value $receipt -Name 'transitionId'
            ownerId = Get-CocPropertyValue -Value $receipt -Name 'ownerId'
            timedOutMilestone = Get-CocPropertyValue -Value $receipt -Name 'timedOutMilestone'
            presentationStable = ConvertTo-CocBoolean (Get-CocPropertyValue -Value $receipt -Name 'presentationStable')
            presentationFailureMask = Get-CocPropertyValue -Value $receipt -Name 'presentationFailureMask'
            presentationFailureReasons = @(Get-CocPropertyValue -Value $receipt -Name 'presentationFailureReasons')
            presentationElapsedMs = $presentationMs
            presentationElapsedFrames = $presentationFrames
            cleanupDrained = ConvertTo-CocBoolean (Get-CocPropertyValue -Value $receipt -Name 'cleanupDrained')
            cleanupFailureMask = Get-CocPropertyValue -Value $receipt -Name 'cleanupFailureMask'
            cleanupFailureReasons = @(Get-CocPropertyValue -Value $receipt -Name 'cleanupFailureReasons')
            cleanupElapsedMs = $cleanupMs
            cleanupElapsedFrames = $cleanupFrames
            strictSatisfied = ConvertTo-CocBoolean (Get-CocPropertyValue -Value $receipt -Name 'strictSatisfied')
            strictFailureMask = Get-CocPropertyValue -Value $receipt -Name 'strictFailureMask'
            strictFailureReasons = @(Get-CocPropertyValue -Value $receipt -Name 'strictFailureReasons')
            strictElapsedMs = $strictMs
            strictElapsedFrames = $strictFrames
            cleanupTailMs = $tailMs
            cleanupTailFrames = $tailFrames
            outstandingCleanupDebt = Get-CocPropertyValue -Value $receipt -Name 'outstandingCleanupDebt'
            timing = Get-CocPropertyValue -Value $receipt -Name 'timing'
            frames = Get-CocPropertyValue -Value $receipt -Name 'frames'
            observation = $observation
            resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $observation
            preparation = $preparation
            producer = Get-CocPropertyValue -Value $receipt -Name 'producer'
            retryCount = Get-CocFirstNumber $receipt @('retryCount', 'retries', 'observation.retryCount', 'observation.retries')
            sessionStretchObservations = Get-CocFirstNumber $receipt @('observation.stretch.sessionObservations', 'sessionStretchObservations')
            consecutiveStretchFrames = Get-CocFirstNumber $receipt @('observation.stretch.consecutiveFrames', 'consecutiveStretchFrames')
            vendorFailures = Get-CocFirstNumber $receipt @('observation.diagnostics.delta.vendorFailures', 'vendorFailures')
            boundsMismatchFallbacks = Get-CocFirstNumber $receipt @('observation.diagnostics.delta.boundsMismatchFallbacks', 'boundsMismatchFallbacks')
            ooms = Get-CocFirstNumber $receipt @('observation.diagnostics.delta.ooms', 'ooms')
            deviceLosses = Get-CocFirstNumber $receipt @('observation.diagnostics.delta.deviceLosses', 'deviceLosses')
            fidelityMismatches = Get-CocFirstNumber $receipt @('observation.diagnostics.delta.fidelityMismatches', 'fidelityMismatches')
        })
    }

    $strictFrames = @($transitions | ForEach-Object { $_.strictElapsedFrames })
    $presentationFrames = @($transitions | ForEach-Object { $_.presentationElapsedFrames })
    $cleanupFrames = @($transitions | ForEach-Object { $_.cleanupElapsedFrames })
    $tailFrames = @($transitions | ForEach-Object { $_.cleanupTailFrames })
    $strictByDestination = [ordered]@{}
    foreach ($cell in @(
            [string]$ProtocolConfig.interiorCellEditorId,
            [string]$ProtocolConfig.startCellEditorId
        )) {
        $strictByDestination[$cell] = Get-CocTimingSummary @(
            $transitions | Where-Object destination -ceq $cell |
                ForEach-Object { $_.strictElapsedFrames }
        )
    }
    $strictTargets = Get-CocPropertyValue -Value $ProtocolConfig.qualification -Name 'strictFrameTargets'
    $cleanupDebtRanked = @(
        $transitions | Sort-Object -Property @(
            @{ Expression = { if ($null -eq $_.cleanupTailFrames) { -1 } else { $_.cleanupTailFrames } }; Descending = $true },
            @{ Expression = { if ($null -eq $_.cleanupTailMs) { -1 } else { $_.cleanupTailMs } }; Descending = $true }
        )
    )
    $publicationSamples = @($transitions | ForEach-Object { $_.resourcePublication })
    $availablePublications = @($publicationSamples | Where-Object { [bool]$_.available })
    $currentPublications = @($availablePublications | Where-Object { [bool]$_.current })
    $preparationSamples = @($transitions | ForEach-Object { $_.preparation })
    $availablePreparation = @($preparationSamples | Where-Object { [bool]$_.available })
    $exactPreparation = @($availablePreparation | Where-Object { [bool]$_.filterApplied })
    return [pscustomobject][ordered]@{
        available = $true
        canonicalMilestone = 'strict'
        strictFrameTargets = $strictTargets
        transitions = @($transitions)
        timings = [pscustomobject][ordered]@{
            presentationFrames = Get-CocTimingSummary $presentationFrames
            cleanupFrames = Get-CocTimingSummary $cleanupFrames
            strictFrames = Get-CocTimingSummary $strictFrames
            cleanupTailFrames = Get-CocTimingSummary $tailFrames
            presentationMs = Get-CocTimingSummary @($transitions | ForEach-Object { $_.presentationElapsedMs })
            cleanupMs = Get-CocTimingSummary @($transitions | ForEach-Object { $_.cleanupElapsedMs })
            strictMs = Get-CocTimingSummary @($transitions | ForEach-Object { $_.strictElapsedMs })
            cleanupTailMs = Get-CocTimingSummary @($transitions | ForEach-Object { $_.cleanupTailMs })
            strictFramesByDestination = [pscustomobject]$strictByDestination
        }
        totals = [pscustomobject][ordered]@{
            retries = Get-CocNumberTotal @($transitions | ForEach-Object { $_.retryCount })
            sessionStretchObservations = Get-CocNumberTotal @($transitions | ForEach-Object { $_.sessionStretchObservations })
            vendorFailures = Get-CocNumberTotal @($transitions | ForEach-Object { $_.vendorFailures })
            boundsMismatchFallbacks = Get-CocNumberTotal @($transitions | ForEach-Object { $_.boundsMismatchFallbacks })
            ooms = Get-CocNumberTotal @($transitions | ForEach-Object { $_.ooms })
            deviceLosses = Get-CocNumberTotal @($transitions | ForEach-Object { $_.deviceLosses })
            fidelityMismatches = Get-CocNumberTotal @($transitions | ForEach-Object { $_.fidelityMismatches })
            presentationFailures = @($transitions | Where-Object { $_.presentationStable -eq $false }).Count
            cleanupFailures = @($transitions | Where-Object { $_.cleanupDrained -eq $false }).Count
            strictFailures = @($transitions | Where-Object { $_.strictSatisfied -eq $false }).Count
        }
        cleanupDebtRanked = $cleanupDebtRanked
        resourcePublication = [pscustomobject][ordered]@{
            samples = $publicationSamples
            availableSamples = $availablePublications.Count
            currentSamples = $currentPublications.Count
            latest = $(if ($publicationSamples.Count -gt 0) { $publicationSamples[-1] } else { Get-DevBenchResourcePublicationTelemetry -Response $null })
        }
        preparation = [pscustomobject][ordered]@{
            samples = $preparationSamples
            availableSamples = $availablePreparation.Count
            exactTransitionSamples = $exactPreparation.Count
            eventCount = Get-CocNumberTotal @(
                $preparationSamples | ForEach-Object { $_.eventCount }
            )
            overwrittenEventsMaximum = $(
                $overwritten = @($availablePreparation | ForEach-Object {
                        ConvertTo-CocNumber $_.overwrittenEvents
                    } | Where-Object { $null -ne $_ })
                if ($overwritten.Count -gt 0) {
                    ($overwritten | Measure-Object -Maximum).Maximum
                } else { $null }
            )
            latest = $(if ($preparationSamples.Count -gt 0) {
                    $preparationSamples[-1]
                } else {
                    Get-DevBenchRenderScalePreparationTelemetry -Response $null
                })
        }
    }
}

Export-ModuleMember -Function Invoke-CocMcpTool, New-CocMeasuredScenario, Test-CocBaseline, Get-CocQualificationAnalysis
