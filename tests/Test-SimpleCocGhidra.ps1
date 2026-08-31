# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot (
    'skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)
$fixture = Join-Path ([IO.Path]::GetTempPath()) (
    'simple-coc-ghidra-' + [Guid]::NewGuid().ToString('N')
)

try {
    $profile = Join-Path $fixture 'profile\modlist.txt'
    $mods = Join-Path $fixture 'mods'
    $pluginDirectory = Join-Path $mods 'Expected Build\SKSE\Plugins'
    $csxRoot = Join-Path $fixture 'community-shaders'
    New-Item -ItemType Directory -Path (Split-Path -Parent $profile) -Force |
        Out-Null
    New-Item -ItemType Directory -Path $pluginDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $csxRoot 'tools') -Force |
        Out-Null
    '+Expected Build' | Set-Content -LiteralPath $profile -Encoding utf8

    $artifactPath = Join-Path $pluginDirectory 'CommunityShaders.dll'
    [IO.File]::WriteAllBytes(
        $artifactPath,
        [Text.Encoding]::UTF8.GetBytes('exact frozen Ghidra fixture')
    )
    $artifact = Get-Item -LiteralPath $artifactPath
    $artifactSha256 = (
        Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256
    ).Hash
    $buildId = 'a' * 64
    [pscustomobject][ordered]@{
        schema = 'community-shaders.build-provenance'
        schemaVersion = 1
        buildId = $buildId
        artifact = [pscustomobject][ordered]@{
            fileName = 'CommunityShaders.dll'
            sha256 = $artifactSha256
            sizeBytes = [long]$artifact.Length
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (
        Join-Path $pluginDirectory 'CSX.BuildManifest.json'
    ) -Encoding utf8

    @'
import hashlib
import json
import pathlib
import sys
manifest = pathlib.Path(sys.argv[sys.argv.index('--manifest') + 1])
artifact = pathlib.Path(sys.argv[sys.argv.index('--artifact') + 1])
expected = json.loads(manifest.read_text(encoding='utf-8-sig'))['artifact']['sha256']
actual = hashlib.sha256(artifact.read_bytes()).hexdigest()
raise SystemExit(0 if expected.lower() == actual.lower() else 1)
'@ | Set-Content -LiteralPath (
        Join-Path $csxRoot 'tools\build_provenance.py'
    ) -Encoding utf8

    @'
param(
    [string]$Action,
    [string]$ProgramPath,
    [string]$ProjectName,
    [switch]$NoExit,
    [switch]$Compact
)
$statePath = Join-Path $PSScriptRoot 'fake-project-state.txt'
if ($Action -eq 'stop') {
    'stopped' | Set-Content -LiteralPath $statePath -Encoding ascii
    [pscustomobject]@{ ok = $true; state = 'stopped' } |
        ConvertTo-Json -Compress:$Compact
    return
}
$sha = (Get-FileHash -LiteralPath $ProgramPath -Algorithm SHA256).Hash
$selectedProject = if (-not (Test-Path -LiteralPath $statePath)) {
    'stale-project'
} else {
    $ProjectName
}
$starting = Test-Path -LiteralPath $statePath
[pscustomobject][ordered]@{
    ok = $true
    state = $(if ($starting) { 'starting' } else { 'ready' })
    managed = $true
    project = [pscustomobject][ordered]@{
        name = $selectedProject
        programPath = [IO.Path]::GetFullPath($ProgramPath)
        programSha256 = $sha
    }
    programMatchesExpectation = -not $starting
} | ConvertTo-Json -Depth 10 -Compress:$Compact
'@ | Set-Content -LiteralPath (
        Join-Path $csxRoot 'tools\ghidra-mcp-control.ps1'
    ) -Encoding utf8

    $common = @{
        ExpectedBuildId = $buildId
        ExpectedArtifactSha256 = $artifactSha256
        ProfilePath = $profile
        ModsPath = $mods
        CommunityShadersRoot = $csxRoot
        Compact = $true
        NoExit = $true
    }
    $prepared = & $scriptPath @common -UserAuthorized `
        -AuthorizationStatement 'frozen Ghidra' | ConvertFrom-Json -Depth 30
    $expectedProject = 'CSX-{0}-{1}' -f (
        $buildId.Substring(0, 16)
    ), ($artifactSha256.Substring(0, 16).ToLowerInvariant())
    Assert-Test $prepared.ok 'Authorized frozen Ghidra preparation failed.'
    Assert-Test (
        $prepared.binding.projectName -ceq $expectedProject
    ) 'Build-specific Ghidra project key is incorrect.'
    Assert-Test (
        $prepared.binding.artifactSha256 -eq $artifactSha256
    ) 'Physical artifact SHA-256 was not retained.'
    Assert-Test (
        $prepared.userAuthorized -and $prepared.state -ceq 'starting' -and
        $prepared.ghidra.managed
    ) 'Bound Ghidra analysis startup was incorrectly treated as a failure.'
    Assert-Test (
        $prepared.projectSwitch.from -ceq 'stale-project' -and
        $prepared.projectSwitch.to -ceq $expectedProject
    ) 'The stale generic project was not switched exactly once.'

    $unauthorized = & $scriptPath @common | ConvertFrom-Json -Depth 30
    Assert-Test (
        -not $unauthorized.ok -and
        $unauthorized.errors[0] -like '*explicit user request*'
    ) 'Ghidra preparation did not fail closed without user authorization.'

    $wrongHashArguments = @{
        ExpectedBuildId = $buildId
        ExpectedArtifactSha256 = ('b' * 64)
        ProfilePath = $profile
        ModsPath = $mods
        CommunityShadersRoot = $csxRoot
        ResolveOnly = $true
        Compact = $true
        NoExit = $true
    }
    $wrongHash = & $scriptPath @wrongHashArguments |
        ConvertFrom-Json -Depth 30
    Assert-Test (
        -not $wrongHash.ok -and
        $wrongHash.errors[0] -like '*does not match*'
    ) 'Physical artifact identity mismatch did not fail closed.'

    [pscustomobject][ordered]@{
        ok = $true
        explicitAuthorization = $true
        physicalProvider = $true
        provenanceBound = $true
        buildSpecificProject = $expectedProject
        staleProjectSwitched = $true
        identityMismatchFailsClosed = $true
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture -PathType Container) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
