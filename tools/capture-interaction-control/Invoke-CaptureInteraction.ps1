# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('capabilities', 'start', 'status', 'observe', 'act', 'wait-save', 'stop', 'abort')]
    [string]$Command,
    [string]$SessionPath,
    [string]$SessionDirectory,
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [ValidateSet('none', 'on-demand', 'sequence')]
    [string]$VisualMode = 'on-demand',
    [ValidateSet('left_eye', 'right_eye', 'side_by_side', 'framed_combined', 'source_native')]
    [string]$PreferredView = 'left_eye',
    [ValidateRange(10, 5000)][int]$RecordIntervalMs = 50,
    [ValidateRange(50, 60000)][int]$FrameIntervalMs = 500,
    [ValidateRange(1, 10000)][int]$MaximumFrames = 7200,
    [ValidateRange(1, 120)][int]$CaptureTimeoutSeconds = 20,
    [ValidateRange(1, 55)][int]$ActionTimeoutSeconds = 15,
    [switch]$AllowNoPlayer,
    [string]$ActionName,
    [string]$ActionArgumentsJson = '{}',
    [string]$DirectTool,
    [string]$DirectArgumentsJson = '{}',
    [switch]$ObserveAfterAction,
    [string]$SaveDirectory,
    [string]$SaveNamePattern = '*',
    [string]$SinceUtc,
    [ValidateRange(0, 10000)][int]$SaveStableMilliseconds = 1000,
    [ValidateRange(1, 55)][int]$WaitTimeoutSeconds = 30,
    [ValidateRange(100, 5000)][int]$WaitPollMilliseconds = 500,
    [string]$DevBenchScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1'),
    [switch]$SkipRuntimeIdentityVerification,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CaptureInteractionControl.psm1') -Force

$stateFileName = 'capture-interaction.session.json'
$screenshotTool = 'communityshaders.screenshot'

function Write-JsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Resolve-StatePath([switch]$ForCreate) {
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) { return [IO.Path]::GetFullPath($SessionPath) }
    if (-not [string]::IsNullOrWhiteSpace($SessionDirectory)) { return Join-Path ([IO.Path]::GetFullPath($SessionDirectory)) $stateFileName }
    if ($ForCreate) { throw '-SessionDirectory or -SessionPath is required for start.' }
    throw '-SessionPath or -SessionDirectory is required.'
}

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Capture interaction session does not exist: $Path" }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 80
    if ([string]$state.contractVersion -ne '1.0.0') { throw "Unsupported capture interaction session contract '$($state.contractVersion)'." }
    return $state
}

function Convert-Arguments([string]$Json, [string]$Label) {
    try { return $Json | ConvertFrom-Json -AsHashtable -Depth 80 -ErrorAction Stop }
    catch { throw "$Label is invalid JSON: $($_.Exception.Message)" }
}

function Invoke-DevBench([string]$Tool, [hashtable]$Arguments, [string]$Runtime, [switch]$RequireSuccess) {
    if (-not (Test-Path -LiteralPath $DevBenchScriptPath -PathType Leaf)) { throw "DevBench controller does not exist: $DevBenchScriptPath" }
    $parameters = @{
        Tool = $Tool
        ArgumentsJson = ($Arguments | ConvertTo-Json -Depth 80 -Compress)
        RuntimePath = $Runtime
        Compact = $true
        NoExit = $true
    }
    if ($RequireSuccess) { $parameters['RequireSuccess'] = $true }
    if ($SkipRuntimeIdentityVerification) { $parameters['SkipRuntimeIdentityVerification'] = $true }
    $raw = & $DevBenchScriptPath call @parameters
    $response = $raw | ConvertFrom-Json -Depth 100
    if (-not $response.ok) { throw "DevBench tool '$Tool' failed: $(@($response.errors) -join '; ')" }
    $content = @($response.data.content)
    if ($content.Count -lt 1) { throw "DevBench tool '$Tool' returned no content." }
    return [pscustomobject][ordered]@{ value = $content[0]; envelope = $response }
}

