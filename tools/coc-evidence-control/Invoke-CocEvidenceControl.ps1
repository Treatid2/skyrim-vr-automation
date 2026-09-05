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
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if ([math]::Abs(($actual - $expected).TotalSeconds) -gt 2) { return $null }
    return $process
}

function Get-OwnedMonitor($State) {
    return Get-OwnedProcess $State 'monitorPid' 'monitorStartedUtc'
}

function Get-OwnedHangCapture($State) {
    $captureState = $State.PSObject.Properties['captureState']
    if (-not $captureState -or
        [string]$captureState.Value -ne 'capture-running') {
        return $null
    }
    return Get-OwnedProcess $State 'capturePid' 'captureStartedUtc'
}

function Get-TargetProcesses([string]$Name, [int]$ProcessId) {
    if ($ProcessId -gt 0) {
        return @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    }
    $processName = [IO.Path]::GetFileNameWithoutExtension($Name)
    return @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
}

function Stop-OwnedProcDumpMonitor($Owned, $Monitor) {
    $target = if ([int]$Owned.data.targetPid -gt 0) {
        [string]$Owned.data.targetPid
    } else {
        [string]$Owned.data.targetName
    }
    $cancelInfo = [Diagnostics.ProcessStartInfo]::new()
    $cancelInfo.FileName = [string]$Owned.data.procDump.path
    $cancelInfo.UseShellExecute = $false
    $cancelInfo.CreateNoWindow = $true
    foreach ($argument in @('-accepteula', '-cancel', $target)) {
        $null = $cancelInfo.ArgumentList.Add($argument)
    }
    $cancel = [Diagnostics.Process]::Start($cancelInfo)
    $null = $cancel.WaitForExit(5000)
    $null = $Monitor.WaitForExit(5000)
    return [pscustomobject]@{
        stopped = [bool]$Monitor.HasExited
        target = $target
        cancelExitCode = if ($cancel.HasExited) { $cancel.ExitCode } else { $null }
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

        $arguments = @(
            '-accepteula', '-ma', '-e', '-n', '2', '-r', '1', '-a'
        )
        if ($TargetPid -gt 0) {
            $arguments += [string]$TargetPid
        } else {
            $arguments += @('-w', $TargetName)
        }
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
        Start-Sleep -Milliseconds 500
        if ($monitor.HasExited) {
            $detail = @(
                $monitor.StandardOutput.ReadToEnd().Trim()
                $monitor.StandardError.ReadToEnd().Trim()
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            throw "ProcDump exited during arming with code $($monitor.ExitCode): $($detail -join ' ')"
        }

        $stateRecord = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-state-v1'
            runId = $runId
            armedUtc = [DateTime]::UtcNow.ToString('o')
            monitorPid = $monitor.Id
            monitorStartedUtc = $monitor.StartTime.ToUniversalTime().ToString('o')
            monitorState = 'armed'
            targetName = $TargetName
            targetPid = $TargetPid
            captureDirectory = $captureDirectory
            statePath = $resolvedStatePath
            procDump = Get-ExecutableRecord $readiness.paths.procDump
            cdb = Get-ExecutableRecord $readiness.paths.cdb
            procDumpArguments = $arguments
            triggerPolicy = 'unhandled-exception'
            manualHangCaptureCommand = 'capture-hang'
        }
        try {
            Write-OwnedState -Value $stateRecord -Path $resolvedStatePath
        }
        catch {
            $publicationError = $_.Exception.Message
            try {
                $rollback = Stop-OwnedProcDumpMonitor -Owned (
                    [pscustomobject]@{ data = $stateRecord }
                ) -Monitor $monitor
            }
            catch {
                throw "Evidence state publication failed and ProcDump cancellation failed: $publicationError; $($_.Exception.Message)"
            }
            if (-not $rollback.stopped) {
                throw "Evidence state publication failed and ProcDump did not stop: $publicationError"
            }
            throw "Evidence state publication failed; the ProcDump monitor was cancelled: $publicationError"
        }
        $targets = @(Get-TargetProcesses $TargetName $TargetPid)
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
        $targets = @(Get-TargetProcesses (
            [string]$owned.data.targetName
        ) ([int]$owned.data.targetPid))
        $dumps = @(Get-ChildItem -LiteralPath (
            [string]$owned.data.captureDirectory
        ) -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc)
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-control-v1'
            ok = $null -ne $monitor -or $null -ne $capture -or
                $dumps.Count -gt 0
            command = 'status'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($capture) {
                'capture-running'
            } elseif (-not $monitor -and $dumps.Count -gt 0) {
                'capture-complete'
            } elseif ($owned.data.PSObject.Properties['captureState'] -and
                [string]$owned.data.captureState -eq 'capture-running') {
                'capture-exited'
            } elseif (-not $monitor) {
                'monitor-exited'
            } elseif ($targets.Count -gt 0) {
                'armed-attached'
            } else {
                'armed-waiting'
            }
            checks = @()
            errors = if ($monitor -or $capture -or $dumps.Count -gt 0) {
                @()
            } elseif ($owned.data.PSObject.Properties['captureState'] -and
                [string]$owned.data.captureState -eq 'capture-running') {
                @('The owned ProcDump hang capture is no longer running and produced no dump.')
            } else {
                @('The owned ProcDump monitor is no longer running.')
            }
            data = [pscustomobject][ordered]@{
                statePath = $owned.path
                monitorPid = [int]$owned.data.monitorPid
                capturePid = if ($owned.data.PSObject.Properties['capturePid']) {
                    [int]$owned.data.capturePid
                } else { $null }
                targetPids = @($targets | ForEach-Object Id)
                captureDirectory = [string]$owned.data.captureDirectory
                coverageActive = $null -ne $monitor
                captureActive = $null -ne $capture
                activeProcessKind = if ($capture) {
                    'hang-capture'
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
            }
        }
    }
    elseif ($Command -eq 'capture-hang') {
        $owned = Read-OwnedState
        $monitor = Get-OwnedMonitor $owned.data
        if (-not $monitor) {
            throw 'The state does not identify a live owned ProcDump monitor.'
        }
        $targetPid = [int]$owned.data.targetPid
        if ($targetPid -le 0 -or
            -not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
            throw 'An exact live target PID is required for a hang capture.'
        }
        $cancel = Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $monitor
        if (-not $cancel.stopped) {
            throw 'The crash monitor did not stop before the explicit hang capture.'
        }

        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $dumpPath = Join-Path ([string]$owned.data.captureDirectory) (
            "SkyrimVR-hang-$stamp.dmp"
        )
        $arguments = @('-accepteula', '-ma', [string]$targetPid, $dumpPath)
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$owned.data.procDump.path
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $arguments) {
            $null = $startInfo.ArgumentList.Add($argument)
        }
        $capture = [Diagnostics.Process]::Start($startInfo)
        if (-not $capture) { throw 'ProcDump hang capture did not start.' }
        $owned.data | Add-Member -NotePropertyName monitorState `
            -NotePropertyValue 'stopped-for-hang-capture' -Force
        $owned.data | Add-Member -NotePropertyName capturePid `
            -NotePropertyValue $capture.Id -Force
        $owned.data | Add-Member -NotePropertyName captureStartedUtc `
            -NotePropertyValue $capture.StartTime.ToUniversalTime().ToString('o') -Force
        $owned.data | Add-Member -NotePropertyName captureState `
            -NotePropertyValue 'capture-running' -Force
        $owned.data | Add-Member -NotePropertyName captureDumpPath `
            -NotePropertyValue $dumpPath -Force
        $owned.data | Add-Member -NotePropertyName captureTrigger `
            -NotePropertyValue 'operator-confirmed-hang' -Force
        try {
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
        }
        catch {
            $publicationError = $_.Exception.Message
            try {
                $rollback = Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $capture
            }
            catch {
                throw "Hang-capture state publication failed and ProcDump cancellation failed: $publicationError; $($_.Exception.Message)"
            }
            if (-not $rollback.stopped) {
                throw "Hang-capture state publication failed and ProcDump did not stop: $publicationError"
            }
            throw "Hang-capture state publication failed; ProcDump was cancelled: $publicationError"
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
            $output = $capture.StandardOutput.ReadToEnd().Trim()
            $errorOutput = $capture.StandardError.ReadToEnd().Trim()
            if ($capture.ExitCode -ne 0) {
                throw "ProcDump hang capture exited with code $($capture.ExitCode): $output $errorOutput"
            }
            $dump = Get-Item -LiteralPath $dumpPath -ErrorAction Stop
            if ($dump.Length -le 0) { throw 'The hang dump is empty.' }
            $receiptPath = Join-Path ([string]$owned.data.captureDirectory) (
                "hang-capture-$stamp.json"
            )
            $captureReceipt = [pscustomobject][ordered]@{
                schema = 'csx-coc-hang-capture-v1'
                capturedUtc = [DateTime]::UtcNow.ToString('o')
                trigger = 'operator-confirmed-hang'
                targetPid = $targetPid
                dumpPath = $dump.FullName
                length = $dump.Length
                hashDeferred = $true
                procDumpExitCode = $capture.ExitCode
            }
            $captureReceipt | ConvertTo-Json -Depth 10 |
                Set-Content -LiteralPath $receiptPath -Encoding utf8
            $owned.data | Add-Member -NotePropertyName captureState `
                -NotePropertyValue 'capture-complete' -Force
            $owned.data | Add-Member -NotePropertyName captureCompletedUtc `
                -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
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
        $monitor = Get-OwnedMonitor $owned.data
        $capture = Get-OwnedHangCapture $owned.data
        $ownedProcess = if ($capture) { $capture } else { $monitor }
        $processKind = if ($capture) { 'hang-capture' } else { 'crash-monitor' }
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

        $cancel = Stop-OwnedProcDumpMonitor -Owned $owned -Monitor $ownedProcess
        $stopped = $cancel.stopped
        if ($stopped -and $capture) {
            $owned.data | Add-Member -NotePropertyName captureState `
                -NotePropertyValue 'capture-stopped' -Force
            $owned.data | Add-Member -NotePropertyName captureStoppedUtc `
                -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            Write-OwnedState -Value $owned.data -Path $owned.path -Replace
        }
        $result = [pscustomobject][ordered]@{
            schema = 'csx-coc-evidence-control-v1'
            ok = $stopped
            command = 'stop'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($stopped) { 'stopped' } else { 'cancel-failed' }
            checks = @()
            errors = if ($stopped) {
                @()
            } else {
                @('ProcDump did not stop after its official cancel command.')
            }
            data = [pscustomobject][ordered]@{
                statePath = $owned.path
                monitorPid = [int]$owned.data.monitorPid
                processKind = $processKind
                processPid = $ownedProcess.Id
                target = $cancel.target
                captureDirectory = [string]$owned.data.captureDirectory
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
        data = $null
    }
}

$json = @{ InputObject = $result; Depth = 30 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
