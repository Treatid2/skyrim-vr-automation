# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\skyrim-vr-automation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$destination = [IO.Path]::GetFullPath($OutputDirectory)
if ([IO.Path]::GetFileName($destination) -ne 'skyrim-vr-automation') { throw "Refusing unexpected distribution target: $destination" }
if ($destination -eq $repositoryRoot -or $repositoryRoot.StartsWith($destination + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Distribution target would contain or replace the source repository: $destination"
}

if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
New-Item -ItemType Directory -Path $destination -Force | Out-Null

$rootFiles = @('.mcp.json', 'AGENTS.md', 'LICENSE', 'README.md', 'toolset.manifest.json', 'CHANGELOG.md', 'PRIVACY.md', 'SUPPORT.md', 'TERMS.md')
foreach ($relative in $rootFiles) {
    $source = Join-Path $repositoryRoot $relative
    if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $destination $relative) }
}

foreach ($tree in @('.codex-plugin', 'skills', 'tools', 'profiles', 'docs', 'native', 'drivers')) {
    $sourceRoot = Join-Path $repositoryRoot $tree
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        if ($file.Name -like '*.local.json' -or
            $relative -match '(^|[\\/])sessions([\\/]|$)' -or
            ($tree -eq 'native' -and $relative -match '(^|[\\/])build(?:-[^\\/]+)?([\\/]|$)') -or
            $relative -match '(^|[\\/])[.]fixture-refresh-[^\\/]+([\\/]|$)') { continue }
        $target = Join-Path (Join-Path $destination $tree) $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

$files = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
[pscustomobject][ordered]@{
    ok = $true
    outputDirectory = $destination
    files = $files.Count
    bytes = [long](($files | Measure-Object Length -Sum).Sum)
} | ConvertTo-Json