function Invoke-Probe([string]$Tool, [hashtable]$Arguments, [string]$Runtime) {
    try {
        $call = Invoke-DevBench -Tool $Tool -Arguments $Arguments -Runtime $Runtime
        return [pscustomobject][ordered]@{ ok = $true; value = $call.value; error = $null }
    }
    catch { return [pscustomobject][ordered]@{ ok = $false; value = $null; error = $_.Exception.Message } }
}

function Wait-VRActionTerminal($Accepted, $State) {
    if (-not $Accepted.PSObject.Properties['generation']) { throw 'Accepted VR action did not return a generation.' }
    $generation = [uint64]$Accepted.generation
    $deadline = [DateTime]::UtcNow.AddSeconds($ActionTimeoutSeconds)
    do {
        $status = (Invoke-DevBench -Tool 'input' -Arguments @{ action='status'; device='vrTrackedSet' } -Runtime ([string]$State.runtimePath) -RequireSuccess).value
        if (-not [bool]$status.active) {
            if ([uint64]$status.generation -lt $generation) { throw "VR action generation $generation disappeared before activation." }
            return $status
        }
        if ([uint64]$status.generation -gt $generation) { throw "VR action generation $generation was superseded by generation $($status.generation)." }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VR action generation $generation did not become terminal within $ActionTimeoutSeconds seconds."
}

function New-ScreenshotCommand([string]$SessionId, [string]$Action) {
    return [ordered]@{
        contractMajor = 1
        contractMinor = 0
        action = $Action
        clientId = "capture-interaction/$SessionId"
        commandId = [guid]::NewGuid().ToString('N')
    }
}

function New-CaptureDescriptor([string]$Directory, [string]$BaseName, [string]$SessionId) {
    return [ordered]@{
        source = [ordered]@{ kind = 'hmd_submission'; fallback = 'reject' }
        outputs = @(
            [ordered]@{ view = 'left_eye'; nameSuffix = 'left'; encoding = [ordered]@{ format = 'png'; colourContract = 'sdr_srgb' } },
            [ordered]@{ view = 'right_eye'; nameSuffix = 'right'; encoding = [ordered]@{ format = 'png'; colourContract = 'sdr_srgb' } }
        )
        destination = [ordered]@{ policy = 'absolute'; directory = $Directory; baseName = $BaseName; overwrite = 'never' }
        clipboard = 'none'
        tags = [ordered]@{ captureInteractionSessionId = $SessionId }
    }
}

function Get-ScreenshotReceipt([string]$RequestId, $State) {
    $arguments = New-ScreenshotCommand ([string]$State.sessionId) 'request_get'
    $arguments['requestId'] = $RequestId
    $call = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$State.runtimePath)
    $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $call.value | Select-Object -First 1)
    if ($receipt.Count -ne 1) { throw "Screenshot request_get did not expose receipt '$RequestId'." }
    return $receipt[0]
}

function Wait-ScreenshotTerminal([string]$RequestId, $State) {
    $deadline = [DateTime]::UtcNow.AddSeconds($CaptureTimeoutSeconds)
    do {
        $receipt = Get-ScreenshotReceipt -RequestId $RequestId -State $State
        if ($receipt.PSObject.Properties['terminal'] -and [bool]$receipt.terminal) { return $receipt }
        if ([string]$receipt.state -in @('completed', 'completed_with_warnings', 'stopped', 'cancelled', 'cancelled_partial', 'failed', 'failed_partial', 'rejected')) { return $receipt }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Screenshot request '$RequestId' did not become terminal within $CaptureTimeoutSeconds seconds."
}

function Start-OnDemandCapture($State) {
    $arguments = New-ScreenshotCommand ([string]$State.sessionId) 'capture'
    $arguments['useSettings'] = $false
    $baseName = 'observe-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $arguments['capture'] = New-CaptureDescriptor ([string]$State.framesDirectory) $baseName ([string]$State.sessionId)
    $call = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$State.runtimePath) -RequireSuccess
    $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $call.value | Select-Object -First 1)
    if ($receipt.Count -ne 1) { throw 'Screenshot capture did not expose an accepted request receipt.' }
    return Wait-ScreenshotTerminal -RequestId ([string]$receipt[0].requestId) -State $State
}

