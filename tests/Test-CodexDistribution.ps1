# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$marketplacePath = Join-Path $repositoryRoot '.agents\plugins\marketplace.json'
$marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
$entry = @($marketplace.plugins | Where-Object name -eq 'skyrim-vr-automation')
if ($entry.Count -ne 1) { throw 'Marketplace must contain exactly one skyrim-vr-automation entry.' }
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $entry[0].source.path))
if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -PathType Leaf)) { throw 'Marketplace plugin manifest is missing.' }

function Test-DistributionFileEqual([string]$PublishedPath, [string]$RebuiltPath) {
    $binaryExtensions = @('.dll', '.exe', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip', '.7z')
    if ($binaryExtensions -contains [IO.Path]::GetExtension($PublishedPath).ToLowerInvariant()) {
        return (Get-FileHash -LiteralPath $PublishedPath -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $RebuiltPath -Algorithm SHA256).Hash
    }

    # Git normalizes tracked text to LF while Windows worktrees may materialize
    # either LF or CRLF. Distribution freshness is about content, not checkout
    # line-ending policy.
    $published = (Get-Content -LiteralPath $PublishedPath -Raw).Replace("`r`n", "`n")
    $rebuilt = (Get-Content -LiteralPath $RebuiltPath -Raw).Replace("`r`n", "`n")
    return $published -ceq $rebuilt
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-distribution-' + [guid]::NewGuid().ToString('N'))
try {
    $rebuilt = Join-Path $fixture 'skyrim-vr-automation'
    $buildResult = & (Join-Path $repositoryRoot 'scripts\Build-CodexMarketplacePlugin.ps1') -OutputDirectory $rebuilt | ConvertFrom-Json
    if (-not $buildResult.ok) { throw 'Distribution builder failed.' }

    $publishedFiles = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($pluginRoot, $_.FullName) } | Sort-Object)
    $rebuiltFiles = @(Get-ChildItem -LiteralPath $rebuilt -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($rebuilt, $_.FullName) } | Sort-Object)
    if (($publishedFiles -join "`n") -ne ($rebuiltFiles -join "`n")) { throw 'Committed marketplace package file set is stale.' }
    foreach ($relative in $rebuiltFiles) {
        if (-not (Test-DistributionFileEqual (Join-Path $pluginRoot $relative) (Join-Path $rebuilt $relative))) {
            throw "Committed marketplace package is stale: $relative"
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $rebuilt '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    $sourceManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'skyrim-vr-automation' -or $manifest.version -ne $sourceManifest.version) { throw 'Rebuilt plugin identity/version is incorrect.' }
    foreach ($skill in @('feedback-control', 'mo2-control', 'mo2-mod-packaging', 'steamvr-null-hmd', 'devbench-control', 'profiler-control', 'shader-cache-control')) {
        if (-not (Test-Path -LiteralPath (Join-Path $rebuilt "skills\$skill\SKILL.md") -PathType Leaf)) { throw "Missing installed skill: $skill" }
    }
    if (@(Get-ChildItem -LiteralPath $rebuilt -Recurse -File -Filter '*.local.json').Count -ne 0) { throw 'Distribution contains machine-local JSON.' }
    if (@(Get-ChildItem -LiteralPath $rebuilt -Recurse -Directory -Force | Where-Object Name -Like '.fixture-refresh-*').Count -ne 0) { throw 'Distribution contains local fixture-refresh evidence.' }

    $simulatedCache = Join-Path $fixture "cache\skyrim-vr-automation\$($manifest.version)"
    New-Item -ItemType Directory -Path (Split-Path -Parent $simulatedCache) -Force | Out-Null
    Copy-Item -LiteralPath $rebuilt -Destination $simulatedCache -Recurse
    foreach ($entryPoint in @(
        'tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1',
        'tools\feedback-control\Invoke-AutomationFeedback.ps1',
        'tools\mo2-control\Invoke-MO2Control.ps1',
        'tools\mo2-mod-package-control\Invoke-MO2ModPackageControl.ps1',
        'tools\steamvr-null-control\Invoke-SteamVRNullControl.ps1',
        'tools\steamvr-head-pose-control\Invoke-SteamVRHeadPoseControl.ps1',
        'drivers\codex_head_pose\bin\win64\driver_codex_head_pose.dll',
        'drivers\codex_head_pose\tools\csx_openvr_pose_probe.exe',
        'tools\devbench-control\Invoke-DevBenchControl.ps1',
        'tools\devbench-control\DevBenchControl.psm1',
        'tools\profiler-control\Measure-CSXProfiler.ps1',
        'tools\shader-cache-control\Compare-CSXShaderCache.ps1',
        'tools\shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1',
        'tools\shader-cache-control\Invoke-CSXShaderCacheCatalog.ps1',
        'tools\process-control\Invoke-BoundedProcess.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $simulatedCache $entryPoint) -PathType Leaf)) { throw "Installed entry point is missing: $entryPoint" }
    }

    [pscustomobject][ordered]@{ ok = $true; marketplace = $marketplace.name; pluginVersion = $manifest.version; files = $rebuiltFiles.Count; simulatedCache = $simulatedCache } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
