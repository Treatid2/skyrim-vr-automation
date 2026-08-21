# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-build-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fixture 'ScreenshotApiTests.exe') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fixture 'not-a-test.exe') -Force | Out-Null
    $result = (& (Join-Path $PSScriptRoot 'Invoke-CSXBuildTests.ps1') -BuildDirectory $fixture -DiscoveryOnly -NoExit | ConvertFrom-Json)
    $ok = $result.ok -and $result.route -eq 'discovery-only' -and $result.directTestExecutables.Count -eq 1 -and $result.directTestExecutables[0] -like '*ScreenshotApiTests.exe'
    [pscustomobject][ordered]@{ ok = $ok; passed = if ($ok) { 1 } else { 0 }; failed = if ($ok) { 0 } else { 1 }; result = $result } | ConvertTo-Json -Depth 20
    if (-not $ok) { exit 1 }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