function Get-CompositeObservation($State, [switch]$CaptureOnDemand) {
    $record = Invoke-Probe 'record' @{ action = 'status' } ([string]$State.runtimePath)
    $menus = Invoke-Probe 'menu' @{ action = 'list' } ([string]$State.runtimePath)
    $game = Invoke-Probe 'inspect' @{ kind = 'state' } ([string]$State.runtimePath)
    $inputStatus = Invoke-Probe 'input' @{ action = 'status'; device = 'vrTrackedSet' } ([string]$State.runtimePath)
    $trackedSet = Invoke-Probe 'input' @{ action = 'observe'; device = 'vrTrackedSet' } ([string]$State.runtimePath)
    $screenshotReceipt = $null
    $screenshotError = $null
    try {
        if ([string]$State.visualMode -eq 'sequence' -and $State.screenshot.requestId) {
            $screenshotReceipt = Get-ScreenshotReceipt -RequestId ([string]$State.screenshot.requestId) -State $State
        }
        elseif ([string]$State.visualMode -eq 'on-demand' -and $CaptureOnDemand) {
            $screenshotReceipt = Start-OnDemandCapture -State $State
        }
    }
    catch { $screenshotError = $_.Exception.Message }
    $latest = if ($screenshotReceipt) { Get-CaptureInteractionLatestFrame -Receipt $screenshotReceipt -PreferredView ([string]$State.preferredView) } else { $null }
    $observationId = [guid]::NewGuid().ToString('N')
    $observation = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'
        observationId = $observationId
        captureInteractionSessionId = [string]$State.sessionId
        observedUtc = [DateTime]::UtcNow.ToString('o')
        latestFrame = $latest
        frameSubmission = $(if ($latest) { [pscustomobject][ordered]@{ kind = 'image-file'; path = [string]$latest.path; mimeType = 'image/png'; view = [string]$latest.view; observationId = $observationId; ordinal = $latest.ordinal; engineFrame = $latest.engineFrame } } else { $null })
        screenshot = [pscustomobject][ordered]@{ mode = [string]$State.visualMode; receipt = $screenshotReceipt; error = $screenshotError }
        recording = $record
        game = $game
        menus = $menus
        input = [pscustomobject][ordered]@{ status = $inputStatus; trackedSet = $trackedSet }
    }
    $observationPath = Join-Path ([string]$State.sessionDirectory) 'latest-observation.json'
    Write-JsonAtomic -Path $observationPath -Value $observation
    return [pscustomobject][ordered]@{ observation = $observation; observationPath = $observationPath }
}

