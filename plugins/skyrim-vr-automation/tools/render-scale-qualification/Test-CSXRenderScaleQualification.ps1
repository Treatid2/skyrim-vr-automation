# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = Join-Path $PSScriptRoot 'RenderScaleQualification.psm1'
$protocolPath = Join-Path $PSScriptRoot 'protocol.v1.json'
Import-Module $module -Force

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-TestObjectSha256($Value) {
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-TestTextSha256([AllowEmptyString()][string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Assert-FinalizerRejects {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Review,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter(Mandatory)][string]$ErrorPattern,
        [Parameter(Mandatory)][string]$Message,
        [switch]$RebindInventory
    )
    $changedRaw = $Raw | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    & $Mutation $changedRaw
    if ($RebindInventory) { Set-TestArtifactInventory -Root $Root -Raw $changedRaw | Out-Null }
    Write-CSXJsonFile -Path (Join-Path $Root 'run.raw.json') -Value $changedRaw | Out-Null
    $changedReview = $Review | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $changedReview.runRawSha256 = Get-CSXFileSha256 (Join-Path $Root 'run.raw.json')
    $changedReview.baselineRunSha256 = Get-CSXPathValue $changedRaw 'baseline.runSha256'
    Write-CSXJsonFile -Path (Join-Path $Root 'visual-review.json') -Value $changedReview | Out-Null
    $result = Update-CSXQualificationReport -EvidenceDirectory $Root
    $errorText = $result.report.errors -join ' | '
    Assert-Test ($result.report.status -notin @('PASS', 'LOCAL_PASS') -and $errorText -match $ErrorPattern) `
        "$Message Status=$($result.report.status); errors=$errorText"
}

function New-TestDiagnosticsDelta {
    return [pscustomobject][ordered]@{
        stress = [pscustomobject]@{ failureEvents = 0 }
        presentation = [pscustomobject]@{ vendorFailureStretchEyeObservations = 0; boundsMismatchFallbackEyeObservations = 0 }
        failures = [pscustomobject]@{
            fidelityMismatches = 0; transition = 0; outOfMemory = 0; deviceLost = 0; dlssLifecycle = 0
            fsrLifecycle = 0; memoryTrim = 0; retirementFence = 0
        }
        dlssTrace = [pscustomobject]@{ droppedRecords = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0 }
    }
}

$publicationRecords = Get-CSXQualificationWaitRecords -ScenarioResult ([pscustomobject]@{
        results = @([pscustomobject]@{
                label = 'coc-01-wait'
                result = [pscustomobject]@{
                    transitionId = 1; satisfied = $true
                    observation = [pscustomobject]@{
                        physical = [pscustomobject]@{
                            stable = [pscustomobject]@{ transitionEpoch = 77 }
                        }
                        resourcePublication = [pscustomobject]@{
                            current = $true; currentGeneration = 31; completedGeneration = 31; publishedGeneration = 31
                            expectedWidth = 1644; expectedHeight = 1826; publishedWidth = 1644; publishedHeight = 1826
                            complete = $true; deferredSetupAcknowledged = $true; deviceMatches = $true; contextMatches = $true
                        }
                    }
                }
            })
    }) -LabelPrefix 'coc' -PreparationResponse ([pscustomobject]@{
        status = [pscustomobject]@{
            preparation = [pscustomobject]@{
                schemaVersion = 1; devBenchOnly = $true; active = $false
                sessionId = 12; qpcFrequency = 10000000
                retainedEvents = 1; capacity = 512
                overwrittenEvents = 0; coalescedEvents = 0
                events = @([pscustomobject]@{
                        sequence = 1; sessionId = 12; requestId = 80
                        transitionEpoch = 77; event = 'request_to_prepared'
                        outcome = 'ready'; occurrences = 1; reasons = @()
                        durationQpcTicks = 500; durationMs = 0.05
                        bytecodeCompilationMs = 0; d3dObjectCreationMs = 0
                    })
            }
        }
    })
Assert-Test ($publicationRecords.Count -eq 1 -and $publicationRecords[0].resourcePublication.available -and
    $publicationRecords[0].resourcePublication.currentGeneration -eq 31 -and
    $publicationRecords[0].resourcePublication.publishedWidth -eq 1644 -and
    $publicationRecords[0].resourcePublication.complete -and
    $publicationRecords[0].resourcePublication.contextMatches -and
    $publicationRecords[0].preparation.filterApplied -and
    $publicationRecords[0].preparation.eventCount -eq 1 -and
    $publicationRecords[0].preparation.stages.request_to_prepared.durationMs.total -eq 0.05) 'Qualification wait extraction preserves publication and preparation telemetry.'
$publicationSummary = Get-CSXResourcePublicationSummary -Records $publicationRecords
Assert-Test ($publicationSummary.availableSamples -eq 1 -and $publicationSummary.currentSamples -eq 1 -and
    $publicationSummary.latest.deferredSetupAcknowledged) 'Qualification telemetry summary retains publication completeness.'

function New-TestFailureBreakdown {
    $breakdown = [ordered]@{}
    foreach ($path in @(
        'stress.failureEvents', 'presentation.vendorFailureStretchEyeObservations', 'presentation.boundsMismatchFallbackEyeObservations',
        'failures.fidelityMismatches', 'failures.transition', 'failures.outOfMemory', 'failures.deviceLost',
        'failures.dlssLifecycle', 'failures.fsrLifecycle', 'failures.memoryTrim', 'failures.retirementFence',
        'dlssTrace.droppedRecords', 'dlssTrace.duplicatedConstantsFailures', 'dlssTrace.evaluateFailures'
    )) { $breakdown[$path] = 0 }
    return [pscustomobject]$breakdown
}

function New-TestTransitionRecord {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][ValidateSet('coc', 'menu')][string]$Assay,
        [Parameter(Mandatory)][int]$Ordinal,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][double]$ElapsedMs
    )
    $transitionId = if ($Assay -eq 'coc') { $Ordinal } else { 100 + $Ordinal }
    $expectedCell = if ($Assay -eq 'coc' -and $Ordinal % 2 -eq 1) {
        [string]$Protocol.fixture.interiorCellEditorId
    }
    else { [string]$Protocol.fixture.startCellEditorId }
    $profile = if ($Assay -eq 'coc') {
        if ($Ordinal % 2 -eq 1) {
            if ($GpuVendor -eq 'NVIDIA') { $Protocol.fixture.profiles.nvidiaInterior } else { $Protocol.fixture.profiles.amdInterior }
        }
        else { $Protocol.fixture.profiles.sharedExterior }
    }
    else {
        $matrixName = if ($GpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' }
        @($Protocol.menuAssay.$matrixName)[$Ordinal - 1]
    }
    $target = Add-CSXExactRuntimeToProfile -Profile $profile -FsrRuntime $FsrRuntime
    $foveationTarget = Get-CSXFoveationTarget $Protocol
    $beginTick = [uint64](1000000 + $transitionId * 1000)
    $dispatchTick = [uint64]($beginTick + 50)
    $stableTick = [uint64]($dispatchTick + [uint64]$ElapsedMs)
    $beginFrame = [uint64](1000 + $transitionId * 5)
    $dispatchFrame = [uint64]($beginFrame + 1)
    $stableFrame = [uint64]($dispatchFrame + 2)
    $stressSessionId = if ($Assay -eq 'coc') { [uint64]501 } else { [uint64]502 }
    $producer = [pscustomobject][ordered]@{ buildId = $BuildId }
    $baseline = [pscustomobject][ordered]@{
        timing = [pscustomobject][ordered]@{ clock = 'query_performance_counter'; beginTick = $beginTick; tickFrequency = [uint64]1000 }
        frame = $beginFrame; stressSessionId = $stressSessionId
    }
    $begin = [pscustomobject][ordered]@{
        action = 'qualification_begin'; transitionId = $transitionId; ownerId = $RunId; accepted = $true
        baseline = $baseline; producer = $producer
    }
    $dispatch = [pscustomobject][ordered]@{
        action = 'qualification_dispatch'; transitionId = $transitionId; ownerId = $RunId; accepted = $true
        timing = [pscustomobject][ordered]@{
            clock = 'query_performance_counter'; elapsedOrigin = 'qualification_dispatch'
            dispatchTick = $dispatchTick; tickFrequency = [uint64]1000
        }
        dispatchFrame = $dispatchFrame; producer = $producer
    }
    $mutation = if ($Assay -eq 'coc') {
        [pscustomobject][ordered]@{ queued = $true }
    }
    else {
        [pscustomobject][ordered]@{
            action = 'apply'; accepted = $true; disposition = 'queued'; method = [string]$target.method
            qualityMode = [int]$target.qualityMode; enabled = [bool]$target.renderScaleMode; dlssPreset = 1
            requestID = [uint64](5000 + $Ordinal); transitionEpoch = [uint64](6000 + $Ordinal); producer = $producer
        }
    }
    $timing = [pscustomobject][ordered]@{
        clock = 'query_performance_counter'; elapsedOrigin = 'qualification_dispatch'; tickFrequency = [uint64]1000
        beginTick = $beginTick; dispatchTick = $dispatchTick; stableTick = $stableTick
        elapsedMs = $ElapsedMs; elapsedFrames = [uint64]2; timeoutMs = [uint64]120000
    }
    $active = [bool]$target.renderScaleMode
    $foveation = [pscustomobject][ordered]@{
        target = $foveationTarget; floatTolerance = 0.0001
        observed = [pscustomobject][ordered]@{
            settings = $foveationTarget
            physical = [pscustomobject][ordered]@{
                foveatedVendorDispatch = ($active -and [bool]$foveationTarget.foveatedVendorDispatch)
                peripheryTAAEnable = ($active -and [bool]$foveationTarget.peripheryTAAEnable)
            }
        }
    }
    $wait = [pscustomobject][ordered]@{
        action = 'qualification_wait'; transitionId = $transitionId; ownerId = $RunId; satisfied = $true; outcome = 'stable'
        baseline = $baseline; timing = $timing
        frames = [pscustomobject][ordered]@{ begin = $beginFrame; dispatch = $dispatchFrame; stable = $stableFrame }
        failureReasons = @(); expectedCell = [pscustomobject][ordered]@{ editorId = $expectedCell }
        currentCell = [pscustomobject][ordered]@{ formId = $(if ($expectedCell -eq $Protocol.fixture.startCellEditorId) { 100 } else { 200 }); editorId = $expectedCell }
        target = $target; foveationTarget = $foveationTarget; foveation = $foveation
        diagnostics = [pscustomobject][ordered]@{ delta = New-TestDiagnosticsDelta }
        producer = $producer
    }
    return [pscustomobject][ordered]@{
        assay = $Assay; ordinal = $Ordinal; transitionId = $transitionId; ownerId = $RunId; outcome = 'stable'
        expectedCell = [pscustomobject][ordered]@{ editorId = $expectedCell; formId = $null }
        target = $target; method = [string]$target.method; qualityMode = [int]$target.qualityMode
        renderScaleMode = [bool]$target.renderScaleMode
        dlssProfile = $(if ($target.method -eq 'dlss') { [string]$target.dlssProfile } else { $null })
        fsrRuntime = $(if ($target.method -eq 'fsr') { [string]$target.fsrRuntime } else { $null })
        foveationTarget = $foveationTarget; qpcTiming = $timing; elapsedMs = $ElapsedMs; elapsedFrames = [uint64]2; satisfied = $true
        receipts = [pscustomobject][ordered]@{ begin = $begin; dispatch = $dispatch; mutation = $mutation; wait = $wait }
    }
}

function Get-TestMenuStrata {
    param([Parameter(Mandatory)][object[]]$Rows)
    $byMethod = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        $byMethod[$method] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object method -eq $method | ForEach-Object elapsedMs)) -IncludeRate
    }
    $byRenderScale = [ordered]@{
        off = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { -not $_.renderScaleMode } | ForEach-Object elapsedMs)) -IncludeRate
        on = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object renderScaleMode | ForEach-Object elapsedMs)) -IncludeRate
    }
    $combined = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        foreach ($state in @($false, $true)) {
            $key = "$method-render-scale-$(if ($state) { 'on' } else { 'off' })"
            $combined[$key] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { $_.method -eq $method -and $_.renderScaleMode -eq $state } | ForEach-Object elapsedMs)) -IncludeRate
        }
    }
    return [pscustomobject][ordered]@{ byMethod = [pscustomobject]$byMethod; byRenderScaleState = [pscustomobject]$byRenderScale; combined = [pscustomobject]$combined }
}

function New-TestCoreAssays {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$VisualIndexSha256,
        [ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor = 'NVIDIA',
        [ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime = 'fsr3'
    )
    $cocRecords = @(1..20 | ForEach-Object {
        New-TestTransitionRecord -Protocol $Protocol -RunId $RunId -BuildId $BuildId -Assay coc -Ordinal $_ `
            -GpuVendor $GpuVendor -FsrRuntime $FsrRuntime -ElapsedMs (20.0 + $_)
    })
    $menuRecords = @(1..25 | ForEach-Object {
        New-TestTransitionRecord -Protocol $Protocol -RunId $RunId -BuildId $BuildId -Assay menu -Ordinal $_ `
            -GpuVendor $GpuVendor -FsrRuntime $FsrRuntime -ElapsedMs (10.0 + $_)
    })
    $validStretch = [pscustomobject]@{ recordAccepted = $true; meanFrames = 1.0; maxFrames = 2; meanMs = 1.0; maxMs = 2.0 }
    $validValidation = [pscustomobject]@{ scenarioOk = $true; stretchError = $null; stressRecordError = $null }
    $cocStress = [pscustomobject]@{
        requestEvents = 20; uniqueRequestEpochs = 20; metrics = 20; uniqueMetricEpochs = 20
        coalescedDuplicateCount = 0; overwrittenEvents = 0; terminalMetricClear = $true; exactMenuCrossBindings = @()
    }
    $menuStress = [pscustomobject]@{
        requestEvents = 25; uniqueRequestEpochs = 25; metrics = 25; uniqueMetricEpochs = 25
        coalescedDuplicateCount = 0; overwrittenEvents = 0; terminalMetricClear = $true
        exactMenuCrossBindings = @($menuRecords | ForEach-Object {
            [pscustomobject][ordered]@{
                ordinal = $_.ordinal; requestID = $_.receipts.mutation.requestID
                transitionEpoch = $_.receipts.mutation.transitionEpoch; method = $_.method
                qualityMode = $_.qualityMode; renderScaleMode = $_.renderScaleMode
            }
        })
    }
    $traceGroups = if ($GpuVendor -eq 'NVIDIA') {
        @($Protocol.menuAssay.nvidiaMatrix | Where-Object method -eq 'dlss' | ForEach-Object {
            [pscustomobject][ordered]@{
                kind = 'dlss_dispatch'; ordinal = [int]$_.ordinal
                summary = [pscustomobject]@{
                    droppedRecords = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0
                    setConstantsCalls = 1; evaluateCalls = 1; totalRecords = 2
                }
                validation = [pscustomobject]@{ summary = [pscustomobject]@{ ok = $true }; records = [pscustomobject]@{ ok = $true } }
            }
        })
    }
    else {
        @([pscustomobject][ordered]@{
            kind = 'capability_only'; summary = [pscustomobject]@{ totalRecords = 0; setConstantsCalls = 0; evaluateCalls = 0 }
            validation = [pscustomobject]@{ ok = $true }
        })
    }
    $visualRuns = @(1..3 | ForEach-Object {
        [pscustomobject]@{ replicate = $_; childReceiptsPath = "visual/rep-$($_.ToString('D2'))/children.receipts.json" }
    })
    return [pscustomobject][ordered]@{
        coc = [pscustomobject]@{
            completed = 20; records = $cocRecords; failureCount = 0; diagnosticFailureLowerBound = 0; failedTransitions = 0
            statistics = Get-CSXMetricSummary -Values ([double[]]@($cocRecords.elapsedMs)) -IncludeRate
            strata = [pscustomobject][ordered]@{
                interior = Get-CSXMetricSummary -Values ([double[]]@($cocRecords | Where-Object { $_.ordinal % 2 -eq 1 } | ForEach-Object elapsedMs)) -IncludeRate
                exterior = Get-CSXMetricSummary -Values ([double[]]@($cocRecords | Where-Object { $_.ordinal % 2 -eq 0 } | ForEach-Object elapsedMs)) -IncludeRate
            }
            failureBreakdown = New-TestFailureBreakdown; failureWilson95 = Get-CSXWilsonInterval -Failures 0 -Trials 20
            stretch = $validStretch; stressTransitions = $cocStress; validation = $validValidation
        }
        menu = [pscustomobject]@{
            matrixName = $(if ($GpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' })
            completed = 25; records = $menuRecords; failureCount = 0; diagnosticFailureLowerBound = 0; failedTransitions = 0
            statistics = Get-CSXMetricSummary -Values ([double[]]@($menuRecords.elapsedMs)) -IncludeRate
            strata = Get-TestMenuStrata -Rows $menuRecords
            failureBreakdown = New-TestFailureBreakdown; failureWilson95 = Get-CSXWilsonInterval -Failures 0 -Trials 25
            stretch = $validStretch; stressTransitions = $menuStress; validation = $validValidation
            dlssTrace = [pscustomobject]@{
                outcome = $(if ($GpuVendor -eq 'NVIDIA') { 'dispatch_validated' } else { 'capability_lifecycle_only_zero_dispatch' })
                evidence = [pscustomobject]@{ ok = $true; groups = $traceGroups; errors = @(); warnings = @() }
            }
        }
        visual = [pscustomobject]@{
            state = 'complete'; completedReplicates = 3; requestedFrames = 48; validatedChildReceipts = 48
            reviewOrdinals = @(1, 8, 16); indexPath = 'visual-index.json'; indexSha256 = $VisualIndexSha256
            fixtureObservations = @(1..4 | ForEach-Object { [pscustomobject]@{ label = "visual-$_"; ok = $true } })
            runs = $visualRuns
        }
    }
}

function New-TestRecoveries {
    return [pscustomobject][ordered]@{
        one = [pscustomobject]@{ state = 'PASS'; requestedDurationMs = 30000; wallClockMs = 30000.0; evidence = 'recovery-1.json' }
        two = [pscustomobject]@{ state = 'PASS'; requestedDurationMs = 30000; wallClockMs = 30000.0; evidence = 'recovery-2.json' }
    }
}

function Copy-TestObject($Value) {
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
}

function Write-TestPng {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][uint32]$Width,
        [Parameter(Mandatory)][uint32]$Height,
        [Parameter(Mandatory)][byte]$Seed
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $bytes = [Collections.Generic.List[byte]]::new()
    $bytes.AddRange([byte[]](137, 80, 78, 71, 13, 10, 26, 10))
    $bytes.AddRange([byte[]](0, 0, 0, 13, 73, 72, 68, 82))
    $bytes.AddRange([byte[]](
        (($Width -shr 24) -band 0xff), (($Width -shr 16) -band 0xff), (($Width -shr 8) -band 0xff), ($Width -band 0xff),
        (($Height -shr 24) -band 0xff), (($Height -shr 16) -band 0xff), (($Height -shr 8) -band 0xff), ($Height -band 0xff),
        8, 2, 0, 0, 0
    ))
    $bytes.AddRange([byte[]](0, 0, 0, 0))
    $bytes.AddRange([byte[]](0, 0, 0, 1, 73, 68, 65, 84, $Seed, 0, 0, 0, 0))
    $bytes.AddRange([byte[]](0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130))
    [IO.File]::WriteAllBytes($Path, $bytes.ToArray())
    return $Path
}

function Write-TestCsv([string]$Path, [object[]]$Rows) {
    $csv = @($Rows | Select-Object assay, ordinal, transitionId, ownerId, outcome, method, qualityMode, renderScaleMode, elapsedMs | ConvertTo-Csv -NoTypeInformation)
    [IO.File]::WriteAllText($Path, ($csv -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
}

function New-TestRuntimeEvidence([string]$BuildId) {
    return [pscustomobject][ordered]@{
        buildId = $BuildId
        health = [pscustomobject][ordered]@{ ok = $true; exe = 'SkyrimVR.exe'; buildId = $BuildId }
        binding = [pscustomobject][ordered]@{
            listenerPid = 4242
            process = [pscustomobject][ordered]@{
                path = 'C:\Games\SkyrimVR.exe'
                startTimeUtc = [DateTime]::SpecifyKind([DateTime]::Parse('2026-08-26T11:00:00'), [DateTimeKind]::Utc)
            }
        }
    }
}

function New-TestStressRecord {
    param([AllowEmptyCollection()][Parameter(Mandatory)][object[]]$Rows, [Parameter(Mandatory)][uint64]$SessionId, [Parameter(Mandatory)][int]$SchemaVersion)
    $requests = [Collections.Generic.List[object]]::new()
    $metrics = [Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows | Sort-Object ordinal)) {
        $ordinal = [int]$row.ordinal
        $requestId = if ([string]$row.assay -eq 'menu') { [uint64]$row.receipts.mutation.requestID } else { [uint64](10000 + $ordinal) }
        $epoch = if ([string]$row.assay -eq 'menu') { [uint64]$row.receipts.mutation.transitionEpoch } else { [uint64](20000 + $ordinal) }
        $method = "k$(([string]$row.method).ToUpperInvariant())"
        $requests.Add([pscustomobject][ordered]@{
            type = 'Request'; sequence = [uint64]$ordinal; requestID = $requestId; transitionEpoch = $epoch
            occurrences = 1; method = $method; qualityMode = [int]$row.qualityMode; active = [bool]$row.renderScaleMode
        })
        $metrics.Add([pscustomobject][ordered]@{
            requestID = $requestId; transitionEpoch = $epoch; method = $method; qualityMode = [int]$row.qualityMode
            completed = $true; superseded = $false
        })
    }
    $gates = @([pscustomobject][ordered]@{ name = 'terminal_state'; passed = $true })
    return [pscustomobject][ordered]@{
        schema = 'community-shaders.vr-render-scale.iteration'; schemaVersion = $SchemaVersion
        session = [pscustomobject][ordered]@{
            id = $SessionId; active = $false; startFrame = [uint64]100; endFrame = [uint64]1000
            coalescedDuplicateCount = 0; overwrittenEvents = 0
        }
        events = @($requests); metrics = @($metrics)
        acceptance = [pscustomobject][ordered]@{ accepted = $true; gates = $gates }
        verdict = [pscustomobject][ordered]@{ accepted = $true; gates = $gates }
    }
}

function New-TestScenarioResult {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][ValidateSet('coc', 'menu')][string]$Assay,
        [Parameter(Mandatory)][string]$BuildId
    )
    $receiptByLabel = @{}
    foreach ($row in $Rows) {
        $prefix = "$Assay-$(([int]$row.ordinal).ToString('D2'))"
        $receiptByLabel["$prefix-begin"] = $row.receipts.begin
        $receiptByLabel["$prefix-dispatch"] = $row.receipts.dispatch
        $receiptByLabel["$prefix-$(if ($Assay -eq 'coc') { 'command' } else { 'apply' })"] = $row.receipts.mutation
        $receiptByLabel["$prefix-wait"] = $row.receipts.wait
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($step in @($Request.steps)) {
        $label = [string]$step.label
        $result = $receiptByLabel[$label]
        if ($null -eq $result) {
            $action = [string](Get-CSXPathValue $step 'args.action' 'synthetic')
            $result = [pscustomobject][ordered]@{ action = $action; producer = [pscustomobject]@{ buildId = $BuildId } }
            if ($action -like 'dlss_trace_*') {
                $result | Add-Member -NotePropertyName capture -NotePropertyValue ([pscustomobject][ordered]@{
                    active = ($action -eq 'dlss_trace_start'); sessionID = [uint64](8000 + $results.Count)
                    totalRecords = 0; setConstantsCalls = 0; evaluateCalls = 0
                })
            }
        }
        $results.Add([pscustomobject][ordered]@{ label = $label; ok = $true; result = $result })
    }
    return [pscustomobject][ordered]@{ ok = $true; aborted = $false; wallClockMs = 1000.0; results = @($results) }
}

function New-TestInactiveEvidence {
    param([Parameter(Mandatory)]$Protocol, [Parameter(Mandatory)][string]$BuildId, [Parameter(Mandatory)][string]$FsrRuntime)
    $foveation = Get-CSXFoveationTarget $Protocol
    $profile = [pscustomobject][ordered]@{
        method = [pscustomobject]@{ name = 'FSR' }; qualityMode = [pscustomobject]@{ name = 'Hoshipa' }
        renderScaleMode = $true; fsrRuntime = [pscustomobject]@{ name = $FsrRuntime }
    }
    return [pscustomobject][ordered]@{
        scene = [pscustomobject][ordered]@{ cell = [pscustomobject]@{ editorId = [string]$Protocol.fixture.startCellEditorId } }
        health = [pscustomobject][ordered]@{ ok = $true; exe = 'SkyrimVR.exe'; buildId = $BuildId }
        qualification = [pscustomobject][ordered]@{ qualification = [pscustomobject]@{ active = $false }; producer = [pscustomobject]@{ buildId = $BuildId } }
        trace = [pscustomobject][ordered]@{ capture = [pscustomobject]@{ active = $false }; producer = [pscustomobject]@{ buildId = $BuildId } }
        renderScale = [pscustomobject][ordered]@{
            status = [pscustomobject][ordered]@{ session = [pscustomobject]@{ active = $false }; cpuPerformance = [pscustomobject]@{ active = $false } }
            producer = [pscustomobject]@{ buildId = $BuildId }
        }
        upscaling = [pscustomobject][ordered]@{
            snapshot = [pscustomobject][ordered]@{ profiles = [pscustomobject][ordered]@{ requested = $profile; effective = $profile; stable = $profile } }
        }
        settings = [pscustomobject][ordered]@{ result = [pscustomobject][ordered]@{ settings = $foveation } }
        screenshot = [pscustomobject][ordered]@{ ok = $true; status = [pscustomobject]@{ active = $false } }
    }
}

function New-TestRecoveryRecord {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$FsrRuntime,
        [Parameter(Mandatory)][string]$Label,
        [switch]$NoWait
    )
    $request = New-CSXRecoveryScenario -Protocol $Protocol -ExpectedBuildId $BuildId -RunId $RunId -FsrRuntime $FsrRuntime -RecoveryLabel $Label
    if ($NoWait) { $request.steps = @($request.steps | Where-Object { -not $_.Contains('wait') }) }
    $payload = New-TestInactiveEvidence -Protocol $Protocol -BuildId $BuildId -FsrRuntime $FsrRuntime
    $results = [Collections.Generic.List[object]]::new()
    $evidence = [ordered]@{}
    foreach ($step in @($request.steps)) {
        $stepLabel = [string]$step.label
        if ($step.Contains('wait')) {
            $resultStep = [pscustomobject][ordered]@{ label = $stepLabel; ok = $true; ms = [int]$step.wait }
            $evidence['wait'] = $resultStep
        }
        else {
            $property = if ($stepLabel -like '*-scene') { 'scene' }
                elseif ($stepLabel -like '*-health') { 'health' }
                elseif ($stepLabel -like '*-qualification-status') { 'qualification' }
                elseif ($stepLabel -like '*-dlss-trace-status') { 'trace' }
                elseif ($stepLabel -like '*-renderscale-status') { 'renderScale' }
                elseif ($stepLabel -like '*-upscaling-snapshot') { 'upscaling' }
                elseif ($stepLabel -like '*-feature-settings') { 'settings' }
                else { 'screenshot' }
            $value = Get-CSXPropertyValue $payload $property
            $resultStep = [pscustomobject][ordered]@{ label = $stepLabel; ok = $true; result = $value }
            $evidence[$property] = $value
        }
        $results.Add($resultStep)
    }
    return [pscustomobject][ordered]@{
        request = $request
        result = [pscustomobject][ordered]@{ ok = $true; aborted = $false; results = @($results) }
        evidence = [pscustomobject]$evidence
        requestedDurationMs = $(if ($NoWait) { 0 } else { 30000 })
        wallClockMs = $(if ($NoWait) { 1000.0 } else { 30000.0 })
    }
}

function Add-TestTranscriptRow {
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)]$Arguments, [Parameter(Mandatory)]$Response)
    $index = $Rows.Count
    $started = [DateTimeOffset]::Parse('2026-08-26T11:00:00Z').AddMilliseconds($index * 10)
    $Rows.Add([pscustomobject][ordered]@{
        startedUtc = $started.ToString('o'); completedUtc = $started.AddMilliseconds(1).ToString('o')
        tool = $Tool; arguments = $Arguments; response = $Response; ok = $true; error = $null
    })
}

function Write-TestVisualEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Assays
    )
    $runs = [Collections.Generic.List[object]]::new()
    $samples = [Collections.Generic.List[object]]::new()
    $baseUtc = [DateTimeOffset]::Parse('2026-08-26T12:00:00Z')
    $serviceSessionId = "screenshot-session-$RunId"
    foreach ($replicate in 1..3) {
        $replicateDirectory = Join-Path $Root "visual\rep-$($replicate.ToString('D2'))"
        New-Item -ItemType Directory -Path $replicateDirectory -Force | Out-Null
        $request = New-CSXVisualSequenceRequest -Protocol $Protocol -RunId $RunId -Replicate $replicate -DestinationDirectory $replicateDirectory
        $requestPath = Write-CSXJsonFile -Path (Join-Path $replicateDirectory 'sequence.request.json') -Value $request
        $requestId = "$($replicate.ToString('D8'))-0000-0000-0000-$($replicate.ToString('D12'))"
        $shortId = ($requestId -replace '-', '').Substring(0, 8)
        $sequenceDirectory = Join-Path $replicateDirectory "CS_sequence_$shortId"
        New-Item -ItemType Directory -Path $sequenceDirectory -Force | Out-Null
        $acceptedUtc = $baseUtc.AddMilliseconds(($replicate - 1) * 60000)
        $terminalUtc = $acceptedUtc.AddMilliseconds(60000)
        $children = [Collections.Generic.List[object]]::new()
        $manifestChildren = [Collections.Generic.List[object]]::new()
        foreach ($ordinal in 1..16) {
            $childRequestId = "$($replicate.ToString('D2'))-$($ordinal.ToString('D6'))-child-request"
            $childAcceptedUtc = $acceptedUtc.AddMilliseconds(($ordinal - 1) * 4000)
            $normalized = [Collections.Generic.List[object]]::new()
            $embedded = [Collections.Generic.List[object]]::new()
            $outputs = [Collections.Generic.List[object]]::new()
            $viewIndex = 0
            foreach ($view in @('left_eye', 'right_eye', 'side_by_side')) {
                $suffix = $view -replace '_', '-'
                $width = if ($view -eq 'side_by_side') { [uint32]2 } else { [uint32]1 }
                $path = Join-Path $sequenceDirectory "frame_$($ordinal.ToString('D6'))_$suffix.png"
                $seed = [byte](($replicate - 1) * 48 + ($ordinal - 1) * 3 + $viewIndex + 1)
                Write-TestPng -Path $path -Width $width -Height 1 -Seed $seed | Out-Null
                $relative = [IO.Path]::GetRelativePath($Root, $path).Replace('\', '/')
                $sha256 = Get-CSXFileSha256 $path
                $length = [uint64](Get-Item -LiteralPath $path).Length
                $normalized.Add([pscustomobject][ordered]@{ view = $view; path = $relative; sha256 = $sha256; width = $width; height = 1 })
                $embedded.Add([pscustomobject][ordered]@{
                    path = [IO.Path]::GetFullPath($path); sha256 = $sha256; bytes = $length; committed = $true; integrityError = $null
                })
                $outputs.Add([pscustomobject][ordered]@{
                    view = $view; encoding = [pscustomobject][ordered]@{ format = 'png'; colourContract = 'sdr_srgb' }; nameSuffix = $suffix
                })
                $viewIndex++
            }
            $child = [pscustomobject][ordered]@{
                state = 'completed'; kind = 'sequence_frame'; clientId = "sequence:$requestId"; commandId = "frame:$ordinal"
                requestId = $childRequestId; parentRequestId = $requestId; sequenceOrdinal = $ordinal
                acceptedUtc = $childAcceptedUtc.ToString('o'); terminalUtc = $childAcceptedUtc.ToString('o')
                warnings = @(); error = $null
                artifactProgress = [pscustomobject][ordered]@{ expected = 3; terminal = 3; successful = 3 }
                effective = [pscustomobject][ordered]@{
                    source = [pscustomobject][ordered]@{ kind = 'hmd_submission'; fallback = 'reject' }
                    destination = [pscustomobject][ordered]@{
                        policy = 'absolute'; directory = [IO.Path]::GetFullPath($sequenceDirectory)
                        baseName = "frame_$($ordinal.ToString('D6'))"; overwrite = 'never'
                    }
                    outputs = @($outputs)
                }
                artifacts = @($embedded)
            }
            $receipt = [pscustomobject][ordered]@{ ok = $true; server = [pscustomobject]@{ sessionId = $serviceSessionId }; result = $child }
            $children.Add([pscustomobject][ordered]@{
                replicate = $replicate; ordinal = $ordinal; requestId = $childRequestId
                acceptedUtc = $childAcceptedUtc.ToString('o'); receipt = $receipt; artifacts = @($normalized)
            })
            $manifestChildren.Add([pscustomobject][ordered]@{
                ordinal = $ordinal; requestId = $childRequestId; state = 'completed'; artifact = $embedded[0]; error = $null
            })
            if ($ordinal -in @(1, 8, 16)) {
                $samples.Add([pscustomobject][ordered]@{ replicate = $replicate; ordinal = $ordinal; artifacts = @($normalized) })
            }
        }
        $childrenPath = Write-CSXJsonFile -Path (Join-Path $replicateDirectory 'children.receipts.json') -Value @($children)
        $manifestPath = Join-Path $sequenceDirectory 'sequence.json'
        $manifest = [pscustomobject][ordered]@{
            state = 'final'; requestId = $requestId; sessionId = $serviceSessionId
            contract = [pscustomobject][ordered]@{ name = 'csx.screenshot'; major = 1 }
            capture = [pscustomobject][ordered]@{
                source = [pscustomobject][ordered]@{ kind = 'hmd_submission'; fallback = 'reject' }
                destination = [pscustomobject][ordered]@{ overwrite = 'never' }
            }
            counts = [pscustomobject][ordered]@{ requested = 16; scheduled = 16; written = 16; dropped = 0; failed = 0; inFlight = 0 }
            packaging = [pscustomobject][ordered]@{
                frameManifest = [pscustomobject][ordered]@{ requested = $true; state = 'written'; path = [IO.Path]::GetFullPath($manifestPath) }
                previewVideo = [pscustomobject][ordered]@{ requested = $false; required = $false; state = 'not_requested' }
            }
            children = @($manifestChildren)
        }
        Write-CSXJsonFile -Path $manifestPath -Value $manifest | Out-Null
        $manifestHash = Get-CSXFileSha256 $manifestPath
        $terminal = [pscustomobject][ordered]@{
            ok = $true; server = [pscustomobject]@{ sessionId = $serviceSessionId }
            result = [pscustomobject][ordered]@{
                state = 'completed'; kind = 'sequence'; clientId = 'csx-render-scale-qualification'
                commandId = "$RunId-visual-$($replicate.ToString('D2'))-start"; requestId = $requestId
                acceptedUtc = $acceptedUtc.ToString('o'); terminalUtc = $terminalUtc.ToString('o'); warnings = @(); error = $null
                artifactProgress = [pscustomobject][ordered]@{ expected = 1; terminal = 1; successful = 1 }
                effective = $request.sequence
                counts = [pscustomobject][ordered]@{ requested = 16; scheduled = 16; acquired = 16; written = 16; dropped = 0; failed = 0; inFlight = 0 }
                manifest = [pscustomobject][ordered]@{ finalPath = [IO.Path]::GetFullPath($manifestPath) }
                artifacts = @([pscustomobject][ordered]@{
                    path = [IO.Path]::GetFullPath($manifestPath); sha256 = $manifestHash
                    bytes = [uint64](Get-Item -LiteralPath $manifestPath).Length; committed = $true; integrityError = $null
                })
            }
        }
        $terminalPath = Write-CSXJsonFile -Path (Join-Path $replicateDirectory 'sequence.terminal.json') -Value $terminal
        $runs.Add([pscustomobject][ordered]@{
            replicate = $replicate; requestId = $requestId; elapsedMs = 60000.0
            manifestPath = [IO.Path]::GetRelativePath($Root, $manifestPath).Replace('\', '/'); manifestSha256 = $manifestHash
            sequenceRequestPath = [IO.Path]::GetRelativePath($Root, $requestPath).Replace('\', '/'); sequenceRequestSha256 = Get-CSXFileSha256 $requestPath
            terminalReceiptPath = [IO.Path]::GetRelativePath($Root, $terminalPath).Replace('\', '/'); terminalReceiptSha256 = Get-CSXFileSha256 $terminalPath
            childReceiptsPath = [IO.Path]::GetRelativePath($Root, $childrenPath).Replace('\', '/'); childReceiptsSha256 = Get-CSXFileSha256 $childrenPath
        })
    }
    $index = [pscustomobject][ordered]@{ schema = 'csx-render-scale-visual-index-v1'; runId = $RunId; samples = @($samples) }
    $indexPath = Write-CSXJsonFile -Path (Join-Path $Root 'visual-index.json') -Value $index
    $Assays.visual = [pscustomobject][ordered]@{
        state = 'complete'; completedReplicates = 3; wallClockMs = 180000.0; requestedFrames = 48; validatedChildReceipts = 48
        reviewOrdinals = @(1, 8, 16); indexPath = 'visual-index.json'; indexSha256 = Get-CSXFileSha256 $indexPath
        fixtureObservationsPath = 'visual/fixture-observations.json'; fixtureObservationsSha256 = $null
        fixtureObservations = @(); runs = @($runs)
    }
    return [pscustomobject][ordered]@{ index = $index; indexPath = $indexPath }
}

function Write-TestProducerEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$ProtocolSource,
        [Parameter(Mandatory)][string]$FixtureSource
    )
    foreach ($directory in @('binding', 'coc', 'menu', 'visual')) { New-Item -ItemType Directory -Path (Join-Path $Root $directory) -Force | Out-Null }
    Copy-Item -LiteralPath $ProtocolSource -Destination (Join-Path $Root 'protocol.json') -Force
    Copy-Item -LiteralPath $FixtureSource -Destination (Join-Path $Root 'fixture-manifest.json') -Force
    Write-CSXJsonFile -Path (Join-Path $Root 'binding/authoritative-list.json') -Value ([pscustomobject][ordered]@{
        ok = $true; runtimeIdentity = $Raw.runtime.binding
    }) | Out-Null
    Write-CSXJsonFile -Path (Join-Path $Root 'binding/raw-session-identity.json') -Value ([pscustomobject][ordered]@{
        verified = $true; pid = $Raw.runtime.binding.listenerPid; exe = $Raw.runtime.health.exe
        processPath = $Raw.runtime.binding.process.path; processStartTimeUtc = $Raw.runtime.binding.process.startTimeUtc
    }) | Out-Null
    Write-CSXJsonFile -Path (Join-Path $Root 'preflight-retained-diagnostics.json') -Value ([pscustomobject]@{ retained = $true }) | Out-Null

    $allRows = @($Raw.assays.coc.records) + @($Raw.assays.menu.records)
    Write-CSXJsonFile -Path (Join-Path $Root 'transitions.json') -Value ([pscustomobject][ordered]@{ schema = 'csx-render-scale-transitions-v1'; rows = $allRows }) | Out-Null
    Write-TestCsv -Path (Join-Path $Root 'transitions.csv') -Rows $allRows
    $scenarioSources = @{}
    foreach ($assay in @('coc', 'menu')) {
        $rows = @($Raw.assays.$assay.records)
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/transitions.json") -Value ([pscustomobject][ordered]@{
            schema = 'csx-render-scale-transitions-v1'; assay = $assay; rows = $rows
        }) | Out-Null
        Write-TestCsv -Path (Join-Path $Root "$assay/transitions.csv") -Rows $rows
        $request = if ($assay -eq 'coc') {
            New-CSXCocScenario -Protocol $Protocol -GpuVendor NVIDIA -FsrRuntime fsr3 -ExpectedBuildId $Raw.runtime.buildId -RunId $Raw.runId
        }
        else {
            (New-CSXMenuScenario -Protocol $Protocol -GpuVendor NVIDIA -FsrRuntime fsr3 -ExpectedBuildId $Raw.runtime.buildId `
                -ExpectedCellEditorId $Protocol.fixture.startCellEditorId -RunId $Raw.runId).scenario
        }
        $result = New-TestScenarioResult -Request $request -Rows $rows -Assay $assay -BuildId $Raw.runtime.buildId
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/scenario.request.json") -Value $request | Out-Null
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/scenario.result.json") -Value $result | Out-Null
        $stressId = if ($assay -eq 'coc') { [uint64]501 } else { [uint64]502 }
        $cpuId = if ($assay -eq 'coc') { [uint64]701 } else { [uint64]702 }
        $stress = New-TestStressRecord -Rows $rows -SessionId $stressId -SchemaVersion ([int]$Protocol.thresholds.stressRecordSchemaVersion)
        $cpu = [pscustomobject][ordered]@{
            schemaVersion = 1; sessionId = $cpuId; active = $false; state = 'stopped'
            window = [pscustomobject][ordered]@{ initialized = $true; startFrame = 1; endFrame = 10 }
        }
        $stressResponse = [pscustomobject][ordered]@{
            action = 'stop'; status = [pscustomobject][ordered]@{ session = [pscustomobject][ordered]@{ id = $stressId; active = $false } }
            record = $stress; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
        }
        $cpuResponse = [pscustomobject][ordered]@{
            action = 'cpu_performance_stop'; cpuPerformance = $cpu; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
        }
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/stress-record.json") -Value $stress | Out-Null
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/cpu-record.json") -Value $cpu | Out-Null
        Write-CSXJsonFile -Path (Join-Path $Root "$assay/diagnostics.json") -Value ([pscustomobject][ordered]@{ stress = $stressResponse; cpu = $cpuResponse }) | Out-Null
        $evidence = [ordered]@{
            scenarioRequest = "$assay/scenario.request.json"; scenarioResult = "$assay/scenario.result.json"
            diagnostics = "$assay/diagnostics.json"; stressRecord = "$assay/stress-record.json"; cpuRecord = "$assay/cpu-record.json"
        }
        if ($assay -eq 'menu') {
            $evidence['dlssTraces'] = 'menu/dlss-traces.json'
            Write-CSXJsonFile -Path (Join-Path $Root 'menu/dlss-traces.json') -Value ([pscustomobject][ordered]@{
                readLimit = [int]$Protocol.menuAssay.traceReadLimit
                detail = 'bounded_partial_raw_records_with_authoritative_summary_and_pinned_failures'
                evidence = $Raw.assays.menu.dlssTrace.evidence
            }) | Out-Null
        }
        $Raw.assays.$assay | Add-Member -NotePropertyName evidence -NotePropertyValue ([pscustomobject]$evidence) -Force
        $Raw.assays.$assay | Add-Member -NotePropertyName wallClockMs -NotePropertyValue 1000.0 -Force
        $scenarioSources[$assay] = [pscustomobject][ordered]@{
            request = $request; result = $result; diagnostics = [pscustomobject][ordered]@{ stress = $stressResponse; cpu = $cpuResponse }
        }
    }

    $recoveries = [Collections.Generic.List[object]]::new()
    foreach ($number in 1..2) {
        $label = if ($number -eq 1) { 'one' } else { 'two' }
        $recovery = New-TestRecoveryRecord -Protocol $Protocol -BuildId $Raw.runtime.buildId -RunId $Raw.runId -FsrRuntime fsr3 -Label $label
        Write-CSXJsonFile -Path (Join-Path $Root "recovery-$number.json") -Value $recovery | Out-Null
        $recoveries.Add($recovery)
    }
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($label in @('visual-before-1', 'visual-after-1', 'visual-after-2', 'visual-after-3')) {
        $observation = New-TestRecoveryRecord -Protocol $Protocol -BuildId $Raw.runtime.buildId -RunId $Raw.runId -FsrRuntime fsr3 -Label $label -NoWait
        $observations.Add([pscustomobject][ordered]@{ label = $label; request = $observation.request; result = $observation.result; evidence = $observation.evidence })
    }
    $observationPath = Write-CSXJsonFile -Path (Join-Path $Root 'visual/fixture-observations.json') -Value ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-visual-fixture-observations-v1'; runId = $Raw.runId; observations = @($observations)
    })
    $Raw.assays.visual.fixtureObservationsSha256 = Get-CSXFileSha256 $observationPath
    $Raw.assays.visual.fixtureObservations = @($observations | ForEach-Object { [pscustomobject][ordered]@{ label = $_.label; ok = [bool]$_.result.ok } })

    $visualStressId = [uint64]503
    $visualCpuId = [uint64]703
    $visualStressRecord = New-TestStressRecord -Rows @() -SessionId $visualStressId -SchemaVersion ([int]$Protocol.thresholds.stressRecordSchemaVersion)
    $visualCpuRecord = [pscustomobject][ordered]@{
        schemaVersion = 1; sessionId = $visualCpuId; active = $false; state = 'stopped'
        window = [pscustomobject][ordered]@{ initialized = $true; startFrame = [uint64]100; endFrame = [uint64]1000 }
    }
    $visualStressResponse = [pscustomobject][ordered]@{
        action = 'stop'
        status = [pscustomobject][ordered]@{
            session = [pscustomobject][ordered]@{ id = $visualStressId; active = $false }
            lastRecord = $visualStressRecord
        }
        producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
    }
    $visualCpuResponse = [pscustomobject][ordered]@{
        action = 'cpu_performance_stop'
        cpuPerformance = [pscustomobject][ordered]@{
            sessionId = $visualCpuId; active = $false; state = 'stopped'; lastRecord = $visualCpuRecord
        }
        producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
    }
    Write-CSXJsonFile -Path (Join-Path $Root 'visual/stress-record.json') -Value $visualStressRecord | Out-Null
    Write-CSXJsonFile -Path (Join-Path $Root 'visual/cpu-record.json') -Value $visualCpuRecord | Out-Null
    Write-CSXJsonFile -Path (Join-Path $Root 'visual/diagnostics.json') -Value ([pscustomobject][ordered]@{
        stress = $visualStressResponse; cpu = $visualCpuResponse
    }) | Out-Null
    $Raw.assays.visual | Add-Member -NotePropertyName evidence -NotePropertyValue ([pscustomobject][ordered]@{
        diagnostics = 'visual/diagnostics.json'; stressRecord = 'visual/stress-record.json'; cpuRecord = 'visual/cpu-record.json'
    }) -Force

    $transcript = [Collections.Generic.List[object]]::new()
    Add-TestTranscriptRow -Rows $transcript -Tool inspect -Arguments ([ordered]@{ kind = 'health' }) -Response $Raw.runtime.health
    foreach ($assay in @('coc', 'menu')) {
        $request = $scenarioSources[$assay].request
        $result = $scenarioSources[$assay].result
        $diagnostics = $scenarioSources[$assay].diagnostics
        $stressId = Get-CSXPathValue $diagnostics 'stress.status.session.id'
        $cpuId = Get-CSXPathValue $diagnostics 'cpu.cpuPerformance.sessionId'
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'reset'; expectedBuildId = $Raw.runtime.buildId }) `
            -Response ([pscustomobject][ordered]@{ action = 'reset'; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId } })
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'cpu_performance_reset'; expectedBuildId = $Raw.runtime.buildId }) `
            -Response ([pscustomobject][ordered]@{ action = 'cpu_performance_reset'; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId } })
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'start'; expectedBuildId = $Raw.runtime.buildId }) `
            -Response ([pscustomobject][ordered]@{
                action = 'start'; status = [pscustomobject]@{ session = [pscustomobject]@{ id = $stressId; active = $true } }
                producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
            })
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'cpu_performance_start'; expectedBuildId = $Raw.runtime.buildId }) `
            -Response ([pscustomobject][ordered]@{
                action = 'cpu_performance_start'; cpuPerformance = [pscustomobject]@{ sessionId = $cpuId; active = $true }
                producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
            })
        for ($index = 0; $index -lt @($request.steps).Count; $index++) {
            $step = $request.steps[$index]
            $arguments = $step.args | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -AsHashtable
            $response = $result.results[$index].result
            if ([string](Get-CSXPropertyValue $arguments 'action') -eq 'dlss_trace_stop') {
                $arguments['expectedSessionId'] = Get-CSXPathValue $response 'capture.sessionID'
            }
            Add-TestTranscriptRow -Rows $transcript -Tool ([string]$step.tool) -Arguments $arguments -Response $response
        }
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'cpu_performance_stop'; expectedSessionId = $cpuId; expectedBuildId = $Raw.runtime.buildId }) -Response $diagnostics.cpu
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
            -Arguments ([ordered]@{ action = 'stop'; expectedSessionId = $stressId; expectedBuildId = $Raw.runtime.buildId }) -Response $diagnostics.stress
        $recoveryIndex = if ($assay -eq 'coc') { 0 } else { 1 }
        Add-TestTranscriptRow -Rows $transcript -Tool scenario -Arguments $recoveries[$recoveryIndex].request -Response $recoveries[$recoveryIndex].result
    }
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'reset'; expectedBuildId = $Raw.runtime.buildId }) `
        -Response ([pscustomobject][ordered]@{ action = 'reset'; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId } })
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'cpu_performance_reset'; expectedBuildId = $Raw.runtime.buildId }) `
        -Response ([pscustomobject][ordered]@{ action = 'cpu_performance_reset'; producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId } })
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'start'; expectedBuildId = $Raw.runtime.buildId }) `
        -Response ([pscustomobject][ordered]@{
            action = 'start'; status = [pscustomobject]@{ session = [pscustomobject]@{ id = $visualStressId; active = $true } }
            producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
        })
    $transcript[-1].startedUtc = '2026-08-26T11:59:58.0000000+00:00'; $transcript[-1].completedUtc = '2026-08-26T11:59:58.1000000+00:00'
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'cpu_performance_start'; expectedBuildId = $Raw.runtime.buildId }) `
        -Response ([pscustomobject][ordered]@{
            action = 'cpu_performance_start'; cpuPerformance = [pscustomobject]@{ sessionId = $visualCpuId; active = $true }
            producer = [pscustomobject]@{ buildId = $Raw.runtime.buildId }
        })
    $transcript[-1].startedUtc = '2026-08-26T11:59:58.1000000+00:00'; $transcript[-1].completedUtc = '2026-08-26T11:59:58.2000000+00:00'
    Add-TestTranscriptRow -Rows $transcript -Tool scenario -Arguments $observations[0].request -Response $observations[0].result
    foreach ($run in @($Raw.assays.visual.runs)) {
        $request = Get-Content -LiteralPath (Join-Path $Root $run.sequenceRequestPath) -Raw | ConvertFrom-Json -Depth 100
        $terminal = Get-Content -LiteralPath (Join-Path $Root $run.terminalReceiptPath) -Raw | ConvertFrom-Json -Depth 100
        $start = [pscustomobject][ordered]@{
            ok = $true; error = $null; server = [pscustomobject]@{ sessionId = [string]$terminal.server.sessionId }
            result = [pscustomobject][ordered]@{
                state = 'running'; kind = 'sequence'; requestId = [string]$terminal.result.requestId
                clientId = 'csx-render-scale-qualification'; commandId = [string]$terminal.result.commandId
                acceptedUtc = [string]$terminal.result.acceptedUtc; effective = $request.sequence
            }
        }
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.screenshot' -Arguments $request -Response $start
        Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.screenshot' `
            -Arguments ([ordered]@{
                contractMajor = 1; clientId = 'csx-render-scale-qualification'
                commandId = "$($Raw.runId)-visual-$(([int]$run.replicate).ToString('D2'))-poll-$('a' * 32)"
                action = 'request_get'; requestId = [string]$terminal.result.requestId
            }) -Response $terminal
        $observationIndex = [int]$run.replicate
        Add-TestTranscriptRow -Rows $transcript -Tool scenario -Arguments $observations[$observationIndex].request -Response $observations[$observationIndex].result
    }
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'cpu_performance_stop'; expectedSessionId = $visualCpuId; expectedBuildId = $Raw.runtime.buildId }) `
        -Response $visualCpuResponse
    $transcript[-1].startedUtc = '2026-08-26T12:03:01.0000000+00:00'; $transcript[-1].completedUtc = '2026-08-26T12:03:01.1000000+00:00'
    Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.renderscale' `
        -Arguments ([ordered]@{ action = 'stop'; expectedSessionId = $visualStressId; expectedBuildId = $Raw.runtime.buildId }) `
        -Response $visualStressResponse
    $transcript[-1].startedUtc = '2026-08-26T12:03:01.1000000+00:00'; $transcript[-1].completedUtc = '2026-08-26T12:03:01.2000000+00:00'
    foreach ($run in @($Raw.assays.visual.runs)) {
        $children = @(Get-Content -LiteralPath (Join-Path $Root $run.childReceiptsPath) -Raw | ConvertFrom-Json -Depth 100)
        foreach ($child in $children) {
            Add-TestTranscriptRow -Rows $transcript -Tool 'communityshaders.screenshot' `
                -Arguments ([ordered]@{
                    contractMajor = 1; clientId = 'csx-render-scale-qualification'
                    commandId = "$($Raw.runId)-visual-$($run.replicate)-child-$($child.ordinal)"
                    action = 'request_get'; requestId = [string]$child.receipt.result.requestId
                }) -Response $child.receipt
        }
    }
    Write-CSXJsonFile -Path (Join-Path $Root 'mcp-transcript.json') -Value @($transcript) | Out-Null
}

function Write-TestAutomatedVisualReviewEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)]$VisualIndex,
        $BaselineVisualIndex = $null
    )
    $reviewRoot = Join-Path $Root 'visual-review'
    New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
    $promptSource = Join-Path $PSScriptRoot ([string]$Protocol.visualAssay.evaluation.promptFile)
    $schemaSource = Join-Path $PSScriptRoot ([string]$Protocol.visualAssay.evaluation.outputSchemaFile)
    $promptPath = Join-Path $reviewRoot 'prompt.v1.md'
    $schemaPath = Join-Path $reviewRoot 'output-schema.v1.json'
    Copy-Item -LiteralPath $promptSource -Destination $promptPath -Force
    Copy-Item -LiteralPath $schemaSource -Destination $schemaPath -Force
    $promptSourceSha256 = Get-CSXFileSha256 $promptPath
    $outputSchemaSourceSha256 = Get-CSXFileSha256 $schemaPath
    Assert-Test ($promptSourceSha256 -eq [string]$Protocol.visualAssay.evaluation.promptSha256) `
        'Synthetic visual-review prompt does not match the protocol pin.'
    Assert-Test ($outputSchemaSourceSha256 -eq [string]$Protocol.visualAssay.evaluation.outputSchemaSha256) `
        'Synthetic visual-review output schema does not match the protocol pin.'

    $versionText = 'codex-cli 0.0-test'
    $codexVersionSha256 = Get-TestTextSha256 $versionText
    $codexRootHelpSha256 = Get-TestTextSha256 '--ask-for-approval'
    $codexExecHelpSha256 = Get-TestTextSha256 '--ephemeral --ignore-user-config --skip-git-repo-check --sandbox --json --output-schema --output-last-message --image --model'
    $features = [ordered]@{ '--ask-for-approval' = $true }
    foreach ($feature in @('--ephemeral', '--ignore-user-config', '--skip-git-repo-check', '--sandbox', '--json', '--output-schema', '--output-last-message', '--image', '--model')) {
        $features[$feature] = $true
    }
    $preflight = [pscustomobject][ordered]@{
        schema = 'csx-codex-visual-review-preflight-v1'; ok = $true; executablePath = 'C:\Tools\codex.exe'
        version = '0.0-test'; versionText = $versionText; versionSha256 = $codexVersionSha256
        rootHelpSha256 = $codexRootHelpSha256; execHelpSha256 = $codexExecHelpSha256
        features = [pscustomobject]$features; missingFeatures = @(); errors = @()
    }
    $preflightRelative = 'visual-review/preflight.json'
    $preflightFull = Write-CSXJsonFile -Path (Join-Path $Root $preflightRelative) -Value $preflight
    $preflightSha256 = Get-CSXFileSha256 $preflightFull
    $promptSourceText = [IO.File]::ReadAllText($promptPath, [Text.Encoding]::UTF8)
    $mode = if ([bool]$Raw.prMode) { 'pr_baseline' } else { 'standalone' }
    $categories = @('sharpness', 'blur', 'shimmer', 'stereoAlignment', 'equalEyeScale', 'geometryCorrespondence')
    $rawBatches = [Collections.Generic.List[object]]::new()
    $executionBatches = [Collections.Generic.List[object]]::new()
    $aliasRoot = Join-Path $reviewRoot ".aliases-$('a' * 32)"

    foreach ($presentationPass in 1..2) {
        foreach ($replicate in 1..3) {
            $batchRelative = "visual-review/pass-$($presentationPass.ToString('D2'))/rep-$($replicate.ToString('D2'))"
            $batchRoot = Join-Path $Root $batchRelative
            New-Item -ItemType Directory -Path $batchRoot -Force | Out-Null
            $requestRelative = "$batchRelative/request.json"
            $responseRelative = "$batchRelative/response.json"
            $eventsRelative = "$batchRelative/events.jsonl"
            $stderrRelative = "$batchRelative/stderr.json"
            $receiptRelative = "$batchRelative/receipt.json"
            $candidatePosition = if (-not [bool]$Raw.prMode) { 'only' } elseif ($presentationPass -eq 1) { 'first' } else { 'second' }
            $attachmentSource = [Collections.Generic.List[object]]::new()

            foreach ($ordinal in @(1, 8, 16)) {
                $candidate = @($VisualIndex.samples | Where-Object {
                    [int]$_.replicate -eq $replicate -and [int]$_.ordinal -eq $ordinal
                })
                Assert-Test ($candidate.Count -eq 1) "Synthetic candidate visual sample $replicate/$ordinal is missing or duplicated."
                if ([bool]$Raw.prMode) {
                    $baseline = @($BaselineVisualIndex.samples | Where-Object {
                        [int]$_.replicate -eq $replicate -and [int]$_.ordinal -eq $ordinal
                    })
                    Assert-Test ($baseline.Count -eq 1) "Synthetic baseline visual sample $replicate/$ordinal is missing or duplicated."
                    $sets = if ($presentationPass -eq 1) {
                        @(
                            [pscustomobject]@{ neutralSet = 'first'; sourceRole = 'candidate'; sample = $candidate[0] },
                            [pscustomobject]@{ neutralSet = 'second'; sourceRole = 'baseline'; sample = $baseline[0] }
                        )
                    }
                    else {
                        @(
                            [pscustomobject]@{ neutralSet = 'first'; sourceRole = 'baseline'; sample = $baseline[0] },
                            [pscustomobject]@{ neutralSet = 'second'; sourceRole = 'candidate'; sample = $candidate[0] }
                        )
                    }
                }
                else {
                    $sets = @([pscustomobject]@{ neutralSet = 'only'; sourceRole = 'candidate'; sample = $candidate[0] })
                }
                foreach ($set in $sets) {
                    foreach ($view in @('left_eye', 'right_eye', 'side_by_side')) {
                        $artifact = @($set.sample.artifacts | Where-Object { [string]$_.view -eq $view })
                        Assert-Test ($artifact.Count -eq 1) "Synthetic $($set.sourceRole) artifact $replicate/$ordinal/$view is missing or duplicated."
                        $sourcePath = if ($set.sourceRole -eq 'baseline') { "baseline/$([string]$artifact[0].path)" } else { [string]$artifact[0].path }
                        $sourceFull = Join-Path $Root $sourcePath
                        $attachmentSource.Add([pscustomobject][ordered]@{
                            neutralSet = [string]$set.neutralSet; sourceRole = [string]$set.sourceRole; sourcePath = $sourcePath
                            ordinal = $ordinal; view = $view; width = [uint32]$artifact[0].width; height = [uint32]$artifact[0].height
                            byteLength = [uint64](Get-Item -LiteralPath $sourceFull).Length; sha256 = [string]$artifact[0].sha256
                        })
                    }
                }
            }
            if (-not [bool]$Raw.prMode -and $presentationPass -eq 2) {
                $reversedAttachments = @($attachmentSource)
                [array]::Reverse($reversedAttachments)
                $attachmentSource = [Collections.Generic.List[object]]::new()
                foreach ($item in $reversedAttachments) { $attachmentSource.Add($item) }
            }
            $attachmentOrder = [Collections.Generic.List[object]]::new()
            $receiptBindings = [Collections.Generic.List[object]]::new()
            $providerBindings = [Collections.Generic.List[object]]::new()
            for ($attachmentOffset = 0; $attachmentOffset -lt $attachmentSource.Count; $attachmentOffset++) {
                $item = $attachmentSource[$attachmentOffset]
                $attachmentIndex = $attachmentOffset + 1
                $aliasName = "$([string]$item.neutralSet)/ordinal-$(([int]$item.ordinal).ToString('D2'))-$([string]$item.view).png"
                $aliasPath = Join-Path (Join-Path $aliasRoot "pass-$($presentationPass.ToString('D2'))-rep-$($replicate.ToString('D2'))") $aliasName
                $attachmentOrder.Add([pscustomobject][ordered]@{
                    attachmentIndex = $attachmentIndex; neutralSet = [string]$item.neutralSet; ordinal = [int]$item.ordinal
                    view = [string]$item.view; width = [uint32]$item.width; height = [uint32]$item.height
                    byteLength = [uint64]$item.byteLength; sha256 = [string]$item.sha256; aliasName = $aliasName
                })
                $receiptBindings.Add([pscustomobject][ordered]@{
                    attachmentIndex = $attachmentIndex; neutralSet = [string]$item.neutralSet; sourceRole = [string]$item.sourceRole
                    sourcePath = [string]$item.sourcePath; aliasPath = $aliasPath; byteLength = [uint64]$item.byteLength; sha256 = [string]$item.sha256
                })
                $providerBindings.Add([pscustomobject][ordered]@{
                    path = $aliasPath; byteLength = [uint64]$item.byteLength; sha256 = [string]$item.sha256
                })
            }

            $requestBody = [pscustomobject][ordered]@{
                runId = [string]$Raw.runId; replicate = $replicate; presentationPass = $presentationPass; mode = $mode
                sampleOrdinals = @(1, 8, 16); attachmentOrder = @($attachmentOrder)
            }
            $requestSha256 = Get-TestObjectSha256 $requestBody
            $requestArtifact = [pscustomobject][ordered]@{
                schema = 'csx-render-scale-image-model-request-v1'; requestSha256 = $requestSha256; body = $requestBody
            }
            $requestFull = Write-CSXJsonFile -Path (Join-Path $Root $requestRelative) -Value $requestArtifact
            $requestFileSha256 = Get-CSXFileSha256 $requestFull
            $effectivePromptText = New-CSXAutomatedVisualPromptText -PromptSourceText $promptSourceText -RequestArtifact $requestArtifact
            $promptEffectiveSha256 = Get-TestTextSha256 $effectivePromptText

            $sampleResponses = [Collections.Generic.List[object]]::new()
            $categoryVerdict = if (-not [bool]$Raw.prMode) { 'pass' } elseif ($presentationPass -eq 1) { 'first_better' } else { 'second_better' }
            foreach ($ordinal in @(1, 8, 16)) {
                $ratings = [ordered]@{}
                foreach ($category in $categories) {
                    $ratings[$category] = [pscustomobject][ordered]@{
                        verdict = $categoryVerdict; confidence = 'high'
                        observation = "Synthetic all-pass $category observation for checkpoint $ordinal."
                        evidenceViews = @('left_eye', 'right_eye', 'side_by_side')
                    }
                }
                $sampleResponses.Add([pscustomobject][ordered]@{ ordinal = $ordinal; categories = [pscustomobject]$ratings })
            }
            $response = [pscustomobject][ordered]@{
                schema = 'csx-render-scale-image-model-response-v1'; provider = 'codex_cli'; model = 'gpt-5.6-sol'
                promptRevision = 1; runId = [string]$Raw.runId; requestSha256 = $requestSha256
                replicate = $replicate; presentationPass = $presentationPass; mode = $mode
                samples = @($sampleResponses); overallVerdict = 'pass'
            }
            $responseFull = Write-CSXJsonFile -Path (Join-Path $Root $responseRelative) -Value $response
            $responseSha256 = Get-CSXFileSha256 $responseFull
            $responseText = [IO.File]::ReadAllText($responseFull, [Text.Encoding]::UTF8)
            $event = [pscustomobject][ordered]@{
                type = 'item.completed'; item = [pscustomobject][ordered]@{ type = 'agent_message'; text = $responseText }
            }
            $eventsText = ($event | ConvertTo-Json -Depth 100 -Compress) + "`n"
            $eventsFull = Join-Path $Root $eventsRelative
            [IO.File]::WriteAllText($eventsFull, $eventsText, [Text.UTF8Encoding]::new($false))
            $eventsSha256 = Get-CSXFileSha256 $eventsFull
            $stderrFull = Write-CSXJsonFile -Path (Join-Path $Root $stderrRelative) -Value ([pscustomobject][ordered]@{
                schema = 'csx-codex-visual-review-stderr-v1'; text = ''
            })
            $stderrSha256 = Get-CSXFileSha256 $stderrFull
            $started = [DateTimeOffset]::Parse('2026-08-26T12:03:10Z').AddMilliseconds(($presentationPass - 1) * 1000 + ($replicate - 1) * 50)
            $completed = $started.AddMilliseconds(500)
            $execution = [pscustomobject][ordered]@{
                ok = $true; status = 'completed'; exitCode = 0; timedOut = $false
                startedUtc = $started.ToString('o'); completedUtc = $completed.ToString('o'); durationMs = 500.0
            }
            $receipt = [pscustomobject][ordered]@{
                schema = 'csx-render-scale-image-model-receipt-v1'; runId = [string]$Raw.runId
                replicate = $replicate; presentationPass = $presentationPass; mode = $mode; provider = 'codex_cli'; model = 'gpt-5.6-sol'
                candidatePosition = $candidatePosition; requestPath = $requestRelative; requestSha256 = $requestSha256
                responsePath = $responseRelative; responseSha256 = $responseSha256; eventsPath = $eventsRelative; eventsSha256 = $eventsSha256
                promptRevision = 1; promptSourceSha256 = $promptSourceSha256; promptEffectiveSha256 = $promptEffectiveSha256
                outputSchemaSourceSha256 = $outputSchemaSourceSha256; codexVersion = '0.0-test'; codexVersionSha256 = $codexVersionSha256
                codexRootHelpSha256 = $codexRootHelpSha256; codexExecHelpSha256 = $codexExecHelpSha256
                imageBindings = @($receiptBindings); execution = $execution; errors = @()
            }
            $receiptFull = Write-CSXJsonFile -Path (Join-Path $Root $receiptRelative) -Value $receipt
            $receiptSha256 = Get-CSXFileSha256 $receiptFull
            $rawBatches.Add([pscustomobject][ordered]@{
                replicate = $replicate; presentationPass = $presentationPass
                requestPath = $requestRelative; requestFileSha256 = $requestFileSha256; requestSha256 = $requestSha256
                responsePath = $responseRelative; responseSha256 = $responseSha256
                eventsPath = $eventsRelative; eventsSha256 = $eventsSha256; stderrPath = $stderrRelative; stderrSha256 = $stderrSha256
                receiptPath = $receiptRelative; receiptSha256 = $receiptSha256
            })
            $executionBatches.Add([pscustomobject][ordered]@{
                presentationPass = $presentationPass; replicate = $replicate; ok = $true; status = 'completed'; processId = 4200 + $presentationPass * 10 + $replicate
                exitCode = 0; timedOut = $false; startedUtc = $started.ToString('o'); completedUtc = $completed.ToString('o'); durationMs = 500.0
                promptSha256 = $promptEffectiveSha256; imageBindings = @($providerBindings); outputSchemaPath = [IO.Path]::GetFullPath($schemaPath)
                responsePath = [IO.Path]::GetFullPath($responseFull); eventsPath = [IO.Path]::GetFullPath($eventsFull)
                stdout = $eventsText; stdoutJsonl = @($event); stderr = ''; response = $response; responseText = $responseText
                responseSha256 = $responseSha256; eventsSha256 = $eventsSha256; errors = @()
            })
        }
    }
    $executionRecord = [pscustomobject][ordered]@{
        schema = 'csx-codex-visual-review-execution-v1'; ok = $true; provider = 'codex_cli'; model = 'gpt-5.6-sol'
        preflight = $preflight; deadlineSeconds = 90; deadlineReached = $false
        startedUtc = '2026-08-26T12:03:10.0000000+00:00'; completedUtc = '2026-08-26T12:03:12.0000000+00:00'; durationMs = 2000.0
        batches = @($executionBatches); errors = @()
    }
    $executionRelative = 'visual-review/execution.json'
    $executionFull = Write-CSXJsonFile -Path (Join-Path $Root $executionRelative) -Value $executionRecord
    $Raw.assays.visual | Add-Member -NotePropertyName automatedReview -NotePropertyValue ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-automated-review-v1'; provider = 'codex_cli'; model = 'gpt-5.6-sol'; promptRevision = 1
        promptPath = 'visual-review/prompt.v1.md'; promptSourceSha256 = $promptSourceSha256
        outputSchemaPath = 'visual-review/output-schema.v1.json'; outputSchemaSourceSha256 = $outputSchemaSourceSha256
        preflightPath = $preflightRelative; preflightSha256 = $preflightSha256
        executionPath = $executionRelative; executionSha256 = Get-CSXFileSha256 $executionFull
        deadlineSeconds = 90; durationMs = 2000.0; batches = @($rawBatches)
    }) -Force
}

