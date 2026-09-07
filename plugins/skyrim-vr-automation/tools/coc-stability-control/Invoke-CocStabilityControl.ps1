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

function Get-JobResult($Job) {
    if ($Job.State -eq 'Completed') {
        return @(Receive-Job -Job $Job -Keep | Select-Object -Last 1)[0]
    }
    $reason = if ($Job.ChildJobs.Count -gt 0 -and $Job.ChildJobs[0].JobStateInfo.Reason) {
        $Job.ChildJobs[0].JobStateInfo.Reason.Message
    } else {
        "job state is $($Job.State)"
    }
    return [pscustomobject]@{ ok = $false; error = $reason }
}

$toolJobScript = {
    param(
        $ModulePath, $Endpoint, $Tool, $ArgumentsJson, $TimeoutSeconds,
        $ExpectedProcessId, $ExpectedProcessStartTimeUtc
    )
    $ErrorActionPreference = 'Stop'
    try {
        Import-Module $ModulePath -Force
        $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 50
        $value = Invoke-CocMcpTool -Endpoint $Endpoint -Tool $Tool `
            -Arguments $arguments -TimeoutSeconds $TimeoutSeconds `
            -ExpectedProcessId $ExpectedProcessId `
            -ExpectedProcessStartTimeUtc $ExpectedProcessStartTimeUtc
        [pscustomobject]@{ ok = $true; receipt = $value }
    }
    catch {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

$dispatchJobScript = {
    param(
        $ModulePath, $Endpoint, $ScenarioJson, $ClaimPath, $AbortPath, $Source,
        [long]$DueTimestamp, [long]$Frequency, $ExpectedProcessId,
        $ExpectedProcessStartTimeUtc
    )
    $ErrorActionPreference = 'Stop'
    if ($DueTimestamp -gt 0) {
        while ($true) {
            $remainingTicks = $DueTimestamp - [Diagnostics.Stopwatch]::GetTimestamp()
            if ($remainingTicks -le 0) { break }
            $remainingMs = [double]$remainingTicks * 1000.0 / [double]$Frequency
            [Threading.Thread]::Sleep([Math]::Max(1, [Math]::Min(25, [int]$remainingMs)))
        }
    }

    if (Test-Path -LiteralPath $AbortPath -PathType Leaf) {
        return [pscustomobject]@{
            ok = $false
            state = 'dispatch-interrupted'
            source = $Source
            error = Get-Content -LiteralPath $AbortPath -Raw
        }
    }

    Import-Module $ModulePath -Force
    $claimResult = New-CocDispatchClaim -Path $ClaimPath -Source $Source
    if ([string]$claimResult.state -ne 'dispatch-claimed') {
        return $claimResult
    }

    try {
        $scenario = $ScenarioJson | ConvertFrom-Json -AsHashtable -Depth 100
        $receipt = Invoke-CocMcpTool -Endpoint $Endpoint -Tool 'scenario' `
            -Arguments $scenario -TimeoutSeconds 20 `
            -ExpectedProcessId $ExpectedProcessId `
            -ExpectedProcessStartTimeUtc $ExpectedProcessStartTimeUtc
        return [pscustomobject]@{
            ok = $true
            state = 'scenario-accepted'
            source = $Source
            acceptedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
            receipt = $receipt
        }
    }
    catch {
        $dispatchError = $_.Exception.Message
        $dispatchState = if ($dispatchError -like "DevBench tool 'scenario' failed:*") {
            'scenario-rejected'
        } else { 'scenario-dispatch-unknown' }
        return [pscustomobject]@{
            ok = $false
            state = $dispatchState
            source = $Source
            error = $dispatchError
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
            $journalRunId = try {
                if ($runIdProperty) { [uint64]$runIdProperty.Value } else { 0 }
            } catch { 0 }
            $journalPid = try {
                if ($pidProperty) { [int]$pidProperty.Value } else { 0 }
            } catch { 0 }
            $journalStart = if ($startProperty) { [string]$startProperty.Value } else { '' }
            $journalEndpoint = if ($endpointProperty) { [string]$endpointProperty.Value } else { '' }
            $journalOwner = if ($ownerProperty) { [string]$ownerProperty.Value } else { '' }
            $journalUri = $null
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
            if (-not [Uri]::TryCreate($journalEndpoint, [UriKind]::Absolute, [ref]$journalUri) -or
                -not $journalUri.IsLoopback -or $journalUri.Scheme -cne 'http') {
                $journalErrors.Add('endpoint is not an absolute loopback HTTP URI')
            }
            if ([string]::IsNullOrWhiteSpace($journalOwner)) {
                $journalErrors.Add('ownerId is missing')
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
                $protocolConfig = Get-Content -LiteralPath ([string]$state.protocolConfigPath) -Raw |
                    ConvertFrom-Json -Depth 30
                $statusReceipt = Invoke-CocMcpTool -Endpoint $journalEndpoint `
                    -Tool 'scenario' -Arguments @{
                        action = 'status'
                        runId = $journalRunId
                    } -TimeoutSeconds 20 -ExpectedProcessId $journalPid `
                    -ExpectedProcessStartTimeUtc $journalStart
                $analysis = Get-CocQualificationAnalysis -Scenario $statusReceipt.value `
                    -ProtocolConfig $protocolConfig -ExpectedOwnerId $journalOwner
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

        $protocolConfig = Get-Content -LiteralPath ([IO.Path]::GetFullPath(
            $ProtocolConfigPath
        )) -Raw | ConvertFrom-Json -Depth 30
        if ([string]$protocolConfig.schema -ne 'csx-coc-stability-protocol-v1') {
            throw 'The COC stability protocol config schema is unsupported.'
        }
        $ownerId = "coc-$([Guid]::NewGuid().ToString('N'))"
        $runDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) $ownerId
        if (Test-Path -LiteralPath $runDirectory) {
            throw "Refusing to reuse evidence directory: $runDirectory"
        }
        New-Item -ItemType Directory -Path $runDirectory | Out-Null
        $resolvedStatePath = Join-Path $runDirectory 'coc-stability-state.json'
        $claimPath = Join-Path $runDirectory 'assay-dispatch.claim'
        $abortPath = Join-Path $runDirectory 'assay-dispatch.abort'

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
        if (-not [bool]$collector.ok -or
            [string]$collector.state -ne 'armed-attached' -or
            $ExpectedPid -notin @($collector.data.targetPids) -or
            [string]$collector.data.targetStartedUtc -cne $expectedProcessStartTimeUtc) {
            throw 'The exact Skyrim PID does not have live owned crash coverage.'
        }

        $phase = 'fixture'
        $fixture = Invoke-CocMcpTool -Endpoint $Endpoint `
            -Tool 'communityshaders.menu' -Arguments @{
                action = 'prepare_coc'
                expectedBuildId = $ExpectedBuildId
            } -TimeoutSeconds 15 -ExpectedProcessId $ExpectedPid `
            -ExpectedProcessStartTimeUtc $expectedProcessStartTimeUtc
        $fixtureAnomalies = [Collections.Generic.List[string]]::new()
        if ($null -eq $fixture.value) {
            $fixtureAnomalies.Add('prepare_coc returned no fixture receipt')
        }
        elseif (@('ready', 'persisted', 'promptRequired') | Where-Object {
                $null -eq $fixture.value.PSObject.Properties[$_]
            }) {
            $fixtureAnomalies.Add('prepare_coc omitted a required fixture field')
        }
        elseif (-not [bool]$fixture.value.ready) {
            $fixtureAnomalies.Add('prepare_coc reported ready:false')
        }
        elseif ([bool]$fixture.value.persisted) {
            $fixtureAnomalies.Add('prepare_coc reported persisted:true')
        }
        elseif ([bool]$fixture.value.promptRequired) {
            $fixtureAnomalies.Add('prepare_coc reported promptRequired:true')
        }

        $phase = 'baseline-and-dispatch'
        $originTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $frequency = [Diagnostics.Stopwatch]::Frequency
        $dueTimestamp = $originTimestamp + [long](
            [double]$BaselineDeadlineMs * [double]$frequency / 1000.0
        )
        $scenario = New-CocMeasuredScenario -ProtocolConfig $protocolConfig `
            -ExpectedBuildId $ExpectedBuildId -OwnerId $ownerId
        $scenarioJson = $scenario | ConvertTo-Json -Depth 100 -Compress

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
            protocolConfigPath = [IO.Path]::GetFullPath($ProtocolConfigPath)
            baselineDeadlineMs = $BaselineDeadlineMs
            scenarioRunId = $null
            dispatchFailure = [pscustomobject]@{
                error = 'Dispatch has not reached a terminal local admission result.'
            }
        }
        Write-AtomicJson -Value $initialState -Path $resolvedStatePath
        $publishedStatePath = $resolvedStatePath

        $watchdogJob = Start-ThreadJob -Name "$ownerId-watchdog" `
            -ScriptBlock $dispatchJobScript -ArgumentList @(
                $modulePath, $Endpoint, $scenarioJson, $claimPath, $abortPath,
                'deadline', $dueTimestamp, $frequency, $ExpectedPid,
                $expectedProcessStartTimeUtc
            )
        $ownedJobs.Add($watchdogJob)
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
                    $ExpectedPid, $expectedProcessStartTimeUtc
                )
            $ownedJobs.Add($baselineJobs[$entry.Key])
        }

        $baselineResults = @{}
        $baselineVerdict = $null
        $earlyJob = $null
        $dispatchResult = $null
        while (-not $dispatchResult) {
            foreach ($entry in $baselineJobs.GetEnumerator()) {
                if (-not $baselineResults.ContainsKey($entry.Key) -and
                    $entry.Value.State -in @('Completed', 'Failed', 'Stopped')) {
                    $jobResult = Get-JobResult $entry.Value
                    $baselineResults[$entry.Key] = if ([bool]$jobResult.ok) {
                        $jobResult.receipt
                    } else {
                        [pscustomobject]@{ error = [string]$jobResult.error }
                    }
                }
            }

            if (-not $earlyJob -and $baselineResults.Count -eq $baselineSpecs.Count) {
                $successful = @($baselineResults.Values | Where-Object {
                    -not $_.PSObject.Properties['error']
                }).Count -eq $baselineSpecs.Count
                if ($successful) {
                    $baselineVerdict = Test-CocBaseline -Results $baselineResults `
                        -ExpectedCell ([string]$protocolConfig.startCellEditorId)
                    if ([bool]$baselineVerdict.ownershipConflict) {
                        $conflictError = @($baselineVerdict.ownershipConflicts) -join '; '
                        [IO.File]::WriteAllText($abortPath, $conflictError)
                        if ($watchdogJob.State -notin @('Completed', 'Failed', 'Stopped')) {
                            Stop-Job -Job $watchdogJob
                        }
                        $dispatchResult = [pscustomobject]@{
                            ok = $false
                            state = 'dispatch-interrupted'
                            source = 'baseline-ownership-conflict'
                            error = $conflictError
                        }
                    }
                    elseif ($fixtureAnomalies.Count -eq 0 -and
                        [bool]$baselineVerdict.acceptable -and
                        [Diagnostics.Stopwatch]::GetTimestamp() -lt $dueTimestamp) {
                        $earlyJob = Start-ThreadJob -Name "$ownerId-early" `
                            -ScriptBlock $dispatchJobScript -ArgumentList @(
                                $modulePath, $Endpoint, $scenarioJson, $claimPath,
                                $abortPath, 'baseline-complete', 0L, $frequency,
                                $ExpectedPid, $expectedProcessStartTimeUtc
                            )
                        $ownedJobs.Add($earlyJob)
                    }
                }
            }

            if (-not $dispatchResult) {
                foreach ($job in @($earlyJob, $watchdogJob) | Where-Object { $_ }) {
                    if ($job.State -in @('Completed', 'Failed', 'Stopped')) {
                        $candidate = Get-JobResult $job
                        $candidateState = $candidate.PSObject.Properties['state']
                        if (-not $candidateState -or
                            [string]$candidateState.Value -ne 'dispatch-already-claimed') {
                            $dispatchResult = $candidate
                            break
                        }
                    }
                }
            }
            if (-not $dispatchResult) {
                $dispatchJobs = @($earlyJob, $watchdogJob) | Where-Object { $_ }
                if ($dispatchJobs.Count -gt 0 -and
                    @($dispatchJobs | Where-Object {
                            $_.State -notin @('Completed', 'Failed', 'Stopped')
                        }).Count -eq 0) {
                    $dispatchResult = [pscustomobject]@{
                        ok = $false
                        state = 'dispatch-claim-unresolved'
                        source = 'coordinator'
                        error = 'Every dispatch claimant terminated without a valid winner.'
                    }
                }
            }
            if (-not $dispatchResult) { [Threading.Thread]::Sleep(10) }
        }

        foreach ($job in @($baselineJobs.Values) + @($earlyJob, $watchdogJob) |
            Where-Object { $_ -and $_.State -notin @('Completed', 'Failed', 'Stopped') }) {
            Stop-Job -Job $job
        }
        foreach ($entry in $baselineJobs.GetEnumerator()) {
            if (-not $baselineResults.ContainsKey($entry.Key)) {
                $baselineResults[$entry.Key] = [pscustomobject]@{
                    incomplete = $true
                    reason = 'assay dispatch deadline reached first'
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
            protocolConfigPath = [IO.Path]::GetFullPath($ProtocolConfigPath)
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
            fixture = $fixture.value
            fixtureAnomalies = @($fixtureAnomalies)
            baseline = $baselineResults
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
