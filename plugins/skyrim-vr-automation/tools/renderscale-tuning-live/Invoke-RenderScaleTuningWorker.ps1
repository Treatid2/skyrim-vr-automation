# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('start', 'status')][string]$Action,
    [string]$RequestPath,
    [string]$StatusPath,
    [string]$NodePath = $env:CSX_TUNING_NODE_PATH
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Action -eq 'status') {
    if (-not $StatusPath) { throw '-StatusPath is required.' }
    Get-Content -Raw -LiteralPath $StatusPath
    exit 0
}
if (-not $RequestPath) { throw '-RequestPath is required.' }
if (-not $NodePath) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCommand) { $NodePath = $nodeCommand.Source }
    else {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $NodePath = @(& $vswhere -latest -products '*' -find 'MSBuild/Microsoft/VisualStudio/NodeJs/node.exe') | Select-Object -First 1
        }
    }
}
if (-not $NodePath -or -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    throw 'Node.js 22 or newer is required; supply -NodePath or CSX_TUNING_NODE_PATH.'
}
$version = & $NodePath --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) {
    throw 'The selected Node.js runtime must be version 22 or newer.'
}
& $NodePath (Join-Path $PSScriptRoot 'durable-worker.js') start ([IO.Path]::GetFullPath($RequestPath))
exit $LASTEXITCODE
