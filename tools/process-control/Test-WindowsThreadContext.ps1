# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    [pscustomobject]@{ ok = $true; skipped = 'Windows-only thread context test.' } |
        ConvertTo-Json
    exit 0
}

$tool = Join-Path $PSScriptRoot 'Invoke-WindowsThreadContext.ps1'
$parseErrors = $null
$tokens = $null
$toolAst = [Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$parseErrors)
$closeHelperAst = @($toolAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Close-NativeHandle' }, $true))[0]
Invoke-Expression $closeHelperAst.Extent.Text
$simulatedCloseFailure = Close-NativeHandle -Handle ([IntPtr]1) -Kind thread -Sample 7 -CloseAction { param($handle) $false } -LastErrorAction { 5 }
if ($simulatedCloseFailure.ok -or $simulatedCloseFailure.kind -ne 'thread' -or $simulatedCloseFailure.sample -ne 7 -or $simulatedCloseFailure.nativeError -ne 5 -or $simulatedCloseFailure.error -notmatch 'Win32 error 5') {
    throw 'Native handle close failure was not retained with exact attribution.'
}
$currentHost = (Get-Process -Id $PID -ErrorAction Stop).Path
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hosts = @($currentHost, $windowsPowerShell) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -Unique
$helper = $null
$wow64Helper = $null
$results = [System.Collections.Generic.List[object]]::new()

try {
    $helperArguments = @{
        FilePath = $currentHost
        ArgumentList = @(
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Start-Sleep -Seconds 120')
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    $helper = Start-Process @helperArguments
    Start-Sleep -Milliseconds 500
    $helper = Get-Process -Id $helper.Id -ErrorAction Stop
    $thread = @($helper.Threads | Sort-Object StartTime | Select-Object -First 1)[0]
    $expectedPath = $helper.Path
    $expectedStart = $helper.StartTime.ToUniversalTime().ToString('o')

    foreach ($hostPath in $hosts) {
        $captureArguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', $tool,
            '-ProcessId', $helper.Id,
            '-ThreadId', $thread.Id,
            '-ExpectedProcessPath', $expectedPath,
            '-ExpectedStartTimeUtc', $expectedStart,
            '-Samples', 2,
            '-IntervalMs', 10,
            '-StackBytes', 256)
        $output = @(& $hostPath @captureArguments 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Thread-context capture failed under '$hostPath': $($output -join [Environment]::NewLine)"
        }
        $capture = ($output -join [Environment]::NewLine) | ConvertFrom-Json
        if (-not $capture.ok -or
            $capture.state -ne 'captured' -or
            $capture.capturedSamples -ne 2 -or
            $capture.identity.processId -ne $helper.Id -or
            $capture.identity.threadId -ne $thread.Id -or
            [string]::IsNullOrWhiteSpace([string]$capture.identity.threadStartTimeUtc) -or
            -not $capture.cleanup.ok -or
            @($capture.cleanup.handles).Count -ne 3 -or
            @($capture.cleanup.handles | Where-Object { -not $_.ok }).Count -ne 0 -or
            $capture.records[0].rip -notmatch '^0x[0-9A-F]+$' -or
            $capture.records[0].rsp -notmatch '^0x[0-9A-F]+$') {
            throw "Thread-context capture returned an invalid contract under '$hostPath'."
        }
        $results.Add([pscustomobject][ordered]@{
            host = $hostPath
            edition = $capture.host.edition
            version = $capture.host.version
            samples = $capture.capturedSamples
        })
    }

    $mismatchArguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $tool,
        '-ProcessId', $helper.Id,
        '-ThreadId', $thread.Id,
        '-ExpectedProcessPath', ($expectedPath + '.wrong'),
        '-ExpectedStartTimeUtc', $expectedStart,
        '-Samples', 1,
        '-NoExit')
    $mismatchOutput = @(& $currentHost @mismatchArguments 2>&1)
    $mismatch = ($mismatchOutput -join [Environment]::NewLine) | ConvertFrom-Json
    if ($mismatch.ok -or
        $mismatch.state -ne 'identity-mismatch' -or
        $mismatch.capturedSamples -ne 0) {
        throw 'The exact process identity guard did not fail closed.'
    }

    $wow64PowerShell = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $targetArchitectureGuard = $false
    if ([Environment]::Is64BitOperatingSystem -and
        (Test-Path -LiteralPath $wow64PowerShell -PathType Leaf)) {
        $wow64Helper = Start-Process -FilePath $wow64PowerShell `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') `
            -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 500
        $wow64Helper = Get-Process -Id $wow64Helper.Id -ErrorAction Stop
        $wow64Thread = @($wow64Helper.Threads | Sort-Object StartTime | Select-Object -First 1)[0]
        $wow64Arguments = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy', 'Bypass',
            '-File', $tool,
            '-ProcessId', $wow64Helper.Id,
            '-ThreadId', $wow64Thread.Id,
            '-ExpectedProcessPath', $wow64Helper.Path,
            '-ExpectedStartTimeUtc', $wow64Helper.StartTime.ToUniversalTime().ToString('o'),
            '-Samples', 1,
            '-NoExit')
        $wow64Output = @(& $currentHost @wow64Arguments 2>&1)
        $wow64Result = ($wow64Output -join [Environment]::NewLine) | ConvertFrom-Json
        if ($wow64Result.ok -or
            $wow64Result.state -ne 'target-architecture-mismatch' -or
            $wow64Result.capturedSamples -ne 0) {
            throw 'The target architecture guard did not reject a WOW64 helper.'
        }
        $targetArchitectureGuard = $true
    }

    [pscustomobject][ordered]@{
        ok = $true
        testedHosts = @($results)
        identityMismatchGuard = $true
        perSampleThreadIdentityGuard = $true
        targetArchitectureGuard = $targetArchitectureGuard
        handleCleanupFailureAttribution = $true
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($null -ne $helper -and
        $null -ne (Get-Process -Id $helper.Id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $helper.Id -Force
    }
    if ($null -ne $wow64Helper -and
        $null -ne (Get-Process -Id $wow64Helper.Id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $wow64Helper.Id -Force
    }
}
