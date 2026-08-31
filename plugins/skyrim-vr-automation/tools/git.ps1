# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$gitArguments = [string[]]$args

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
    throw 'git.exe was not found on PATH. Install Git for Windows.'
}

Push-Location $repositoryRoot
try {
    & $git.Source -c "safe.directory=$repositoryRoot" @gitArguments
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
