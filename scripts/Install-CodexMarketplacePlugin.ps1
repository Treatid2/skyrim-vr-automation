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
    if ($normalized.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\\' + $normalized.Substring(8)
    }
    elseif ($normalized.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }
    $fullPath = [IO.Path]::GetFullPath($normalized)
    $root = [IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $root.Length -and
        ($fullPath.EndsWith([IO.Path]::DirectorySeparatorChar) -or $fullPath.EndsWith([IO.Path]::AltDirectorySeparatorChar))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Assert-StrictDescendantPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Description
    )

    $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $Candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description '$Candidate' is not a strict descendant of '$Root'."
    }
}

function Assert-NoReparsePointTraversal {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Description
    )

    Assert-StrictDescendantPath -Root $Root -Candidate $Candidate -Description $Description
    $relativePath = [IO.Path]::GetRelativePath($Root, $Candidate)
    $current = $Root
    foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description traverses reparse point '$current'."
        }
    }
}

function Get-VerifiedFileInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Description
    )

    $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
    $reparsePoints = @($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
    if ($reparsePoints.Count -gt 0) {
        throw "$Description contains unsupported reparse point '$($reparsePoints[0].FullName)'."
    }
    return @($items | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
            [IO.Path]::GetRelativePath($Root, $_.FullName)
        } | Sort-Object)
}

function Get-InstalledEntry {
    $list = Invoke-CodexJson -Arguments @('plugin', 'list', '--marketplace', $MarketplaceName, '--json')
    $installed = if ($null -ne $list.installed) { @($list.installed) } else { @() }
    $matches = @($installed | Where-Object pluginId -eq "${PluginName}@${MarketplaceName}")
    if ($matches.Count -gt 1) {
        throw "Codex returned duplicate installed registrations for ${PluginName}@${MarketplaceName}."
    }
    return $(if ($matches.Count -eq 1) { $matches[0] } else { $null })
}

function Add-Plugin {
    return Invoke-CodexJson -Arguments @('plugin', 'add', "${PluginName}@${MarketplaceName}", '--json')
}

function Assert-MarketplaceRegistration {
    $marketplaceList = Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'list', '--json')
    $marketplaces = if ($null -ne $marketplaceList.marketplaces) { @($marketplaceList.marketplaces) } else { @() }
    $configured = @($marketplaces | Where-Object name -eq $MarketplaceName)
    if ($configured.Count -ne 1) {
        throw "Codex must report exactly one '$MarketplaceName' marketplace registration; found $($configured.Count)."
    }
    $configuredRoot = Resolve-NormalizedPath -Path ([string]$configured[0].root)
    if (-not $configuredRoot.Equals($resolvedMarketplaceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Marketplace '$MarketplaceName' points to '$configuredRoot', not '$resolvedMarketplaceRoot'."
    }
    return $configured[0]
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
$sourceDescriptor = $marketplaceEntries[0].source
if ($null -eq $sourceDescriptor) {
    throw "Marketplace entry '$PluginName' has no source descriptor."
}
$sourceKindProperty = $sourceDescriptor.PSObject.Properties['source']
if ($null -eq $sourceKindProperty -or [string]$sourceKindProperty.Value -cne 'local') {
    throw "Marketplace entry '$PluginName' must use source kind 'local'."
}
$sourcePathProperty = $sourceDescriptor.PSObject.Properties['path']
$sourceRelativePath = if ($null -ne $sourcePathProperty) { [string]$sourcePathProperty.Value } else { '' }
if ([string]::IsNullOrWhiteSpace($sourceRelativePath)) {
    throw "Marketplace entry '$PluginName' must provide a non-empty relative source path."
}
if ([IO.Path]::IsPathRooted($sourceRelativePath) -or @($sourceRelativePath -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
    throw "Marketplace entry '$PluginName' source path must be relative and must not traverse parent directories: '$sourceRelativePath'."
}
$sourcePluginRoot = Resolve-NormalizedPath -Path (Join-Path $resolvedMarketplaceRoot $sourceRelativePath)
Assert-StrictDescendantPath -Root $resolvedMarketplaceRoot -Candidate $sourcePluginRoot -Description "Marketplace entry '$PluginName' source root"
if (-not (Test-Path -LiteralPath $sourcePluginRoot -PathType Container)) {
    throw "Marketplace source plugin root is missing: $sourcePluginRoot"
}
Assert-NoReparsePointTraversal -Root $resolvedMarketplaceRoot -Candidate $sourcePluginRoot -Description "Marketplace entry '$PluginName' source root"
$sourceManifestPath = Join-Path $sourcePluginRoot '.codex-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    throw "Source plugin manifest is missing: $sourceManifestPath"
}
$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
$sourceManifestName = [string]$sourceManifest.name
if ($sourceManifestName -cne $PluginName) {
    throw "Source plugin manifest name '$sourceManifestName' does not match '$PluginName'."
}
$expectedVersion = [string]$sourceManifest.version
if ([string]::IsNullOrWhiteSpace($expectedVersion)) {
    throw "Source plugin manifest has no version: $sourceManifestPath"
}

$marketplaceList = Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'list', '--json')
$marketplaces = if ($null -ne $marketplaceList.marketplaces) { @($marketplaceList.marketplaces) } else { @() }
$configured = @($marketplaces | Where-Object name -eq $MarketplaceName)
if ($configured.Count -gt 1) {
    throw "Codex returned duplicate '$MarketplaceName' marketplace registrations."
}

$registrationRefreshed = $false
if ($configured.Count -eq 0) {
    Invoke-CodexJson -Arguments @('plugin', 'marketplace', 'add', $resolvedMarketplaceRoot, '--json') | Out-Null
    Assert-MarketplaceRegistration | Out-Null
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
    Assert-MarketplaceRegistration | Out-Null
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
$sourceFiles = Get-VerifiedFileInventory -Root $sourcePluginRoot -Description 'Marketplace source plugin tree'
$installedFiles = Get-VerifiedFileInventory -Root $installedRoot -Description 'Installed plugin tree'
if (($sourceFiles -join "`n") -cne ($installedFiles -join "`n")) {
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
