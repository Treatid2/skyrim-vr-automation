# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-doctor-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $target = Join-Path $fixture 'config\machine.local.json'
    $script = Join-Path $PSScriptRoot 'Invoke-SkyrimVRAutomationDoctor.ps1'
    $dry = & (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target -WhatIf | ConvertFrom-Json
    if (-not $dry.ok -or $dry.state -ne 'dry-run' -or (Test-Path -LiteralPath $target)) { throw 'Doctor init dry-run failed.' }
    $created = (& (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target | ConvertFrom-Json)
    if (-not $created.ok -or -not (Test-Path -LiteralPath $target)) { throw 'Doctor init did not create the target.' }
    if ((Get-Content -LiteralPath $script -Raw) -notmatch 'Invoke-BoundedProcess\.ps1') { throw 'Doctor validation does not use the bounded process controller.' }
    $inspected = & (Get-Process -Id $PID).Path -NoProfile -File $script inspect -ConfigPath $target -UserConfigPath $target -NoExit | ConvertFrom-Json
    $primeCheck = @($inspected.checks | Where-Object name -eq 'prime-profile-launch-readiness')
    if ($primeCheck.Count -ne 1 -or $primeCheck[0].status -ne 'fail' -or $primeCheck[0].data.configurationProperty -ne 'defaults.testProfileSource') { throw "Doctor did not identify the exact maintained source profile configuration prerequisite: $($primeCheck | ConvertTo-Json -Depth 12 -Compress)" }
    $fixtureCheck = @($inspected.checks | Where-Object name -eq 'prime-profile-world-entry-integrity')
    if ($fixtureCheck.Count -ne 1 -or $fixtureCheck[0].status -ne 'fail' -or [string]::IsNullOrWhiteSpace([string]$fixtureCheck[0].data.exampleManifestPath)) { throw "Doctor did not fail an integrity-invalid prime-profile world-entry save: $($fixtureCheck | ConvertTo-Json -Depth 12 -Compress)" }
    $second = & (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target 2>&1
    if ($LASTEXITCODE -eq 0 -or (($second -join "`n") -notmatch 'not overwritten')) { throw 'Doctor init overwrote or did not reject an existing target.' }
    [pscustomobject]@{ ok = $true; target = $target } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
