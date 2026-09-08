# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ProcDumpPath,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$TargetPid,
    [Parameter(Mandatory)][string]$TargetStartedUtc,
    [Parameter(Mandatory)][string]$DumpPath,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [ValidateRange(1, 30)][int]$AdmissionTimeoutSeconds = 3
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
        return [Math]::Abs((
                $process.StartTime.ToUniversalTime() - $expected
            ).TotalSeconds) -le 2
    }
    catch { return $false }
}

function Set-StateProperty($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$workerStartedUtc = (Get-Process -Id $PID -ErrorAction Stop).StartTime.
    ToUniversalTime().ToString('o')
$procDumpExitCode = $null
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

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ProcDumpPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-accepteula', '-ma', [string]$TargetPid, $DumpPath)) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    $procDump = [Diagnostics.Process]::Start($startInfo)
    if (-not $procDump) { throw 'ProcDump hang capture did not start.' }
    $outputTask = $procDump.StandardOutput.ReadToEndAsync()
    $errorTask = $procDump.StandardError.ReadToEndAsync()
    $procDump.WaitForExit()
    $output = $outputTask.GetAwaiter().GetResult().Trim()
    $errorOutput = $errorTask.GetAwaiter().GetResult().Trim()
    $procDumpExitCode = $procDump.ExitCode
    if ($procDumpExitCode -ne 0) {
        throw "ProcDump hang capture exited with code $procDumpExitCode`: $output $errorOutput"
    }
    $dump = Get-Item -LiteralPath $DumpPath -ErrorAction Stop
    if ($dump.Length -le 0) { throw 'The hang dump is empty.' }

    $receipt = [pscustomobject][ordered]@{
        schema = 'csx-coc-hang-capture-v1'
        capturedUtc = [DateTime]::UtcNow.ToString('o')
        trigger = 'operator-confirmed-hang'
        targetPid = $TargetPid
        targetStartedUtc = $TargetStartedUtc
        captureWorkerPid = $PID
        captureWorkerStartedUtc = $workerStartedUtc
        dumpPath = $dump.FullName
        length = $dump.Length
        hashDeferred = $true
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
    exit 0
}
catch {
    $failure = $_.Exception.Message
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
