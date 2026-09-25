# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('run', 'status')]
    [string]$Command = 'run',
    [string]$Endpoint = 'http://127.0.0.1:8921/mcp',
    [ValidateRange(0, [int]::MaxValue)][int]$ExpectedPid = 0,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildId,
    [string]$CollectorStatePath,
    [string]$EvidenceRoot,
    [string]$StatePath,
    [string]$ProtocolConfigPath = (Join-Path $PSScriptRoot 'protocol.v1.json'),
    [ValidateRange(1000, 60000)][int]$BaselineDeadlineMs = 10000,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'CocStabilityControl.psm1'
Import-Module $modulePath -Force
$ownedJobs = [Collections.Generic.List[object]]::new()
$phase = 'initializing'
$publishedStatePath = $null
$failureData = $null

function Write-AtomicJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 100 |
            Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function ConvertTo-CocUtcRoundtripText($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('o') }
    return [string]$Value
}

function Get-JobResult($Job) {
    if ($Job.State -eq 'Completed') {
        $output = @(Receive-Job -Job $Job -Keep)
        if ($output.Count -gt 0) { return $output[-1] }
        return [pscustomobject]@{
            ok = $false
            error = 'The completed background job produced no result.'
        }
    }
    $reason = if ($Job.ChildJobs.Count -gt 0 -and $Job.ChildJobs[0].JobStateInfo.Reason) {
        $Job.ChildJobs[0].JobStateInfo.Reason.Message
    } else {
        "job state is $($Job.State)"
    }
    return [pscustomobject]@{ ok = $false; error = $reason }
}

function Get-CocFixtureAnomalies($Value) {
    $anomalies = [Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        $anomalies.Add('prepare_coc returned no fixture receipt')
        return @($anomalies)
    }

    $missingFields = @(@('ready', 'persisted', 'promptRequired') | Where-Object {
            $null -eq $Value.PSObject.Properties[$_]
        })
    if ($missingFields.Count -gt 0) {
        $anomalies.Add('prepare_coc omitted a required fixture field')
    }
    foreach ($name in @('ready', 'persisted', 'promptRequired')) {
        $property = $Value.PSObject.Properties[$name]
        if ($property -and $property.Value -isnot [bool]) {
            $anomalies.Add("prepare_coc field '$name' must be a non-null Boolean")
        }
    }
    if ($Value.PSObject.Properties['ready'] -and $Value.ready -is [bool] -and
        -not [bool]$Value.ready) {
        $anomalies.Add('prepare_coc reported ready:false')
    }
    if ($Value.PSObject.Properties['persisted'] -and $Value.persisted -is [bool] -and
        [bool]$Value.persisted) {
        $anomalies.Add('prepare_coc reported persisted:true')
    }
    if ($Value.PSObject.Properties['promptRequired'] -and
        $Value.promptRequired -is [bool] -and
        [bool]$Value.promptRequired) {
        $anomalies.Add('prepare_coc reported promptRequired:true')
    }
    return @($anomalies)
}

function Test-CocBaselineAdmissionTiming {
    param(
        [Parameter(Mandatory)]$Timing,
        [Parameter(Mandatory)][long]$DueTimestamp,
        [Parameter(Mandatory)][long]$DecisionTimestamp,
        [Parameter(Mandatory)][int]$ExpectedCount
    )
    $late = @($Timing.GetEnumerator() | Where-Object {
            $null -eq $_.Value -or -not $_.Value.PSObject.Properties['completedTimestamp'] -or
            [long]$_.Value.completedTimestamp -gt $DueTimestamp
        } | ForEach-Object Key)
    $decisionLate = $DecisionTimestamp -gt $DueTimestamp
    return [pscustomobject][ordered]@{
        acceptable = $Timing.Count -eq $ExpectedCount -and $late.Count -eq 0 -and
            -not $decisionLate
        lateResults = @($late)
        decisionLate = $decisionLate
        dueTimestamp = $DueTimestamp
        decisionTimestamp = $DecisionTimestamp
    }
}