function Add-ActionLog($State, $Entry) {
    $path = Join-Path ([string]$State.sessionDirectory) 'actions.ndjson'
    $line = $Entry | ConvertTo-Json -Depth 80 -Compress
    [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    return $path
}

try {
    if ($Command -eq 'capabilities') {
        if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw '-RuntimePath or CSX_DEVBENCH_RUNTIME_PATH is required.' }
        $catalog = Get-CaptureInteractionActionCatalog
        $input = Invoke-Probe 'input' @{ action = 'capabilities' } $RuntimePath
        $screenshots = Invoke-Probe $screenshotTool (New-ScreenshotCommand 'capabilities' 'capabilities') $RuntimePath
        $data = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; visualModes = @('none', 'on-demand', 'sequence')
            actions = $catalog; directToolPassthrough = $true; input = $input; screenshots = $screenshots
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'capabilities'; data = $data; errors = @() }
    }
    elseif ($Command -eq 'start') {
        if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw '-RuntimePath or CSX_DEVBENCH_RUNTIME_PATH is required.' }
        $resolvedStatePath = Resolve-StatePath -ForCreate
        $resolvedSessionDirectory = Split-Path -Parent $resolvedStatePath
        if (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf) { throw "Refusing to overwrite an existing session: $resolvedStatePath" }
        New-Item -ItemType Directory -Path $resolvedSessionDirectory -Force | Out-Null
        $framesDirectory = Join-Path $resolvedSessionDirectory 'frames'
        if ($VisualMode -ne 'none') { New-Item -ItemType Directory -Path $framesDirectory -Force | Out-Null }
        $sessionId = [guid]::NewGuid().ToString()
        $recordCall = Invoke-DevBench -Tool 'record' -Arguments @{ action = 'start'; intervalMs = $RecordIntervalMs; allowNoPlayer = [bool]$AllowNoPlayer; correlationId = $sessionId } -Runtime $RuntimePath -RequireSuccess
        $screenshotState = [pscustomobject][ordered]@{ requestId = $null; startReceipt = $null }
        try {
            if ($VisualMode -eq 'sequence') {
                $arguments = New-ScreenshotCommand $sessionId 'sequence_start'
                $arguments['sequence'] = [ordered]@{
                    frameCount = $MaximumFrames
                    useSettings = $false
                    schedule = [ordered]@{ basis = 'wall_clock'; intervalMs = $FrameIntervalMs; startDelayMs = 0; pausePolicy = 'hold' }
                    backpressure = [ordered]@{ policy = 'skip'; maximumConsecutiveSkips = 20 }
                    failurePolicy = 'continue'
                    capture = New-CaptureDescriptor $framesDirectory 'frame' $sessionId
                    packaging = [ordered]@{ frameManifest = $true; previewVideo = [ordered]@{ requested = $false; required = $false; framesPerSecond = [Math]::Max(1, [int](1000 / $FrameIntervalMs)) } }
                }
                $started = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime $RuntimePath -RequireSuccess
                $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $started.value | Select-Object -First 1)
                if ($receipt.Count -ne 1) { throw 'Screenshot sequence did not expose an accepted request receipt.' }
                $screenshotState.requestId = [string]$receipt[0].requestId
                $screenshotState.startReceipt = $receipt[0]
            }
        }
        catch {
            try { $null = Invoke-DevBench -Tool 'record' -Arguments @{ action = 'stop' } -Runtime $RuntimePath } catch {}
            throw "Visual capture start failed after recording began; recording was rolled back. $($_.Exception.Message)"
        }
        $state = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; sessionId = $sessionId; status = 'active'
            createdUtc = [DateTime]::UtcNow.ToString('o'); updatedUtc = [DateTime]::UtcNow.ToString('o')
            sessionDirectory = $resolvedSessionDirectory; statePath = $resolvedStatePath; runtimePath = [IO.Path]::GetFullPath($RuntimePath)
            visualMode = $VisualMode; preferredView = $PreferredView; framesDirectory = $framesDirectory
            recording = [pscustomobject][ordered]@{ startReceipt = $recordCall.value; stopReceipt = $null }
            screenshot = $screenshotState; stopErrors = @()
        }
        try { Write-JsonAtomic -Path $resolvedStatePath -Value $state }
        catch {
            if ($screenshotState.requestId) {
                try {
                    $cancel = New-ScreenshotCommand $sessionId 'request_cancel'
                    $cancel['requestId'] = [string]$screenshotState.requestId
                    $null = Invoke-DevBench -Tool $screenshotTool -Arguments $cancel -Runtime $RuntimePath
                } catch {}
            }
            try { $null = Invoke-DevBench -Tool 'record' -Arguments @{ action = 'stop' } -Runtime $RuntimePath } catch {}
            throw "Session-state persistence failed after capture start; started services were rolled back. $($_.Exception.Message)"
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'session-started'; data = $state; errors = @() }
    }
    else {
        $resolvedStatePath = Resolve-StatePath
        $state = Read-State $resolvedStatePath
        if ($Command -eq 'status') {
            $data = $state
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$state.status; data = $data; errors = @() }
        }
        elseif ($Command -eq 'observe') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            $data = Get-CompositeObservation -State $state -CaptureOnDemand
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'observed'; data = $data; errors = @() }
        }
        elseif ($Command -eq 'act') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            $actionId = [guid]::NewGuid().ToString('N')
            $startedUtc = [DateTime]::UtcNow.ToString('o')
            if (-not [string]::IsNullOrWhiteSpace($DirectTool)) {
                $directArgs = Convert-Arguments $DirectArgumentsJson 'DirectArgumentsJson'
                $call = Invoke-DevBench -Tool $DirectTool -Arguments $directArgs -Runtime ([string]$state.runtimePath) -RequireSuccess
                $actionReceipt = [pscustomobject][ordered]@{ mode = 'direct'; tool = $DirectTool; arguments = $directArgs; result = $call.value }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($ActionName)) { throw '-ActionName or -DirectTool is required for act.' }
                $actionArgs = Convert-Arguments $ActionArgumentsJson 'ActionArgumentsJson'
                if ($ActionName -eq 'key-tap') {
                    $compiled = New-CaptureInteractionFrames -ObservedFrame ([pscustomobject]@{ hmd=@{}; left=@{controller=@{}}; right=@{controller=@{}} }) -ActionName $ActionName -ActionArguments ([pscustomobject]$actionArgs)
                    $call = Invoke-DevBench -Tool 'input' -Arguments ([hashtable]($compiled.arguments | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable)) -Runtime ([string]$state.runtimePath) -RequireSuccess
                    $actionReceipt = [pscustomobject][ordered]@{ mode = 'named'; name = $ActionName; compiled = $compiled; result = $call.value }
                }
                else {
                    $observed = Invoke-DevBench -Tool 'input' -Arguments @{ action = 'observe'; device = 'vrTrackedSet' } -Runtime ([string]$state.runtimePath) -RequireSuccess
                    if (-not $observed.value.PSObject.Properties['frame']) { throw 'Tracked-set observation returned no frame.' }
                    $frames = @(New-CaptureInteractionFrames -ObservedFrame $observed.value.frame -ActionName $ActionName -ActionArguments ([pscustomobject]$actionArgs))
                    $inputArgs = @{ action = 'sequence'; device = 'vrTrackedSet'; owner = "capture-interaction:$($state.sessionId)"; tailMs = 50; frames = $frames }
                    $call = Invoke-DevBench -Tool 'input' -Arguments $inputArgs -Runtime ([string]$state.runtimePath) -RequireSuccess
                    $terminal = Wait-VRActionTerminal -Accepted $call.value -State $state
                    $actionReceipt = [pscustomobject][ordered]@{ mode = 'named'; name = $ActionName; arguments = $actionArgs; observedFrame = $observed.value; compiledFrames = $frames; result = $call.value; terminal = $terminal }
                }
            }
            $entry = [pscustomobject][ordered]@{ actionId = $actionId; sessionId = [string]$state.sessionId; startedUtc = $startedUtc; completedUtc = [DateTime]::UtcNow.ToString('o'); receipt = $actionReceipt }
            $actionLogPath = Add-ActionLog -State $state -Entry $entry
            $after = if ($ObserveAfterAction) { Get-CompositeObservation -State $state -CaptureOnDemand } else { $null }
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'action-submitted'; data = [pscustomobject][ordered]@{ action = $entry; actionLogPath = $actionLogPath; observation = $after }; errors = @() }
        }
        elseif ($Command -eq 'wait-save') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            if ([string]::IsNullOrWhiteSpace($SaveDirectory)) { throw 'wait-save requires -SaveDirectory.' }
            $boundaryText = if ([string]::IsNullOrWhiteSpace($SinceUtc)) { [string]$state.createdUtc } else { $SinceUtc }
            $boundary = ConvertTo-CaptureInteractionUtcBoundary -Value $boundaryText
            $deadline = [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
            $observations = [Collections.Generic.List[object]]::new()
            $matched = $null
            do {
                $candidates = @(Get-CaptureInteractionSaveCandidates -Directory $SaveDirectory -SinceUtc $boundary -NamePattern $SaveNamePattern)
                $observations.Add([pscustomobject][ordered]@{ observedUtc=[DateTime]::UtcNow.ToString('o'); candidates=$candidates })
                if ($candidates.Count -gt 0) {
                    $candidate = $candidates[-1]
                    if ($SaveStableMilliseconds -eq 0) { $matched = $candidate; break }
                    Start-Sleep -Milliseconds $SaveStableMilliseconds
                    $after = @(Get-CaptureInteractionSaveCandidates -Directory $SaveDirectory -SinceUtc $boundary -NamePattern $SaveNamePattern | Where-Object path -eq $candidate.path)
                    if ($after.Count -eq 1 -and [long]$after[0].bytes -eq [long]$candidate.bytes -and [string]$after[0].lastWriteUtc -eq [string]$candidate.lastWriteUtc) { $matched = $after[0]; break }
                }
                Start-Sleep -Milliseconds $WaitPollMilliseconds
            } while ([DateTime]::UtcNow -lt $deadline)
            $waitReceipt = [pscustomobject][ordered]@{
                contractVersion='1.0.0'; sessionId=[string]$state.sessionId
                boundaryUtc=$boundary.ToString('o'); namePattern=$SaveNamePattern
                stableMilliseconds=$SaveStableMilliseconds; timeoutSeconds=$WaitTimeoutSeconds
                completedUtc=[DateTime]::UtcNow.ToString('o'); matched=$matched; observations=@($observations)
            }
            $waitPath = Join-Path ([string]$state.sessionDirectory) ('save-wait-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
            Write-JsonAtomic -Path $waitPath -Value $waitReceipt
            $result = [pscustomobject][ordered]@{ ok=($null -ne $matched); command=$Command; state=$(if ($matched) {'save-stable'} else {'timeout'}); data=[pscustomobject][ordered]@{ receipt=$waitReceipt; receiptPath=$waitPath }; errors=$(if ($matched) {@()} else {@("No stable matching save appeared before the $WaitTimeoutSeconds-second deadline.")}) }
        }
        else {
            $errors = [Collections.Generic.List[string]]::new()
            $screenshotReceipt = $null
            if ($state.screenshot.requestId) {
                try {
                    $action = if ($Command -eq 'stop') { 'sequence_stop' } else { 'request_cancel' }
                    $arguments = New-ScreenshotCommand ([string]$state.sessionId) $action
                    $arguments['requestId'] = [string]$state.screenshot.requestId
                    $null = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$state.runtimePath)
                    $screenshotReceipt = Wait-ScreenshotTerminal -RequestId ([string]$state.screenshot.requestId) -State $state
                }
                catch { $errors.Add($_.Exception.Message) }
            }
            try { $null = Invoke-DevBench -Tool 'input' -Arguments @{ action = 'releaseAll'; device = 'vrTrackedSet'; owner = "capture-interaction:$($state.sessionId)" } -Runtime ([string]$state.runtimePath) } catch { $errors.Add($_.Exception.Message) }
            $recordStop = $null
            try { $recordStop = (Invoke-DevBench -Tool 'record' -Arguments @{ action = 'stop' } -Runtime ([string]$state.runtimePath)).value } catch { $errors.Add($_.Exception.Message) }
            $state.status = if ($errors.Count -eq 0) { if ($Command -eq 'stop') { 'stopped' } else { 'aborted' } } else { 'stopped-with-errors' }
            $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
            $state.recording.stopReceipt = $recordStop
            $state.screenshot | Add-Member -NotePropertyName terminalReceipt -NotePropertyValue $screenshotReceipt -Force
            $state.stopErrors = @($errors)
            Write-JsonAtomic -Path $resolvedStatePath -Value $state
            $result = [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; command = $Command; state = [string]$state.status; data = $state; errors = @($errors) }
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; command = $Command; state = 'tool-error'; data = $null; errors = @($_.Exception.Message) }
}

$json = @{ InputObject = $result; Depth = 100 }
if ($Compact) { $json['Compress'] = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
