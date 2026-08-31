# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Get-DevBenchSemanticStatus {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $known = $false
    $reasons = [Collections.Generic.List[string]]::new()
    $codes = [Collections.Generic.List[string]]::new()
    $states = [Collections.Generic.List[string]]::new()
    $retryableHints = [Collections.Generic.List[bool]]::new()
    $replaySchedulerReceipts = [Collections.Generic.List[string]]::new()
    $explicitOutcomeEvidence = [Collections.Generic.List[string]]::new()
    $guardCodes = @('producer_mismatch', 'contract_mismatch', 'unsupported_contract_major', 'idempotency_conflict')
    $successNames = @('success', 'ok', 'ready', 'completed', 'accepted', 'idle', 'available')
    $transientNames = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running')

    function Test-ExplicitOutcomeValue($Value) {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $true }
        if ($Value -is [string] -or $Value -is [ValueType]) { return $false }
        if ($Value -is [Collections.IDictionary]) {
            $evidenceProperties = @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            foreach ($entry in $Value) { if (Test-ExplicitOutcomeValue $entry) { return $true } }
            return $false
        }
        else {
            $evidenceProperties = @($Value.PSObject.Properties)
        }
        foreach ($property in $evidenceProperties) {
            $name = [string]$property.Name
            if ($name -in @('ok', 'success', 'passed', 'failed', 'aborted', 'code', 'state', 'status', 'resultStatus') -and $null -ne $property.Value) {
                return $true
            }
            if (Test-ExplicitOutcomeValue $property.Value) { return $true }
        }
        return $false
    }

    function Visit-Value($Value, [string]$Path) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        if ($Value -is [Collections.IDictionary]) {
            $properties = @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            $index = 0
            foreach ($entry in $Value) { Visit-Value $entry "$Path[$index]"; $index++ }
            return
        }
        else {
            $properties = @($Value.PSObject.Properties)
        }

        $propertyNames = @($properties | ForEach-Object { [string]$_.Name })
        if ($propertyNames -contains 'done' -and $propertyNames -contains 'runId' -and $propertyNames -contains 'result') {
            $resultProperty = @($properties | Where-Object Name -eq 'result' | Select-Object -First 1)
            if ($resultProperty.Count -eq 1 -and $null -ne $resultProperty[0].Value -and
                $resultProperty[0].Value.PSObject.Properties['stepsRun']) {
                $replaySchedulerReceipts.Add($Path)
            }
        }
        foreach ($evidenceName in @('semantic', 'postconditions', 'outcomeChecks', 'assertions')) {
            $evidenceProperty = @($properties | Where-Object Name -eq $evidenceName | Select-Object -First 1)
            if ($evidenceProperty.Count -eq 1 -and (Test-ExplicitOutcomeValue $evidenceProperty[0].Value)) {
                $explicitOutcomeEvidence.Add("$Path.$evidenceName")
            }
        }

        foreach ($property in $properties) {
            $name = [string]$property.Name
            $childPath = if ([string]::IsNullOrWhiteSpace($Path)) { $name } else { "$Path.$name" }
            $child = $property.Value
            if ($name -eq 'ok' -and $null -ne $child) {
                $script:semanticKnown = $true
                if (-not [bool]$child) { $reasons.Add("$childPath is false") }
            }
            elseif ($name -in @('success', 'passed') -and $child -is [bool]) {
                $script:semanticKnown = $true
                if (-not [bool]$child) { $reasons.Add("$childPath is false") }
            }
            elseif ($name -eq 'failed' -and $child -is [bool]) {
                $script:semanticKnown = $true
                if ([bool]$child) { $reasons.Add("$childPath is true") }
            }
            elseif ($name -eq 'aborted' -and [bool]$child) {
                $script:semanticKnown = $true
                $reasons.Add("$childPath is true")
            }
            elseif ($name -eq 'retryable' -and $null -ne $child) {
                $script:semanticKnown = $true
                if ([bool]$child) { $retryableHints.Add($true) }
            }
            elseif ($name -eq 'code' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) {
                $script:semanticKnown = $true
                if (-not $codes.Contains([string]$child)) { $codes.Add([string]$child) }
                if ([string]$child -notin $successNames) { $reasons.Add("$childPath is '$child'") }
            }
            elseif ($name -eq 'state' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) {
                if (-not $states.Contains([string]$child)) { $states.Add([string]$child) }
            }
            elseif ($name -in @('status', 'resultStatus') -and $null -ne $child) {
                $nameProperty = $child.PSObject.Properties['name']
                $valueProperty = $child.PSObject.Properties['value']
                if ($nameProperty) {
                    $script:semanticKnown = $true
                    $statusName = [string]$nameProperty.Value
                    if (-not $codes.Contains($statusName)) { $codes.Add($statusName) }
                    if ($statusName -notin $successNames) { $reasons.Add("$childPath.name is '$statusName'") }
                }
                if ($valueProperty) {
                    $script:semanticKnown = $true
                    if ([int64]$valueProperty.Value -ne 0) { $reasons.Add("$childPath.value is $($valueProperty.Value)") }
                }
            }
            Visit-Value $child $childPath
        }
    }

    $script:semanticKnown = $false
    try {
        foreach ($item in @($Content)) { Visit-Value $item 'content' }
        $known = $script:semanticKnown
    }
    finally {
        Remove-Variable semanticKnown -Scope Script -ErrorAction SilentlyContinue
    }
    $schedulerOnly = $replaySchedulerReceipts.Count -gt 0 -and $explicitOutcomeEvidence.Count -eq 0 -and $reasons.Count -eq 0
    if ($schedulerOnly) { $known = $false }
    $guarded = @($codes | Where-Object { $_ -in $guardCodes }).Count -gt 0
    $transient = $retryableHints.Count -gt 0 -or @($codes + $states | Where-Object { $_ -in $transientNames }).Count -gt 0
    $ok = $reasons.Count -eq 0
    $outcome = if ($schedulerOnly) { 'scheduler-complete-unverified' } elseif ($ok) { if ($transient) { 'accepted-transient' } else { 'success' } } elseif ($guarded) { 'guard-rejected' } else { 'failure' }
    return [pscustomobject][ordered]@{
        known = $known
        ok = $ok
        outcome = $outcome
        guarded = $guarded
        transient = $transient
        codes = @($codes)
        states = @($states)
        reasons = @($reasons | Select-Object -Unique)
        schedulerOnly = $schedulerOnly
        schedulerReceiptPaths = @($replaySchedulerReceipts)
        explicitOutcomeEvidence = @($explicitOutcomeEvidence)
    }
}