$toolJobScript = {
    param(
        $ModulePath, $Endpoint, $Tool, $ArgumentsJson, $TimeoutSeconds,
        $ExpectedProcessId, $ExpectedProcessStartTimeUtc, $ExpectedBuildId
    )
    $ErrorActionPreference = 'Stop'
    try {
        Import-Module $ModulePath -Force
        $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 50
        $value = Invoke-CocMcpTool -Endpoint $Endpoint -Tool $Tool `
            -Arguments $arguments -TimeoutSeconds $TimeoutSeconds `
            -ExpectedProcessId $ExpectedProcessId `
            -ExpectedProcessStartTimeUtc $ExpectedProcessStartTimeUtc `
            -ExpectedBuildId $ExpectedBuildId
        [pscustomobject]@{
            ok = $true
            receipt = $value
            completedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        }
    }
    catch {
        [pscustomobject]@{
            ok = $false
            error = $_.Exception.Message
            completedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        }
    }
}

try {
    if ($Command -eq 'status') {
        $phase = 'status'
        if ([string]::IsNullOrWhiteSpace($StatePath)) {
            throw 'StatePath is required for status.'
        }
        $resolvedStatePath = [IO.Path]::GetFullPath($StatePath)
        $state = Get-Content -LiteralPath $resolvedStatePath -Raw |
            ConvertFrom-Json -Depth 100
        if ([string]$state.schema -ne 'csx-coc-stability-state-v1') {
            throw 'The state is not owned by COC stability control.'
        }
        if ([string]$state.outcome -cne 'scenario-accepted') {
            $dispatchFailure = if ($state.PSObject.Properties['dispatchFailure']) {
                $state.dispatchFailure
            } else { $null }
            $dispatchError = if ($null -ne $dispatchFailure -and
                $dispatchFailure.PSObject.Properties['error']) {
                [string]$dispatchFailure.error
            } else { "Scenario state is '$([string]$state.outcome)' without a recoverable accepted run." }
            $result = [pscustomobject][ordered]@{
                schema = 'csx-coc-stability-control-v1'
                ok = $false
                command = 'status'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                state = if ([string]$state.outcome -ceq 'dispatch-pending') {
                    'recovery-required'
                } else { 'failed' }
                data = [pscustomobject]@{
                    statePath = $resolvedStatePath
                    ownerId = [string]$state.ownerId
                    scenarioRunId = $null
                    scenario = $null
                    analysis = $null
                    dispatchFailure = $dispatchFailure
                    fixture = if ($state.PSObject.Properties['fixture']) { $state.fixture } else { $null }
                    fixtureFailure = if ($state.PSObject.Properties['fixtureFailure']) { $state.fixtureFailure } else { $null }
                    baseline = if ($state.PSObject.Properties['baseline']) { $state.baseline } else { $null }
                    baselineVerdict = if ($state.PSObject.Properties['baselineVerdict']) { $state.baselineVerdict } else { $null }
                    baselineTiming = if ($state.PSObject.Properties['baselineTiming']) { $state.baselineTiming } else { $null }
                }
                errors = @($dispatchError)
            }
        }
        else {
            $journalErrors = [Collections.Generic.List[string]]::new()
            $runIdProperty = $state.PSObject.Properties['scenarioRunId']
            $pidProperty = $state.PSObject.Properties['expectedPid']
            $startProperty = $state.PSObject.Properties['expectedProcessStartTimeUtc']
            $endpointProperty = $state.PSObject.Properties['endpoint']
            $ownerProperty = $state.PSObject.Properties['ownerId']
            $buildProperty = $state.PSObject.Properties['expectedBuildId']
            $protocolEncodingProperty = $state.PSObject.Properties['protocolEncoding']
            $protocolHashProperty = $state.PSObject.Properties['protocolSha256']
            $protocolBytesProperty = $state.PSObject.Properties['protocolBytes']
            $journalRunId = try {
                if ($runIdProperty) { [uint64]$runIdProperty.Value } else { 0 }
            } catch { 0 }
            $journalPid = try {
                if ($pidProperty) { [int]$pidProperty.Value } else { 0 }
            } catch { 0 }
            $journalStart = if ($startProperty) { ConvertTo-CocUtcRoundtripText $startProperty.Value } else { '' }
            $journalEndpoint = if ($endpointProperty) { [string]$endpointProperty.Value } else { '' }
            $journalOwner = if ($ownerProperty) { [string]$ownerProperty.Value } else { '' }
            $journalBuild = if ($buildProperty) { [string]$buildProperty.Value } else { '' }
            if ($journalRunId -le 0) { $journalErrors.Add('scenarioRunId is missing or invalid') }
            if ($journalPid -le 0) { $journalErrors.Add('expectedPid is missing or invalid') }
            try {
                $null = [DateTimeOffset]::Parse(
                    $journalStart,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
            catch { $journalErrors.Add('expectedProcessStartTimeUtc is missing or invalid') }
            try { Assert-CocCanonicalEndpoint -Endpoint $journalEndpoint | Out-Null }
            catch { $journalErrors.Add($_.Exception.Message) }
            if ([string]::IsNullOrWhiteSpace($journalOwner)) {
                $journalErrors.Add('ownerId is missing')
            }
            if ($journalBuild -notmatch '^[A-Fa-f0-9]{64}$') {
                $journalErrors.Add('expectedBuildId is missing or invalid')
            }
            if (-not $protocolEncodingProperty -or -not $protocolHashProperty -or
                -not $protocolBytesProperty) {
                $journalErrors.Add('the immutable protocol snapshot is missing')
            }
            if ($journalErrors.Count -gt 0) {
                $result = [pscustomobject][ordered]@{
                    schema = 'csx-coc-stability-control-v1'
                    ok = $false
                    command = 'status'
                    timestampUtc = [DateTime]::UtcNow.ToString('o')
                    state = 'journal-invalid'
                    data = [pscustomobject]@{
                        statePath = $resolvedStatePath
                        ownerId = $journalOwner
                        scenarioRunId = if ($journalRunId -gt 0) { $journalRunId } else { $null }
                        scenario = $null
                        analysis = $null
                    }
                    errors = @($journalErrors)
                }
            }
            else {
                $protocolConfig = Get-CocProtocolFromSnapshot `
                    -Encoding ([string]$protocolEncodingProperty.Value) `
                    -Sha256 ([string]$protocolHashProperty.Value) `
                    -Bytes ([string]$protocolBytesProperty.Value)
                $statusReceipt = Invoke-CocMcpTool -Endpoint $journalEndpoint `
                    -Tool 'scenario' -Arguments @{
                        action = 'status'
                        runId = $journalRunId
                    } -TimeoutSeconds 20 -ExpectedProcessId $journalPid `
                    -ExpectedProcessStartTimeUtc $journalStart `
                    -ExpectedBuildId $journalBuild
                $analysis = Get-CocQualificationAnalysis -Scenario $statusReceipt.value `
                    -ProtocolConfig $protocolConfig -ExpectedOwnerId $journalOwner `
                    -ExpectedBuildId $journalBuild
                $disposition = Get-CocScenarioDisposition `
                    -Scenario $statusReceipt.value -Analysis $analysis
                $result = [pscustomobject][ordered]@{
                    schema = 'csx-coc-stability-control-v1'
                    ok = [bool]$disposition.ok
                    command = 'status'
                    timestampUtc = [DateTime]::UtcNow.ToString('o')
                    state = [string]$disposition.state
                    data = [pscustomobject]@{
                        statePath = $resolvedStatePath
                        ownerId = $journalOwner
                        scenarioRunId = $journalRunId
                        scenario = $statusReceipt.value
                        analysis = $analysis
                    }
                    errors = @($disposition.errors)
                }
            }
        }
    }
    else {
        $phase = 'input-validation'
        if ($ExpectedPid -le 0) { throw 'ExpectedPid is required for run.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedBuildId)) {
            throw 'ExpectedBuildId is required for run.'
        }
        if ([string]::IsNullOrWhiteSpace($CollectorStatePath)) {
            throw 'CollectorStatePath is required for run.'
        }
        if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
            throw 'EvidenceRoot is required for run.'
        }

        Assert-CocCanonicalEndpoint -Endpoint $Endpoint | Out-Null
        $protocolPath = [IO.Path]::GetFullPath($ProtocolConfigPath)
        $protocolSnapshot = New-CocProtocolSnapshot -ProtocolJson (
            [IO.File]::ReadAllText($protocolPath, [Text.UTF8Encoding]::new($false, $true))
        )
        $protocolConfig = $protocolSnapshot.config
        $ownerId = "coc-$([Guid]::NewGuid().ToString('N'))"
        $runDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) $ownerId
        if (Test-Path -LiteralPath $runDirectory) {
            throw "Refusing to reuse evidence directory: $runDirectory"
        }
        New-Item -ItemType Directory -Path $runDirectory | Out-Null
        $resolvedStatePath = Join-Path $runDirectory 'coc-stability-state.json'
        $claimPath = Join-Path $runDirectory 'assay-dispatch.claim'

        try {
            $expectedProcess = Get-Process -Id $ExpectedPid -ErrorAction Stop
            $expectedProcessStartTimeUtc = $expectedProcess.StartTime.ToUniversalTime().ToString('o')
        }
        catch {
            throw "The expected Skyrim process identity is inaccessible: $($_.Exception.Message)"
        }

        $evidenceTool = Join-Path $PSScriptRoot `
            '..\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
        $collectorText = & $evidenceTool status `
            -StatePath $CollectorStatePath -Compact -NoExit
        $collector = $collectorText | ConvertFrom-Json -Depth 50
        $collectorTargetStartUtc = ConvertTo-CocUtcRoundtripText $collector.data.targetStartedUtc
        if (-not [bool]$collector.ok -or
            [string]$collector.state -ne 'armed-attached' -or
            $ExpectedPid -notin @($collector.data.targetPids) -or
            $collectorTargetStartUtc -cne $expectedProcessStartTimeUtc) {
            throw 'The exact Skyrim PID does not have live owned crash coverage.'
        }

        $phase = 'baseline-and-dispatch'
        $originTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $frequency = [Diagnostics.Stopwatch]::Frequency
        $dueTimestamp = $originTimestamp + [long](
            [double]$BaselineDeadlineMs * [double]$frequency / 1000.0
        )
        $scenario = New-CocMeasuredScenario -ProtocolConfig $protocolConfig `
            -ExpectedBuildId $ExpectedBuildId -OwnerId $ownerId
        $fixture = $null
        $fixtureFailure = $null
        $fixtureAnomalies = @()

        $initialState = [pscustomobject][ordered]@{
            schema = 'csx-coc-stability-state-v1'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            outcome = 'dispatch-pending'
            endpoint = $Endpoint
            ownerId = $ownerId
            expectedPid = $ExpectedPid
            expectedProcessStartTimeUtc = $expectedProcessStartTimeUtc
            expectedBuildId = $ExpectedBuildId
            collectorStatePath = [IO.Path]::GetFullPath($CollectorStatePath)
            protocolConfigPath = $protocolPath
            protocolEncoding = $protocolSnapshot.encoding
            protocolSha256 = $protocolSnapshot.sha256
            protocolBytes = $protocolSnapshot.bytes
            baselineDeadlineMs = $BaselineDeadlineMs
            scenarioRunId = $null
            dispatchFailure = [pscustomobject]@{
                error = 'Dispatch has not reached a terminal local admission result.'
            }
        }
        Write-AtomicJson -Value $initialState -Path $resolvedStatePath
        $publishedStatePath = $resolvedStatePath

        $baselineSpecs = [ordered]@{
            state = @('inspect', @{ kind = 'state' })
            scene = @('inspect', @{ kind = 'scene' })
            upscaling = @('communityshaders.upscaling_api', @{
                action = 'snapshot'
                contractMajor = 1
                clientId = $ownerId
                commandId = "$ownerId-baseline-upscaling"
                expectedBuildId = $ExpectedBuildId
            })
            renderscale = @('communityshaders.renderscale', @{
                action = 'status'
                expectedBuildId = $ExpectedBuildId
            })
            image = @('communityshaders.screenshot', @{
                action = 'capture'
                contractMajor = 1
                clientId = $ownerId
                commandId = "$ownerId-baseline-image"
                useSettings = $true
            })
        }
        $baselineJobs = [ordered]@{}
        foreach ($entry in $baselineSpecs.GetEnumerator()) {
            $baselineJobs[$entry.Key] = Start-ThreadJob `
                -Name "$ownerId-baseline-$($entry.Key)" `
                -ScriptBlock $toolJobScript -ArgumentList @(
                    $modulePath, $Endpoint, [string]$entry.Value[0],
                    ($entry.Value[1] | ConvertTo-Json -Depth 30 -Compress), 15,
                    $ExpectedPid, $expectedProcessStartTimeUtc, $ExpectedBuildId
                )
            $ownedJobs.Add($baselineJobs[$entry.Key])
        }

        $baselineResults = @{}
        $baselineTiming = [ordered]@{}
        while ($baselineResults.Count -lt $baselineSpecs.Count -and
            [Diagnostics.Stopwatch]::GetTimestamp() -lt $dueTimestamp) {
            foreach ($entry in $baselineJobs.GetEnumerator()) {
                if (-not $baselineResults.ContainsKey($entry.Key) -and
                    $entry.Value.State -in @('Completed', 'Failed', 'Stopped')) {
                    $jobResult = Get-JobResult $entry.Value
                    $receivedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
                    $completedTimestamp = if ($jobResult.PSObject.Properties['completedTimestamp']) {
                        [long]$jobResult.completedTimestamp
                    } else { $receivedTimestamp }
                    $baselineTiming[$entry.Key] = [pscustomobject][ordered]@{
                        completedTimestamp = $completedTimestamp
                        receivedTimestamp = $receivedTimestamp
                    }
                    $baselineResults[$entry.Key] = if ($completedTimestamp -gt $dueTimestamp) {
                        [pscustomobject]@{
                            incomplete = $true
                            late = $true
                            error = 'baseline admission deadline expired before this check completed'
                            receipt = if ([bool]$jobResult.ok) { $jobResult.receipt } else { $null }
                        }
                    } elseif ([bool]$jobResult.ok) {
                        $jobResult.receipt
                    } else {
                        [pscustomobject]@{ error = [string]$jobResult.error }
                    }
                }
            }
            if ($baselineResults.Count -lt $baselineSpecs.Count) {
                [Threading.Thread]::Sleep(10)
            }
        }

        foreach ($job in @($baselineJobs.Values) |
            Where-Object { $_ -and $_.State -notin @('Completed', 'Failed', 'Stopped') }) {
            Stop-Job -Job $job
        }
        foreach ($entry in $baselineJobs.GetEnumerator()) {
            if (-not $baselineResults.ContainsKey($entry.Key)) {
                $baselineResults[$entry.Key] = [pscustomobject]@{
                    incomplete = $true
                    error = 'baseline admission deadline expired before this check completed'
                }
            }
        }
        $baselineResultSetComplete = @($baselineResults.Values | Where-Object {
                -not $_.PSObject.Properties['error']
            }).Count -eq $baselineSpecs.Count
        $baselineVerdict = $null
        if ($baselineResultSetComplete) {
            try {
                $baselineVerdict = Test-CocBaseline -Results $baselineResults `
                    -ExpectedCell ([string]$protocolConfig.startCellEditorId)
            }
            catch {
                $baselineVerdict = [pscustomobject][ordered]@{
                    acceptable = $false
                    ownershipConflict = $false
                    ownershipConflicts = @()
                    reasons = @("baseline semantic evaluation failed: $($_.Exception.Message)")
                }
            }
        }
        $baselineDecisionTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $baselineTimingVerdict = Test-CocBaselineAdmissionTiming `
            -Timing $baselineTiming -DueTimestamp $dueTimestamp `
            -DecisionTimestamp $baselineDecisionTimestamp `
            -ExpectedCount $baselineSpecs.Count
        $successful = [bool]$baselineTimingVerdict.acceptable -and $baselineResultSetComplete
        $dispatchResult = $null
        if (-not $successful) {
            $dispatchResult = [pscustomobject]@{
                ok = $false
                state = if ($baselineTimingVerdict.decisionLate -or
                    @($baselineTimingVerdict.lateResults).Count -gt 0) {
                    'baseline-deadline-expired'
                } else { 'baseline-incomplete' }
                source = 'baseline-admission'
                error = 'Every baseline ownership and readiness check must complete before scenario mutation.'
            }
        } elseif (-not [bool]$baselineVerdict.acceptable) {
            $dispatchResult = [pscustomobject]@{
                ok = $false
                state = 'dispatch-interrupted'
                source = if ([bool]$baselineVerdict.ownershipConflict) {
                    'baseline-ownership-conflict'
                } else { 'baseline-rejected' }
                error = @($baselineVerdict.reasons) -join '; '
            }
        } else {
            $phase = 'fixture'
            try {
                $fixture = Invoke-CocMcpTool -Endpoint $Endpoint `
                    -Tool 'communityshaders.menu' -Arguments @{
                        action = 'prepare_coc'
                        expectedBuildId = $ExpectedBuildId
                    } -TimeoutSeconds 15 -ExpectedProcessId $ExpectedPid `
                    -ExpectedProcessStartTimeUtc $expectedProcessStartTimeUtc `
                    -ExpectedBuildId $ExpectedBuildId
            }
            catch {
                $fixtureFailure = [pscustomobject][ordered]@{
                    effect = 'unknown'
                    error = $_.Exception.Message
                }
                $dispatchResult = [pscustomobject]@{
                    ok = $false
                    state = 'fixture-call-failed'
                    source = 'fixture-admission'
                    error = $_.Exception.Message
                }
            }
            if ($null -eq $dispatchResult) {
                $fixtureAnomalies = @(Get-CocFixtureAnomalies -Value $fixture.value)
            }
            if ($null -eq $dispatchResult -and $fixtureAnomalies.Count -gt 0) {
                $dispatchResult = [pscustomobject]@{
                    ok = $false
                    state = 'fixture-rejected'
                    source = 'fixture-admission'
                    error = @($fixtureAnomalies) -join '; '
                }
            } elseif ($null -eq $dispatchResult) {
                $claim = New-CocDispatchClaim -Path $claimPath -Source 'baseline-complete'
                if ([string]$claim.state -ne 'dispatch-claimed') {
                    $dispatchResult = $claim
                } else {
                    try {
                        $receipt = Invoke-CocMcpTool -Endpoint $Endpoint `
                            -Tool 'scenario' -Arguments $scenario `
                            -TimeoutSeconds 20 -ExpectedProcessId $ExpectedPid `
                            -ExpectedProcessStartTimeUtc $expectedProcessStartTimeUtc `
                            -ExpectedBuildId $ExpectedBuildId
                        $dispatchResult = [pscustomobject]@{
                            ok = $true
                            state = 'scenario-accepted'
                            source = 'baseline-complete'
                            acceptedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
                            receipt = $receipt
                        }
                    } catch {
                        $dispatchResult = [pscustomobject]@{
                            ok = $false
                            state = if ($_.Exception.Message -like "DevBench tool 'scenario' failed:*") {
                                'scenario-rejected'
                            } else { 'scenario-dispatch-unknown' }
                            source = 'baseline-complete'
                            error = $_.Exception.Message
                        }
                    }
                }
            }
        }
        $dispatchStateProperty = $dispatchResult.PSObject.Properties['state']
        $dispatchSourceProperty = $dispatchResult.PSObject.Properties['source']
        $dispatchErrorProperty = $dispatchResult.PSObject.Properties['error']
        $dispatchState = if ($dispatchStateProperty) {
            [string]$dispatchStateProperty.Value
        } else { 'unknown' }
        $dispatchSource = if ($dispatchSourceProperty) {
            [string]$dispatchSourceProperty.Value
        } else { 'unknown' }
        $dispatchError = if ($dispatchErrorProperty) {
            [string]$dispatchErrorProperty.Value
        } else { 'The dispatch job returned no error detail.' }
        $runIdProperty = if ($dispatchResult.PSObject.Properties['receipt'] -and
            $dispatchResult.receipt -and $dispatchResult.receipt.PSObject.Properties['value'] -and
            $dispatchResult.receipt.value) {
            $dispatchResult.receipt.value.PSObject.Properties['runId']
        } else { $null }
        $scenarioRunId = if ($runIdProperty) {
            try { [uint64]$runIdProperty.Value } catch { $null }
        } else { $null }
        $dispatchAccepted = [bool]$dispatchResult.ok -and
            $dispatchState -eq 'scenario-accepted' -and
            $null -ne $scenarioRunId -and $scenarioRunId -gt 0
        if ([bool]$dispatchResult.ok -and
            $dispatchState -eq 'scenario-accepted' -and -not $dispatchAccepted) {
            $dispatchError = 'The scenario admission receipt omitted a valid run ID.'
            $dispatchState = 'scenario-admission-invalid'
        }
        $acceptedElapsedMs = if ($dispatchAccepted) {
            [Math]::Round(
                ([double]([long]$dispatchResult.acceptedTimestamp -
                        $originTimestamp) * 1000.0 / [double]$frequency), 3
            )
        } else { $null }
        $stateRecord = [pscustomobject][ordered]@{
            schema = 'csx-coc-stability-state-v1'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            outcome = if ($dispatchAccepted) { 'scenario-accepted' } else { $dispatchState }
            endpoint = $Endpoint
            ownerId = $ownerId
            expectedPid = $ExpectedPid
            expectedProcessStartTimeUtc = $expectedProcessStartTimeUtc
            expectedBuildId = $ExpectedBuildId
            collectorStatePath = [IO.Path]::GetFullPath($CollectorStatePath)
            protocolConfigPath = $protocolPath
            protocolEncoding = $protocolSnapshot.encoding
            protocolSha256 = $protocolSnapshot.sha256
            protocolBytes = $protocolSnapshot.bytes
            baselineDeadlineMs = $BaselineDeadlineMs
            dispatchSource = $dispatchSource
            dispatchState = $dispatchState
            dispatchAcceptedElapsedMs = $acceptedElapsedMs
            scenarioRunId = $scenarioRunId
            dispatchFailure = if ($dispatchAccepted) { $null } else {
                [pscustomobject][ordered]@{
                    error = $dispatchError
                    detail = $dispatchResult
                }
            }
            fixture = if ($fixture) { $fixture.value } else { $null }
            fixtureFailure = $fixtureFailure
            fixtureAnomalies = @($fixtureAnomalies)
            baseline = $baselineResults
            baselineTiming = $baselineTiming
            baselineTimingVerdict = $baselineTimingVerdict
            baselineVerdict = $baselineVerdict
        }
        $failureData = [pscustomobject][ordered]@{
            phase = 'state-publication'
            nextAction = if ($dispatchAccepted) {
                'reconcile_exact_accepted_run_before_retry'
            } else { 'inspect_retained_dispatch_state' }
            statePath = $resolvedStatePath
            ownerId = $ownerId
            scenarioRunId = $scenarioRunId
            endpoint = $Endpoint
            expectedPid = $ExpectedPid
            expectedProcessStartTimeUtc = $expectedProcessStartTimeUtc
            dispatchState = $dispatchState
            dispatchReceipt = if ($dispatchResult.PSObject.Properties['receipt']) {
                $dispatchResult.receipt
            } else { $null }
            dispatchFailure = if ($dispatchAccepted) { $null } else {
                [pscustomobject][ordered]@{
                    error = $dispatchError
                    detail = $dispatchResult
                }
            }
            fixture = if ($fixture) { $fixture.value } else { $null }
            fixtureFailure = $fixtureFailure
            fixtureAnomalies = @($fixtureAnomalies)
            baseline = $baselineResults
            baselineTiming = $baselineTiming
            baselineTimingVerdict = $baselineTimingVerdict
            baselineVerdict = $baselineVerdict
        }
        Write-AtomicJson -Value $stateRecord -Path $resolvedStatePath
        $publishedStatePath = $resolvedStatePath
        if (-not $dispatchAccepted) {
            throw "The measured scenario was not accepted: $dispatchError"
        }
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-stability-control-v1'
            ok = $true
            command = 'run'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = 'scenario-accepted'
            data = [pscustomobject]@{
                ownerId = $ownerId
                scenarioRunId = $scenarioRunId
                statePath = $resolvedStatePath
                dispatchSource = $dispatchSource
                dispatchAcceptedElapsedMs = $acceptedElapsedMs
                baselineDeadlineMs = $BaselineDeadlineMs
                fixtureAnomalies = @($fixtureAnomalies)
                baseline = $baselineResults
                baselineVerdict = $baselineVerdict
            }
            errors = @()
        }
        $failureData = $null
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-control-v1'
        ok = $false
        command = $Command
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = 'blocked-awaiting-user'
        data = if ($failureData) { $failureData } else {
            [pscustomobject]@{
                phase = $phase
                nextAction = 'ask_user'
                statePath = $publishedStatePath
            }
        }
        errors = @($_.Exception.Message)
    }
}
finally {
    foreach ($job in @($ownedJobs)) {
        if ($null -eq $job) { continue }
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

$json = @{ InputObject = $result; Depth = 100 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