function Set-TestArtifactInventory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Raw)
    $excluded = @(
        '.csx-render-scale-qualification.lock', 'automation-artifacts.json', 'run.raw.json', 'run.json',
        'visual-review.json', 'failures.json', 'pr-summary.md', 'qualification-summary.md'
    )
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        if ($relative.StartsWith('baseline/', [StringComparison]::OrdinalIgnoreCase) -or $relative -in $excluded) { continue }
        $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
        if ($extension -notin @('.json', '.jsonl', '.csv', '.png', '.md')) { continue }
        $entries.Add([pscustomobject][ordered]@{
            path = $relative; kind = $extension.Substring(1); byteLength = [uint64]$file.Length; sha256 = Get-CSXFileSha256 $file.FullName
        })
    }
    $inventory = [pscustomobject][ordered]@{
        schema = 'csx-render-scale-automation-artifacts-v1'; runId = $Raw.runId
        candidateBuildId = $Raw.runtime.buildId; protocolSha256 = $Raw.protocol.sha256; entries = @($entries)
    }
    $path = Write-CSXJsonFile -Path (Join-Path $Root 'automation-artifacts.json') -Value $inventory
    $binding = [pscustomobject][ordered]@{
        schema = $inventory.schema; path = 'automation-artifacts.json'; sha256 = Get-CSXFileSha256 $path; entryCount = @($entries).Count
    }
    $Raw | Add-Member -NotePropertyName artifactInventory -NotePropertyValue $binding -Force
    return $binding
}

