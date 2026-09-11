# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocEvidenceControl.ps1'
$script = Get-Content -LiteralPath $scriptPath -Raw
$completionWorkerPath = Join-Path $PSScriptRoot 'Complete-CocHangCapture.ps1'
$completionWorkerScript = Get-Content -LiteralPath $completionWorkerPath -Raw
$ownedProcessSourcePath = Join-Path $PSScriptRoot 'CocOwnedProcess.cs'
if (-not ('CocOwnedProcess' -as [type])) {
    Add-Type -Path $ownedProcessSourcePath
}
$ownedProcessFixture = [CocOwnedProcess]::Start(
    (Get-Process -Id $PID).Path,
    @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
)
$ownedProcessFixturePid = $ownedProcessFixture.Process.Id
$ownedProcessFixture.Dispose()
Start-Sleep -Milliseconds 100
if (Get-Process -Id $ownedProcessFixturePid -ErrorAction SilentlyContinue) {
    throw 'Closing the capture job did not terminate its exact child process.'
}
$workerTokens = $null
$workerParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $completionWorkerPath, [ref]$workerTokens, [ref]$workerParseErrors
) | Out-Null
if ($workerParseErrors.Count -ne 0) {
    throw 'The hang-capture completion worker does not parse.'
}
foreach ($requiredText in @(
        'csx-coc-hang-capture-v1',
        'captureWorkerPid',
        'captureWorkerStartedUtc',
        'targetStartedUtc',
        'procDumpPid',
        'procDumpStartedUtc',
        'procDumpExitCode',
        'sha256',
        'hash-pending',
        'CocOwnedProcess',
        'WaitForExit($CaptureTimeoutSeconds * 1000)',
        "'capture-complete'",
        "'capture-failed'"
    )) {
    if (-not $completionWorkerScript.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "The hang-capture completion worker is missing: $requiredText"
    }
}

$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors
)
$ownedProcessFunction = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-OwnedProcess'
    }, $true)
if ($parseErrors.Count -ne 0 -or $null -eq $ownedProcessFunction) {
    throw 'Could not isolate Get-OwnedProcess for inaccessible-process coverage.'
}
$stopOutcomeFunction = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-CocStopOutcome'
    }, $true)
