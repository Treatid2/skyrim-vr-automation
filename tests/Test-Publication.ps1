# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
    'LICENSE',
    'README.md',
    'toolset.manifest.json',
    'CHANGELOG.md',
    'PRIVACY.md',
    'SUPPORT.md',
    'TERMS.md',
    '.mcp.json',
    '.agents/plugins/marketplace.json',
    '.codex-plugin/plugin.json',
    'skills/feedback-control/SKILL.md',
    'skills/feedback-control/agents/openai.yaml',
    'skills/mo2-control/SKILL.md',
    'skills/mo2-control/agents/openai.yaml',
    'skills/steamvr-null-hmd/SKILL.md',
    'skills/steamvr-null-hmd/agents/openai.yaml',
    'tools/steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1',
    'native/steamvr-head-pose/CMakeLists.txt',
    'drivers/codex_head_pose/driver.vrdrivermanifest',
    'drivers/codex_head_pose/build-provenance.json',
    'drivers/codex_head_pose/licenses/OpenVR-LICENSE.txt',
    'skills/devbench-control/SKILL.md',
    'skills/devbench-control/agents/openai.yaml',
    'skills/profiler-control/SKILL.md',
    'skills/profiler-control/agents/openai.yaml',
    'skills/renderscale-tuning-nvidia/SKILL.md',
    'skills/renderscale-tuning-nvidia/references/matrix.v1.json',
    'skills/renderscale-tuning-amd/SKILL.md',
    'skills/renderscale-tuning-amd/references/matrix.v1.json',
    'tools/renderscale-tuning-live/runner.js',
    'tools/renderscale-tuning-finalizer/finalizer.js',
    'tools/fork-reciprocal-search/validate-campaign.js',
    'skills/shader-cache-control/SKILL.md',
    'skills/shader-cache-control/agents/openai.yaml',
    'plugins/skyrim-vr-automation/.codex-plugin/plugin.json',
    'plugins/skyrim-vr-automation/.mcp.json'
)
$forbidden = @(
    ('L:' + '\Codex'),
    ('D:' + '\Games\Skyrim\MadGod2'),
    ('Mark-' + 'SkyrimVR'),
    ('CS-OCU-' + 'Rationalisation')
)
$violations = [System.Collections.Generic.List[object]]::new()

foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $required) -PathType Leaf)) {
        $violations.Add([pscustomobject]@{ file = $required; issue = 'required public-release file is missing' })
    }
}

$trackedFiles = @(& git -C $repositoryRoot ls-files)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate tracked files.' }
$candidateFiles = @(& git -C $repositoryRoot ls-files --cached --others --exclude-standard | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate public-release candidate files.' }
foreach ($trackedLocal in @($trackedFiles | Where-Object { $_ -like '*.local.json' })) {
    $violations.Add([pscustomobject]@{ file = $trackedLocal; issue = 'machine-local configuration is tracked' })
}

foreach ($relativePath in $candidateFiles) {
    $path = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { continue }
    foreach ($needle in $forbidden) {
        if ($content.Contains($needle, [StringComparison]::OrdinalIgnoreCase)) {
            $violations.Add([pscustomobject]@{ file = $relativePath; issue = "contains private workspace identifier: $needle" })
        }
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'toolset.manifest.json') -Raw | ConvertFrom-Json
if ($manifest.license -ne 'GPL-3.0-or-later') {
    $violations.Add([pscustomobject]@{ file = 'toolset.manifest.json'; issue = 'license is not GPL-3.0-or-later' })
}

foreach ($manifestRelative in @(
    '.codex-plugin/plugin.json',
    'plugins/skyrim-vr-automation/.codex-plugin/plugin.json'
)) {
    $manifestPath = Join-Path $repositoryRoot $manifestRelative
    $pluginManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($pluginManifest.name -ne 'skyrim-vr-automation') {
        $violations.Add([pscustomobject]@{ file = $manifestRelative; issue = 'plugin name does not match the public package' })
    }
    if ($pluginManifest.license -ne 'GPL-3.0-or-later') {
        $violations.Add([pscustomobject]@{ file = $manifestRelative; issue = 'license is not GPL-3.0-or-later' })
    }
    $pluginRoot = Split-Path -Parent (Split-Path -Parent $manifestPath)
    $mcpPath = Join-Path -Path $pluginRoot -ChildPath ([string]$pluginManifest.mcpServers)
    if ($pluginManifest.mcpServers -ne './.mcp.json' -or
        -not (Test-Path -LiteralPath $mcpPath -PathType Leaf)) {
        $violations.Add([pscustomobject]@{ file = $manifestRelative; issue = 'mcpServers does not resolve to the packaged MCP configuration' })
    }
}

foreach ($relativePath in @('skills/feedback-control/SKILL.md', 'skills/mo2-control/SKILL.md', 'skills/steamvr-null-hmd/SKILL.md', 'skills/devbench-control/SKILL.md', 'skills/profiler-control/SKILL.md', 'skills/shader-cache-control/SKILL.md')) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot $relativePath) -Raw
    if ($content -match '\[TODO:') {
        $violations.Add([pscustomobject]@{ file = $relativePath; issue = 'contains an unfinished skill placeholder' })
    }
}

$result = [pscustomobject][ordered]@{
    ok = $violations.Count -eq 0
    trackedFiles = $trackedFiles.Count
    candidateFiles = $candidateFiles.Count
    violations = @($violations)
}
$result | ConvertTo-Json -Depth 5
if (-not $result.ok) { exit 1 }
