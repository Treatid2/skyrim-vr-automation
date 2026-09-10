# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ProcDumpPath,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$TargetPid,
    [Parameter(Mandatory)][string]$TargetStartedUtc,
    [Parameter(Mandatory)][string]$DumpPath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [ValidateRange(1, 30)][int]$AdmissionTimeoutSeconds = 3,
    [ValidateRange(10, 300)][int]$CaptureTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-AtomicJson($Value, [string]$Path) {
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory (
        '.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString('N')
    )
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 30),
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Test-ExactProcess([int]$ProcessId, [string]$ExpectedStartTimeUtc) {
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $expected = [DateTimeOffset]::Parse(
            $ExpectedStartTimeUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
        return $process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq
            $expected.ToFileTimeUtc()
    }
    catch { return $false }
}

function Set-StateProperty($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$workerStartedUtc = (Get-Process -Id $PID -ErrorAction Stop).StartTime.
    ToUniversalTime().ToString('o')
$procDumpExitCode = $null
$ownedProcDump = $null
try {
    $admissionDeadline = [DateTime]::UtcNow.AddSeconds($AdmissionTimeoutSeconds)
    $state = $null
    do {
        try {
            $candidate = Get-Content -LiteralPath $StatePath -Raw |
                ConvertFrom-Json -Depth 30
            if ([int]$candidate.capturePid -eq $PID -and
                [string]$candidate.captureStartedUtc -ceq $workerStartedUtc -and
                [string]$candidate.captureDumpPath -ceq [IO.Path]::GetFullPath($DumpPath) -and
                [string]$candidate.captureReceiptPath -ceq [IO.Path]::GetFullPath($ReceiptPath)) {
                $state = $candidate
            }
        }
        catch { $state = $null }
        if (-not $state) { Start-Sleep -Milliseconds 25 }
    } while (-not $state -and [DateTime]::UtcNow -lt $admissionDeadline)
    if (-not $state) {
        throw 'The capture worker was not admitted by its exact state journal.'
    }
    if (-not (Test-ExactProcess -ProcessId $TargetPid `
            -ExpectedStartTimeUtc $TargetStartedUtc)) {
        throw 'The admitted target process changed before ProcDump launch.'
    }

    Add-Type -Path (Join-Path $PSScriptRoot 'CocOwnedProcess.cs')
    $ownedProcDump = [CocOwnedProcess]::Start($ProcDumpPath, @(
            '-accepteula', '-ma', [string]$TargetPid, $DumpPath
        ))
    $procDump = $ownedProcDump.Process
    $procDumpStartedUtc = $procDump.StartTime.ToUniversalTime().ToString('o')
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -Depth 30
    if ([int]$state.capturePid -ne $PID -or
        [string]$state.captureStartedUtc -cne $workerStartedUtc) {
        throw 'Capture ownership changed before ProcDump admission.'
    }
    Set-StateProperty $state 'captureProcDumpPid' $procDump.Id
    Set-StateProperty $state 'captureProcDumpStartedUtc' $procDumpStartedUtc
    Set-StateProperty $state 'captureState' 'capture-running'
    Write-AtomicJson -Value $state -Path $StatePath

    if (-not $procDump.WaitForExit($CaptureTimeoutSeconds * 1000)) {
        $ownedProcDump.Dispose()
        $ownedProcDump = $null
        throw "ProcDump hang capture exceeded its $CaptureTimeoutSeconds-second bound."
    }
    $procDumpExitCode = $procDump.ExitCode
    if ($procDumpExitCode -ne 0) {
        throw "ProcDump hang capture exited with code $procDumpExitCode."
    }
    $dump = Get-Item -LiteralPath $DumpPath -ErrorAction Stop
    if ($dump.Length -le 0) { throw 'The hang dump is empty.' }

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -Depth 30
    if ([int]$state.captureProcDumpPid -ne $procDump.Id -or
        [string]$state.captureProcDumpStartedUtc -cne $procDumpStartedUtc) {
        throw 'ProcDump ownership changed before digest finalization.'
    }
    Set-StateProperty $state 'captureState' 'hash-pending'
    Write-AtomicJson -Value $state -Path $StatePath
    $lengthBeforeHash = $dump.Length
    $lastWriteBeforeHash = $dump.LastWriteTimeUtc.ToFileTimeUtc()
    $sha256 = (Get-FileHash -LiteralPath $dump.FullName -Algorithm SHA256).
        Hash.ToLowerInvariant()
    $dump.Refresh()
    if ($dump.Length -ne $lengthBeforeHash -or
        $dump.LastWriteTimeUtc.ToFileTimeUtc() -ne $lastWriteBeforeHash) {
        throw 'The hang dump changed while its digest was being finalized.'
    }

    $receipt = [pscustomobject][ordered]@{
        schema = 'csx-coc-hang-capture-v1'
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        trigger = 'operator-confirmed-hang'
        targetPid = $TargetPid
        targetStartedUtc = $TargetStartedUtc
        captureWorkerPid = $PID
        captureWorkerStartedUtc = $workerStartedUtc
        procDumpPid = $procDump.Id
        procDumpStartedUtc = $procDumpStartedUtc
        dumpPath = $dump.FullName
        length = $dump.Length
        sha256 = $sha256
        procDumpExitCode = $procDumpExitCode
    }
    Write-AtomicJson -Value $receipt -Path $ReceiptPath

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -Depth 30
    if ([int]$state.capturePid -ne $PID -or
        [string]$state.captureStartedUtc -cne $workerStartedUtc) {
        throw 'Capture ownership changed before completion publication.'
    }
    Set-StateProperty $state 'captureState' 'capture-complete'
    Set-StateProperty $state 'captureCompletedUtc' ([DateTime]::UtcNow.ToString('o'))
    Set-StateProperty $state 'captureReceiptPath' ([IO.Path]::GetFullPath($ReceiptPath))
    Set-StateProperty $state 'captureProcDumpExitCode' $procDumpExitCode
    Write-AtomicJson -Value $state -Path $StatePath
    $ownedProcDump.Dispose()
    $ownedProcDump = $null
    exit 0
}
catch {
    $failure = $_.Exception.Message
    if ($ownedProcDump) {
        try { $ownedProcDump.Dispose() } catch {
            $failure = "$failure; ProcDump job cleanup failed: $($_.Exception.Message)"
        }
    }
    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -Depth 30
        if ([int]$state.capturePid -eq $PID -and
            [string]$state.captureStartedUtc -ceq $workerStartedUtc) {
            Set-StateProperty $state 'captureState' 'capture-failed'
            Set-StateProperty $state 'captureFailure' $failure
            Set-StateProperty $state 'captureProcDumpExitCode' $procDumpExitCode
            Write-AtomicJson -Value $state -Path $StatePath
        }
    }
    catch {
        $failure = "$failure; completion-state publication failed: $($_.Exception.Message)"
    }
    [Console]::Error.WriteLine($failure)
    exit 1
}