if ($null -eq $stopOutcomeFunction) {
    throw 'Could not isolate Get-CocStopOutcome for stop-result coverage.'
}
Invoke-Expression $stopOutcomeFunction.ToString()
$monitorStop = Get-CocStopOutcome -ProcessKind crash-monitor -Value (
    [pscustomobject]@{ cleanupComplete = $true; target = '42'; cancelExited = $true }
)
$workerStop = Get-CocStopOutcome -ProcessKind hang-capture-worker -Value (
    [pscustomobject]@{ cleanupComplete = $true; captureExited = $true }
)
$failedWorkerStop = Get-CocStopOutcome -ProcessKind hang-capture-procdump -Value (
    [pscustomobject]@{ cleanupComplete = $false; captureExited = $false }
)
$cancellationStop = Get-CocStopOutcome -ProcessKind cancellation-helper -Value (
    [pscustomobject]@{ cleanupComplete = $true; captureExited = $true }
)
if (-not $monitorStop.stopped -or $monitorStop.target -ne '42' -or
    $monitorStop.cancelState -ne 'exited' -or -not $workerStop.stopped -or
    $null -ne $workerStop.target -or $workerStop.cancelState -ne 'exited' -or
    -not $cancellationStop.stopped -or $cancellationStop.cancelState -ne 'exited' -or
    $failedWorkerStop.stopped -or $null -ne $failedWorkerStop.target -or
    $failedWorkerStop.cancelState -ne 'cleanup-incomplete') {
    throw 'Stop-result normalization did not preserve process-specific result shapes.'
}
$ownedProcessOriginal = $ownedProcessFunction.ToString()
$ownedProcessSource = $ownedProcessOriginal.Replace(
    '$process = Get-Process -Id ([int]$pidValue.Value) -ErrorAction SilentlyContinue',
    '$process = $script:InaccessibleProcessFixture'
)
if ($ownedProcessSource -ceq $ownedProcessOriginal) {
    throw 'Get-OwnedProcess no longer contains the expected process lookup to stub.'
}
Invoke-Expression $ownedProcessSource
$script:InaccessibleProcessFixture = [pscustomobject]@{}
$script:InaccessibleProcessFixture | Add-Member -MemberType ScriptProperty `
    -Name StartTime -Value { throw 'Access denied fixture' }
$inaccessibleState = [pscustomobject]@{
    monitorPid = 42
    monitorStartedUtc = [DateTime]::UtcNow.ToString('o')
}
$inaccessibleResult = Get-OwnedProcess $inaccessibleState 'monitorPid' 'monitorStartedUtc'
if ($null -ne $inaccessibleResult) {
    throw 'An inaccessible process identity was accepted as owned.'
}
$script:InaccessibleProcessFixture = Get-Process -Id $PID
$replacementState = [pscustomobject]@{
    monitorPid = $PID
    monitorStartedUtc = [DateTime]::UtcNow.AddHours(-1).ToString('o')
}
if ($null -ne (Get-OwnedProcess $replacementState 'monitorPid' 'monitorStartedUtc')) {
    throw 'A reused PID with a different start time was accepted as owned.'
}
$nearReplacementState = [pscustomobject]@{
    monitorPid = $PID
    monitorStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().
        AddMilliseconds(1).ToString('o')
}
if ($null -ne (Get-OwnedProcess $nearReplacementState 'monitorPid' 'monitorStartedUtc')) {
    throw 'A near-time process mismatch was accepted as the same lifetime.'
}

foreach ($requiredText in @(
    "[ValidateSet('inspect', 'arm', 'status', 'capture-hang', 'stop')]",
    "'-ma'",
    "'-e'",
    "'-n', '2'",
    "'-r', '1'",
    "'-a'",
    "'-cancel'",
    'csx-coc-evidence-state-v1',
    'MinimumFreeGiB = 100',
    'CSX_COC_EVIDENCE_ROOT',
    'Test-DumpRootWriteAccess',
    'Assert-StatePathWriteAccess',
    'Write-OwnedState',
    "name = 'dump-write'",
    "code = 'evidence-output-not-writable'",
    '[IO.File]::WriteAllText',
    '[IO.File]::Delete',
    'DateTimeOffset]::Parse',
    'InvariantCulture',
    "triggerPolicy = 'unhandled-exception'",
    "trigger = 'operator-confirmed-hang'",
    'Stop-OwnedProcDumpMonitor',
    'Stop-HangCaptureWorker',
    '$Capture.Kill()',
    'Get-OwnedHangCapture',
    'Get-OwnedProcDumpCapture',
    'Get-OwnedCancellation',
    'Get-OwnedTarget',
    'targetStartedUtc',
    'cleanupComplete',
    'Get-ValidatedCaptureCompletion',
    'captureReceiptPath',
    'Complete-CocHangCapture.ps1',
    'captureStartedUtc',
    "-NotePropertyValue 'capture-running' -Force",
    'captureActive',
    "processKind = `$processKind",
    'cdb'
)) {
    if (-not $script.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "COC evidence controller is missing: $requiredText"
    }
}

$captureRollback = $script.IndexOf(
    '$rollback = Stop-HangCaptureWorker -Capture $capture',
    [StringComparison]::Ordinal
)
if ($captureRollback -lt 0) {
    throw 'Hang-capture publication rollback does not stop the exact worker.'
}

foreach ($forbiddenText in @(
    "'-t'",
    "'-e', '1'",
    "'-h'",
    'Stop-Process',
    'GhidraMcpUrl',
    'GhidraInstallRoot',
    'PyGhidraPath',
    "@('-w', `$TargetName)",
    'hashDeferred'
)) {
    if ($script.Contains($forbiddenText, [StringComparison]::Ordinal)) {
        throw "COC evidence controller contains unsafe behavior: $forbiddenText"
    }
}

