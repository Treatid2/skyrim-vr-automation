# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'arm', 'status', 'capture-hang', 'stop')]
    [string]$Command = 'inspect',

    [string]$ProcDumpPath = $env:CSX_PROCDUMP_PATH,
    [string]$CdbPath = $env:CSX_CDB_PATH,
    [string]$EvidenceRoot = $env:CSX_COC_EVIDENCE_ROOT,
    [string]$DumpRoot = $env:CSX_COC_DUMP_ROOT,
    [string]$StatePath,
    [string]$TargetName = 'SkyrimVR.exe',
    [ValidateRange(0, [int]::MaxValue)][int]$TargetPid = 0,
    [ValidateRange(1, 2048)][int]$MinimumFreeGiB = 100,
    [ValidateRange(10, 300)][int]$CaptureTimeoutSeconds = 120,
    [ValidateSet('none', 'stop-before-termination', 'cancel-identity-unavailable', 'monitor-identity-unavailable', 'capture-identity-unavailable')]
    [string]$InternalTestFailurePoint = 'none',
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failureData = $null

function Get-CandidateEvidenceRoots {
    $roots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $roots.Add([IO.Path]::GetFullPath($EvidenceRoot))
    }

    $cursor = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath((Get-Location).Path))
    for ($depth = 0; $cursor -and $depth -lt 6; $depth++) {
        $candidate = Join-Path $cursor.FullName 'codex-ghidra-live'
        if (-not $roots.Contains($candidate)) { $roots.Add($candidate) }
        $cursor = $cursor.Parent
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        foreach ($relative in @(
            'Coding\GitHub\codex-ghidra-live',
            'GitHub\codex-ghidra-live'
        )) {
            $candidate = Join-Path $drive.Root $relative
            if (-not $roots.Contains($candidate)) { $roots.Add($candidate) }
        }
    }
    return @($roots)
}

function Resolve-FirstFile {
    param(
        [string]$ExplicitPath,
        [string[]]$CommandNames,
        [string[]]$CandidatePaths
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Configured executable does not exist: $resolved"
        }
        return $resolved
    }

    foreach ($name in $CommandNames) {
        $commandInfo = Get-Command $name -ErrorAction SilentlyContinue
        if ($commandInfo -and
            (Test-Path -LiteralPath $commandInfo.Source -PathType Leaf)) {
            return [IO.Path]::GetFullPath($commandInfo.Source)
        }
    }
    foreach ($candidate in $CandidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-ToolPaths {
    $evidenceRoots = @(Get-CandidateEvidenceRoots)
    $procDumpCandidates = @($evidenceRoots | ForEach-Object {
        Join-Path $_ 'tools\procdump\procdump64.exe'
    })
    $cdbCandidates = @($evidenceRoots | ForEach-Object {
        Join-Path $_ 'tools\windbg-x64\amd64\cdb.exe'
    })

    [pscustomobject][ordered]@{
        procDump = Resolve-FirstFile $ProcDumpPath @(
            'procdump64.exe', 'procdump64'
        ) $procDumpCandidates
        cdb = Resolve-FirstFile $CdbPath @('cdb.exe', 'cdb') $cdbCandidates
        evidenceRoots = $evidenceRoots
    }
}

function Resolve-DumpRoot([string[]]$EvidenceRoots) {
    if (-not [string]::IsNullOrWhiteSpace($DumpRoot)) {
        return [IO.Path]::GetFullPath($DumpRoot)
    }
    foreach ($root in $EvidenceRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            return [IO.Path]::GetFullPath(
                (Join-Path $root 'captures\coc-stability')
            )
        }
    }
    throw 'DumpRoot is required. Pass -DumpRoot or set CSX_COC_DUMP_ROOT.'
}

function Test-DumpRootWriteAccess([string]$Root) {
    $probeDirectory = $null
    $probeFile = $null
    try {
        $resolvedRoot = [IO.Directory]::CreateDirectory(
            [IO.Path]::GetFullPath($Root)
        ).FullName
        $probeDirectory = Join-Path $resolvedRoot (
            '.coc-evidence-write-probe-' + [Guid]::NewGuid().ToString('N')
        )
        [IO.Directory]::CreateDirectory($probeDirectory) | Out-Null
        $probeFile = Join-Path $probeDirectory 'probe.txt'
        [IO.File]::WriteAllText($probeFile, 'coc-evidence-write-probe')
        if (-not (Test-Path -LiteralPath $probeFile -PathType Leaf)) {
            throw 'The write probe did not create its expected file.'
        }
        return [pscustomobject]@{
            ok = $true
            code = $null
            error = $null
        }
    } catch {
        return [pscustomobject]@{
            ok = $false
            code = 'evidence-output-not-writable'
            error = $_.Exception.Message
        }
    } finally {
        if ($probeFile -and (Test-Path -LiteralPath $probeFile -PathType Leaf)) {
            [IO.File]::Delete($probeFile)
        }
        if ($probeDirectory -and
            (Test-Path -LiteralPath $probeDirectory -PathType Container)) {
            [IO.Directory]::Delete($probeDirectory, $false)
        }
    }
}

function Assert-StatePathWriteAccess([string]$Path) {
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Evidence state directory does not exist: $directory"
    }

    $probe = Join-Path $directory (
        '.coc-evidence-state-probe-' + [Guid]::NewGuid().ToString('N')
    )
    try {
        [IO.File]::WriteAllText($probe, 'coc-evidence-state-probe')
    }
    finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) {
            [IO.File]::Delete($probe)
        }
    }
}