function Bind-TestRawToExistingInventory([string]$Root, $Raw) {
    $path = Join-Path $Root 'automation-artifacts.json'
    $inventory = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
    $Raw.artifactInventory = [pscustomobject][ordered]@{
        schema = 'csx-render-scale-automation-artifacts-v1'; path = 'automation-artifacts.json'
        sha256 = Get-CSXFileSha256 $path; entryCount = @($inventory.entries).Count
    }
}

function New-TestEvidenceEnvelope {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)]$ProtocolRecord,
        [Parameter(Mandatory)]$FixtureIdentity,
        [Parameter(Mandatory)][string]$ProtocolSource,
        [Parameter(Mandatory)][string]$FixtureSource,
        $Baseline = $null
    )
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $assays = New-TestCoreAssays -Protocol $ProtocolRecord.protocol -RunId $RunId -BuildId $BuildId -VisualIndexSha256 ('0' * 64)
    $visual = Write-TestVisualEvidence -Root $Root -Protocol $ProtocolRecord.protocol -RunId $RunId -Assays $assays
    $raw = [pscustomobject][ordered]@{
        schema = $(if ($null -eq $Baseline) { 'csx-render-scale-local-v1-raw' } else { 'csx-render-scale-pr-v1-raw' })
        runId = $RunId; createdUtc = '2026-08-26T12:10:00Z'; prMode = [bool]($null -ne $Baseline)
        protocol = [pscustomobject][ordered]@{
            schema = 'csx-render-scale-pr-v1'; revision = [int]$ProtocolRecord.protocol.protocolRevision; sha256 = $ProtocolRecord.sha256
            requiredMethodsCommit = 'b46edeaed14c41ad41225641c3a4943f1db25db6'
        }
        fixture = Copy-TestObject $FixtureIdentity
        runtime = New-TestRuntimeEvidence $BuildId
        time = [pscustomobject][ordered]@{
            deadlineStartsAfterRuntimeBinding = $true; captureAssaysElapsedMs = 450000.0; visualEvaluationElapsedMs = 50000.0
            orchestrationElapsedMs = 500000.0; performanceElapsedMs = 450000.0; within600Seconds = $true
        }
        assays = $assays; recoveries = New-TestRecoveries; baseline = $Baseline
        artifactInventory = $null
        automatedGates = [pscustomobject][ordered]@{ passed = $true; failures = @(); infrastructureErrors = @() }
        warnings = @()
    }
    Write-TestProducerEvidence -Root $Root -Raw $raw -Protocol $ProtocolRecord.protocol -ProtocolSource $ProtocolSource -FixtureSource $FixtureSource
    $baselineIndex = if ($null -ne $Baseline) {
        Get-Content -LiteralPath (Join-Path $Root $Baseline.visualIndexPath) -Raw | ConvertFrom-Json -Depth 100
    }
    else { $null }
    Write-TestAutomatedVisualReviewEvidence -Root $Root -Raw $raw -Protocol $ProtocolRecord.protocol `
        -VisualIndex $visual.index -BaselineVisualIndex $baselineIndex
    Set-TestArtifactInventory -Root $Root -Raw $raw | Out-Null
    Write-CSXJsonFile -Path (Join-Path $Root 'run.raw.json') -Value $raw | Out-Null
    $review = New-CSXAutomatedVisualReview -EvidenceDirectory $Root -RunRaw $raw -VisualIndex $visual.index -BaselineVisualIndex $baselineIndex
    Write-CSXJsonFile -Path (Join-Path $Root 'visual-review.json') -Value $review | Out-Null
    $final = Update-CSXQualificationReport -EvidenceDirectory $Root
    return [pscustomobject][ordered]@{ raw = $raw; review = $review; index = $visual.index; final = $final }
}

function Assert-EvidenceTamperRejected {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CaseRoot,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [ValidateSet('none', 'existing', 'regenerate')][string]$InventoryMode = 'none',
        [Parameter(Mandatory)][string]$ErrorPattern,
        [Parameter(Mandatory)][string]$Message
    )
    Copy-Item -LiteralPath $SourceRoot -Destination $CaseRoot -Recurse
    try {
        $raw = Get-Content -LiteralPath (Join-Path $CaseRoot 'run.raw.json') -Raw | ConvertFrom-Json -Depth 100
        & $Mutation $CaseRoot $raw
        if ($InventoryMode -eq 'existing') { Bind-TestRawToExistingInventory -Root $CaseRoot -Raw $raw }
        elseif ($InventoryMode -eq 'regenerate') { Set-TestArtifactInventory -Root $CaseRoot -Raw $raw | Out-Null }
        Write-CSXJsonFile -Path (Join-Path $CaseRoot 'run.raw.json') -Value $raw | Out-Null
        $review = Get-Content -LiteralPath (Join-Path $CaseRoot 'visual-review.json') -Raw | ConvertFrom-Json -Depth 100
        $review.runRawSha256 = Get-CSXFileSha256 (Join-Path $CaseRoot 'run.raw.json')
        $review.baselineRunSha256 = $(if ([bool]$raw.prMode) { [string]$raw.baseline.runSha256 } else { $null })
        Write-CSXJsonFile -Path (Join-Path $CaseRoot 'visual-review.json') -Value $review | Out-Null
        $result = Update-CSXQualificationReport -EvidenceDirectory $CaseRoot
        Assert-Test ($result.report.status -notin @('PASS', 'LOCAL_PASS') -and
            ($result.report.errors -join ' | ') -match $ErrorPattern) $Message
    }
    finally {
        if (Test-Path -LiteralPath $CaseRoot) { Remove-Item -LiteralPath $CaseRoot -Recurse -Force }
    }
}

function Update-TestAutomatedResponseEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)][ValidateRange(0, 5)][int]$BatchOffset,
        [Parameter(Mandatory)][scriptblock]$Mutation
    )
    $automated = $Raw.assays.visual.automatedReview
    $batch = $automated.batches[$BatchOffset]
    $responsePath = Join-Path $Root $batch.responsePath
    $response = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json -Depth 100
    & $Mutation $response
    Write-CSXJsonFile -Path $responsePath -Value $response | Out-Null
    $responseSha256 = Get-CSXFileSha256 $responsePath
    $responseText = [IO.File]::ReadAllText($responsePath, [Text.Encoding]::UTF8)
    $batch.responseSha256 = $responseSha256

    $eventsPath = Join-Path $Root $batch.eventsPath
    $eventObjects = @(([IO.File]::ReadAllText($eventsPath, [Text.Encoding]::UTF8) -split '\r?\n') |
        Where-Object { $_ -match '\S' } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
    $agentMessages = @($eventObjects | Where-Object { [string]$_.type -eq 'item.completed' -and [string]$_.item.type -eq 'agent_message' })
    Assert-Test ($agentMessages.Count -gt 0) 'Synthetic provider events do not contain an attributable agent response.'
    $agentMessages[-1].item.text = $responseText
    $eventsText = (@($eventObjects | ForEach-Object { $_ | ConvertTo-Json -Depth 100 -Compress }) -join "`n") + "`n"
    [IO.File]::WriteAllText($eventsPath, $eventsText, [Text.UTF8Encoding]::new($false))
    $eventsSha256 = Get-CSXFileSha256 $eventsPath
    $batch.eventsSha256 = $eventsSha256

    $receiptPath = Join-Path $Root $batch.receiptPath
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 100
    $receipt.responseSha256 = $responseSha256
    $receipt.eventsSha256 = $eventsSha256
    Write-CSXJsonFile -Path $receiptPath -Value $receipt | Out-Null
    $batch.receiptSha256 = Get-CSXFileSha256 $receiptPath

    $executionPath = Join-Path $Root $automated.executionPath
    $execution = Get-Content -LiteralPath $executionPath -Raw | ConvertFrom-Json -Depth 100
    $providerBatch = $execution.batches[$BatchOffset]
    $providerBatch.response = $response
    $providerBatch.responseText = $responseText
    $providerBatch.responseSha256 = $responseSha256
    $providerBatch.stdout = $eventsText
    $providerBatch.stdoutJsonl = @($eventObjects)
    $providerBatch.eventsSha256 = $eventsSha256
    Write-CSXJsonFile -Path $executionPath -Value $execution | Out-Null
    $automated.executionSha256 = Get-CSXFileSha256 $executionPath
}

function Assert-AutomatedVisualEvidenceRejects {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CaseRoot,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter(Mandatory)][string]$ErrorPattern,
        [Parameter(Mandatory)][string]$Message,
        [switch]$ExpectIntegrityOk
    )
    Copy-Item -LiteralPath $SourceRoot -Destination $CaseRoot -Recurse
    try {
        $raw = Get-Content -LiteralPath (Join-Path $CaseRoot 'run.raw.json') -Raw | ConvertFrom-Json -Depth 100
        $candidateIndex = Get-Content -LiteralPath (Join-Path $CaseRoot 'visual-index.json') -Raw | ConvertFrom-Json -Depth 100
        $baselineIndex = Get-Content -LiteralPath (Join-Path $CaseRoot $raw.baseline.visualIndexPath) -Raw | ConvertFrom-Json -Depth 100
        $sourcePrefix = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $casePrefix = [IO.Path]::GetFullPath($CaseRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $executionPath = Join-Path $CaseRoot $raw.assays.visual.automatedReview.executionPath
        $execution = Get-Content -LiteralPath $executionPath -Raw | ConvertFrom-Json -Depth 100
        for ($batchOffset = 0; $batchOffset -lt 6; $batchOffset++) {
            $batch = $raw.assays.visual.automatedReview.batches[$batchOffset]
            $receiptPath = Join-Path $CaseRoot $batch.receiptPath
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 100
            for ($bindingOffset = 0; $bindingOffset -lt @($receipt.imageBindings).Count; $bindingOffset++) {
                $aliasPath = [string]$receipt.imageBindings[$bindingOffset].aliasPath
                Assert-Test ($aliasPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) `
                    'Copied automated-review receipt alias does not begin at its source evidence root.'
                $rebased = $casePrefix + $aliasPath.Substring($sourcePrefix.Length)
                $receipt.imageBindings[$bindingOffset].aliasPath = $rebased
                $execution.batches[$batchOffset].imageBindings[$bindingOffset].path = $rebased
            }
            foreach ($pathName in @('outputSchemaPath', 'responsePath', 'eventsPath')) {
                $recordedPath = [string]$execution.batches[$batchOffset].$pathName
                Assert-Test ($recordedPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) `
                    "Copied provider $pathName does not begin at its source evidence root."
                $execution.batches[$batchOffset].$pathName = $casePrefix + $recordedPath.Substring($sourcePrefix.Length)
            }
            Write-CSXJsonFile -Path $receiptPath -Value $receipt | Out-Null
            $batch.receiptSha256 = Get-CSXFileSha256 $receiptPath
        }
        Write-CSXJsonFile -Path $executionPath -Value $execution | Out-Null
        $raw.assays.visual.automatedReview.executionSha256 = Get-CSXFileSha256 $executionPath
        & $Mutation $CaseRoot $raw
        $result = Test-CSXAutomatedVisualReviewEvidence -EvidenceDirectory $CaseRoot -RunRaw $raw `
            -VisualIndex $candidateIndex -BaselineVisualIndex $baselineIndex
        $errorText = $result.errors -join ' | '
        Assert-Test (-not $result.ok -and $errorText -match $ErrorPattern -and
            (-not $ExpectIntegrityOk -or $result.integrityOk)) `
            "$Message errors=$errorText"
    }
    finally {
        if (Test-Path -LiteralPath $CaseRoot) { Remove-Item -LiteralPath $CaseRoot -Recurse -Force }
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-render-scale-qualification-' + [guid]::NewGuid().ToString('N'))
try {
    $record = Get-CSXQualificationProtocol -Path $protocolPath
    $protocol = $record.protocol
    Assert-Test ($record.sha256 -match '^[a-f0-9]{64}$') 'Protocol hash is not SHA-256.'
    Assert-Test ($protocol.transitionTimingOrigin -eq 'qualification_dispatch' -and
        $protocol.transitionExecution -eq 'fail_fast_top_level_mcp') 'Protocol does not freeze fail-fast dispatch-to-stable timing.'
    Assert-Test ($protocol.requiredMethodsCommit -eq 'b46edeaed14c41ad41225641c3a4943f1db25db6') 'Required methods commit is not frozen.'
    $reorderedProtocol = ($protocol | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $first = $reorderedProtocol.menuAssay.nvidiaMatrix[0]
    $reorderedProtocol.menuAssay.nvidiaMatrix[0] = $reorderedProtocol.menuAssay.nvidiaMatrix[1]
    $reorderedProtocol.menuAssay.nvidiaMatrix[1] = $first
    $reorderRejected = $false
    try { Assert-CSXProtocol -Protocol $reorderedProtocol } catch { $reorderRejected = $true }
    Assert-Test $reorderRejected 'A reordered canonical menu matrix was accepted.'
    foreach ($mutation in @('cell', 'foveation', 'visual', 'gate')) {
        $changedProtocol = ($protocol | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
        switch ($mutation) {
            cell { $changedProtocol.fixture.interiorCellEditorId = 'WhiterunBanneredMare' }
            foveation { $changedProtocol.fixture.foveation.peripheryTAAOuterScale = 0.6 }
            visual { $changedProtocol.visualAssay.source.fallback = 'game_mirror' }
            gate { $changedProtocol.thresholds.maximumPresentationStretchEpisodeFrames = 3 }
        }
        $mutationRejected = $false
        try { Assert-CSXProtocol -Protocol $changedProtocol } catch { $mutationRejected = $true }
        Assert-Test $mutationRejected "A revision-$($protocol.protocolRevision) $mutation mutation was accepted."
    }
    $moduleSource = Get-Content -LiteralPath $module -Raw
    $toolCallBody = [regex]::Match($moduleSource, '(?s)function Invoke-CSXMcpTool.*?(?=function Get-CSXRemainingMilliseconds)').Value
    Assert-Test ($toolCallBody -match 'Invoke-WebRequest' -and $toolCallBody -notmatch 'Invoke-CSXRetriedWebRequest') 'Mutating MCP tools/call can still be replayed.'

    $runner = Join-Path $PSScriptRoot 'Invoke-CSXRenderScaleQualification.ps1'
    $runnerSource = Get-Content -LiteralPath $runner -Raw
    Assert-Test ($runnerSource -match '(?s)cleanupHealth.*?Assert-AuthoritativeRuntimeBinding' -and
        $runnerSource -match '(?s)qualification\.ownerId.*?script:runId') 'Emergency cleanup is not bound to the runtime and transition owner.'
    $protectedEvidence = Join-Path $fixture 'protected-evidence'
    New-Item -ItemType Directory -Path $protectedEvidence -Force | Out-Null
    $sentinelPath = Join-Path $protectedEvidence 'sentinel.txt'
    [IO.File]::WriteAllText($sentinelPath, 'preserve-me')
    $protectedResult = (& $runner -EvidenceDirectory $protectedEvidence -RuntimePath (Join-Path $fixture 'missing-runtime.json') `
        -ExpectedBuildId ('f' * 64) -GpuVendor NVIDIA -FixtureManifestPath (Join-Path $fixture 'missing-fixture.json') `
        -NoExit -Compact) | ConvertFrom-Json -Depth 100
    Assert-Test ($protectedResult.status -eq 'INFRASTRUCTURE_ERROR' -and
        @(Get-ChildItem -LiteralPath $protectedEvidence -Force).Count -eq 1 -and
        [IO.File]::ReadAllText($sentinelPath) -eq 'preserve-me') 'A rejected nonempty evidence directory was modified.'

    $cocNvidia = New-CSXCocScenario -Protocol $protocol -GpuVendor NVIDIA -FsrRuntime fsr4 -ExpectedBuildId ('a' * 64) -RunId test
    Assert-Test (@($cocNvidia.steps).Count -eq 80) 'COC scenario is not exactly begin/dispatch/coc/wait x20.'
    Assert-Test (@($cocNvidia.steps | Where-Object tool -eq 'console').Count -eq 20) 'COC scenario does not contain exactly 20 console COCs.'
    $cocDispatches = @($cocNvidia.steps | Where-Object label -like 'coc-*-dispatch')
    Assert-Test ($cocDispatches.Count -eq 20 -and @($cocDispatches.args.ownerId | Sort-Object -Unique)[0] -eq 'test') 'COC dispatch marks are incomplete or not owner-bound.'
    $cocWaits = @($cocNvidia.steps | Where-Object label -like 'coc-*-wait')
    Assert-Test ($cocWaits.Count -eq 20 -and @($cocWaits.args.timeoutMs | Sort-Object -Unique)[0] -eq 120000) 'COC waiter ceiling is incorrect.'
    Assert-Test ($cocWaits[0].args.target.method -eq 'dlss' -and $cocWaits[0].args.target.dlssProfile -eq 'K' -and -not $cocWaits[0].args.target.renderScaleMode) 'NVIDIA interior target is not exact DLAA/K.'
    Assert-Test ($cocWaits[1].args.target.method -eq 'fsr' -and $cocWaits[1].args.target.fsrRuntime -eq 'fsr4' -and $cocWaits[1].args.target.qualityMode -eq 1) 'Exterior target did not freeze the FSR runtime.'
    Assert-Test ($cocWaits[0].args.foveation.peripheryTAAEnable -and [double]$cocWaits[0].args.foveation.peripheryTAAOuterScale -eq 0.7) 'COC waiter omitted the exact foveation target.'

    $nvidiaMenu = New-CSXMenuScenario -Protocol $protocol -GpuVendor NVIDIA -FsrRuntime fsr3 -ExpectedBuildId ('b' * 64) -ExpectedCellEditorId WindhelmExterior01 -RunId test
    Assert-Test (@($nvidiaMenu.scenario.steps | Where-Object label -like 'menu-*-wait').Count -eq 25) 'NVIDIA menu matrix does not contain 25 waits.'
    Assert-Test (@($nvidiaMenu.scenario.steps | Where-Object label -like 'menu-*-dispatch').Count -eq 25) 'NVIDIA menu matrix does not contain 25 dispatch marks.'
    Assert-Test (@($nvidiaMenu.scenario.steps | Where-Object { $_.label -like 'menu-*-dlss_trace_read' }).Count -eq @($protocol.menuAssay.nvidiaMatrix | Where-Object method -eq dlss).Count) 'NVIDIA DLSS transitions are not individually traced.'
    $lastNvidiaWait = @($nvidiaMenu.scenario.steps | Where-Object label -eq 'menu-25-wait')[0]
    Assert-Test ($lastNvidiaWait.args.target.method -eq 'fsr' -and $lastNvidiaWait.args.target.qualityMode -eq 1) 'NVIDIA matrix does not end at FSR Hoshipa.'

    $amdMenu = New-CSXMenuScenario -Protocol $protocol -GpuVendor AMD -FsrRuntime fsr3 -ExpectedBuildId ('c' * 64) -ExpectedCellEditorId WindhelmExterior01 -RunId test
    Assert-Test (@($amdMenu.scenario.steps | Where-Object label -like 'menu-*-wait').Count -eq 25) 'AMD menu matrix does not contain 25 waits.'
    Assert-Test (@($amdMenu.scenario.steps | Where-Object label -like 'menu-*-dispatch').Count -eq 25) 'AMD menu matrix does not contain 25 dispatch marks.'
    Assert-Test (@($amdMenu.scenario.steps | Where-Object { $_.label -like 'menu-*-apply' -and $_.args.method -ne 'fsr' }).Count -eq 0) 'AMD matrix attempts a non-FSR apply.'
    Assert-Test (@($amdMenu.scenario.steps | Where-Object label -like 'amd-capability-dlss_trace_*').Count -eq 4) 'AMD matrix omitted the zero-dispatch DLSS trace lifecycle check.'

    $recovery = New-CSXRecoveryScenario -Protocol $protocol -ExpectedBuildId ('d' * 64) -RunId test -FsrRuntime fsr4 -RecoveryLabel one
    Assert-Test (@($recovery.steps | Where-Object { $null -ne (Get-CSXPropertyValue $_ 'wait') }).Count -eq 1 -and [int]$recovery.steps[0].wait -eq 30000) 'Recovery does not contain exactly one 30 second server wait.'
    Assert-Test (@($recovery.steps | Where-Object { [string](Get-CSXPathValue $_ 'args.action') -in @('qualification_begin', 'qualification_dispatch', 'qualification_wait', 'qualification_cancel') }).Count -eq 0) 'Recovery incorrectly uses a fresh-transition waiter.'
    Assert-Test (@($recovery.steps | Where-Object { (Get-CSXPropertyValue $_ 'tool') -eq 'communityshaders.screenshot' }).Count -eq 1) 'Recovery omitted screenshot readiness.'

    $visualRequest = New-CSXVisualSequenceRequest -Protocol $protocol -RunId test -Replicate 1 -DestinationDirectory $fixture
    Assert-Test ($visualRequest.sequence.frameCount -eq 16 -and $visualRequest.sequence.schedule.basis -eq 'wall_clock' -and $visualRequest.sequence.schedule.intervalMs -eq 4000) 'Visual wall-clock sequence is incorrect.'
    Assert-Test (@($visualRequest.sequence.capture.outputs).Count -eq 3 -and $visualRequest.sequence.capture.source.fallback -eq 'reject') 'Visual sequence does not request all stereo views with reject fallback.'

    $summary = Get-CSXMetricSummary -Values ([double[]]@(1, 2, 3, 4)) -IncludeRate
    Assert-Test ($summary.total -eq 10 -and $summary.median -eq 2.5 -and $summary.mean -eq 2.5 -and [Math]::Abs($summary.sampleStandardDeviation - 1.2909944487) -lt 0.000001 -and $summary.p95 -eq 4 -and $summary.transitionsPerMinute -eq 24000) 'Metric summary does not use the required definitions.'
    $wilson = Get-CSXWilsonInterval -Failures 0 -Trials 20
    Assert-Test ($wilson.lower -eq 0 -and $wilson.upper -gt 0.16 -and $wilson.upper -lt 0.17) 'Wilson 95% interval is incorrect.'

    $traceSummary = [pscustomobject]@{
        active = $false; sessionID = 7; capacity = 256; retainedRecords = 3; totalRecords = 4; overwrittenRecords = 1; droppedRecords = 0
        setConstantsCalls = 2; evaluateCalls = 2; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $traceStartSummary = [pscustomobject]@{
        active = $true; sessionID = 7; capacity = 256; retainedRecords = 0; totalRecords = 0; overwrittenRecords = 0; droppedRecords = 0
        setConstantsCalls = 0; evaluateCalls = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $traceResetSummary = [pscustomobject]@{
        active = $false; sessionID = 6; capacity = 256; retainedRecords = 0; totalRecords = 0; overwrittenRecords = 0; droppedRecords = 0
        setConstantsCalls = 0; evaluateCalls = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $leftSignature = [pscustomobject]@{
        traceSessionID = 7; frame = 30; frameToken = 40; requestedViewport = 0; resolvedViewport = 0; eye = 0
        output = [pscustomobject]@{ width = 100; height = 100 }; extentIn = [pscustomobject]@{ width = 70; height = 70 }
        extentOut = [pscustomobject]@{ width = 100; height = 100 }; qualityMode = 1; dlssPreset = 1
        streamlineConstants = [pscustomobject]@{ cameraFOV = @(1, 2) }
        resources = [pscustomobject]@{ colorIn = '0x0000000000000001'; colorOut = '0x0000000000000002'; depth = '0x0000000000000003'; motionVectors = '0x0000000000000004' }
    }
    $rightSignature = [pscustomobject]@{
        traceSessionID = 7; frame = 30; frameToken = 40; requestedViewport = 1; resolvedViewport = 1; eye = 1
        output = [pscustomobject]@{ width = 100; height = 100 }; extentIn = [pscustomobject]@{ width = 70; height = 70 }
        extentOut = [pscustomobject]@{ width = 100; height = 100 }; qualityMode = 1; dlssPreset = 1
        streamlineConstants = [pscustomobject]@{ cameraFOV = @(1, 2) }
        resources = [pscustomobject]@{ colorIn = '0x0000000000000011'; colorOut = '0x0000000000000012'; depth = '0x0000000000000013'; motionVectors = '0x0000000000000014' }
    }
    $leftConstants = [pscustomobject]@{ sequence = 1; timestampQPC = 10; stage = 'set_constants'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $leftSignature }
    $rightConstants = [pscustomobject]@{ sequence = 3; timestampQPC = 11; stage = 'set_constants'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $rightSignature }
    $traceRecords = @(
        [pscustomobject]@{ current = [pscustomobject]@{ sequence = 2; timestampQPC = 11; stage = 'evaluate'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $leftSignature }; previousConstantsFound = $true; previousConstants = $leftConstants },
        [pscustomobject]@{ current = $rightConstants; previousConstantsFound = $false },
        [pscustomobject]@{ current = [pscustomobject]@{ sequence = 4; timestampQPC = 12; stage = 'evaluate'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $rightSignature }; previousConstantsFound = $true; previousConstants = $rightConstants }
    )
    $traceWaitResults = @(foreach ($ordinal in 1..25) {
        [pscustomobject]@{
            label = "menu-$($ordinal.ToString('D2'))-wait"
            result = [pscustomobject]@{ target = [pscustomobject]@{ method = $(if ($ordinal -eq 1) { 'dlss' } else { 'fsr' }); qualityMode = 1 } }
        }
    })
    $traceScenario = [pscustomobject]@{ results = @($traceWaitResults) + @(
        [pscustomobject]@{ label = 'menu-dlss_trace_status-preflight'; result = [pscustomobject]@{ action = 'dlss_trace_status'; capture = $traceResetSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_reset'; result = [pscustomobject]@{ action = 'dlss_trace_reset'; capture = $traceResetSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_start'; result = [pscustomobject]@{ action = 'dlss_trace_start'; capture = $traceStartSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_stop'; result = [pscustomobject]@{ action = 'dlss_trace_stop'; capture = $traceSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_read'; result = [pscustomobject]@{ action = 'dlss_trace_read'; capture = [pscustomobject]@{
            summary = $traceSummary; afterSequence = 0; limit = 16; availableFromSequence = 2; requestedSequenceOverwritten = $true
            latestSequence = 4; lastReturnedSequence = 4; moreAvailable = $false; records = $traceRecords
        } } }
    ) }
    $traceCheck = Test-CSXDLSSScenarioEvidence -ScenarioResult $traceScenario -GpuVendor NVIDIA
    Assert-Test ($traceCheck.ok -and $traceCheck.warnings.Count -eq 1) 'Ring overwrite was not classified as partial raw detail only.'
    $traceSummary.droppedRecords = 1
    Assert-Test (-not (Test-CSXDLSSScenarioEvidence -ScenarioResult $traceScenario -GpuVendor NVIDIA).ok) 'Dropped DLSS records did not fail the trace gate.'
    $traceSummary.droppedRecords = 0
    $truncatedTrace = $traceScenario | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $truncatedRead = @($truncatedTrace.results | Where-Object label -eq 'menu-01-dlss_trace_read')[0]
    $truncatedRead.result.capture.records = @($truncatedRead.result.capture.records | Select-Object -First 2)
    Assert-Test (-not (Test-CSXDLSSScenarioEvidence -ScenarioResult $truncatedTrace -GpuVendor NVIDIA).ok) 'A truncated DLSS read page passed retained-record completeness.'

    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $fixtureManifestPath = Join-Path $fixture 'fixture.json'
    Write-CSXJsonFile -Path $fixtureManifestPath -Value ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-fixture-v1'; fixtureId = 'test-fixture'
        save = [pscustomobject]@{ id = 'save'; sha256 = ('1' * 64) }
        camera = [pscustomobject]@{ id = 'camera'; configurationSha256 = ('2' * 64) }
        vrFpsStabilizer = [pscustomobject]@{ version = '1.0'; configurationSha256 = ('3' * 64) }
        gpu = [pscustomobject]@{ vendor = 'NVIDIA'; deviceId = '0x2684'; driverVersion = '32.0.15.9000' }
        hmd = [pscustomobject]@{ model = 'hmd'; runtime = 'SteamVR'; runtimeVersion = 'runtime'; refreshHz = 90 }
        attestation = [pscustomobject]@{ operatorId = 'offline-test'; recordedUtc = '2026-08-26T12:00:00Z'; operatorAttestedFields = @('save', 'camera', 'vrFpsStabilizer', 'hmd') }
    }) | Out-Null
    $fixtureRecord = Get-CSXFixtureManifest -Path $fixtureManifestPath -GpuVendor NVIDIA
    Assert-Test ($fixtureRecord.sha256 -match '^[a-f0-9]{64}$') 'Fixture manifest was not hash-bound.'
    $liveGpu = Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
        available = $true; driverVersionAvailable = $true; vendorId = 0x10DE; deviceId = 0x2684
        driverVersion = '32.0.15.9000'; description = 'NVIDIA test adapter'; luidHigh = 1; luidLow = 2
    }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA
    Assert-Test ($liveGpu.verified -and $liveGpu.deviceId -eq '0x2684') 'Live GPU identity was not bound to the fixture.'
    $wrongGpuRejected = $false
    try {
        Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
            available = $true; driverVersionAvailable = $true; vendorId = 0x1002; deviceId = 0x2684; driverVersion = '32.0.15.9000'
        }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA | Out-Null
    } catch { $wrongGpuRejected = $true }
    Assert-Test $wrongGpuRejected 'A live adapter from the wrong vendor was accepted.'
    $wrongDriverRejected = $false
    try {
        Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
            available = $true; driverVersionAvailable = $true; vendorId = 0x10DE; deviceId = 0x2684; driverVersion = '32.0.15.9999'
        }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA | Out-Null
    } catch { $wrongDriverRejected = $true }
    Assert-Test $wrongDriverRejected 'A mismatched live driver version was accepted.'
    $fixtureMismatchRejected = $false
    try { Get-CSXFixtureManifest -Path $fixtureManifestPath -GpuVendor AMD | Out-Null } catch { $fixtureMismatchRejected = $true }
    Assert-Test $fixtureMismatchRejected 'Fixture GPU mismatch was accepted.'
    $fixtureManifestIdentity = [pscustomobject][ordered]@{
        schema = 'csx-render-scale-fixture-v1'; fixtureId = [string]$fixtureRecord.manifest.fixtureId
        sha256 = $fixtureRecord.sha256; path = 'fixture-manifest.json'; identity = $fixtureRecord.manifest
    }
    $fixtureInputs = [pscustomobject][ordered]@{
        protocolSha256 = $record.sha256; gpuVendor = 'NVIDIA'; fsrRuntime = 'fsr3'
        fixtureManifest = $fixtureManifestIdentity; matrixName = 'nvidiaMatrix'
    }
    $fixtureIdentity = [pscustomobject][ordered]@{
        gpuVendor = 'NVIDIA'; fsrRuntime = 'fsr3'; matrixName = 'nvidiaMatrix'
        fingerprint = Get-TestObjectSha256 $fixtureInputs
        manifest = $fixtureManifestIdentity; inputs = $fixtureInputs
    }
    $candidateRoot = Join-Path $fixture 'candidate'
    $baselineRoot = Join-Path $candidateRoot 'baseline'
    $candidateBuildId = 'e' * 64
    $baselineBuildId = 'f' * 64
    $baselineEnvelope = New-TestEvidenceEnvelope -Root $baselineRoot -RunId rsq-baseline -BuildId $baselineBuildId `
        -ProtocolRecord $record -FixtureIdentity $fixtureIdentity -ProtocolSource $protocolPath -FixtureSource $fixtureManifestPath
    Assert-Test ($baselineEnvelope.final.report.status -eq 'LOCAL_PASS') `
        "Complete standalone baseline evidence did not finalize: $($baselineEnvelope.final.report.errors -join ' | ')"
    $standaloneAutomated = $baselineEnvelope.raw.assays.visual.automatedReview
    Assert-Test ($standaloneAutomated.schema -eq 'csx-render-scale-automated-review-v1' -and
        $standaloneAutomated.provider -eq 'codex_cli' -and $standaloneAutomated.model -eq 'gpt-5.6-sol' -and
        [int]$standaloneAutomated.deadlineSeconds -eq 90 -and @($standaloneAutomated.batches).Count -eq 6) `
        'Standalone synthetic evidence does not bind the exact unattended image-model envelope.'
    Assert-Test ((@($standaloneAutomated.batches | ForEach-Object { "$($_.presentationPass):$($_.replicate)" }) -join ',') -eq
        '1:1,1:2,1:3,2:1,2:2,2:3') 'Standalone image-model batches are not in pass-major order.'
    $standalonePassOne = Get-Content -LiteralPath (Join-Path $baselineRoot $standaloneAutomated.batches[0].requestPath) -Raw | ConvertFrom-Json -Depth 100
    $standalonePassTwo = Get-Content -LiteralPath (Join-Path $baselineRoot $standaloneAutomated.batches[3].requestPath) -Raw | ConvertFrom-Json -Depth 100
    $standaloneOrderOne = @($standalonePassOne.body.attachmentOrder | ForEach-Object { "$($_.ordinal):$($_.view):$($_.sha256)" })
    $standaloneOrderTwo = @($standalonePassTwo.body.attachmentOrder | ForEach-Object { "$($_.ordinal):$($_.view):$($_.sha256)" })
    [array]::Reverse($standaloneOrderOne)
    Assert-Test (@($standalonePassOne.body.attachmentOrder).Count -eq 9 -and
        (@($standalonePassOne.body.attachmentOrder.attachmentIndex) -join ',') -eq '1,2,3,4,5,6,7,8,9' -and
        ($standaloneOrderOne -join ',') -eq ($standaloneOrderTwo -join ',')) `
        'Standalone pass two is not the exact reversed, one-based nine-attachment presentation.'

    $candidatePreview = New-TestCoreAssays -Protocol $protocol -RunId rsq-candidate -BuildId $candidateBuildId -VisualIndexSha256 ('0' * 64)
    $cocComparison = Get-CSXPairedComparison -Candidate @($candidatePreview.coc.records) -Baseline @($baselineEnvelope.raw.assays.coc.records)
    $menuComparison = Get-CSXPairedComparison -Candidate @($candidatePreview.menu.records) -Baseline @($baselineEnvelope.raw.assays.menu.records)
    $baselineMetadata = [pscustomobject][ordered]@{
        path = 'baseline/run.json'; runSha256 = Get-CSXFileSha256 (Join-Path $baselineRoot 'run.json')
        rawPath = 'baseline/run.raw.json'; rawSha256 = Get-CSXFileSha256 (Join-Path $baselineRoot 'run.raw.json')
        visualReviewPath = 'baseline/visual-review.json'; visualReviewSha256 = Get-CSXFileSha256 (Join-Path $baselineRoot 'visual-review.json')
        artifactInventoryPath = 'baseline/automation-artifacts.json'; artifactInventorySha256 = Get-CSXFileSha256 (Join-Path $baselineRoot 'automation-artifacts.json')
        artifactInventoryEntryCount = @((Get-Content -LiteralPath (Join-Path $baselineRoot 'automation-artifacts.json') -Raw | ConvertFrom-Json -Depth 100).entries).Count
        visualIndexPath = 'baseline/visual-index.json'; visualIndexSha256 = Get-CSXFileSha256 (Join-Path $baselineRoot 'visual-index.json')
        candidateRunId = 'rsq-candidate'; baselineRunId = 'rsq-baseline'; baselineBuildId = $baselineBuildId; expectedBaselineBuildId = $baselineBuildId
        cocPaired = $cocComparison; menuPaired = $menuComparison
        gates = [pscustomobject][ordered]@{ cocAggregateMedianP95 = $true; menuAggregateMedianP95 = $true }
    }
    $candidateEnvelope = New-TestEvidenceEnvelope -Root $candidateRoot -RunId rsq-candidate -BuildId $candidateBuildId `
        -ProtocolRecord $record -FixtureIdentity $fixtureIdentity -ProtocolSource $protocolPath -FixtureSource $fixtureManifestPath `
        -Baseline $baselineMetadata
    $raw = $candidateEnvelope.raw
    $review = $candidateEnvelope.review
    $candidateIndex = $candidateEnvelope.index
    $baselineIndex = $baselineEnvelope.index
    Assert-Test ($candidateEnvelope.final.report.status -eq 'PASS') `
        "Complete PR artifact envelope did not finalize: $($candidateEnvelope.final.report.errors -join ' | ')"
    $prAutomated = $raw.assays.visual.automatedReview
    Assert-Test ((@($prAutomated.batches | ForEach-Object { "$($_.presentationPass):$($_.replicate)" }) -join ',') -eq
        '1:1,1:2,1:3,2:1,2:2,2:3') 'PR image-model batches are not in pass-major order.'
    $prFirstReceipt = Get-Content -LiteralPath (Join-Path $candidateRoot $prAutomated.batches[0].receiptPath) -Raw | ConvertFrom-Json -Depth 100
    $prSecondReceipt = Get-Content -LiteralPath (Join-Path $candidateRoot $prAutomated.batches[3].receiptPath) -Raw | ConvertFrom-Json -Depth 100
    $prFirstResponse = Get-Content -LiteralPath (Join-Path $candidateRoot $prAutomated.batches[0].responsePath) -Raw | ConvertFrom-Json -Depth 100
    $prSecondResponse = Get-Content -LiteralPath (Join-Path $candidateRoot $prAutomated.batches[3].responsePath) -Raw | ConvertFrom-Json -Depth 100
    Assert-Test ($prFirstReceipt.candidatePosition -eq 'first' -and $prSecondReceipt.candidatePosition -eq 'second' -and
        @($prFirstReceipt.imageBindings).Count -eq 18 -and @($prSecondReceipt.imageBindings).Count -eq 18 -and
        $prFirstResponse.samples[0].categories.sharpness.verdict -eq 'first_better' -and
        $prSecondResponse.samples[0].categories.sharpness.verdict -eq 'second_better') `
        'PR synthetic evidence does not preserve the blinded first/second candidate swap.'

    $reviewResult = Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $review -BaselineVisualIndex $baselineIndex
    Assert-Test $reviewResult.ok 'A correctly hash-bound PR visual review did not pass.'
    $humanReview = Copy-TestObject $review
    $humanReview.reviewer.kind = 'human'
    $humanResult = Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $humanReview -BaselineVisualIndex $baselineIndex
    Assert-Test (-not $humanResult.ok -and ($humanResult.errors -join ' | ') -match 'human|image_model') `
        'Protocol revision 4 accepted a human visual review.'
    $duplicateReview = ($review | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $duplicateReview.samples[0].candidateArtifacts[2] = $duplicateReview.samples[0].candidateArtifacts[1]
    Assert-Test (-not (Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $duplicateReview -BaselineVisualIndex $baselineIndex).ok) 'A duplicated candidate artifact binding was accepted.'
    $summaryText = Get-Content -LiteralPath $candidateEnvelope.final.summaryPath -Raw
    Assert-Test ($summaryText -match 'all 9 checkpoints' -and $summaryText -match 'sharpness, blur, shimmer, stereo alignment, equal-eye scale, geometry correspondence, and render-scale latch') `
        'Passing summary omitted the concise nine-checkpoint visual-quality verdict.'

    $automatedVisualRejections = @(
        [pscustomobject]@{
            name = 'low confidence'; pattern = 'low confidence'; expectIntegrityOk = $true
            mutate = {
                param($root, $value)
                Update-TestAutomatedResponseEvidence -Root $root -Raw $value -BatchOffset 0 -Mutation {
                    param($response) $response.samples[0].categories.sharpness.confidence = 'low'
                }
            }
        },
        [pscustomobject]@{
            name = 'indeterminate response'; pattern = 'indeterminate'; expectIntegrityOk = $true
            mutate = {
                param($root, $value)
                Update-TestAutomatedResponseEvidence -Root $root -Raw $value -BatchOffset 0 -Mutation {
                    param($response)
                    $response.samples[0].categories.blur.verdict = 'indeterminate'
                    $response.overallVerdict = 'indeterminate'
                }
            }
        },
        [pscustomobject]@{
            name = 'swapped-order inconsistency'; pattern = 'disagrees after the blinded order swap|regression or inconclusive'; expectIntegrityOk = $true
            mutate = {
                param($root, $value)
                Update-TestAutomatedResponseEvidence -Root $root -Raw $value -BatchOffset 3 -Mutation {
                    param($response) $response.samples[0].categories.sharpness.verdict = 'first_better'
                }
            }
        },
        [pscustomobject]@{
            name = 'request body self-hash'; pattern = 'request self-hash binding'
            mutate = {
                param($root, $value)
                $batch = $value.assays.visual.automatedReview.batches[0]
                $path = Join-Path $root $batch.requestPath
                $request = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
                $request.body.sampleOrdinals = @(1, 8, 8)
                Write-CSXJsonFile -Path $path -Value $request | Out-Null
                $batch.requestFileSha256 = Get-CSXFileSha256 $path
            }
        },
        [pscustomobject]@{
            name = 'receipt hash'; pattern = 'receipt SHA-256 binding'
            mutate = { param($root, $value) $value.assays.visual.automatedReview.batches[0].receiptSha256 = ('0' * 64) }
        },
        [pscustomobject]@{
            name = 'preflight hash'; pattern = 'preflight SHA-256 binding'
            mutate = { param($root, $value) $value.assays.visual.automatedReview.preflightSha256 = ('0' * 64) }
        },
        [pscustomobject]@{
            name = 'visual diagnostic owned session'; pattern = 'task-owned|transcript does not contain exactly one stress'
            mutate = {
                param($root, $value)
                $stressPath = Join-Path $root 'visual/stress-record.json'
                $diagnosticsPath = Join-Path $root 'visual/diagnostics.json'
                $stress = Get-Content -LiteralPath $stressPath -Raw | ConvertFrom-Json -Depth 100
                $diagnostics = Get-Content -LiteralPath $diagnosticsPath -Raw | ConvertFrom-Json -Depth 100
                $stress.session.id = 999
                $diagnostics.stress.status.session.id = 999
                $diagnostics.stress.status.lastRecord.session.id = 999
                Write-CSXJsonFile -Path $stressPath -Value $stress | Out-Null
                Write-CSXJsonFile -Path $diagnosticsPath -Value $diagnostics | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'visual diagnostic enclosure'; pattern = 'UTC interval does not enclose'
            mutate = {
                param($root, $value)
                $path = Join-Path $root 'mcp-transcript.json'
                $transcript = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100)
                $cpuStop = @($transcript | Where-Object {
                    $_.tool -eq 'communityshaders.renderscale' -and $_.arguments.action -eq 'cpu_performance_stop' -and
                    [int]$_.arguments.expectedSessionId -eq 703
                })[0]
                $stressStop = @($transcript | Where-Object {
                    $_.tool -eq 'communityshaders.renderscale' -and $_.arguments.action -eq 'stop' -and
                    [int]$_.arguments.expectedSessionId -eq 503
                })[0]
                $cpuStop.startedUtc = '2026-08-26T12:02:58.0000000+00:00'; $cpuStop.completedUtc = '2026-08-26T12:02:58.1000000+00:00'
                $stressStop.startedUtc = '2026-08-26T12:02:58.2000000+00:00'; $stressStop.completedUtc = '2026-08-26T12:02:58.3000000+00:00'
                Write-CSXJsonFile -Path $path -Value $transcript | Out-Null
            }
        }
    )
    $automatedCaseNumber = 0
    foreach ($case in $automatedVisualRejections) {
        $automatedCaseNumber++
        Assert-AutomatedVisualEvidenceRejects -SourceRoot $candidateRoot `
            -CaseRoot (Join-Path $fixture "automated-tamper-$($automatedCaseNumber.ToString('D2'))") `
            -Mutation $case.mutate -ErrorPattern $case.pattern `
            -Message "Automated visual validator accepted $($case.name) evidence." `
            -ExpectIntegrityOk:([bool](Get-CSXPropertyValue $case 'expectIntegrityOk' $false))
    }

    $candidateRejections = @(
        [pscustomobject]@{ name = 'raw schema'; pattern = 'Raw schema'; mutate = { param($value) $value.schema = 'csx-render-scale-local-v1-raw' } },
        [pscustomobject]@{ name = 'automated gate'; pattern = 'Automated gates'; mutate = { param($value) $value.automatedGates.passed = $false } },
        [pscustomobject]@{ name = 'duplicate COC ordinal'; pattern = 'ordinal 2 is missing or duplicated'; mutate = { param($value) $value.assays.coc.records[1].ordinal = 1 } },
        [pscustomobject]@{ name = 'performance gate'; pattern = 'performance comparison gates'; mutate = { param($value) $value.baseline.gates.cocAggregateMedianP95 = $false } },
        [pscustomobject]@{
            name = 'missing automated batch'; pattern = 'six|batch|Automated visual'
            mutate = { param($value) $value.assays.visual.automatedReview.batches = @($value.assays.visual.automatedReview.batches | Select-Object -First 5) }
        }
    )
    foreach ($case in $candidateRejections) {
        Assert-FinalizerRejects -Root $candidateRoot -Raw $raw -Review $review -Mutation $case.mutate `
            -ErrorPattern $case.pattern -Message "Finalizer accepted invalid $($case.name) evidence." -RebindInventory
    }
    Write-CSXJsonFile -Path (Join-Path $candidateRoot 'run.raw.json') -Value $raw | Out-Null
    $review.runRawSha256 = Get-CSXFileSha256 (Join-Path $candidateRoot 'run.raw.json')
    $review.baselineRunSha256 = $raw.baseline.runSha256
    Write-CSXJsonFile -Path (Join-Path $candidateRoot 'visual-review.json') -Value $review | Out-Null

    $tamperCases = @(
        [pscustomobject]@{
            name = 'inventory-hash'; mode = 'none'; pattern = 'inventory SHA-256 binding'
            mutate = { param($root, $value) $value.artifactInventory.sha256 = ('0' * 64) }
        },
        [pscustomobject]@{
            name = 'inventory-path'; mode = 'existing'; pattern = 'invalid or excluded path|escapes the evidence root'
            mutate = {
                param($root, $value)
                $inventoryPath = Join-Path $root 'automation-artifacts.json'
                $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 100
                $inventory.entries[0].path = '../escape.json'
                Write-CSXJsonFile -Path $inventoryPath -Value $inventory | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'extra-file'; mode = 'none'; pattern = 'Uninventoried automation producer artifact|Unsupported file'
            mutate = { param($root, $value) [IO.File]::WriteAllText((Join-Path $root 'untracked.json'), '{}') }
        },
        [pscustomobject]@{
            name = 'scenario-receipt'; mode = 'regenerate'; pattern = 'scenario receipt'
            mutate = {
                param($root, $value)
                $path = Join-Path $root 'coc/scenario.result.json'
                $source = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
                $source.results[0].result.transitionId = 999
                Write-CSXJsonFile -Path $path -Value $source | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'cpu-session'; mode = 'regenerate'; pattern = 'CPU record|diagnostic response|diagnostic session IDs'
            mutate = {
                param($root, $value)
                $cpuPath = Join-Path $root 'coc/cpu-record.json'; $diagnosticPath = Join-Path $root 'coc/diagnostics.json'
                $cpu = Get-Content -LiteralPath $cpuPath -Raw | ConvertFrom-Json -Depth 100; $cpu.sessionId = 999
                $diagnostics = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json -Depth 100
                $diagnostics.cpu.cpuPerformance.sessionId = 999
                Write-CSXJsonFile -Path $cpuPath -Value $cpu | Out-Null; Write-CSXJsonFile -Path $diagnosticPath -Value $diagnostics | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'stress-session'; mode = 'regenerate'; pattern = 'stress record session|different stress session|diagnostic session IDs'
            mutate = {
                param($root, $value)
                $stressPath = Join-Path $root 'coc/stress-record.json'; $diagnosticPath = Join-Path $root 'coc/diagnostics.json'
                $stress = Get-Content -LiteralPath $stressPath -Raw | ConvertFrom-Json -Depth 100; $stress.session.id = 999
                $diagnostics = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json -Depth 100
                $diagnostics.stress.status.session.id = 999; $diagnostics.stress.record.session.id = 999
                Write-CSXJsonFile -Path $stressPath -Value $stress | Out-Null; Write-CSXJsonFile -Path $diagnosticPath -Value $diagnostics | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'recovery'; mode = 'regenerate'; pattern = 'Recovery one'
            mutate = {
                param($root, $value)
                $path = Join-Path $root 'recovery-1.json'; $source = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
                $source.evidence.scene.cell.editorId = 'WrongCell'
                @($source.result.results | Where-Object label -eq 'one-recovery-scene')[0].result.cell.editorId = 'WrongCell'
                Write-CSXJsonFile -Path $path -Value $source | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'transcript'; mode = 'regenerate'; pattern = 'MCP transcript'
            mutate = {
                param($root, $value)
                $path = Join-Path $root 'mcp-transcript.json'; $source = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100)
                $source[0].response.ok = $false
                Write-CSXJsonFile -Path $path -Value $source | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'sequence-request'; mode = 'regenerate'; pattern = 'sequence request differs'
            mutate = {
                param($root, $value)
                $run = $value.assays.visual.runs[0]; $path = Join-Path $root $run.sequenceRequestPath
                $source = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
                $source.sequence.schedule.intervalMs = 3999
                Write-CSXJsonFile -Path $path -Value $source | Out-Null; $run.sequenceRequestSha256 = Get-CSXFileSha256 $path
                $transcriptPath = Join-Path $root 'mcp-transcript.json'; $transcript = @(Get-Content $transcriptPath -Raw | ConvertFrom-Json -Depth 100)
                $row = @($transcript | Where-Object { $_.tool -eq 'communityshaders.screenshot' -and $_.arguments.action -eq 'sequence_start' -and $_.arguments.commandId -eq $source.commandId })[0]
                $row.arguments = $source; $row.response.result.effective = $source.sequence
                Write-CSXJsonFile -Path $transcriptPath -Value $transcript | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'manifest'; mode = 'regenerate'; pattern = 'final manifest identity|capture contract'
            mutate = {
                param($root, $value)
                $run = $value.assays.visual.runs[0]; $manifestPath = Join-Path $root $run.manifestPath
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
                $manifest.capture.source.fallback = 'game_mirror'; Write-CSXJsonFile -Path $manifestPath -Value $manifest | Out-Null
                $run.manifestSha256 = Get-CSXFileSha256 $manifestPath
                $terminalPath = Join-Path $root $run.terminalReceiptPath
                $terminal = Get-Content -LiteralPath $terminalPath -Raw | ConvertFrom-Json -Depth 100
                $terminal.result.artifacts[0].sha256 = $run.manifestSha256; $terminal.result.artifacts[0].bytes = [uint64](Get-Item $manifestPath).Length
                Write-CSXJsonFile -Path $terminalPath -Value $terminal | Out-Null; $run.terminalReceiptSha256 = Get-CSXFileSha256 $terminalPath
                $transcriptPath = Join-Path $root 'mcp-transcript.json'; $transcript = @(Get-Content $transcriptPath -Raw | ConvertFrom-Json -Depth 100)
                $row = @($transcript | Where-Object {
                    $_.tool -eq 'communityshaders.screenshot' -and $_.response.result.kind -eq 'sequence' -and
                    $_.response.result.state -eq 'completed' -and $_.response.result.requestId -eq $run.requestId
                })[0]
                $row.response = $terminal; Write-CSXJsonFile -Path $transcriptPath -Value $transcript | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'child-receipt'; mode = 'regenerate'; pattern = 'child receipt identity'
            mutate = {
                param($root, $value)
                $run = $value.assays.visual.runs[0]; $path = Join-Path $root $run.childReceiptsPath
                $children = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100); $children[1].receipt.result.clientId = 'wrong-client'
                Write-CSXJsonFile -Path $path -Value $children | Out-Null; $run.childReceiptsSha256 = Get-CSXFileSha256 $path
                $transcriptPath = Join-Path $root 'mcp-transcript.json'; $transcript = @(Get-Content $transcriptPath -Raw | ConvertFrom-Json -Depth 100)
                $row = @($transcript | Where-Object { $_.tool -eq 'communityshaders.screenshot' -and $_.response.result.requestId -eq $children[1].requestId })[0]
                $row.response = $children[1].receipt; Write-CSXJsonFile -Path $transcriptPath -Value $transcript | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'non-review-png-iend'; mode = 'regenerate'; pattern = 'IEND|PNG|144 PNG artifacts'
            mutate = {
                param($root, $value)
                $run = $value.assays.visual.runs[0]; $childrenPath = Join-Path $root $run.childReceiptsPath
                $children = @(Get-Content -LiteralPath $childrenPath -Raw | ConvertFrom-Json -Depth 100); $wrapper = $children[1]
                $artifact = @($wrapper.artifacts | Where-Object view -eq 'side_by_side')[0]; $path = Join-Path $root $artifact.path
                $bytes = [IO.File]::ReadAllBytes($path); [IO.File]::WriteAllBytes($path, $bytes[0..($bytes.Length - 13)])
                $sha = Get-CSXFileSha256 $path; $length = [uint64](Get-Item $path).Length
                $artifact.sha256 = $sha
                $embedded = @($wrapper.receipt.result.artifacts | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.path).EndsWith('_side-by-side') })[0]
                $embedded.sha256 = $sha; $embedded.bytes = $length
                Write-CSXJsonFile -Path $childrenPath -Value $children | Out-Null; $run.childReceiptsSha256 = Get-CSXFileSha256 $childrenPath
                $transcriptPath = Join-Path $root 'mcp-transcript.json'; $transcript = @(Get-Content $transcriptPath -Raw | ConvertFrom-Json -Depth 100)
                $row = @($transcript | Where-Object { $_.tool -eq 'communityshaders.screenshot' -and $_.response.result.requestId -eq $wrapper.requestId })[0]
                $row.response = $wrapper.receipt; Write-CSXJsonFile -Path $transcriptPath -Value $transcript | Out-Null
            }
        },
        [pscustomobject]@{
            name = 'baseline-raw'; mode = 'none'; pattern = 'Bundled baseline run.raw SHA-256|baseline.*raw'
            mutate = { param($root, $value) [IO.File]::AppendAllText((Join-Path $root 'baseline/run.raw.json'), ' ') }
        },
        [pscustomobject]@{
            name = 'baseline-artifact'; mode = 'none'; pattern = 'Bundled baseline raw envelope|baseline.*artifact|length/hash binding'
            mutate = {
                param($root, $value)
                $baselineIndex = Get-Content -LiteralPath (Join-Path $root 'baseline/visual-index.json') -Raw | ConvertFrom-Json -Depth 100
                $relative = "baseline/$([string]$baselineIndex.samples[0].artifacts[0].path)"
                [IO.File]::AppendAllText((Join-Path $root $relative), 'x')
            }
        }
    )
    $caseNumber = 0
    foreach ($case in $tamperCases) {
        $caseNumber++
        Assert-EvidenceTamperRejected -SourceRoot $candidateRoot -CaseRoot (Join-Path $fixture "tamper-$($caseNumber.ToString('D2'))") `
            -Mutation $case.mutate -InventoryMode $case.mode -ErrorPattern $case.pattern `
            -Message "Finalizer accepted tampered $($case.name) evidence."
    }

    [pscustomobject]@{ ok = $true; protocolSha256 = $record.sha256; cocTransitions = 20; nvidiaMenuTransitions = 25; amdMenuTransitions = 25; visualSamples = 9 } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