function Get-DevBenchServiceState {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $found = [Collections.Generic.List[object]]::new()
    function Visit-State($Value, [string]$Path) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        $properties = if ($Value -is [Collections.IDictionary]) {
            @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            $i = 0; foreach ($entry in $Value) { Visit-State $entry "$Path[$i]"; $i++ }; return
        }
        else { @($Value.PSObject.Properties) }
        foreach ($property in $properties) {
            $childPath = if ($Path) { "$Path.$($property.Name)" } else { [string]$property.Name }
            if ([string]$property.Name -eq 'state' -and $property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $priority = if ($childPath -match '(^|\.)result\.state$') { 0 } elseif ($childPath -eq 'content.state') { 1 } else { 2 }
                $found.Add([pscustomobject]@{ state = [string]$property.Value; path = $childPath; priority = $priority })
            }
            Visit-State $property.Value $childPath
        }
    }
    foreach ($item in @($Content)) { Visit-State $item 'content' }
    return @($found | Sort-Object priority, path | Select-Object -First 1)
}

function Test-DevBenchServiceReady {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Content,
        [string[]]$AcceptedStates = @('ready', 'idle', 'available', 'completed', 'success', 'ok'),
        [string[]]$RetryableStates = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running')
    )
    $semantic = Get-DevBenchSemanticStatus -Content $Content
    $stateRecord = @(Get-DevBenchServiceState -Content $Content | Select-Object -First 1)
    $state = if ($stateRecord.Count -gt 0) { [string]$stateRecord[0].state } else { $null }
    $retryable = $semantic.transient -or ($state -in $RetryableStates)
    $terminalFailure = -not $semantic.ok -and -not $retryable
    $probeReturnedContent = @($Content).Count -gt 0
    # Transport success or arbitrary non-empty content proves only that the
    # tool answered. Readiness requires a recognized positive contract state;
    # otherwise polling an unknown payload could repeatedly dispatch work and
    # then promote the unclassified response to ready.
    $ready = if ($state) { $state -in $AcceptedStates } elseif ($semantic.known) { $semantic.ok -and -not $retryable } else { $false }
    return [pscustomobject][ordered]@{
        ready = $ready
        retryable = $retryable
        terminalFailure = $terminalFailure
        state = $state
        statePath = if ($stateRecord.Count -gt 0) { $stateRecord[0].path } else { $null }
        probeReturnedContent = $probeReturnedContent
        semantic = $semantic
    }
}

function Test-DevBenchNoBlockingMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuState,
        [string[]]$IgnoredMenus = @('HUD Menu')
    )
    $openMenus = if ($MenuState.PSObject.Properties['openMenus']) { @($MenuState.openMenus) } else { @() }
    $blocking = @($openMenus | Where-Object { $_ -notin $IgnoredMenus })
    $messageBoxOpen = $MenuState.PSObject.Properties['messageBoxOpen'] -and [bool]$MenuState.messageBoxOpen
    return [pscustomobject][ordered]@{
        satisfied = $blocking.Count -eq 0 -and -not $messageBoxOpen
        openMenus = $openMenus
        ignoredMenus = @($IgnoredMenus)
        blockingMenus = $blocking
        messageBoxOpen = [bool]$messageBoxOpen
    }
}

function Get-DevBenchMenuDismissalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuObservation,
        [string[]]$DismissBlockingMenus = @()
    )
    $requested = @($DismissBlockingMenus |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $blocking = if ($MenuObservation.PSObject.Properties['blockingMenus']) {
        @($MenuObservation.blockingMenus)
    }
    else {
        @()
    }
    $messageBoxOpen = $MenuObservation.PSObject.Properties['messageBoxOpen'] -and
        [bool]$MenuObservation.messageBoxOpen
    $dismiss = @($blocking | Where-Object { $_ -in $requested })
    $retained = @($blocking | Where-Object { $_ -notin $requested })
    $permitted = -not $messageBoxOpen -and $dismiss.Count -gt 0 -and $retained.Count -eq 0
    $reason = if ($messageBoxOpen) {
        'message-box-requires-explicit-answer'
    }
    elseif ($retained.Count -gt 0) {
        'unlisted-blocking-menu'
    }
    elseif ($dismiss.Count -eq 0) {
        'no-listed-menu-open'
    }
    else {
        'explicit-menu-dismissal'
    }
    return [pscustomobject][ordered]@{
        permitted = $permitted
        reason = $reason
        requestedMenus = $requested
        dismissMenus = $dismiss
        retainedMenus = $retained
        messageBoxOpen = [bool]$messageBoxOpen
    }
}

function Get-DevBenchNamedValue {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value.ToLowerInvariant() }
    $name = $Value.PSObject.Properties['name']
    if ($name -and $null -ne $name.Value) {
        return ([string]$name.Value).ToLowerInvariant()
    }
    return ([string]$Value).ToLowerInvariant()
}

function Get-DevBenchTelemetryMember {
    param($Value, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Value -or $Value -is [ValueType] -or $Value -is [string]) {
        return $null
    }
    if ($Value -is [Collections.IDictionary]) {
        return $(if ($Value.Contains($Name)) { $Value[$Name] } else { $null })
    }
    $property = $Value.PSObject.Properties[$Name]
    return $(if ($property) { $property.Value } else { $null })
}

