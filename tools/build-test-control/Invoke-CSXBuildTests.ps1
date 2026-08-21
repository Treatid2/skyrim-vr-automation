# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BuildDirectory,
    [string[]]$TestExecutablePath = @(),
    [string]$EvidenceDirectory,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 300,
    [switch]$DiscoveryOnly,
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BoundedCommand {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { $null = $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $startedUtc = [DateTime]::UtcNow
    if (-not $process.Start()) { throw "Failed to start: $FilePath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        try { $process.Kill($true) } catch {}
        $process.WaitForExit()
    }
    return [pscustomobject][ordered]@{
        filePath = $FilePath
        arguments = @($ArgumentList)
        startedUtc = $startedUtc.ToString('o')
        elapsedMilliseconds = [int64]([DateTime]::UtcNow - $startedUtc).TotalMilliseconds
        timedOut = -not $completed
        exitCode = if ($completed) { $process.ExitCode } else { $null }
        stdout = $stdoutTask.GetAwaiter().GetResult()
        stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Get-DirectTestExecutables([string]$Directory, [string[]]$Explicit) {
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($path in $Explicit) {
        $resolved = [IO.Path]::GetFullPath($path)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Explicit test executable does not exist: $resolved" }
        if (-not $paths.Contains($resolved)) { $paths.Add($resolved) }
    }
    if ($paths.Count -eq 0) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction Stop | Where-Object {
            $_.Extension -ieq '.exe' -and $_.BaseName -match '(?i)(^Tests?$|[A-Za-z0-9]Tests?$)'
        } | Sort-Object FullName)) {
            if (-not $paths.Contains($file.FullName)) { $paths.Add($file.FullName) }
        }
    }
    return @($paths)
}

try {
    $build = [IO.Path]::GetFullPath($BuildDirectory)
    if (-not (Test-Path -LiteralPath $build -PathType Container)) { throw "Build directory does not exist: $build" }
    $directTests = @(Get-DirectTestExecutables -Directory $build -Explicit $TestExecutablePath)
    $ctest = $null
    $ctestTests = @()
    $route = 'discovery-only'
    $runs = @()

    if (-not $DiscoveryOnly) {
        $ctestCommand = Get-Command ctest -ErrorAction SilentlyContinue
        if ($ctestCommand) {
            $ctestDiscovery = Invoke-BoundedCommand -FilePath $ctestCommand.Source -ArgumentList @('--test-dir', $build, '--show-only=json-v1')
            if (-not $ctestDiscovery.timedOut -and $ctestDiscovery.exitCode -eq 0) {
                try {
                    $ctestJson = $ctestDiscovery.stdout | ConvertFrom-Json -Depth 30 -ErrorAction Stop
                    $ctestTests = @($ctestJson.tests)
                }
                catch {
                    $ctestTests = @()
                }
            }
            $ctest = [pscustomobject][ordered]@{ discovery = $ctestDiscovery; testCount = $ctestTests.Count; run = $null }
        }

        if ($ctestTests.Count -gt 0) {
            $route = 'ctest'
            $ctest.run = Invoke-BoundedCommand -FilePath $ctestCommand.Source -ArgumentList @('--test-dir', $build, '--output-on-failure')
            $runs = @($ctest.run)
        }
        else {
            $route = 'direct-executables'
            foreach ($test in $directTests) { $runs += Invoke-BoundedCommand -FilePath $test }
        }
    }

    $failures = @($runs | Where-Object { $_.timedOut -or $null -eq $_.exitCode -or $_.exitCode -ne 0 })
    $ok = if ($DiscoveryOnly) { $directTests.Count -gt 0 } else { $runs.Count -gt 0 -and $failures.Count -eq 0 }
    $result = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'
        ok = $ok
        route = $route
        buildDirectory = $build
        ctest = $ctest
        directTestExecutables = @($directTests)
        runs = @($runs)
        summary = [pscustomobject][ordered]@{ discovered = if ($ctestTests.Count -gt 0) { $ctestTests.Count } else { $directTests.Count }; executed = $runs.Count; failed = $failures.Count }
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = $(if ($ok) { @() } elseif ($runs.Count -eq 0 -and -not $DiscoveryOnly) { @('No CTest tests or direct branch-local test executables were found.') } elseif ($DiscoveryOnly) { @('No branch-local test executables were found.') } else { @('One or more test executables failed or timed out.') })
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
        $evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
        New-Item -ItemType Directory -Path $evidence -Force | Out-Null
        $evidencePath = Join-Path $evidence 'csx-build-tests.json'
        $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $evidencePath -Encoding utf8
        $result | Add-Member -NotePropertyName evidencePath -NotePropertyValue $evidencePath
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'; ok = $false; route = 'error'; buildDirectory = $BuildDirectory
        ctest = $null; directTestExecutables = @(); runs = @(); summary = $null
        timestampUtc = [DateTime]::UtcNow.ToString('o'); errors = @($_.Exception.Message)
    }
}

$json = @{ InputObject = $result; Depth = 30 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
