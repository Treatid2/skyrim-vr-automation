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

function Write-AtomicJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path
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
    param($ModulePath, $Endpoint, $Tool, $ArgumentsJson, $TimeoutSeconds)
    $ErrorActionPreference = 'Stop'
    try {
        Import-Module $ModulePath -Force
        $arguments = $ArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 50
        $value = Invoke-CocMcpTool -Endpoint $Endpoint -Tool $Tool `
            -Arguments $arguments -TimeoutSeconds $TimeoutSeconds
        [pscustomobject]@{ ok = $true; receipt = $value }
    }
    catch {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    }
}

$dispatchJobScript = {
    param(
        $ModulePath, $Endpoint, $ScenarioJson, $ClaimPath, $Source,
        [long]$DueTimestamp, [long]$Frequency
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

    $claim = $null
    try {
        $claim = [IO.File]::Open(
            $ClaimPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read
        )
        $writer = [IO.StreamWriter]::new($claim)
        $writer.Write($Source)
        $writer.Flush()
        $writer.Dispose()
        $claim = $null
    }
    catch [IO.IOException] {
        if ($claim) { $claim.Dispose() }
        return [pscustomobject]@{ ok = $true; state = 'dispatch-already-claimed'; source = $Source }
    }

    try {
        Import-Module $ModulePath -Force
        $scenario = $ScenarioJson | ConvertFrom-Json -AsHashtable -Depth 100
        $receipt = Invoke-CocMcpTool -Endpoint $Endpoint -Tool 'scenario' `
            -Arguments $scenario -TimeoutSeconds 20
        return [pscustomobject]@{
            ok = $true
            state = 'scenario-accepted'
            source = $Source
            acceptedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
            receipt = $receipt
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false
            state = 'scenario-rejected'
            source = $Source
            error = $_.Exception.Message
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
        $protocolConfig = Get-Content -LiteralPath ([string]$state.protocolConfigPath) -Raw |
            ConvertFrom-Json -Depth 30
        $statusReceipt = Invoke-CocMcpTool -Endpoint ([string]$state.endpoint) `
            -Tool 'scenario' -Arguments @{
                action = 'status'
                runId = [uint64]$state.scenarioRunId
            } -TimeoutSeconds 20
        $scenarioDone = [bool]$statusReceipt.value.done
        $scenarioOk = -not $scenarioDone -or [bool]$statusReceipt.value.ok
        $analysis = Get-CocQualificationAnalysis -Scenario $statusReceipt.value `
            -ProtocolConfig $protocolConfig
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-stability-control-v1'
            ok = $scenarioOk
            command = 'status'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if (-not $scenarioDone) {
                'running'
            } elseif ($scenarioOk) {
                'complete'
            } else {
                'failed'
            }
            data = [pscustomobject]@{
                statePath = $resolvedStatePath
                ownerId = [string]$state.ownerId
                scenarioRunId = [uint64]$state.scenarioRunId
                scenario = $statusReceipt.value
                analysis = $analysis
            }
            errors = if ($scenarioOk) { @() } else { @([string]$statusReceipt.value.error) }
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

        $evidenceTool = Join-Path $PSScriptRoot `
            '..\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
        $collectorText = & $evidenceTool status `
            -StatePath $CollectorStatePath -Compact -NoExit
        $collector = $collectorText | ConvertFrom-Json -Depth 50
        if (-not [bool]$collector.ok -or
            [string]$collector.state -ne 'armed-attached' -or
            $ExpectedPid -notin @($collector.data.targetPids)) {
            throw 'The exact Skyrim PID does not have live owned crash coverage.'
        }

        $phase = 'fixture'
        $fixture = Invoke-CocMcpTool -Endpoint $Endpoint `
            -Tool 'communityshaders.menu' -Arguments @{
                action = 'prepare_coc'
                expectedBuildId = $ExpectedBuildId
            } -TimeoutSeconds 15
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

        $watchdogJob = Start-ThreadJob -Name "$ownerId-watchdog" `
            -ScriptBlock $dispatchJobScript -ArgumentList @(
                $modulePath, $Endpoint, $scenarioJson, $claimPath,
                'deadline', $dueTimestamp, $frequency
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
                    ($entry.Value[1] | ConvertTo-Json -Depth 30 -Compress), 15
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
                    if ($fixtureAnomalies.Count -eq 0 -and
                        [bool]$baselineVerdict.acceptable -and
                        [Diagnostics.Stopwatch]::GetTimestamp() -lt $dueTimestamp) {
                        $earlyJob = Start-ThreadJob -Name "$ownerId-early" `
                            -ScriptBlock $dispatchJobScript -ArgumentList @(
                                $modulePath, $Endpoint, $scenarioJson, $claimPath,
                                'baseline-complete', 0L, $frequency
                            )
                        $ownedJobs.Add($earlyJob)
                    }
                }
            }

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
        if (-not [bool]$dispatchResult.ok -or
            [string]$dispatchResult.state -ne 'scenario-accepted') {
            throw "The measured scenario was not accepted: $($dispatchResult.error)"
        }
        $scenarioRunId = [uint64]$dispatchResult.receipt.value.runId
        $acceptedElapsedMs = [Math]::Round(
            ([double]([long]$dispatchResult.acceptedTimestamp - $originTimestamp) *
                1000.0 / [double]$frequency), 3
        )
        $stateRecord = [pscustomobject][ordered]@{
            schema = 'csx-coc-stability-state-v1'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            endpoint = $Endpoint
            ownerId = $ownerId
            expectedPid = $ExpectedPid
            expectedBuildId = $ExpectedBuildId
            collectorStatePath = [IO.Path]::GetFullPath($CollectorStatePath)
            protocolConfigPath = [IO.Path]::GetFullPath($ProtocolConfigPath)
            baselineDeadlineMs = $BaselineDeadlineMs
            dispatchSource = [string]$dispatchResult.source
            dispatchAcceptedElapsedMs = $acceptedElapsedMs
            scenarioRunId = $scenarioRunId
            fixture = $fixture.value
            fixtureAnomalies = @($fixtureAnomalies)
            baseline = $baselineResults
            baselineVerdict = $baselineVerdict
        }
        Write-AtomicJson -Value $stateRecord -Path $resolvedStatePath
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
                dispatchSource = [string]$dispatchResult.source
                dispatchAcceptedElapsedMs = $acceptedElapsedMs
                baselineDeadlineMs = $BaselineDeadlineMs
                fixtureAnomalies = @($fixtureAnomalies)
                baseline = $baselineResults
                baselineVerdict = $baselineVerdict
            }
            errors = @()
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        schema = 'csx-coc-stability-control-v1'
        ok = $false
        command = $Command
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = 'blocked-awaiting-user'
        data = [pscustomobject]@{
            phase = $phase
            nextAction = 'ask_user'
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
