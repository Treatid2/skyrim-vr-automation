# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-plugin-registration-' + [guid]::NewGuid().ToString('N'))
$priorStatePath = $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE
try {
    $marketplaceRoot = Join-Path $fixture 'marketplace'
    $pluginRoot = Join-Path $marketplaceRoot 'plugins\skyrim-vr-automation'
    $manifestRoot = Join-Path $marketplaceRoot '.agents\plugins'
    $installRoot = Join-Path $fixture 'cache\skyrim-vr-tools\skyrim-vr-automation\0.8.0+codex.current'
    New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.codex-plugin'), (Join-Path $pluginRoot 'skills\coc-stability'), $manifestRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $manifestRoot 'marketplace.json'), @'
{"name":"skyrim-vr-tools","plugins":[{"name":"skyrim-vr-automation","source":{"source":"local","path":"./plugins/skyrim-vr-automation"}}]}
'@, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $pluginRoot '.codex-plugin\plugin.json'), '{"name":"skyrim-vr-automation","version":"0.8.0+codex.current"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $pluginRoot 'skills\coc-stability\SKILL.md'), 'current', [Text.UTF8Encoding]::new($false))

    $statePath = Join-Path $fixture 'state.json'
    [pscustomobject][ordered]@{
        marketplaceRegistered = $true
        marketplaceRoot = [IO.Path]::GetFullPath($marketplaceRoot)
        pluginInstalled = $true
        stale = $true
        staleVersion = '0.8.0+codex.stale'
        expectedVersion = '0.8.0+codex.current'
        sourcePluginRoot = [IO.Path]::GetFullPath($pluginRoot)
        installedRoot = [IO.Path]::GetFullPath($installRoot)
        pluginAddCount = 0
        pluginRemoveCount = 0
        marketplaceAddCount = 0
        marketplaceRemoveCount = 0
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
    $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE = $statePath

    $mockPath = Join-Path $fixture 'codex-mock.ps1'
    [IO.File]::WriteAllText($mockPath, @'
$ErrorActionPreference = 'Stop'
$statePath = $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$command = @($args)
function Save-State { $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM }
if (($command[0..2] -join ' ') -eq 'plugin marketplace list') {
    $items = if ($state.marketplaceRegistered) { @([pscustomobject]@{ name = 'skyrim-vr-tools'; root = $state.marketplaceRoot }) } else { @() }
    [pscustomobject]@{ marketplaces = $items } | ConvertTo-Json -Depth 5
    return
}
if (($command[0..1] -join ' ') -eq 'plugin list') {
    $items = if ($state.pluginInstalled) {
        @([pscustomobject]@{
                pluginId = 'skyrim-vr-automation@skyrim-vr-tools'
                name = 'skyrim-vr-automation'
                marketplaceName = 'skyrim-vr-tools'
                version = $(if ($state.stale) { $state.staleVersion } else { $state.expectedVersion })
                installed = $true
                enabled = $true
            })
    }
    else { @() }
    [pscustomobject]@{ installed = $items; available = @() } | ConvertTo-Json -Depth 5
    return
}
if (($command[0..1] -join ' ') -eq 'plugin add') {
    if (Test-Path -LiteralPath $state.installedRoot) { Remove-Item -LiteralPath $state.installedRoot -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $state.installedRoot) -Force | Out-Null
    Copy-Item -LiteralPath $state.sourcePluginRoot -Destination $state.installedRoot -Recurse
    $state.pluginInstalled = $true
    $state.pluginAddCount++
    Save-State
    [pscustomobject]@{ pluginId = 'skyrim-vr-automation@skyrim-vr-tools'; version = $state.expectedVersion; installedPath = $state.installedRoot } | ConvertTo-Json
    return
}
if (($command[0..1] -join ' ') -eq 'plugin remove') {
    $state.pluginInstalled = $false
    $state.pluginRemoveCount++
    Save-State
    [pscustomobject]@{ pluginId = 'skyrim-vr-automation@skyrim-vr-tools' } | ConvertTo-Json
    return
}
if (($command[0..2] -join ' ') -eq 'plugin marketplace remove') {
    $state.marketplaceRegistered = $false
    $state.marketplaceRemoveCount++
    Save-State
    [pscustomobject]@{ marketplaceName = 'skyrim-vr-tools' } | ConvertTo-Json
    return
}
if (($command[0..2] -join ' ') -eq 'plugin marketplace add') {
    $state.marketplaceRegistered = $true
    $state.marketplaceRoot = [IO.Path]::GetFullPath($command[3])
    $state.stale = $false
    $state.marketplaceAddCount++
    Save-State
    [pscustomobject]@{ marketplaceName = 'skyrim-vr-tools'; installedRoot = $state.marketplaceRoot } | ConvertTo-Json
    return
}
throw "Unexpected mock command: $($command -join ' ')"
'@, [Text.UTF8Encoding]::new($false))

    $powerShell = (Get-Process -Id $PID).Path
    $guarded = $false
    try {
        & (Join-Path $repositoryRoot 'scripts\Install-CodexMarketplacePlugin.ps1') `
            -MarketplaceRoot $marketplaceRoot `
            -CodexCommand $powerShell `
            -CodexPrefixArguments @('-NoProfile', '-File', $mockPath) | Out-Null
    }
    catch {
        $guarded = $_.Exception.Message -like '*-ConfirmSafeCacheRotation*'
    }
    if (-not $guarded) { throw 'Installer did not guard cache rotation.' }

    $result = & (Join-Path $repositoryRoot 'scripts\Install-CodexMarketplacePlugin.ps1') `
        -MarketplaceRoot $marketplaceRoot `
        -CodexCommand $powerShell `
        -CodexPrefixArguments @('-NoProfile', '-File', $mockPath) `
        -ConfirmSafeCacheRotation | ConvertFrom-Json
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

    if (-not $result.ok -or $result.registeredVersion -ne '0.8.0+codex.current') { throw 'Installer did not verify the current registration.' }
    if (-not $result.registrationRefreshed -or $result.staleReportedVersion -ne '0.8.0+codex.stale') { throw 'Installer did not classify the stale registration.' }
    if (-not $result.sourceAndInstalledMatch -or $result.verifiedFiles -ne 2) { throw 'Installer did not hash-verify the installed plugin.' }
    if (-not $result.safeCacheRotationConfirmed -or -not $result.requiresCodexHostReload) { throw 'Installer did not preserve its cache-rotation contract.' }
    if ($state.pluginAddCount -ne 2 -or $state.pluginRemoveCount -ne 1) { throw 'Installer did not perform exactly one bounded plugin repair.' }
    if ($state.marketplaceAddCount -ne 1 -or $state.marketplaceRemoveCount -ne 1) { throw 'Installer did not perform exactly one bounded marketplace refresh.' }

    [pscustomobject][ordered]@{
        ok = $true
        staleVersionDetected = $result.staleReportedVersion
        registeredVersion = $result.registeredVersion
        boundedMarketplaceRefresh = $true
        sourceAndInstalledMatch = $result.sourceAndInstalledMatch
        safeCacheRotationGuard = $true
        requiresCodexHostReload = $result.requiresCodexHostReload
    } | ConvertTo-Json
}
finally {
    $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE = $priorStatePath
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
