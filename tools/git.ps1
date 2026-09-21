# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$gitArguments = [string[]]$args

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
    throw 'git.exe was not found on PATH. Install Git for Windows.'
}

function Find-GitRepositoryRoot([string]$StartPath) {
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($StartPath))
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName '.git')) { return $current.FullName }
        $current = $current.Parent
    }
    return $null
}

$configuredRoot = [Environment]::GetEnvironmentVariable('CSX_AUTOMATION_REPOSITORY_ROOT')
if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
    $repositoryRoot = Find-GitRepositoryRoot -StartPath $configuredRoot
    if ($null -eq $repositoryRoot -or -not [string]::Equals(
            [IO.Path]::GetFullPath($configuredRoot).TrimEnd('\', '/'),
            [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CSX_AUTOMATION_REPOSITORY_ROOT must name the exact root of a Git checkout.'
    }
}
else {
    $repositoryRoot = Find-GitRepositoryRoot -StartPath (Get-Location).Path
    if ($null -eq $repositoryRoot) {
        $repositoryRoot = Find-GitRepositoryRoot -StartPath $PSScriptRoot
    }
}
if ($null -eq $repositoryRoot) {
    throw 'No source Git checkout was found. Run from the checkout or set CSX_AUTOMATION_REPOSITORY_ROOT to its exact root; packaged plugin files are not a repository.'
}
$repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)

Push-Location -LiteralPath $repositoryRoot
try {
    & $git.Source -c "safe.directory=$repositoryRoot" @gitArguments
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
