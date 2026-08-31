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
    $toolsetManifest = Get-Content -LiteralPath (Join-Path $rebuilt 'toolset.manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'skyrim-vr-automation' -or $manifest.version -ne $sourceManifest.version) { throw 'Rebuilt plugin identity/version is incorrect.' }
    if ($manifest.mcpServers -ne './.mcp.json' -or $sourceManifest.mcpServers -ne './.mcp.json') { throw 'DevBench MCP companion registration is missing.' }
    $mcpPath = Join-Path $rebuilt '.mcp.json'
    if (-not (Test-Path -LiteralPath $mcpPath -PathType Leaf)) { throw 'DevBench MCP companion file is missing.' }
    $mcp = Get-Content -LiteralPath $mcpPath -Raw | ConvertFrom-Json
    $servers = @($mcp.mcpServers.PSObject.Properties)
    if ($servers.Count -ne 1 -or $servers[0].Name -ne 'devbench_vr') { throw 'DevBench MCP registration is missing or ambiguous.' }
    if ($servers[0].Value.type -ne 'http' -or $servers[0].Value.url -ne 'http://127.0.0.1:8921/mcp') { throw 'DevBench MCP endpoint is not the expected loopback server.' }
    foreach ($skill in @('feedback-control', 'mo2-control', 'steamvr-null-hmd', 'devbench-control', 'coc-stability', 'simple-coc', 'simple-coc-5', 'simple-csm', 'renderscale-tuning-nvidia', 'renderscale-tuning-amd', 'static-coc', 'fidelstab', 'render-scale-qualification', 'profiler-control', 'shader-cache-control', 'perftune-upscaling', 'capture-interaction-control')) {
        if (-not (Test-Path -LiteralPath (Join-Path $rebuilt "skills\$skill\SKILL.md") -PathType Leaf)) { throw "Missing installed skill: $skill" }
    }
    if (@(Get-ChildItem -LiteralPath $rebuilt -Recurse -File -Filter '*.local.json').Count -ne 0) { throw 'Distribution contains machine-local JSON.' }
    if (@(Get-ChildItem -LiteralPath $rebuilt -Recurse -Directory -Force | Where-Object Name -Like '.fixture-refresh-*').Count -ne 0) { throw 'Distribution contains local fixture-refresh evidence.' }

    $simulatedCache = Join-Path $fixture "cache\skyrim-vr-automation\$($manifest.version)"
    New-Item -ItemType Directory -Path (Split-Path -Parent $simulatedCache) -Force | Out-Null
    Copy-Item -LiteralPath $rebuilt -Destination $simulatedCache -Recurse
    foreach ($entryPoint in @(
        'tools\modlist-control\Invoke-SkyrimVRModlist.ps1',
        'tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1',
        'tools\feedback-control\Invoke-AutomationFeedback.ps1',
        'tools\mo2-control\Invoke-MO2Control.ps1',
        'tools\steamvr-null-control\Invoke-SteamVRNullControl.ps1',
        'tools\steamvr-head-pose-control\Invoke-SteamVRHeadPoseControl.ps1',
        'drivers\codex_head_pose\bin\win64\driver_codex_head_pose.dll',
        'drivers\codex_head_pose\tools\csx_openvr_pose_probe.exe',
        'tools\devbench-control\Invoke-DevBenchControl.ps1',
        'tools\devbench-control\DevBenchControl.psm1',
        'tools\render-scale-qualification\Invoke-CSXRenderScaleQualification.ps1',
        'tools\render-scale-qualification\RenderScaleQualification.psm1',
        'tools\render-scale-qualification\fixture.example.json',
        'tools\render-scale-qualification\protocol.v1.json',
        'tools\render-scale-qualification\Test-CSXRenderScaleQualification.ps1',
        'tools\renderscale-tuning-finalizer\finalizer.js',
        'tools\renderscale-tuning-live\runner.js',
        'tools\profiler-control\Measure-CSXProfiler.ps1',
        'tools\shader-cache-control\Compare-CSXShaderCache.ps1',
        'tools\shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1',
        'tools\shader-cache-control\Invoke-CSXShaderCacheCatalog.ps1',
        'tools\process-control\Invoke-BoundedProcess.ps1'
        'tools\process-control\Invoke-WindowsThreadContext.ps1'
        'tools\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
        'tools\coc-stability-control\Invoke-CocStabilityControl.ps1'
        'tools\coc-stability-control\CocStabilityControl.psm1'
        'tools\coc-stability-control\protocol.v1.json'
        'tools\capture-interaction-control\Invoke-CaptureInteraction.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $simulatedCache $entryPoint) -PathType Leaf)) { throw "Installed entry point is missing: $entryPoint" }
    }

    $hydratedPluginPath = Join-Path $simulatedCache '.codex-plugin\plugin.json'
    [IO.File]::WriteAllText($hydratedPluginPath, '{"name":"skyrim-vr-automation","category":"Developer Tools","interface":{"category":"Developer Tools"}}', [Text.UTF8Encoding]::new($false))
    $hydratedFeedbackRoot = Join-Path $fixture 'hydrated-feedback'
    $hydratedFeedback = & (Join-Path $simulatedCache 'tools\feedback-control\Invoke-AutomationFeedback.ps1') submit -FeedbackRoot $hydratedFeedbackRoot -Area packaging -Kind defect -Summary 'Hydrated cache probe' -Observed 'Observed.' -Expected 'Expected.' -Compact | ConvertFrom-Json -Depth 50
    if (-not $hydratedFeedback.ok -or $hydratedFeedback.state -ne 'recorded' -or $hydratedFeedback.data.feedback.toolkit.version -ne [string]$toolsetManifest.version -or $null -ne $hydratedFeedback.data.feedback.toolkit.pluginVersion) { throw 'Feedback control rejected hydration-stripped plugin metadata.' }

    [pscustomobject][ordered]@{ ok = $true; marketplace = $marketplace.name; pluginVersion = $manifest.version; files = $rebuiltFiles.Count; simulatedCache = $simulatedCache } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
