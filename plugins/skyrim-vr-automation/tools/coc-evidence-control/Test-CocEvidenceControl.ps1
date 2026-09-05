# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocEvidenceControl.ps1'
$script = Get-Content -LiteralPath $scriptPath -Raw

foreach ($requiredText in @(
    "[ValidateSet('inspect', 'arm', 'status', 'capture-hang', 'stop')]",
    "'-ma'",
    "'-e'",
    "'-n', '2'",
    "'-r', '1'",
    "'-a'",
    '@(''-w'', $TargetName)',
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
    'Get-OwnedHangCapture',
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

foreach ($forbiddenText in @(
    "'-t'",
    "'-e', '1'",
    "'-h'",
    'Stop-Process',
    'GhidraMcpUrl',
    'GhidraInstallRoot',
    'PyGhidraPath'
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
    'Hang-capture state publication failed; ProcDump was cancelled',
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
    [pscustomobject][ordered]@{
        schema = 'csx-coc-evidence-state-v1'
        monitorPid = [int]::MaxValue
        monitorStartedUtc = [DateTime]::UtcNow.ToString('o')
        targetName = 'pwsh.exe'
        targetPid = $PID
        captureDirectory = $fixture
        procDump = [pscustomobject]@{ path = $pwsh }
        capturePid = $capture.Id
        captureStartedUtc = $capture.StartTime.ToUniversalTime().ToString('o')
        captureState = 'capture-running'
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath -Encoding utf8

    $running = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if (-not $running.ok -or $running.state -ne 'capture-running' -or
        $running.data.coverageActive -or -not $running.data.captureActive -or
        $running.data.activeProcessKind -ne 'hang-capture' -or
        $running.data.capturePid -ne $capture.Id) {
        throw 'Status did not recognize the persisted live hang capture.'
    }

    $capture.Kill()
    $capture.WaitForExit()
    $exited = & $scriptPath status -StatePath $statePath -Compact -NoExit |
        ConvertFrom-Json -Depth 20
    if ($exited.ok -or $exited.state -ne 'capture-exited' -or
        @($exited.errors)[0] -notlike '*hang capture*') {
        throw "Status misclassified an exited persisted hang capture: $($exited | ConvertTo-Json -Depth 10 -Compress)"
    }
}
finally {
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