function Write-OwnedState {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Replace
    )

    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $temporary -Encoding utf8
        $move = @{
            LiteralPath = $temporary
            Destination = $Path
        }
        if ($Replace) { $move.Force = $true }
        Move-Item @move
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-ExecutableRecord([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $item = Get-Item -LiteralPath $Path
    [pscustomobject][ordered]@{
        path = $item.FullName
        version = $item.VersionInfo.FileVersion
        length = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

function Get-LocalReadiness {
    $paths = Get-ToolPaths
    $resolvedDumpRoot = Resolve-DumpRoot $paths.evidenceRoots
    $driveRoot = [IO.Path]::GetPathRoot($resolvedDumpRoot)
    $drive = [IO.DriveInfo]::new($driveRoot)
    $freeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    $dumpWriteAccess = Test-DumpRootWriteAccess $resolvedDumpRoot
    $checks = [Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{
        name = 'procdump'
        ok = -not [string]::IsNullOrWhiteSpace($paths.procDump)
        value = $paths.procDump
        code = $null
        error = $null
    })
    $checks.Add([pscustomobject]@{
        name = 'cdb'
        ok = -not [string]::IsNullOrWhiteSpace($paths.cdb)
        value = $paths.cdb
        code = $null
        error = $null
    })
    $checks.Add([pscustomobject]@{
        name = 'dump-space'
        ok = $freeGiB -ge $MinimumFreeGiB
        value = [pscustomobject]@{
            root = $resolvedDumpRoot
            drive = $driveRoot
            freeGiB = $freeGiB
            requiredGiB = $MinimumFreeGiB
        }
        code = $null
        error = $null
    })
    $checks.Add([pscustomobject]@{
        name = 'dump-write'
        ok = [bool]$dumpWriteAccess.ok
        value = [pscustomobject]@{ root = $resolvedDumpRoot }
        code = $dumpWriteAccess.code
        error = $dumpWriteAccess.error
    })

    $failed = @($checks | Where-Object { -not $_.ok })
    [pscustomobject][ordered]@{
        ok = $failed.Count -eq 0
        checks = @($checks)
        errors = @($failed | ForEach-Object {
            $detail = if ($_.error) { ": $($_.error)" } else { '' }
            $code = if ($_.code) { " ($($_.code))" } else { '' }
            "Readiness check failed: $($_.name)$code$detail"
        })
        paths = [pscustomobject][ordered]@{
            procDump = $paths.procDump
            cdb = $paths.cdb
            dumpRoot = $resolvedDumpRoot
        }
    }
}

function Read-OwnedState {
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        throw 'StatePath is required for status and stop.'
    }
    $resolved = [IO.Path]::GetFullPath($StatePath)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Evidence state does not exist: $resolved"
    }
    $state = Get-Content -LiteralPath $resolved -Raw |
        ConvertFrom-Json -Depth 20
    if ([string]$state.schema -ne 'csx-coc-evidence-state-v1') {
        throw "Evidence state schema is not owned by this tool: $resolved"
    }
    return [pscustomobject]@{ path = $resolved; data = $state }
}

function Get-OwnedProcess($State, [string]$PidProperty, [string]$StartedProperty) {
    $pidValue = $State.PSObject.Properties[$PidProperty]
    $startedValue = $State.PSObject.Properties[$StartedProperty]
    if (-not $pidValue -or -not $startedValue) { return $null }
    $process = Get-Process -Id ([int]$pidValue.Value) -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        $expectedValue = $startedValue.Value
        $expected = if ($expectedValue -is [DateTime]) {
            $expectedValue.ToUniversalTime()
        } elseif ($expectedValue -is [DateTimeOffset]) {
            $expectedValue.UtcDateTime
        } else {
            [DateTimeOffset]::Parse(
                [string]$expectedValue,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).UtcDateTime
        }
        $actual = $process.StartTime.ToUniversalTime()
    }
    catch { return $null }
    if ($actual.ToFileTimeUtc() -ne $expected.ToFileTimeUtc()) { return $null }
    return $process
}

function Get-OwnedMonitor($State) {
    return Get-OwnedProcess $State 'monitorPid' 'monitorStartedUtc'
}

function Get-OwnedHangCapture($State) {
    $captureState = $State.PSObject.Properties['captureState']
    if (-not $captureState -or
        [string]$captureState.Value -notin @(
            'capture-running', 'hash-pending', 'capture-cleanup-incomplete'
        )) {
        return $null
    }
    return Get-OwnedProcess $State 'capturePid' 'captureStartedUtc'
}

