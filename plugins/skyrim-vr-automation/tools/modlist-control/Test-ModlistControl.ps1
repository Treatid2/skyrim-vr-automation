# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$toolRoot = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $PSScriptRoot 'Invoke-SkyrimVRModlist.ps1'
$resolverPath = Join-Path $toolRoot 'mo2-control\ConfigResolution.psm1'
Import-Module $resolverPath -Force

$passes = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
function Assert-ModlistTest([bool]$Condition, [string]$Name) {
    if ($Condition) { $passes.Add($Name) } else { $failures.Add($Name) }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-modlists-' + [guid]::NewGuid().ToString('N'))
$oldConfig = $env:SKYRIM_VR_AUTOMATION_CONFIG
$oldModlist = $env:SKYRIM_VR_AUTOMATION_MODLIST
try {
    $env:SKYRIM_VR_AUTOMATION_CONFIG = $null
    $env:SKYRIM_VR_AUTOMATION_MODLIST = $null
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $source = Join-Path $fixture 'source.json'
    [ordered]@{
        contractVersion = '0.4.0'; machine = 'fixture'
        mo2 = [ordered]@{ root = 'C:\MO2'; executable = 'C:\MO2\ModOrganizer.exe' }
        defaults = [ordered]@{ profile = 'Stable'; testProfileSource = 'Stable'; executable = 'SKSE' }
        storage = [ordered]@{ sessionStaging = 'C:\sessions'; archive = 'C:\archive' }
        limits = [ordered]@{ maxEnumeratedFiles = 100 }
        session = [ordered]@{ lockFile = 'C:\sessions\active.lock.json' }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $source -Encoding utf8

    $main = & $entry register -Name main -ConfigPath $source -UserRoot $fixture -NoExit | ConvertFrom-Json
    $synergy = & $entry register -Name synergy -ConfigPath $source -UserRoot $fixture -NoExit | ConvertFrom-Json
    Assert-ModlistTest ($main.ok -and $synergy.ok) 'register creates two exact named configs'

    $stablePath = Join-Path $fixture 'machine.local.json'
    $unselected = Resolve-MO2ControlConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control') -UserConfigPath $stablePath
    Assert-ModlistTest (-not $unselected.exists -and $unselected.source -eq 'named-selection-required') 'multiple named configs never fall through to a default'

    $selected = & $entry select -Name main -UserRoot $fixture -NoExit | ConvertFrom-Json
    $resolved = Resolve-MO2ControlConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control') -UserConfigPath $stablePath
    Assert-ModlistTest ($selected.ok -and $resolved.exists -and $resolved.source -eq 'active-modlist' -and $resolved.modlist -eq 'main') 'persisted selection resolves one exact config'

    $env:SKYRIM_VR_AUTOMATION_MODLIST = 'synergy'
    $environment = Resolve-MO2ControlConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control') -UserConfigPath $stablePath
    Assert-ModlistTest ($environment.exists -and $environment.source -eq 'environment-modlist' -and $environment.modlist -eq 'synergy') 'environment name explicitly overrides persisted selection'
    $env:SKYRIM_VR_AUTOMATION_MODLIST = $null

    $explicit = Resolve-MO2ControlConfigPath -ConfigPath $source -PackageRoot (Join-Path $toolRoot 'mo2-control') -UserConfigPath $stablePath
    Assert-ModlistTest ($explicit.path -eq $source -and $explicit.source -eq 'explicit') 'explicit config retains highest precedence'

    $duplicate = & $entry register -Name main -ConfigPath $source -UserRoot $fixture -NoExit | ConvertFrom-Json
    Assert-ModlistTest (-not $duplicate.ok) 'register refuses to overwrite an existing name'
    $invalid = & $entry resolve -Name 'Not Safe' -UserRoot $fixture -NoExit | ConvertFrom-Json
    Assert-ModlistTest (-not $invalid.ok) 'unsafe or ambiguous names are rejected'

    $listed = & $entry list -UserRoot $fixture -NoExit | ConvertFrom-Json
    Assert-ModlistTest ($listed.ok -and $listed.data.modlists.Count -eq 2 -and @($listed.data.modlists | Where-Object selected).name -eq 'main') 'list reports all configs and the active name'

    [pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 5
    if ($failures.Count -gt 0) { exit 1 }
}
finally {
    $env:SKYRIM_VR_AUTOMATION_CONFIG = $oldConfig
    $env:SKYRIM_VR_AUTOMATION_MODLIST = $oldModlist
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
