# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$MarketplaceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MarketplaceName = 'skyrim-vr-tools',
    [string]$PluginName = 'skyrim-vr-automation',
    [string]$CodexCommand = 'codex',
    [string[]]$CodexPrefixArguments = @(),
    [switch]$ConfirmSafeCacheRotation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ConfirmSafeCacheRotation) {
    throw 'Plugin installation replaces versioned cache paths. Finish every active automation run, then rerun with -ConfirmSafeCacheRotation and fully reload the Codex host.'
}

function Invoke-CodexJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $global:LASTEXITCODE = 0
    $output = @(& $CodexCommand @CodexPrefixArguments @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "codex $($Arguments -join ' ') failed with exit code ${exitCode}: $text"
    }
    try {
        return $text | ConvertFrom-Json -Depth 50
    }
    catch {
        throw "codex $($Arguments -join ' ') returned invalid JSON: $text"
    }
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path
    if ($normalized.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    return [IO.Path]::GetFullPath($normalized).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

function Get-InstalledEntry {
    $list = Invoke-CodexJson -Arguments @('plugin', 'list', '--marketplace', $MarketplaceName, '--json')
    $matches = @($list.installed | Where-Object pluginId -eq "${PluginName}@${MarketplaceName}")
    if ($matches.Count -gt 1) {
        throw "Codex returned duplicate installed registrations for ${PluginName}@${MarketplaceName}."
    }
    return $(if ($matches.Count -eq 1) { $matches[0] } else { $null })
}

function Add-Plugin {
    return Invoke-CodexJson -Arguments @('plugin', 'add', "${PluginName}@${MarketplaceName}", '--json')
}

$resolvedMarketplaceRoot = Resolve-NormalizedPath -Path $MarketplaceRoot
$marketplaceManifestPath = Join-Path $resolvedMarketplaceRoot '.agents\plugins\marketplace.json'
if (-not (Test-Path -LiteralPath $marketplaceManifestPath -PathType Leaf)) {
    throw "Marketplace manifest is missing: $marketplaceManifestPath"
}

$marketplaceManifest = Get-Content -LiteralPath $marketplaceManifestPath -Raw | ConvertFrom-Json
if ($marketplaceManifest.name -ne $MarketplaceName) {
    throw "Marketplace name '$($marketplaceManifest.name)' does not match '$MarketplaceName'."
}
$marketplaceEntries = @($marketplaceManifest.plugins | Where-Object name -eq $PluginName)
if ($marketplaceEntries.Count -ne 1) {
    throw "Marketplace must contain exactly one '$PluginName' entry."
}
$sourcePluginRoot = Resolve-NormalizedPath -Path (Join-Path $resolvedMarketplaceRoot $marketplaceEntries[0].source.path)
$sourceManifestPath = Join-Path $sourcePluginRoot '.codex-plugin\plugin.json'
$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
$expectedVersion = [string]$sourceManifest.version
if ([string]::IsNullOrWhiteSpace($expectedVersion)) {
    throw "Source plugin manifest has no version: $sourceManifestPath"
}

$marketplaceList = Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'list', '--json')
$configured = @($marketplaceList.marketplaces | Where-Object name -eq $MarketplaceName)
if ($configured.Count -gt 1) {
    throw "Codex returned duplicate '$MarketplaceName' marketplace registrations."
}

$registrationRefreshed = $false
if ($configured.Count -eq 0) {
    Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'add', $resolvedMarketplaceRoot, '--json') | Out-Null
    $registrationRefreshed = $true
}
else {
    $configuredRoot = Resolve-NormalizedPath -Path ([string]$configured[0].root)
    if (-not $configuredRoot.Equals($resolvedMarketplaceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Marketplace '$MarketplaceName' points to '$configuredRoot', not '$resolvedMarketplaceRoot'."
    }
}

$addResult = Add-Plugin
$entry = Get-InstalledEntry
$staleReportedVersion = if ($null -ne $entry) { [string]$entry.version } else { $null }
if ($null -eq $entry -or $entry.version -ne $expectedVersion) {
    if ($null -ne $entry) {
        Invoke-CodexJson -Arguments @('plugin', 'remove', "${PluginName}@${MarketplaceName}", '--json') | Out-Null
    }
    Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'remove', $MarketplaceName, '--json') | Out-Null
    Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'add', $resolvedMarketplaceRoot, '--json') | Out-Null
    $registrationRefreshed = $true
    $addResult = Add-Plugin
    $entry = Get-InstalledEntry
}

if ($null -eq $entry -or -not $entry.installed -or $entry.version -ne $expectedVersion) {
    $actualVersion = if ($null -ne $entry) { [string]$entry.version } else { '<missing>' }
    throw "Codex registration is stale after one scoped refresh: expected '$expectedVersion', got '$actualVersion'."
}
if ($addResult.version -ne $expectedVersion) {
    throw "Codex installed '$($addResult.version)' instead of '$expectedVersion'."
}

$installedRoot = Resolve-NormalizedPath -Path ([string]$addResult.installedPath)
if (-not (Test-Path -LiteralPath $installedRoot -PathType Container)) {
    throw "Codex reported a missing installed path: $installedRoot"
}
$sourceFiles = @(Get-ChildItem -LiteralPath $sourcePluginRoot -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($sourcePluginRoot, $_.FullName)
    } | Sort-Object)
$installedFiles = @(Get-ChildItem -LiteralPath $installedRoot -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($installedRoot, $_.FullName)
    } | Sort-Object)
if (($sourceFiles -join "`n") -ne ($installedFiles -join "`n")) {
    throw 'Installed plugin file set does not match the marketplace source.'
}
foreach ($relativePath in $sourceFiles) {
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $sourcePluginRoot $relativePath) -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath (Join-Path $installedRoot $relativePath) -Algorithm SHA256).Hash
    if ($sourceHash -ne $installedHash) {
        throw "Installed plugin content differs from source: $relativePath"
    }
}

[pscustomobject][ordered]@{
    ok = $true
    pluginId = "${PluginName}@${MarketplaceName}"
    expectedVersion = $expectedVersion
    registeredVersion = [string]$entry.version
    staleReportedVersion = $staleReportedVersion
    registrationRefreshed = $registrationRefreshed
    installedPath = $installedRoot
    verifiedFiles = $sourceFiles.Count
    sourceAndInstalledMatch = $true
    safeCacheRotationConfirmed = $true
    requiresCodexHostReload = $true
} | ConvertTo-Json -Depth 5