function Get-TargetProcesses([string]$Name, [int]$ProcessId) {
    if ($ProcessId -le 0) { return @() }
    return @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-OwnedProcDumpCapture($State) {
    if (-not $State.PSObject.Properties['captureState'] -or
        [string]$State.captureState -notin @(
            'capture-running', 'hash-pending', 'capture-cleanup-incomplete'
        )) {
        return $null
    }
    return Get-OwnedProcess $State 'captureProcDumpPid' `
        'captureProcDumpStartedUtc'
}

function Get-OwnedCancellation($State) {
    $resolution = Resolve-OwnedCancellation $State
    if ($resolution.state -eq 'owned') { return $resolution.process }
    return $null
}

function Resolve-RecordedProcess(
    $State,
    [string]$PidProperty,
    [string]$StartedProperty,
    [string]$UnavailableFailurePoint = ''
) {
    $pidValue = $State.PSObject.Properties[$PidProperty]
    $startedValue = $State.PSObject.Properties[$StartedProperty]
    $hasPid = $pidValue -and $null -ne $pidValue.Value
    $hasStarted = $startedValue -and $null -ne $startedValue.Value
    if (-not $hasPid -and -not $hasStarted) {
        return [pscustomobject]@{ state = 'not-recorded'; process = $null }
    }
    if (-not $hasPid) {
        return [pscustomobject]@{ state = 'unresolved'; process = $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($UnavailableFailurePoint) -and
        $InternalTestFailurePoint -eq $UnavailableFailurePoint) {
        return [pscustomobject]@{ state = 'unresolved'; process = $null }
    }
    try {
        $process = Get-Process -Id ([int]$pidValue.Value) -ErrorAction SilentlyContinue
    }
    catch {
        return [pscustomobject]@{ state = 'unresolved'; process = $null }
    }
    if (-not $process) {
        return [pscustomobject]@{ state = 'absent'; process = $null }
    }
    if (-not $hasStarted) {
        return [pscustomobject]@{ state = 'unresolved'; process = $null }
    }
    try {
        $expectedValue = $startedValue.Value
        $expected = if ($expectedValue -is [DateTime]) {
            $expectedValue.ToUniversalTime()
        } elseif ($expectedValue -is [DateTimeOffset]) {
            $expectedValue.UtcDateTime
        } else {
            [DateTimeOffset]::Parse(
                [string]$expectedValue,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            ).UtcDateTime
        }
        $actual = $process.StartTime.ToUniversalTime()
    }
    catch {
        return [pscustomobject]@{ state = 'unresolved'; process = $null }
    }
    if ($actual.ToFileTimeUtc() -ne $expected.ToFileTimeUtc()) {
        return [pscustomobject]@{ state = 'replaced'; process = $null }
    }
    return [pscustomobject]@{ state = 'owned'; process = $process }
}

function Resolve-OwnedCancellation($State) {
    if (-not $State.PSObject.Properties['cancelState'] -or
        [string]$State.cancelState -ne 'cleanup-incomplete') {
        return [pscustomobject]@{ state = 'not-pending'; process = $null }
    }
    $resolution = Resolve-RecordedProcess $State 'cancelPid' 'cancelStartedUtc' `
        'cancel-identity-unavailable'
    if ($resolution.state -eq 'not-recorded') {
        return [pscustomobject]@{ state = 'not-pending'; process = $null }
    }
    return $resolution
}

function Get-OwnedTarget($State) {
    if (-not $State.PSObject.Properties['targetPid'] -or
        -not $State.PSObject.Properties['targetStartedUtc'] -or
        [int]$State.targetPid -le 0) {
        return $null
    }
    return Get-OwnedProcess $State 'targetPid' 'targetStartedUtc'
}

function Stop-OwnedProcDumpMonitor($Owned, $Monitor) {
    $ownedTarget = Get-OwnedTarget $Owned.data
    if (-not $ownedTarget) {
        throw 'The exact target lifetime is unavailable; cancellation is not authorized.'
    }
    $target = [string]$ownedTarget.Id
    $cancelInfo = [Diagnostics.ProcessStartInfo]::new()
    $cancelInfo.FileName = [string]$Owned.data.procDump.path
    $cancelInfo.UseShellExecute = $false
    $cancelInfo.CreateNoWindow = $true
    foreach ($argument in @('-accepteula', '-cancel', $target)) {
        $null = $cancelInfo.ArgumentList.Add($argument)
    }
    $cancel = [Diagnostics.Process]::Start($cancelInfo)
    if (-not $cancel) { throw 'ProcDump cancellation helper did not start.' }
    $cancelStartedUtc = try {
        $cancel.StartTime.ToUniversalTime().ToString('o')
    } catch {
        try { if (-not $cancel.HasExited) { $cancel.Kill() } } catch {}
        try { $cancel.WaitForExit(5000) | Out-Null } catch {}
        return [pscustomobject]@{
            stopped = $false; cleanupComplete = $false; target = $target
            cancelPid = $cancel.Id; cancelStartedUtc = $null
            cancelExited = [bool]$cancel.HasExited; cancelExitCode = $null
            monitorPid = $Monitor.Id; monitorExited = [bool]$Monitor.HasExited
            error = 'The ProcDump cancellation helper start time is inaccessible.'
        }
    }
    $cancelExited = $cancel.WaitForExit(5000)
    $monitorExited = $Monitor.WaitForExit(5000)
    return [pscustomobject]@{
        stopped = [bool]$monitorExited -and [bool]$Monitor.HasExited
        cleanupComplete = [bool]$cancelExited -and [bool]$cancel.HasExited -and
            [bool]$monitorExited -and [bool]$Monitor.HasExited -and
            $null -ne (Get-OwnedTarget $Owned.data)
        target = $target
        cancelPid = $cancel.Id
        cancelStartedUtc = $cancelStartedUtc
        cancelExited = [bool]$cancelExited -and [bool]$cancel.HasExited
        cancelExitCode = if ($cancelExited -and $cancel.HasExited) {
            $cancel.ExitCode
        } else { $null }
        monitorPid = $Monitor.Id
        monitorExited = [bool]$monitorExited -and [bool]$Monitor.HasExited
    }
}

function Stop-HangCaptureWorker([Diagnostics.Process]$Capture) {
    $startedUtc = try {
        $Capture.StartTime.ToUniversalTime().ToString('o')
    } catch { $null }
    try {
        if (-not $Capture.HasExited) { $Capture.Kill() }
        $exited = $Capture.WaitForExit(5000)
        return [pscustomobject]@{
            cleanupComplete = [bool]$exited -and [bool]$Capture.HasExited
            capturePid = $Capture.Id
            captureStartedUtc = $startedUtc
            captureExited = [bool]$exited -and [bool]$Capture.HasExited
        }
    }
    catch {
        return [pscustomobject]@{
            cleanupComplete = $false
            capturePid = $Capture.Id
            captureStartedUtc = $startedUtc
            captureExited = $false
            error = $_.Exception.Message
        }
    }
}

function Get-CocStopOutcome {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)]
        [ValidateSet('crash-monitor', 'hang-capture-worker', 'hang-capture-procdump', 'cancellation-helper')]
        [string]$ProcessKind
    )

    $exitProperty = if ($ProcessKind -eq 'crash-monitor') {
        'cancelExited'
    } else { 'captureExited' }
    $exitMember = $Value.PSObject.Properties[$exitProperty]
    $exited = $null -ne $exitMember -and [bool]$exitMember.Value
    return [pscustomobject][ordered]@{
        stopped = $Value.PSObject.Properties['cleanupComplete'] -and
            [bool]$Value.cleanupComplete
        target = if ($Value.PSObject.Properties['target']) {
            $Value.target
        } else { $null }
        cancelState = if ($exited) { 'exited' } else { 'cleanup-incomplete' }
    }
}

