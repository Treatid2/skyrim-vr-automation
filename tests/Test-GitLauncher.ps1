# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$launcher = Join-Path $repositoryRoot 'tools\git.ps1'
$powerShell = (Get-Process -Id $PID).Path
$failures = [Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    $failures.Add('repository Git launcher exists')
}
else {
    Push-Location ([IO.Path]::GetTempPath())
    try {
        $observedRoot = (& $powerShell -NoProfile -File $launcher rev-parse --show-toplevel 2>&1 | Out-String).Trim()
        $successExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($successExitCode -ne 0 -or -not [string]::Equals(
            [IO.Path]::GetFullPath($observedRoot),
            $repositoryRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        $failures.Add('launcher runs Git from the exact repository root')
    }

    & $powerShell -NoProfile -File $launcher codex-invalid-subcommand 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $failures.Add('launcher propagates a failing Git exit code')
    }

    $source = Get-Content -LiteralPath $launcher -Raw
    if ($source -notmatch 'safe\.directory=\$repositoryRoot' -or $source -match '(?i)config\s+--global') {
        $failures.Add('launcher scopes safe.directory without global Git mutation')
    }
}

$result = [pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    assertions = 3
    failures = @($failures)
}
$result | ConvertTo-Json -Depth 5
if (-not $result.ok) { exit 1 }