function Find-DevBenchTelemetryNode {
    param(
        $Response,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(0, 8)][int]$MaxDepth = 3
    )

    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ value = $Response; path = '$'; depth = 0 })
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        $candidate = Get-DevBenchTelemetryMember $entry.value $Name
        if ($null -ne $candidate) {
            return [pscustomobject]@{
                value = $candidate
                path = "$($entry.path).$Name"
            }
        }
        if ([int]$entry.depth -ge $MaxDepth) { continue }
        foreach ($childName in @('value', 'result', 'status', 'observation')) {
            $child = Get-DevBenchTelemetryMember $entry.value $childName
            if ($null -ne $child) {
                $queue.Enqueue([pscustomobject]@{
                        value = $child
                        path = "$($entry.path).$childName"
                        depth = [int]$entry.depth + 1
                    })
            }
        }
    }
    return $null
}

function Get-DevBenchResourcePublicationTelemetry {
    [CmdletBinding()]
    param($Response)

    function New-PublicationTelemetry($Publication, [string]$SourcePath) {
        $fields = @(
            'current', 'currentGeneration', 'completedGeneration',
            'publishedGeneration', 'expectedWidth', 'expectedHeight',
            'publishedWidth', 'publishedHeight', 'complete',
            'deferredSetupAcknowledged', 'deviceMatches', 'contextMatches',
            'evaluated', 'present', 'generationMatchesCurrent',
            'generationMatchesCompleted', 'dimensionsMatch'
        )
        $missing = [Collections.Generic.List[string]]::new()
        $values = [ordered]@{}
        foreach ($field in $fields) {
            $values[$field] = Get-DevBenchTelemetryMember $Publication $field
            if ($null -eq $values[$field]) { $missing.Add($field) }
        }
        return [pscustomobject][ordered]@{
            schema = 'csx-resource-publication-telemetry-v1'
            available = $null -ne $Publication
            sourcePath = $SourcePath
            missingFields = @($missing)
            current = $values.current
            currentGeneration = $values.currentGeneration
            completedGeneration = $values.completedGeneration
            publishedGeneration = $values.publishedGeneration
            expectedWidth = $values.expectedWidth
            expectedHeight = $values.expectedHeight
            publishedWidth = $values.publishedWidth
            publishedHeight = $values.publishedHeight
            complete = $values.complete
            deferredSetupAcknowledged = $values.deferredSetupAcknowledged
            deviceMatches = $values.deviceMatches
            contextMatches = $values.contextMatches
            evaluated = $values.evaluated
            present = $values.present
            generationMatchesCurrent = $values.generationMatchesCurrent
            generationMatchesCompleted = $values.generationMatchesCompleted
            dimensionsMatch = $values.dimensionsMatch
        }
    }

    $node = Find-DevBenchTelemetryNode -Response $Response `
        -Name 'resourcePublication'
    return $(if ($node) {
            New-PublicationTelemetry $node.value $node.path
        } else {
            New-PublicationTelemetry $null $null
        })
}

function Get-DevBenchPreparationMetricSummary {
    param([object[]]$Values)

    $numbers = [Collections.Generic.List[double]]::new()
    $invalidCount = 0
    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }
        $number = 0.0
        if (-not [double]::TryParse(
                [string]$value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$number
            ) -or
            [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            $invalidCount++
            continue
        }
        $numbers.Add($number)
    }
    if ($numbers.Count -eq 0) {
        return [pscustomobject][ordered]@{
            count = 0; invalidCount = $invalidCount
            total = $null; mean = $null; min = $null; max = $null
        }
    }
    $measure = $numbers | Measure-Object -Sum -Average -Minimum -Maximum
    return [pscustomobject][ordered]@{
        count = $numbers.Count
        invalidCount = $invalidCount
        total = [Math]::Round([double]$measure.Sum, 6)
        mean = [Math]::Round([double]$measure.Average, 6)
        min = [Math]::Round([double]$measure.Minimum, 6)
        max = [Math]::Round([double]$measure.Maximum, 6)
    }
}

function Get-DevBenchRenderScalePreparationTelemetry {
    [CmdletBinding()]
    param(
        $Response,
        $TransitionEpoch
    )

    $eventNames = @(
        'request_queued', 'admission_check', 'early_exit',
        'shader_cache_busy_wait', 'sss_raymarch_prewarm', 'ssgi_prewarm',
        'dlss_preparation', 'fsr_preparation', 'fsr4_preparation',
        'd3d_object_creation', 'total_preparation', 'request_to_prepared',
        'prepared_to_creator'
    )
    $topLevelFields = @(
        'schemaVersion', 'devBenchOnly', 'active', 'sessionId',
        'qpcFrequency', 'retainedEvents', 'capacity', 'overwrittenEvents',
        'coalescedEvents', 'events'
    )
    $node = Find-DevBenchTelemetryNode -Response $Response -Name 'preparation'
    $preparation = if ($node) { $node.value } else { $null }
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($field in $topLevelFields) {
        if ($null -eq (Get-DevBenchTelemetryMember $preparation $field)) {
            $missing.Add($field)
        }
    }

    $allEventsValue = Get-DevBenchTelemetryMember $preparation 'events'
    $allEvents = @()
    if ($null -ne $allEventsValue) {
        $allEvents = @($allEventsValue)
    }
    $filterApplied = $PSBoundParameters.ContainsKey('TransitionEpoch') -and
        $null -ne $TransitionEpoch
    $events = @()
    if ($filterApplied) {
        $events = @($allEvents | Where-Object {
                [string](Get-DevBenchTelemetryMember $_ 'transitionEpoch') -ceq
                    [string]$TransitionEpoch
            })
    }
    else {
        $events = @($allEvents)
    }

    $stages = [ordered]@{}
    foreach ($eventName in $eventNames) {
        $records = @($events | Where-Object {
                [string](Get-DevBenchTelemetryMember $_ 'event') -ceq $eventName
            })
        $occurrences = @($records | ForEach-Object {
                Get-DevBenchTelemetryMember $_ 'occurrences'
            })
        $outcomes = @($records | ForEach-Object {
                Get-DevBenchTelemetryMember $_ 'outcome'
            } | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $reasons = @($records | ForEach-Object {
                @(Get-DevBenchTelemetryMember $_ 'reasons')
            } | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $occurrenceSummary = Get-DevBenchPreparationMetricSummary $occurrences
        $stages[$eventName] = [pscustomobject][ordered]@{
            observed = $records.Count -gt 0
            recordCount = $records.Count
            occurrenceCount = $(if ($null -eq $preparation) {
                    $null
                } elseif ($records.Count -eq 0) {
                    0
                } elseif ($occurrenceSummary.invalidCount -eq 0) {
                    $occurrenceSummary.total
                } else { $null })
            occurrenceInvalidCount = $occurrenceSummary.invalidCount
            outcomes = $outcomes
            reasons = $reasons
            durationMs = Get-DevBenchPreparationMetricSummary @(
                $records | ForEach-Object {
                    Get-DevBenchTelemetryMember $_ 'durationMs'
                }
            )
            durationQpcTicks = Get-DevBenchPreparationMetricSummary @(
                $records | ForEach-Object {
                    Get-DevBenchTelemetryMember $_ 'durationQpcTicks'
                }
            )
            bytecodeCompilationMs = Get-DevBenchPreparationMetricSummary @(
                $records | ForEach-Object {
                    Get-DevBenchTelemetryMember $_ 'bytecodeCompilationMs'
                }
            )
            d3dObjectCreationMs = Get-DevBenchPreparationMetricSummary @(
                $records | ForEach-Object {
                    Get-DevBenchTelemetryMember $_ 'd3dObjectCreationMs'
                }
            )
        }
    }

    return [pscustomobject][ordered]@{
        schema = 'csx-render-scale-preparation-telemetry-v1'
        available = $null -ne $preparation
        sourcePath = $(if ($node) { $node.path } else { $null })
        missingFields = @($missing)
        schemaVersion = Get-DevBenchTelemetryMember $preparation 'schemaVersion'
        devBenchOnly = Get-DevBenchTelemetryMember $preparation 'devBenchOnly'
        active = Get-DevBenchTelemetryMember $preparation 'active'
        sessionId = Get-DevBenchTelemetryMember $preparation 'sessionId'
        qpcFrequency = Get-DevBenchTelemetryMember $preparation 'qpcFrequency'
        retainedEvents = Get-DevBenchTelemetryMember $preparation 'retainedEvents'
        capacity = Get-DevBenchTelemetryMember $preparation 'capacity'
        overwrittenEvents = Get-DevBenchTelemetryMember $preparation 'overwrittenEvents'
        coalescedEvents = Get-DevBenchTelemetryMember $preparation 'coalescedEvents'
        transitionEpochFilter = $(if ($filterApplied) { $TransitionEpoch } else { $null })
        filterApplied = $filterApplied
        allEventCount = $allEvents.Count
        eventCount = $events.Count
        events = $events
        stages = [pscustomobject]$stages
    }
}

function Test-DevBenchUpscalingProfilesEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    foreach ($name in @('method', 'qualityMode', 'renderScaleMode', 'dlssProfile', 'fsrRuntime')) {
        $leftProperty = $Left.PSObject.Properties[$name]
        $rightProperty = $Right.PSObject.Properties[$name]
        if (-not $leftProperty -or -not $rightProperty) { return $false }
        $leftValue = if ($name -eq 'renderScaleMode') { [bool]$leftProperty.Value } else { Get-DevBenchNamedValue $leftProperty.Value }
        $rightValue = if ($name -eq 'renderScaleMode') { [bool]$rightProperty.Value } else { Get-DevBenchNamedValue $rightProperty.Value }
        if ($leftValue -ne $rightValue) { return $false }
    }
    return $true
}

function Test-DevBenchUpscalingStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$UpscalingSnapshot,
        [Parameter(Mandatory)]$RenderScaleStatus,
        $ExpectedProfile
    )

    $snapshot = if ($UpscalingSnapshot.PSObject.Properties['snapshot']) { $UpscalingSnapshot.snapshot } else { $UpscalingSnapshot }
    $renderStatus = if ($RenderScaleStatus.PSObject.Properties['status']) { $RenderScaleStatus.status } else { $RenderScaleStatus }
    $reasons = [Collections.Generic.List[string]]::new()
    function Require-StableValue([bool]$Condition, [string]$Reason) {
        if (-not $Condition) { $reasons.Add($Reason) }
    }

    $profilePresence = if ($snapshot.PSObject.Properties['profilePresence']) { [uint32]$snapshot.profilePresence } else { [uint32]0 }
    $flags = if ($snapshot.PSObject.Properties['flags']) { [uint64]$snapshot.flags } else { [uint64]0 }
    $renderScaleStatusName = Get-DevBenchNamedValue (Get-DevBenchTelemetryMember $snapshot 'renderScaleStatus')
    $transitionState = Get-DevBenchNamedValue (Get-DevBenchTelemetryMember $snapshot 'transitionState')
    $renderScaleActive = $renderScaleStatusName -eq 'active'
    $profiles = Get-DevBenchTelemetryMember $snapshot 'profiles'
    $requestedProfile = Get-DevBenchTelemetryMember $profiles 'requested'
    $effectiveProfile = Get-DevBenchTelemetryMember $profiles 'effective'
    $stableProfile = Get-DevBenchTelemetryMember $profiles 'stable'
    $hasRequested = ($profilePresence -band [uint32]0x2) -ne 0 -and $null -ne $requestedProfile
    $hasEffective = ($profilePresence -band [uint32]0x8) -ne 0 -and $null -ne $effectiveProfile
    $hasStable = ($profilePresence -band [uint32]0x10) -ne 0 -and $null -ne $stableProfile
    $expectsNativeProfile = $null -ne $ExpectedProfile -and
        $ExpectedProfile.PSObject.Properties['renderScaleMode'] -and
        -not [bool]$ExpectedProfile.renderScaleMode
    $criticalConditions = @(
        'loading_transition', 'relatch_pending', 'transition_pending',
        'first_world_frame_pending', 'post_load_recovery',
        'provider_check_pending', 'provider_unavailable', 'restart_required',
        'resource_recovery'
    )
    $observedConditions = Get-DevBenchTelemetryMember $snapshot 'observedConditions'
    $conditionNames = if ($observedConditions -and $observedConditions.PSObject.Properties['names']) {
        @($observedConditions.names | ForEach-Object { ([string]$_).ToLowerInvariant() })
    } else { @() }
    $blockingConditions = @($conditionNames | Where-Object { $_ -in $criticalConditions })

    Require-StableValue (($flags -band [uint64]0x1) -ne 0) 'provider check is incomplete'
    Require-StableValue (($flags -band [uint64]0x2) -eq 0) 'an upscaling transition is active'
    Require-StableValue (($flags -band [uint64]0x4) -eq 0) 'an upscaling restart is required'
    $activeOperationId = Get-DevBenchTelemetryMember $snapshot 'activeOperationId'
    Require-StableValue ($null -ne $activeOperationId -and [uint64]$activeOperationId -eq 0) 'an upscaling operation is still active'
    Require-StableValue ($blockingConditions.Count -eq 0) "blocking upscaling conditions remain: $($blockingConditions -join ', ')"
    if ($expectsNativeProfile) {
        Require-StableValue ($hasEffective) 'the effective native profile is not authoritative'
        if ($hasEffective) {
            Require-StableValue (Test-DevBenchUpscalingProfilesEqual $effectiveProfile $ExpectedProfile) 'effective native profile does not match the expected target'
        }
    }
    else {
        Require-StableValue ($hasRequested -and $hasEffective) 'requested and effective profiles are not both authoritative'
        if ($hasRequested -and $hasEffective) {
            Require-StableValue (Test-DevBenchUpscalingProfilesEqual $requestedProfile $effectiveProfile) 'requested and effective profiles differ'
        }
        if ($hasStable -and $hasEffective) {
            Require-StableValue (Test-DevBenchUpscalingProfilesEqual $stableProfile $effectiveProfile) 'stable and effective profiles differ'
        }
    }
    $dimensions = Get-DevBenchTelemetryMember $snapshot 'dimensions'
    $displayEyeWidth = Get-DevBenchTelemetryMember $dimensions 'displayEyeWidth'
    $displayEyeHeight = Get-DevBenchTelemetryMember $dimensions 'displayEyeHeight'
    $renderEyeWidth = Get-DevBenchTelemetryMember $dimensions 'renderEyeWidth'
    $renderEyeHeight = Get-DevBenchTelemetryMember $dimensions 'renderEyeHeight'
    Require-StableValue (
        $null -ne $displayEyeWidth -and [uint32]$displayEyeWidth -gt 0 -and
        $null -ne $displayEyeHeight -and [uint32]$displayEyeHeight -gt 0 -and
        $null -ne $renderEyeWidth -and [uint32]$renderEyeWidth -gt 0 -and
        $null -ne $renderEyeHeight -and [uint32]$renderEyeHeight -gt 0
    ) 'upscaling dimensions are not materialized'

    $method = if ($hasEffective) { Get-DevBenchNamedValue $effectiveProfile.method } else { $null }
    $qualityMode = if ($hasEffective) { Get-DevBenchNamedValue $effectiveProfile.qualityMode } else { $null }
    $effectiveRenderScaleMode = if ($hasEffective) { [bool]$effectiveProfile.renderScaleMode } else { $false }
    $dlssProfile = if ($hasEffective) { Get-DevBenchNamedValue $effectiveProfile.dlssProfile } else { $null }
    $fsrRuntime = if ($hasEffective) { Get-DevBenchNamedValue $effectiveProfile.fsrRuntime } else { $null }
    $frame = Get-DevBenchTelemetryMember $renderStatus 'frame'
    $controller = Get-DevBenchTelemetryMember $renderStatus 'controller'
    $gate = Get-DevBenchTelemetryMember $renderStatus 'vendorWorkGate'
    if ($null -eq $controller -or $null -eq $gate) {
        Require-StableValue ($null -ne $controller) 'render-scale controller telemetry is missing'
        Require-StableValue ($null -ne $gate) 'vendor work gate telemetry is missing'
        return [pscustomobject][ordered]@{
            satisfied = $false
            renderScaleActive = $renderScaleActive
            stereoEvidence = 'unavailable'
            method = $method
            qualityMode = $qualityMode
            effectiveRenderScaleMode = $effectiveRenderScaleMode
            expectedProfile = $ExpectedProfile
            expectedProfileMatches = if ($null -ne $ExpectedProfile -and $hasEffective) { Test-DevBenchUpscalingProfilesEqual $effectiveProfile $ExpectedProfile } else { $null }
            dlssProfile = $dlssProfile
            fsrRuntime = $fsrRuntime
            frame = if ($null -ne $frame) { [uint32]$frame } else { [uint32]0 }
            signature = $null
            resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $RenderScaleStatus
            reasons = @($reasons | Select-Object -Unique)
        }
    }
    Require-StableValue (-not [bool]$controller.terminalFailureSignaled) 'render-scale terminal failure is signaled'
    Require-StableValue (-not [bool]$controller.terminalDeviceLossSignaled) 'render-scale device loss is signaled'
    Require-StableValue ([uint64]$controller.unresolvedPhysicalMutationEpoch -eq 0) 'a physical render-scale mutation remains unresolved'
    Require-StableValue (-not [bool]$gate.active) 'the vendor work gate is active'
    Require-StableValue ([bool]$gate.completedWorldFrame) 'no completed destination world frame is available'
    foreach ($name in @('loadingMenu', 'loadingPresentationActive', 'postLoadResetPending', 'relatchQueued', 'relatchInProgress', 'relatchFramePending', 'relatchPostLoadSettle', 'recoveryPending', 'relatchPending', 'profileTransitionPending')) {
        $property = $gate.PSObject.Properties[$name]
        if ($property) { Require-StableValue (-not [bool]$property.Value) "vendor work gate '$name' remains active" }
    }
    if ($controller.postLoadRecovery) {
        Require-StableValue (-not [bool]$controller.postLoadRecovery.active) 'post-load render-scale recovery is active'
    }
    if ($controller.memoryTrim) {
        Require-StableValue (-not [bool]$controller.memoryTrim.pending) 'render-scale memory trim is pending'
    }
    if ($controller.retirement) {
        Require-StableValue (
            [uint32]$controller.retirement.pendingSets -eq 0 -and
            -not [bool]$controller.retirement.fencePending -and
            -not [bool]$controller.retirement.capacityBlocked
        ) 'render-scale resource retirement is pending'
    }
    if ($controller.engineTargetRetirement) {
        Require-StableValue (-not [bool]$controller.engineTargetRetirement.pending) 'engine render-target retirement is pending'
    }

    $stereoEvidence = 'native_pipeline_frames'
    if ($renderScaleActive) {
        $stereoEvidence = 'render_scale_fidelity'
        Require-StableValue (($flags -band [uint64]0x10) -ne 0 -and ($flags -band [uint64]0x20) -ne 0) 'render-scale is not both latched and active'
        Require-StableValue ($hasStable) 'the stable render-scale profile is not authoritative'
        Require-StableValue ($transitionState -eq 'active') "render-scale transition state is '$transitionState'"
        Require-StableValue ((Get-DevBenchNamedValue $renderStatus.modeStatus) -eq 'active') 'render-scale mode status is not active'
        Require-StableValue ((Get-DevBenchNamedValue $controller.state) -eq 'active') 'render-scale controller is not active'
        Require-StableValue ((Get-DevBenchNamedValue $controller.presentationPhase) -in @('stereo_proven', 'released')) 'stereo presentation has not been proven or released'
        Require-StableValue ([bool]$controller.stable.valid -and [bool]$controller.stable.active) 'stable render-scale contract is invalid or inactive'

        $fidelity = $controller.fidelity
        Require-StableValue ([bool]$fidelity.active -and [bool]$fidelity.bothEyesValid) 'both render-scale eyes are not valid'
        Require-StableValue ([uint32]$fidelity.evaluationEyeMask -eq 3 -and [uint32]$fidelity.invariantEyeMask -eq 3) 'both-eye evaluation or invariant mask is incomplete'
        Require-StableValue ([uint32]$fidelity.lastMismatchMask -eq 0) 'the latest render-scale fidelity observation mismatched'
        $fidelityEyes = @($fidelity.eyes)
        Require-StableValue ($fidelityEyes.Count -eq 2) 'render-scale fidelity did not expose two eyes'
        if ($fidelityEyes.Count -eq 2) {
            Require-StableValue (@($fidelityEyes | Where-Object { -not [bool]$_.valid -or -not [bool]$_.evaluated }).Count -eq 0) 'one or more render-scale eyes are invalid or unevaluated'
            Require-StableValue ([Math]::Abs([int64]$fidelityEyes[0].frame - [int64]$fidelityEyes[1].frame) -le 1) 'render-scale eye observations are not frame-coherent'
        }

        $presentation = $controller.presentation
        $presentationEyes = @($presentation.eyes)
        Require-StableValue ([uint32]$presentation.consecutiveBothEyesVendorFrames -ge 2) 'fewer than two consecutive stereo vendor frames are proven'
        Require-StableValue ($presentationEyes.Count -eq 2) 'render-scale presentation did not expose two eyes'
        if ($presentationEyes.Count -eq 2) {
            $paths = @($presentationEyes | ForEach-Object { Get-DevBenchNamedValue $_.path } | Select-Object -Unique)
            Require-StableValue (@($presentationEyes | Where-Object { -not [bool]$_.valid -or [bool]$_.loadingOrMenuContext -or [bool]$_.transitionCooldown }).Count -eq 0) 'one or more presentation eyes remain invalid or transitional'
            Require-StableValue ($paths.Count -eq 1 -and $paths[0] -eq 'vendorevaluated') 'both eyes are not using the same vendor-evaluated presentation path'
        }

        if ($method -eq 'fsr') {
            $fsr = $renderStatus.fsrDispatch
            Require-StableValue ([bool]$fsr.actualDispatchBothEyesValid -and [bool]$fsr.actualDispatchBackendConverged) 'FSR did not prove a converged two-eye dispatch'
            Require-StableValue (-not [bool]$fsr.actualRuntimeFallbackObserved) 'FSR runtime fallback is active'
            Require-StableValue (-not [bool]$fsr.shaderCompilationActive) 'shader compilation is active'
            Require-StableValue ([bool]$fsr.contractReady -and (Get-DevBenchNamedValue $fsr.contractLifecyclePhase) -eq 'ready') 'FSR runtime contract is not ready'
        }
        elseif ($method -eq 'dlss') {
            $lifecycle = $controller.dlssLifecycle
            Require-StableValue ([bool]$lifecycle.resourcesPresent -and [bool]$lifecycle.readyForContract) 'DLSS runtime resources are not ready'
            Require-StableValue ((Get-DevBenchNamedValue $lifecycle.phase) -eq 'ready' -and [uint32]$lifecycle.failures -eq 0) 'DLSS runtime lifecycle is not cleanly ready'
        }
    }
    else {
        $controllerState = Get-DevBenchNamedValue $controller.state
        $nativeControllerSettled =
            ($transitionState -eq 'idle' -and $controllerState -eq 'idle') -or
            ($transitionState -eq 'active' -and $controllerState -eq 'active')
        Require-StableValue ($nativeControllerSettled) "native-resolution controller state is '$transitionState/$controllerState'"
        Require-StableValue (($flags -band [uint64]0x10) -eq 0 -and ($flags -band [uint64]0x20) -eq 0) 'render-scale remains latched or active for a native-resolution profile'
    }

    $signature = if ($hasEffective) {
        @(
            $method,
            (Get-DevBenchNamedValue $effectiveProfile.qualityMode),
            [bool]$effectiveProfile.renderScaleMode,
            (Get-DevBenchNamedValue $effectiveProfile.dlssProfile),
            (Get-DevBenchNamedValue $effectiveProfile.fsrRuntime),
            [uint32]$displayEyeWidth,
            [uint32]$displayEyeHeight,
            [uint32]$renderEyeWidth,
            [uint32]$renderEyeHeight,
            [uint64]$controller.targetEpoch,
            [uint32]$controller.stable.contractGeneration
        ) -join '|'
    } else { $null }

    return [pscustomobject][ordered]@{
        satisfied = $reasons.Count -eq 0
        renderScaleActive = $renderScaleActive
        stereoEvidence = $stereoEvidence
        method = $method
        qualityMode = $qualityMode
        effectiveRenderScaleMode = $effectiveRenderScaleMode
        expectedProfile = $ExpectedProfile
        expectedProfileMatches = if ($null -ne $ExpectedProfile -and $hasEffective) { Test-DevBenchUpscalingProfilesEqual $effectiveProfile $ExpectedProfile } else { $null }
        dlssProfile = $dlssProfile
        fsrRuntime = $fsrRuntime
        frame = if ($null -ne $frame) { [uint32]$frame } else { [uint32]0 }
        signature = $signature
        resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $RenderScaleStatus
        reasons = @($reasons | Select-Object -Unique)
    }
}

function Get-DevBenchRuntimeExpectations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Runtime)
    $pidValue = $null
    foreach ($name in @('pid', 'processId')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) { $pidValue = [int]$property.Value; break }
    }
    $exeValue = $null
    foreach ($name in @('exe', 'executable')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $exeValue = [string]$property.Value; break }
    }
    $buildId = if ($Runtime.PSObject.Properties['buildId']) { [string]$Runtime.buildId } else { $null }
    $artifactPath = if ($Runtime.PSObject.Properties['artifactPath']) { [string]$Runtime.artifactPath } elseif ($Runtime.PSObject.Properties['dllPath']) { [string]$Runtime.dllPath } else { $null }
    $artifactSha256 = if ($Runtime.PSObject.Properties['artifactSha256']) { [string]$Runtime.artifactSha256 } else { $null }
    return [pscustomobject][ordered]@{ port = [int]$Runtime.port; pid = $pidValue; exe = $exeValue; buildId = $buildId; artifactPath = $artifactPath; artifactSha256 = $artifactSha256 }
}

function Test-DevBenchMainMenuReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuState,
        [string[]]$AllowedMenus = @('HUD Menu', 'Main Menu')
    )
    $openMenus = if ($MenuState.PSObject.Properties['openMenus']) { @($MenuState.openMenus) } else { @() }
    $unexpected = @($openMenus | Where-Object { $_ -notin $AllowedMenus })
    $messageBoxOpen = $MenuState.PSObject.Properties['messageBoxOpen'] -and [bool]$MenuState.messageBoxOpen
    $mainMenuOpen = $openMenus -contains 'Main Menu'
    return [pscustomobject][ordered]@{
        satisfied = $mainMenuOpen -and $unexpected.Count -eq 0 -and -not $messageBoxOpen
        mainMenuOpen = $mainMenuOpen
        openMenus = $openMenus
        allowedMenus = @($AllowedMenus)
        unexpectedMenus = $unexpected
        messageBoxOpen = [bool]$messageBoxOpen
    }
}

function Resolve-DevBenchServiceProbeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToolDefinition,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][bool]$ArgumentsSupplied,
        [Parameter(Mandatory)][string]$ToolName
    )

    if ($ArgumentsSupplied) {
        throw "serviceReady does not accept explicit -ArgumentsJson because an arbitrary action cannot be proven read-only across retries. Use toolAvailable for registration-only waits or omit -ArgumentsJson so the controller can synthesize a qualified probe."
    }

    $schemaProperty = $ToolDefinition.PSObject.Properties['inputSchema']
    if (-not $schemaProperty -or $null -eq $schemaProperty.Value) {
        throw "serviceReady cannot safely probe '$ToolName' because tools/list did not publish an inputSchema. Use toolAvailable when registration is sufficient."
    }
    $schema = $schemaProperty.Value
    $requiredProperty = $schema.PSObject.Properties['required']
    [string[]]$required = @()
    if ($requiredProperty -and $null -ne $requiredProperty.Value) {
        $required = @($requiredProperty.Value | ForEach-Object { [string]$_ })
    }
    if ($required.Count -eq 0) {
        return [pscustomobject][ordered]@{ arguments = $Arguments; source = 'schema-empty-valid'; synthesizedAction = $null }
    }

    $missing = @($required | Where-Object { -not $Arguments.Contains($_) })
    if ($missing.Count -eq 0) {
        return [pscustomobject][ordered]@{ arguments = $Arguments; source = 'schema-satisfied'; synthesizedAction = $null }
    }
    $supportedEnvelope = @('contractMajor', 'clientId', 'commandId', 'action')
    $unknownRequired = @($missing | Where-Object { $_ -notin $supportedEnvelope })
    if ($unknownRequired.Count -gt 0) {
        throw "serviceReady cannot synthesize a qualified read-only probe for '$ToolName'; required field(s) are not part of the registry envelope: $($unknownRequired -join ', '). Use toolAvailable or add a reviewed tool-specific probe adapter."
    }

    $propertiesProperty = $schema.PSObject.Properties['properties']
    $properties = if ($propertiesProperty) { $propertiesProperty.Value } else { $null }
    $action = $null
    if ($missing -contains 'action') {
        $actionSchema = if ($properties) { $properties.PSObject.Properties['action'] } else { $null }
        $enumProperty = if ($actionSchema) { $actionSchema.Value.PSObject.Properties['enum'] } else { $null }
        $allowedActions = if ($enumProperty) { @($enumProperty.Value | ForEach-Object { [string]$_ }) } else { @() }
        if ($allowedActions.Count -eq 0 -or $allowedActions -contains 'registry') { $action = 'registry' }
        elseif ($allowedActions -contains 'capabilities') { $action = 'capabilities' }
        else {
            throw "serviceReady cannot synthesize a qualified read-only probe for '$ToolName'; action supports neither registry nor capabilities. Use toolAvailable or add a reviewed tool-specific probe adapter."
        }
    }

    $resolved = [ordered]@{}
    foreach ($key in $Arguments.Keys) { $resolved[[string]$key] = $Arguments[$key] }
    if ($missing -contains 'contractMajor') {
        $contractSchema = if ($properties) { $properties.PSObject.Properties['contractMajor'] } else { $null }
        $constProperty = if ($contractSchema) { $contractSchema.Value.PSObject.Properties['const'] } else { $null }
        $defaultProperty = if ($contractSchema) { $contractSchema.Value.PSObject.Properties['default'] } else { $null }
        $resolved['contractMajor'] = if ($constProperty) { [int]$constProperty.Value } elseif ($defaultProperty) { [int]$defaultProperty.Value } else { 1 }
    }
    if ($missing -contains 'clientId') { $resolved['clientId'] = 'devbench-control-service-ready' }
    if ($missing -contains 'commandId') { $resolved['commandId'] = "service-ready-$([guid]::NewGuid().ToString('N'))" }
    if ($missing -contains 'action') { $resolved['action'] = $action }

    return [pscustomobject][ordered]@{ arguments = $resolved; source = 'schema-registry-envelope'; synthesizedAction = $action }
}

function Test-DevBenchPerformanceNeutral {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $observations = [Collections.Generic.List[object]]::new()
    $scan = [pscustomobject]@{ sawDistortionField = $false }
    function Visit-PerformanceState($Value) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        $properties = if ($Value -is [Collections.IDictionary]) {
            @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            foreach ($entry in $Value) { Visit-PerformanceState $entry }
            return
        }
        else { @($Value.PSObject.Properties) }

        $distortion = @($properties | Where-Object Name -eq 'performanceDistorted') | Select-Object -First 1
        if ($null -ne $distortion) {
            $scan.sawDistortionField = $true
            $epoch = @($properties | Where-Object Name -eq 'performanceEpoch') | Select-Object -First 1
            $physical = @($properties | Where-Object Name -eq 'physicalStateKnown') | Select-Object -First 1
            $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
            $epochIsInteger = $null -ne $epoch -and
                @($integerTypes | Where-Object { $_.IsInstanceOfType($epoch.Value) }).Count -gt 0
            if ($distortion.Value -is [bool] -and $epochIsInteger -and
                $null -ne $physical -and $physical.Value -is [bool]) {
                $observations.Add([pscustomobject][ordered]@{
                    distorted = [bool]$distortion.Value
                    epoch = [uint64]$epoch.Value
                    physicalStateKnown = [bool]$physical.Value
                })
            }
        }
        foreach ($property in $properties) { Visit-PerformanceState $property.Value }
    }

    foreach ($item in @($Content)) { Visit-PerformanceState $item }
    $known = $observations.Count -gt 0
    $distorted = @($observations | Where-Object distorted).Count -gt 0
    $physicalStateKnown = $known -and
        @($observations | Where-Object { -not $_.physicalStateKnown }).Count -eq 0
    $epochs = @($observations | ForEach-Object epoch | Sort-Object -Unique)
    $epochKnown = $epochs.Count -eq 1
    return [pscustomobject][ordered]@{
        known = $known
        neutral = $known -and -not $distorted -and $physicalStateKnown -and $epochKnown
        performanceDistorted = $distorted
        performanceEpoch = if ($epochKnown) { [uint64]$epochs[0] } else { $null }
        physicalStateKnown = $physicalStateKnown
        reason = if (-not $known -and $scan.sawDistortionField) {
            'performance-ownership-state-missing'
        }
        elseif (-not $known) {
            'performance-distortion-state-missing'
        }
        elseif ($distorted) {
            'intrusive-temporal-probe-armed'
        }
        elseif (-not $physicalStateKnown) {
            'performance-physical-state-unproven'
        }
        elseif (-not $epochKnown) {
            'performance-epoch-ambiguous'
        }
        else {
            'intrusive-temporal-probe-disarmed'
        }
    }
}

function Test-DevBenchPerformanceWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )

    $applicable = [bool]$Before.applicable -or [bool]$After.applicable
    $sameApplicability = [bool]$Before.applicable -eq [bool]$After.applicable
    $sameEpoch = -not $applicable -or
        ($null -ne $Before.performanceEpoch -and
            $null -ne $After.performanceEpoch -and
            [uint64]$Before.performanceEpoch -eq [uint64]$After.performanceEpoch)
    $valid = $sameApplicability -and [bool]$Before.neutral -and
        [bool]$After.neutral -and $sameEpoch
    return [pscustomobject][ordered]@{
        valid = $valid
        applicable = $applicable
        sameEpoch = $sameEpoch
        before = $Before
        after = $After
        reason = if (-not $sameApplicability) {
            'performance-probe-registration-changed'
        }
        elseif (-not [bool]$Before.neutral) {
            [string]$Before.reason
        }
        elseif (-not [bool]$After.neutral) {
            [string]$After.reason
        }
        elseif (-not $sameEpoch) {
            'performance-probe-epoch-changed'
        }
        else {
            'performance-window-neutral'
        }
    }
}

Export-ModuleMember -Function Get-DevBenchSemanticStatus, Get-DevBenchServiceState, Test-DevBenchServiceReady, Test-DevBenchNoBlockingMenu, Test-DevBenchMainMenuReady, Get-DevBenchMenuDismissalPlan, Get-DevBenchNamedValue, Get-DevBenchResourcePublicationTelemetry, Get-DevBenchRenderScalePreparationTelemetry, Test-DevBenchUpscalingProfilesEqual, Test-DevBenchUpscalingStable, Get-DevBenchRuntimeExpectations, Resolve-DevBenchServiceProbeArguments, Test-DevBenchPerformanceNeutral, Test-DevBenchPerformanceWindow