function Get-ValidatedCaptureCompletion($State) {
    if (-not $State.PSObject.Properties['captureState'] -or
        [string]$State.captureState -cne 'capture-complete' -or
        -not $State.PSObject.Properties['captureDumpPath'] -or
        -not $State.PSObject.Properties['captureReceiptPath'] -or
        -not $State.PSObject.Properties['capturePid'] -or
        -not $State.PSObject.Properties['captureStartedUtc'] -or
        -not $State.PSObject.Properties['captureProcDumpPid'] -or
        -not $State.PSObject.Properties['captureProcDumpStartedUtc'] -or
        -not $State.PSObject.Properties['targetPid'] -or
        -not $State.PSObject.Properties['targetStartedUtc']) {
        return $null
    }
    $dumpPath = [string]$State.captureDumpPath
    $receiptPath = [string]$State.captureReceiptPath
    if (-not (Test-Path -LiteralPath $dumpPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return $null
    }
    $dump = Get-Item -LiteralPath $dumpPath
    if ($dump.Length -le 0) { return $null }
    try {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw |
            ConvertFrom-Json -Depth 10
    }
    catch { return $null }
    foreach ($required in @(
            'schema', 'dumpPath', 'length', 'captureWorkerPid',
            'captureWorkerStartedUtc', 'targetPid', 'targetStartedUtc',
            'procDumpPid', 'procDumpStartedUtc', 'procDumpExitCode', 'sha256'
        )) {
        if (-not $receipt.PSObject.Properties[$required]) { return $null }
    }
    $actualHash = try {
        (Get-FileHash -LiteralPath $dump.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    } catch { return $null }
    if ([string]$receipt.schema -ne 'csx-coc-hang-capture-v1' -or
        [string]$receipt.dumpPath -cne $dump.FullName -or
        [long]$receipt.length -ne [long]$dump.Length -or
        [int]$receipt.captureWorkerPid -ne [int]$State.capturePid -or
        [string]$receipt.captureWorkerStartedUtc -cne [string]$State.captureStartedUtc -or
        [int]$receipt.procDumpPid -ne [int]$State.captureProcDumpPid -or
        [string]$receipt.procDumpStartedUtc -cne [string]$State.captureProcDumpStartedUtc -or
        [int]$receipt.targetPid -ne [int]$State.targetPid -or
        [string]$receipt.targetStartedUtc -cne [string]$State.targetStartedUtc -or
        [string]$receipt.sha256 -cne $actualHash -or
        [int]$receipt.procDumpExitCode -ne 0) {
        return $null
    }
    return [pscustomobject]@{
        dump = $dump
        receipt = $receipt
        receiptPath = $receiptPath
    }
}

function New-InspectionResult($Readiness) {
    [pscustomobject][ordered]@{
        schema = 'csx-coc-evidence-control-v1'
        ok = $Readiness.ok
        command = 'inspect'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = if ($Readiness.ok) { 'ready' } else { 'configuration-required' }
        checks = $Readiness.checks
        errors = $Readiness.errors
        data = [pscustomobject][ordered]@{
            tools = [pscustomobject][ordered]@{
                procDump = Get-ExecutableRecord $Readiness.paths.procDump
                cdb = Get-ExecutableRecord $Readiness.paths.cdb
            }
            dumpRoot = $Readiness.paths.dumpRoot
        }
    }
}

try {
    if ($Command -eq 'inspect') {
        $result = New-InspectionResult (Get-LocalReadiness)
    }
    elseif ($Command -eq 'arm') {
        if ($TargetPid -le 0) {
            throw 'TargetPid is required; name-only crash-monitor ownership is not permitted.'
        }
        $readiness = Get-LocalReadiness
        if (-not $readiness.ok) { throw ($readiness.errors -join '; ') }
        $runId = '{0}-{1}' -f [DateTime]::UtcNow.ToString(
            'yyyyMMddTHHmmssfffZ'
        ), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $captureDirectory = Join-Path $readiness.paths.dumpRoot $runId
        New-Item -ItemType Directory -Path $captureDirectory -Force | Out-Null
        $resolvedStatePath = if ([string]::IsNullOrWhiteSpace($StatePath)) {
            Join-Path $captureDirectory 'coc-evidence-state.json'
        } else {
            [IO.Path]::GetFullPath($StatePath)
        }
        if (Test-Path -LiteralPath $resolvedStatePath) {
            throw "Refusing to overwrite evidence state: $resolvedStatePath"
        }
        Assert-StatePathWriteAccess $resolvedStatePath

        $admittedTarget = Get-Process -Id $TargetPid -ErrorAction Stop
        $targetStartedUtc = $admittedTarget.StartTime.ToUniversalTime().ToString('o')

        $arguments = @(
            '-accepteula', '-ma', '-e', '-n', '2', '-r', '1', '-a'
        )
        $arguments += [string]$TargetPid
        $arguments += $captureDirectory

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $readiness.paths.procDump
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            $null = $startInfo.ArgumentList.Add($argument)
        }
        $monitor = [Diagnostics.Process]::new()
        $monitor.StartInfo = $startInfo
        if (-not $monitor.Start()) { throw 'ProcDump did not start.' }
        $failureData = [pscustomobject]@{
            monitorPid = $monitor.Id
            statePath = $resolvedStatePath
            captureDirectory = $captureDirectory
            cleanup = $null
        }
        Start-Sleep -Milliseconds 500
        if ($monitor.HasExited) {
            $detail = @(
                $monitor.StandardOutput.ReadToEnd().Trim()
                $monitor.StandardError.ReadToEnd().Trim()
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            throw "ProcDump exited during arming with code $($monitor.ExitCode): $($detail -join ' ')"
        }

        $stateRecord = $null
        try {
            $stateRecord = [pscustomobject][ordered]@{
                schema = 'csx-coc-evidence-state-v1'
                runId = $runId
                armedUtc = [DateTime]::UtcNow.ToString('o')
                monitorPid = $monitor.Id
                monitorStartedUtc = $monitor.StartTime.ToUniversalTime().ToString('o')
                monitorState = 'armed'
                targetName = $TargetName
                targetPid = $TargetPid
                targetStartedUtc = $targetStartedUtc
                captureDirectory = $captureDirectory
                statePath = $resolvedStatePath
                procDump = Get-ExecutableRecord $readiness.paths.procDump
                cdb = Get-ExecutableRecord $readiness.paths.cdb
                procDumpArguments = $arguments
                triggerPolicy = 'unhandled-exception'
                manualHangCaptureCommand = 'capture-hang'
            }
            Write-OwnedState -Value $stateRecord -Path $resolvedStatePath
        }
        catch {
            $publicationError = $_.Exception.Message
            $rollbackOwner = if ($stateRecord) {
                [pscustomobject]@{ data = $stateRecord }
            } else {
                [pscustomobject]@{
                    data = [pscustomobject]@{
                        targetPid = $TargetPid
                        targetName = $TargetName
                        targetStartedUtc = $targetStartedUtc
                        procDump = [pscustomobject]@{ path = $readiness.paths.procDump }
                    }
                }
            }
            try {
                $rollback = Stop-OwnedProcDumpMonitor -Owned $rollbackOwner `
                    -Monitor $monitor
            }
            catch {
                $failureData | Add-Member -NotePropertyName cleanupError `
                    -NotePropertyValue $_.Exception.Message -Force
                throw "Evidence state publication failed and ProcDump cancellation failed: $publicationError; $($_.Exception.Message)"
            }
            $failureData.cleanup = $rollback
            if (-not $rollback.cleanupComplete) {
                throw "Evidence state publication failed and ProcDump cleanup is incomplete: $publicationError"
            }
            throw "Evidence state publication failed; the ProcDump monitor was cancelled: $publicationError"
        }
        $failureData = $null
        $targets = @(Get-OwnedTarget $stateRecord | Where-Object { $null -ne $_ })
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-control-v1'
            ok = $true
            command = 'arm'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($targets.Count -gt 0) {
                'armed-attached'
            } else {
                'armed-waiting'
            }
            checks = $readiness.checks
            errors = @()
            data = $stateRecord
        }
    }
    elseif ($Command -eq 'status') {
        $owned = Read-OwnedState
        $monitor = Get-OwnedMonitor $owned.data
        $capture = Get-OwnedHangCapture $owned.data
        $procDumpCapture = Get-OwnedProcDumpCapture $owned.data
        $cancellationResolution = Resolve-OwnedCancellation $owned.data
        $cancellation = $cancellationResolution.process
        $cancellationPending = $cancellationResolution.state -in @('owned', 'unresolved')
        $ownedTarget = Get-OwnedTarget $owned.data
        $targets = if ($ownedTarget) { @($ownedTarget) } else { @() }
        $dumps = @(Get-ChildItem -LiteralPath (
            [string]$owned.data.captureDirectory
        ) -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc)
        $validatedCompletion = Get-ValidatedCaptureCompletion $owned.data
        $persistedCaptureState = if ($owned.data.PSObject.Properties['captureState']) {
            [string]$owned.data.captureState
        } else { $null }
        $captureEvidencePartial = $persistedCaptureState -in @(
            'capture-running', 'hash-pending', 'capture-complete',
            'capture-failed', 'capture-cleanup-incomplete'
        ) -and -not $capture -and -not $procDumpCapture -and
            -not $validatedCompletion
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-control-v1'
            ok = ($null -ne $monitor -or $null -ne $capture -or
                $null -ne $procDumpCapture -or
                $null -ne $validatedCompletion
            ) -and -not $cancellationPending
            command = 'status'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($capture -or $procDumpCapture) {
                if ($persistedCaptureState -eq 'hash-pending') {
                    'hash-pending'
                } else { 'capture-running' }
            } elseif ($cancellationPending) {
                'cleanup-incomplete'
            } elseif ($validatedCompletion) {
                'capture-complete'
            } elseif ($captureEvidencePartial) {
                'capture-evidence-partial'
            } elseif (-not $monitor) {
                'monitor-exited'
            } elseif (@($targets).Count -gt 0) {
                'armed-attached'
            } else {
                'armed-waiting'
            }
            checks = @()
            errors = if ($cancellationResolution.state -eq 'unresolved') {
                @('The pending ProcDump cancellation helper identity cannot be verified; recovery remains blocked.')
            } elseif ($cancellation) {
                @('The owned ProcDump cancellation helper is still running.')
            } elseif ($monitor -or $capture -or $procDumpCapture -or
                $validatedCompletion) {
                @()
            } elseif ($captureEvidencePartial) {
                @($(if ($persistedCaptureState -eq 'capture-failed' -and
                        $owned.data.PSObject.Properties['captureFailure']) {
                            "The owned ProcDump hang capture failed: $([string]$owned.data.captureFailure)"
                        } else {
                            'The owned ProcDump hang capture has no validated completion receipt; retained dump files remain partial or unattributed evidence.'
                        }))
            } else {
                @('The owned ProcDump monitor is no longer running.')
            }
            data = [pscustomobject][ordered]@{
                statePath = $owned.path
                monitorPid = [int]$owned.data.monitorPid
                capturePid = if ($owned.data.PSObject.Properties['capturePid']) {
                    [int]$owned.data.capturePid
                } else { $null }
                procDumpPid = if ($owned.data.PSObject.Properties['captureProcDumpPid']) {
                    [int]$owned.data.captureProcDumpPid
                } else { $null }
                targetPids = @($targets | ForEach-Object Id)
                targetStartedUtc = if ($ownedTarget) {
                    $ownedTarget.StartTime.ToUniversalTime().ToString('o')
                } else { $null }
                cancelPid = if ($cancellationPending) {
                    [int]$owned.data.cancelPid
                } else { $null }
                cancelStartedUtc = if ($cancellationPending) {
                    [string]$owned.data.cancelStartedUtc
                } else { $null }
                cancellationIdentityState = $cancellationResolution.state
                captureDirectory = [string]$owned.data.captureDirectory
                coverageActive = $null -ne $monitor
                captureActive = $null -ne $capture -or $null -ne $procDumpCapture
                activeProcessKind = if ($cancellationResolution.state -eq 'unresolved') {
                    'cancellation-helper-unresolved'
                } elseif ($cancellation) {
                    'cancellation-helper'
                } elseif ($capture) {
                    'hang-capture-worker'
                } elseif ($procDumpCapture) {
                    'hang-capture-procdump'
                } elseif ($monitor) { 'crash-monitor' } else { $null }
                triggerPolicy = if ($owned.data.PSObject.Properties['triggerPolicy']) {
                    [string]$owned.data.triggerPolicy
                } else {
                    'legacy-unclassified'
                }
                dumps = @($dumps | ForEach-Object {
                    [pscustomobject]@{
                        path = $_.FullName
                        length = $_.Length
                        lastWriteUtc = $_.LastWriteTimeUtc.ToString('o')
                        trigger = if ($_.BaseName -like '*-hang-*') {
                            'operator-confirmed-hang'
                        } elseif ($owned.data.PSObject.Properties['triggerPolicy']) {
                            [string]$owned.data.triggerPolicy
                        } else {
                            'legacy-unclassified'
                        }
                    }
                })
                completionReceiptPath = if ($validatedCompletion) {
                    [string]$validatedCompletion.receiptPath
                } else { $null }
            }
        }
    }
    elseif ($Command -eq 'capture-hang') {
        $owned = Read-OwnedState
        $existingCancellationResolution = Resolve-OwnedCancellation $owned.data
        $existingCancellation = $existingCancellationResolution.process
        if ($existingCancellationResolution.state -in @('owned', 'unresolved')) {
            $failureData = [pscustomobject][ordered]@{
                statePath = $owned.path
                cancelPid = [int]$owned.data.cancelPid
                cancelStartedUtc = [string]$owned.data.cancelStartedUtc
                cancelState = 'cleanup-incomplete'
                cancellationIdentityState = $existingCancellationResolution.state
            }
            throw 'An unresolved owned ProcDump cancellation helper must be stopped before capture-hang.'
        }
        $monitor = Get-OwnedMonitor $owned.data
        if (-not $monitor) {
            throw 'The state does not identify a live owned ProcDump monitor.'
        }
        $target = Get-OwnedTarget $owned.data
        if (-not $target) {
            throw 'The admitted target process lifetime is no longer available for hang capture.'
        }
        $targetPid = $target.Id
        $cancel = Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $monitor
        $owned.data | Add-Member -NotePropertyName monitorState `
            -NotePropertyValue $(if ($cancel.monitorExited) {
                'stopped-for-hang-capture'
            } else { 'cleanup-incomplete' }) -Force
        $owned.data | Add-Member -NotePropertyName cancelPid `
            -NotePropertyValue $cancel.cancelPid -Force
        $owned.data | Add-Member -NotePropertyName cancelStartedUtc `
            -NotePropertyValue $cancel.cancelStartedUtc -Force
        $owned.data | Add-Member -NotePropertyName cancelState `
            -NotePropertyValue $(if ($cancel.cancelExited) {
                'exited'
            } else { 'cleanup-incomplete' }) -Force
        try {
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
        }
        catch {
            $failureData = [pscustomobject]@{
                statePath = $owned.path
                targetPid = $targetPid
                cleanup = $cancel
            }
            throw "Monitor retirement state publication failed: $($_.Exception.Message)"
        }
        if (-not $cancel.cleanupComplete) {
            $failureData = [pscustomobject]@{
                statePath = $owned.path
                targetPid = $targetPid
                cleanup = $cancel
            }
            throw 'ProcDump cancellation did not complete before the explicit hang capture.'
        }
        $target = Get-OwnedTarget $owned.data
        if (-not $target) {
            throw 'The admitted target process changed before hang capture launch.'
        }

        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $dumpPath = Join-Path ([string]$owned.data.captureDirectory) (
            "SkyrimVR-hang-$stamp.dmp"
        )
        $receiptPath = Join-Path ([string]$owned.data.captureDirectory) (
            "hang-capture-$stamp.json"
        )
        $completionWorker = Join-Path $PSScriptRoot 'Complete-CocHangCapture.ps1'
        if (-not (Test-Path -LiteralPath $completionWorker -PathType Leaf)) {
            throw "The hang-capture completion worker is missing: $completionWorker"
        }
        $arguments = @(
            '-NoLogo', '-NoProfile', '-File', $completionWorker,
            '-StatePath', $owned.path,
            '-ProcDumpPath', [string]$owned.data.procDump.path,
            '-TargetPid', [string]$targetPid,
            '-TargetStartedUtc', [string]$owned.data.targetStartedUtc,
            '-DumpPath', $dumpPath,
            '-ReceiptPath', $receiptPath,
            '-CaptureTimeoutSeconds', [string]$CaptureTimeoutSeconds
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Process -Id $PID -ErrorAction Stop).Path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            $null = $startInfo.ArgumentList.Add($argument)
        }
        $capture = [Diagnostics.Process]::Start($startInfo)
        if (-not $capture) { throw 'ProcDump hang capture did not start.' }
        $captureStartedUtc = $capture.StartTime.ToUniversalTime().ToString('o')
        $outputTask = $capture.StandardOutput.ReadToEndAsync()
        $errorTask = $capture.StandardError.ReadToEndAsync()
        $failureData = [pscustomobject]@{
            statePath = $owned.path
            capturePid = $capture.Id
            captureStartedUtc = $captureStartedUtc
            dumpPath = $dumpPath
            receiptPath = $receiptPath
            cleanup = $null
        }
        try {
            $owned.data | Add-Member -NotePropertyName capturePid `
                -NotePropertyValue $capture.Id -Force
            $owned.data | Add-Member -NotePropertyName captureStartedUtc `
                -NotePropertyValue $captureStartedUtc -Force
            $owned.data | Add-Member -NotePropertyName captureState `
                -NotePropertyValue 'capture-running' -Force
            $owned.data | Add-Member -NotePropertyName captureDumpPath `
                -NotePropertyValue $dumpPath -Force
            $owned.data | Add-Member -NotePropertyName captureReceiptPath `
                -NotePropertyValue $receiptPath -Force
            $owned.data | Add-Member -NotePropertyName captureTrigger `
                -NotePropertyValue 'operator-confirmed-hang' -Force
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
        }
        catch {
            $publicationError = $_.Exception.Message
            $rollback = Stop-HangCaptureWorker -Capture $capture
            $failureData.cleanup = $rollback
            if (-not $rollback.cleanupComplete) {
                throw "Hang-capture state publication failed and completion-worker cleanup is incomplete: $publicationError"
            }
            throw "Hang-capture state publication failed; the completion worker was stopped: $publicationError"
        }
        $completed = $capture.WaitForExit($CaptureTimeoutSeconds * 1000)
        if (-not $completed) {
            $result = [pscustomobject][ordered]@{
                schema = 'csx-coc-evidence-control-v1'
                ok = $true
                command = 'capture-hang'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                state = 'capture-running'
                checks = @()
                errors = @()
                data = [pscustomobject]@{
                    statePath = $owned.path
                    capturePid = $capture.Id
                    targetPid = $targetPid
                    dumpPath = $dumpPath
                    trigger = 'operator-confirmed-hang'
                }
            }
        }
        else {
            $output = $outputTask.GetAwaiter().GetResult().Trim()
            $errorOutput = $errorTask.GetAwaiter().GetResult().Trim()
            $completedState = Get-Content -LiteralPath $owned.path -Raw |
                ConvertFrom-Json -Depth 30
            $validatedCompletion = Get-ValidatedCaptureCompletion $completedState
            if ($capture.ExitCode -ne 0 -or -not $validatedCompletion) {
                throw "Hang-capture completion worker exited with code $($capture.ExitCode): $output $errorOutput"
            }
            $dump = $validatedCompletion.dump
            $result = [pscustomobject][ordered]@{
                schema = 'csx-coc-evidence-control-v1'
                ok = $true
                command = 'capture-hang'
                timestampUtc = [DateTime]::UtcNow.ToString('o')
                state = 'capture-complete'
                checks = @()
                errors = @()
                data = [pscustomobject]@{
                    statePath = $owned.path
                    targetPid = $targetPid
                    dumpPath = $dump.FullName
                    length = $dump.Length
                    trigger = 'operator-confirmed-hang'
                    receiptPath = $receiptPath
                }
            }
        }
    }
    else {
        $owned = Read-OwnedState
        $monitorResolution = Resolve-RecordedProcess $owned.data 'monitorPid' `
            'monitorStartedUtc' 'monitor-identity-unavailable'
        $monitor = if ($monitorResolution.state -eq 'owned') {
            $monitorResolution.process
        } else { $null }
        $capturePending = $owned.data.PSObject.Properties['captureState'] -and
            [string]$owned.data.captureState -in @(
                'capture-running', 'hash-pending', 'capture-cleanup-incomplete'
            )
        $captureResolution = if ($capturePending) {
            Resolve-RecordedProcess $owned.data 'capturePid' 'captureStartedUtc' `
                'capture-identity-unavailable'
        } else { [pscustomobject]@{ state = 'not-pending'; process = $null } }
        $capture = if ($captureResolution.state -eq 'owned') {
            $captureResolution.process
        } else { $null }
        $procDumpCaptureResolution = if ($capturePending) {
            Resolve-RecordedProcess $owned.data 'captureProcDumpPid' `
                'captureProcDumpStartedUtc'
        } else { [pscustomobject]@{ state = 'not-pending'; process = $null } }
        $procDumpCapture = if ($procDumpCaptureResolution.state -eq 'owned') {
            $procDumpCaptureResolution.process
        } else { $null }
        $cancellationResolution = Resolve-OwnedCancellation $owned.data
        $cancellation = $cancellationResolution.process
        if ($cancellationResolution.state -eq 'unresolved') {
            $failureData = [pscustomobject][ordered]@{
                statePath = $owned.path
                cancelPid = [int]$owned.data.cancelPid
                cancelStartedUtc = [string]$owned.data.cancelStartedUtc
                cancelState = 'cleanup-incomplete'
                cancellationIdentityState = 'unresolved'
            }
            throw 'The pending ProcDump cancellation helper identity cannot be verified; cleanup remains blocked.'
        }
        $ownedProcess = if ($cancellation) {
            $cancellation
        } elseif ($capture) {
            $capture
        } elseif ($procDumpCapture) { $procDumpCapture } else { $monitor }
        $processKind = if ($cancellation) {
            'cancellation-helper'
        } elseif ($capture) {
            'hang-capture-worker'
        } elseif ($procDumpCapture) { 'hang-capture-procdump' } else { 'crash-monitor' }
        if (-not $ownedProcess) {
            throw 'The state does not identify a live owned ProcDump process.'
        }
        $recentDump = @(Get-ChildItem -LiteralPath (
            [string]$owned.data.captureDirectory
        ) -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Where-Object {
                ([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalSeconds -lt 15
            })
        if ($recentDump.Count -gt 0) {
            throw 'A dump was written recently; wait before stopping ProcDump.'
        }

        $cancel = if ($InternalTestFailurePoint -eq 'stop-before-termination' -and
            $processKind -ne 'crash-monitor') {
            [pscustomobject][ordered]@{
                cleanupComplete = $false
                capturePid = $ownedProcess.Id
                captureStartedUtc = $ownedProcess.StartTime.ToUniversalTime().ToString('o')
                captureExited = $false
                error = 'Injected stop failure before exact-process termination.'
            }
        } elseif ($processKind -eq 'crash-monitor') {
            Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $ownedProcess
        } else {
            Stop-HangCaptureWorker -Capture $ownedProcess
        }
        $stopOutcome = Get-CocStopOutcome -Value $cancel -ProcessKind $processKind
        $selectedStopped = [bool]$stopOutcome.stopped
        $retainedCancelPid = if ($processKind -eq 'cancellation-helper') {
            if ($selectedStopped) { $null } else { $ownedProcess.Id }
        } elseif ($cancel.PSObject.Properties['cancelPid']) {
            $cancel.cancelPid
        } else { $null }
        $retainedCancelStartedUtc = if ($processKind -eq 'cancellation-helper') {
            if ($selectedStopped) {
                $null
            } else {
                $ownedProcess.StartTime.ToUniversalTime().ToString('o')
            }
        } elseif ($cancel.PSObject.Properties['cancelStartedUtc']) {
            $cancel.cancelStartedUtc
        } else { $null }
        $unresolvedProcessKinds = @(
            if ($monitorResolution.state -eq 'unresolved') { 'crash-monitor' }
            if ($captureResolution.state -eq 'unresolved') { 'hang-capture-worker' }
            if ($procDumpCaptureResolution.state -eq 'unresolved') {
                'hang-capture-procdump'
            }
        )
        $otherOwnedProcessAlive = @(
            if ($processKind -ne 'crash-monitor') { $monitor }
            if ($processKind -ne 'hang-capture-worker') { $capture }
            if ($processKind -ne 'hang-capture-procdump') { $procDumpCapture }
        ).Where({ $null -ne $_ -and -not $_.HasExited }).Count -gt 0 -or
            @($unresolvedProcessKinds).Count -gt 0
        $stopped = $selectedStopped -and -not $otherOwnedProcessAlive
        $owned.data | Add-Member -NotePropertyName cancelPid `
            -NotePropertyValue $retainedCancelPid -Force
        $owned.data | Add-Member -NotePropertyName cancelStartedUtc `
            -NotePropertyValue $retainedCancelStartedUtc -Force
        $owned.data | Add-Member -NotePropertyName cancelState `
            -NotePropertyValue $stopOutcome.cancelState -Force
        if (($cancel.PSObject.Properties['monitorExited'] -and $cancel.monitorExited) -or
            $processKind -in @('hang-capture-worker', 'hang-capture-procdump')) {
            $owned.data | Add-Member -NotePropertyName captureState `
                -NotePropertyValue $(if ($stopped) {
                    'capture-stopped'
                } else { 'capture-cleanup-incomplete' }) -Force
            $owned.data | Add-Member -NotePropertyName captureStoppedUtc `
                -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        }
        try {
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
        }
        catch {
            $failureData = [pscustomobject]@{
                statePath = $owned.path
                cleanup = $cancel
            }
            throw "ProcDump cleanup state publication failed: $($_.Exception.Message)"
        }
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-control-v1'
            ok = $stopped
            command = 'stop'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($stopped) { 'stopped' } else { 'cleanup-incomplete' }
            checks = @()
            errors = if ($stopped) {
                @()
            } else {
                @('ProcDump cleanup did not account for both the owned process and cancellation helper.')
            }
            data = [pscustomobject][ordered]@{
                statePath = $owned.path
                monitorPid = [int]$owned.data.monitorPid
                processKind = $processKind
                processPid = $ownedProcess.Id
                target = $stopOutcome.target
                captureDirectory = [string]$owned.data.captureDirectory
                cleanup = $cancel
                unresolvedProcessKinds = @($unresolvedProcessKinds)
            }
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        schema = 'csx-coc-evidence-control-v1'
        ok = $false
        command = $Command
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = 'tool-error'
        checks = @()
        errors = @($_.Exception.Message)
        data = $failureData
    }
}

$json = @{ InputObject = $result; Depth = 30 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