$statePreflight = $script.IndexOf(
    'Assert-StatePathWriteAccess $resolvedStatePath',
    [StringComparison]::Ordinal
)
$monitorStart = $script.IndexOf(
    "if (-not `$monitor.Start())",
    [StringComparison]::Ordinal
)
if ($statePreflight -lt 0 -or $monitorStart -lt 0 -or
    $statePreflight -ge $monitorStart) {
    throw 'The state-file destination must be proven writable before ProcDump starts.'
}
$captureStart = $script.IndexOf(
    '$capture = [Diagnostics.Process]::Start($startInfo)',
    [StringComparison]::Ordinal
)
$capturePublication = $script.IndexOf(
    'Write-OwnedState -Value $owned.data -Path $owned.path -Replace',
    $captureStart,
    [StringComparison]::Ordinal
)
$captureWait = $script.IndexOf(
    '$completed = $capture.WaitForExit',
    [StringComparison]::Ordinal
)
if ($captureStart -lt 0 -or $capturePublication -lt $captureStart -or
    $captureWait -le $capturePublication) {
    throw 'A manual hang capture must publish its owned process before waiting.'
}
foreach ($rollback in @(
    'Evidence state publication failed; the ProcDump monitor was cancelled',
    'Hang-capture state publication failed; the completion worker was stopped',
    'Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $ownedProcess'
)) {
    if (-not $script.Contains($rollback, [StringComparison]::Ordinal)) {
        throw "COC evidence controller lacks process rollback: $rollback"
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) (
    'coc-evidence-control-' + [Guid]::NewGuid().ToString('N')
)
$capture = $null
$monitorFixture = $null
$cancelFixture = $null
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $pwsh = (Get-Process -Id $PID).Path
    $missingStatePath = Join-Path $fixture 'missing\state.json'
    $preflight = & $scriptPath arm -ProcDumpPath $pwsh -CdbPath $pwsh `
        -DumpRoot $fixture -StatePath $missingStatePath -TargetPid $PID `
        -MinimumFreeGiB 1 -Compact -NoExit | ConvertFrom-Json -Depth 20
    if ($preflight.ok -or $preflight.state -ne 'tool-error' -or
        @($preflight.errors)[0] -notlike '*state directory does not exist*') {
        throw 'Arm did not reject an invalid state destination before launch.'
    }
    $nameOnly = & $scriptPath arm -ProcDumpPath $pwsh -CdbPath $pwsh `
        -DumpRoot $fixture -StatePath (Join-Path $fixture 'name-only.json') `
        -MinimumFreeGiB 1 -Compact -NoExit | ConvertFrom-Json -Depth 20
    if ($nameOnly.ok -or @($nameOnly.errors)[0] -notlike '*TargetPid is required*') {
        throw 'Name-only crash-monitor ownership was not rejected.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30'
        )) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    $capture = [Diagnostics.Process]::Start($startInfo)
    $statePath = Join-Path $fixture 'state.json'
    $targetStartedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $captureStartedUtc = $capture.StartTime.ToUniversalTime().ToString('o')
    [pscustomobject][ordered]@{
        schema = 'csx-coc-evidence-state-v1'
        monitorPid = [int]::MaxValue
        monitorStartedUtc = [DateTime]::UtcNow.ToString('o')
        targetName = 'pwsh.exe'
        targetPid = $PID
        targetStartedUtc = $targetStartedUtc
        captureDirectory = $fixture
        procDump = [pscustomobject]@{ path = $pwsh }
        capturePid = $capture.Id
        captureStartedUtc = $captureStartedUtc
        captureState = 'capture-running'
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8

    $running = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $running.ok -or $running.state -ne 'capture-running' -or
        $running.data.coverageActive -or -not $running.data.captureActive -or
        $running.data.activeProcessKind -ne 'hang-capture-worker' -or
        $running.data.capturePid -ne $capture.Id) {
        throw 'Status did not recognize the persisted live hang capture.'
    }

    $failedWorkerCleanup = & $scriptPath stop -StatePath $statePath `
        -InternalTestFailurePoint stop-before-termination -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($failedWorkerCleanup.ok -or $failedWorkerCleanup.state -ne 'cleanup-incomplete' -or
        -not (Get-Process -Id $capture.Id -ErrorAction SilentlyContinue)) {
        throw 'Controlled worker cleanup failure did not retain the live exact process.'
    }
    $reloadedWorker = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $reloadedWorker.data.captureActive -or
        $reloadedWorker.data.activeProcessKind -ne 'hang-capture-worker') {
        throw 'Reloaded cleanup-incomplete state lost the live owned worker.'
    }
    $recoveredWorker = & $scriptPath stop -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $recoveredWorker.ok -or $recoveredWorker.state -ne 'stopped' -or
        (Get-Process -Id $capture.Id -ErrorAction SilentlyContinue)) {
        throw 'A later authorized stop did not resolve the retained worker lifetime.'
    }

    $capture = [Diagnostics.Process]::Start($startInfo)
    $captureStartedUtc = $capture.StartTime.ToUniversalTime().ToString('o')
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.capturePid = [int]::MaxValue
    $state.captureStartedUtc = [DateTime]::UtcNow.ToString('o')
    $state | Add-Member -NotePropertyName captureProcDumpPid -NotePropertyValue $capture.Id -Force
    $state | Add-Member -NotePropertyName captureProcDumpStartedUtc -NotePropertyValue $captureStartedUtc -Force
    $state.captureState = 'capture-running'
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    $failedProcDumpCleanup = & $scriptPath stop -StatePath $statePath `
        -InternalTestFailurePoint stop-before-termination -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    $reloadedProcDump = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($failedProcDumpCleanup.ok -or -not $reloadedProcDump.data.captureActive -or
        $reloadedProcDump.data.activeProcessKind -ne 'hang-capture-procdump') {
        throw 'Reloaded cleanup-incomplete state lost the live owned ProcDump child.'
    }
    $recoveredProcDump = & $scriptPath stop -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $recoveredProcDump.ok -or
        (Get-Process -Id $capture.Id -ErrorAction SilentlyContinue)) {
        throw 'A later authorized stop did not resolve the retained ProcDump lifetime.'
    }

    $monitorFixture = [Diagnostics.Process]::Start($startInfo)
    $cancelFixture = [Diagnostics.Process]::Start($startInfo)
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.monitorPid = $monitorFixture.Id
    $state.monitorStartedUtc = $monitorFixture.StartTime.ToUniversalTime().ToString('o')
    $state.capturePid = [int]::MaxValue
    $state.captureStartedUtc = [DateTime]::UtcNow.ToString('o')
    $state.captureProcDumpPid = [int]::MaxValue
    $state.captureProcDumpStartedUtc = [DateTime]::UtcNow.ToString('o')
    $state.captureState = 'capture-stopped'
    $state | Add-Member -NotePropertyName cancelPid -NotePropertyValue $cancelFixture.Id -Force
    $state | Add-Member -NotePropertyName cancelStartedUtc `
        -NotePropertyValue $cancelFixture.StartTime.ToUniversalTime().ToString('o') -Force
    $state | Add-Member -NotePropertyName cancelState -NotePropertyValue 'cleanup-incomplete' -Force
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8
    $cancellationStatus = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($cancellationStatus.ok -or $cancellationStatus.state -ne 'cleanup-incomplete') {
        throw 'Status did not retain the independently owned cancellation helper.'
    }
    $cancellationRecovery = & $scriptPath stop -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($cancellationRecovery.ok -or $cancellationRecovery.state -ne 'cleanup-incomplete' -or
        (Get-Process -Id $cancelFixture.Id -ErrorAction SilentlyContinue) -or
        -not (Get-Process -Id $monitorFixture.Id -ErrorAction SilentlyContinue)) {
        throw 'Stop did not resolve the prior cancellation helper before preserving the still-live monitor.'
    }
    $afterCancellation = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ([string]$afterCancellation.cancelState -ne 'exited' -or
        [int]$afterCancellation.monitorPid -ne $monitorFixture.Id) {
        throw 'Cancellation recovery overwrote unresolved monitor ownership.'
    }
    $monitorFixture.Kill()
    $monitorFixture.WaitForExit()

    $capture = [Diagnostics.Process]::Start($startInfo)
    $captureStartedUtc = $capture.StartTime.ToUniversalTime().ToString('o')
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.capturePid = $capture.Id
    $state.captureStartedUtc = $captureStartedUtc
    $state.captureProcDumpPid = [int]::MaxValue
    $state.captureProcDumpStartedUtc = [DateTime]::UtcNow.ToString('o')
    $state.captureState = 'capture-running'
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8

    $capture.Kill()
    $capture.WaitForExit()
    $exited = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($exited.ok -or $exited.state -ne 'capture-evidence-partial' -or
        @($exited.errors)[0] -notlike '*validated completion receipt*') {
        throw "Status misclassified an exited persisted hang capture: $($exited | ConvertTo-Json -Depth 10 -Compress)"
    }

    $unrelatedDump = Join-Path $fixture 'older-unrelated.dmp'
    [IO.File]::WriteAllBytes($unrelatedDump, [byte[]](1, 2, 3))
    $withUnrelatedDump = & $scriptPath status -StatePath $statePath `
        -Compact -NoExit | ConvertFrom-Json -Depth 20
    if ($withUnrelatedDump.ok -or
        $withUnrelatedDump.state -ne 'capture-evidence-partial') {
        throw 'An unrelated dump was accepted as completion of the current capture.'
    }

    $currentDump = Join-Path $fixture 'current.dmp'
    [IO.File]::WriteAllBytes($currentDump, [byte[]](4, 5, 6, 7))
    $receiptPath = Join-Path $fixture 'current.json'
    $currentHash = (Get-FileHash -LiteralPath $currentDump -Algorithm SHA256).
        Hash.ToLowerInvariant()
    [pscustomobject]@{
        schema = 'csx-coc-hang-capture-v1'
        dumpPath = $currentDump
        length = 4
        targetPid = $PID
        targetStartedUtc = $targetStartedUtc
        captureWorkerPid = $capture.Id
        captureWorkerStartedUtc = $captureStartedUtc
        procDumpPid = $capture.Id
        procDumpStartedUtc = $captureStartedUtc
        procDumpExitCode = 0
        sha256 = $currentHash
    } | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state | Add-Member -NotePropertyName captureDumpPath `
        -NotePropertyValue $currentDump -Force
    $state | Add-Member -NotePropertyName captureReceiptPath `
        -NotePropertyValue $receiptPath -Force
    $state | Add-Member -NotePropertyName captureProcDumpPid `
        -NotePropertyValue $capture.Id -Force
    $state | Add-Member -NotePropertyName captureProcDumpStartedUtc `
        -NotePropertyValue $captureStartedUtc -Force
    $state.captureState = 'capture-complete'
    $state | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $statePath -Encoding utf8
    $complete = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $complete.ok -or $complete.state -ne 'capture-complete' -or
        [string]$complete.data.completionReceiptPath -cne $receiptPath) {
        throw 'Exact nonempty dump and matching receipt were not accepted as completion.'
    }
    [IO.File]::WriteAllBytes($currentDump, [byte[]](7, 6, 5, 4))
    $substituted = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($substituted.ok -or $substituted.state -ne 'capture-evidence-partial') {
        throw 'A same-length replacement dump retained completed-evidence status.'
    }
}
finally {
    foreach ($process in @($cancelFixture, $monitorFixture)) {
        if ($process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
    }
    if ($capture -and -not $capture.HasExited) {
        $capture.Kill()
        $capture.WaitForExit()
    }
    if (Test-Path -LiteralPath $fixture -PathType Container) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $true
    fullUnhandledCrashDump = $true
    automaticHangDump = $false
    explicitHangDump = $true
    normalExitDump = $false
    firstChanceDump = $false
    boundedDumpCount = 2
    officialCancellation = $true
    statePublicationRollback = $true
    timedOutCaptureOwnership = $true
} | ConvertTo-Json
