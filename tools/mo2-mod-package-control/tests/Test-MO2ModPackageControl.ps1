# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$controller = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Invoke-MO2ModPackageControl.ps1'))
$powerShell = (Get-Process -Id $PID).Path
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-mod-package-control-' + [guid]::NewGuid().ToString('N'))
$assertions = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:assertions++
}

function Invoke-Control([string[]]$Arguments) {
    $output = & $powerShell -NoProfile -NonInteractive -File $controller @Arguments -Compact 2>&1
    $exitCode = $LASTEXITCODE
    $text = @($output | ForEach-Object { [string]$_ }) -join "`n"
    $parsed = $text | ConvertFrom-Json -Depth 30
    return [pscustomobject]@{ exitCode = $exitCode; output = $text; result = $parsed }
}

function New-TestZip([string]$Path, [hashtable]$Members) {
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in @($Members.Keys | Sort-Object)) {
                $entry = $archive.CreateEntry($name)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write([string]$Members[$name]) } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $dataRoot = Join-Path $fixture 'Data'
    New-Item -ItemType Directory -Path (Join-Path $dataRoot 'SKSE\Plugins') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dataRoot 'SKSE\Plugins\Example.dll'), 'dll-bytes')
    [IO.File]::WriteAllText((Join-Path $fixture 'LICENSE.txt'), 'license')

    $packageA = Join-Path $fixture 'a.zip'
    $createdA = Invoke-Control @('package', '-DataRoot', $dataRoot, '-OutputPath', $packageA, '-DocumentationFiles', (Join-Path $fixture 'LICENSE.txt'))
    Assert-True ($createdA.exitCode -eq 0 -and $createdA.result.ok) 'package succeeds for an explicit Data root'
    Assert-True ($createdA.result.result.inspection.layout.classification -eq 'direct-data-root') 'created package is a direct Data-root layout'
    Assert-True (Test-Path -LiteralPath ($packageA + '.receipt.json') -PathType Leaf) 'package writes a receipt'

    $packageB = Join-Path $fixture 'b.zip'
    $createdB = Invoke-Control @('package', '-DataRoot', $dataRoot, '-OutputPath', $packageB, '-DocumentationFiles', (Join-Path $fixture 'LICENSE.txt'))
    Assert-True ($createdB.exitCode -eq 0) 'second deterministic package succeeds'
    Assert-True ((Get-FileHash $packageA -Algorithm SHA256).Hash -eq (Get-FileHash $packageB -Algorithm SHA256).Hash) 'same inputs produce identical ZIP bytes'

    $inspection = Invoke-Control @('inspect', '-ArchivePath', $packageA)
    Assert-True ($inspection.exitCode -eq 0 -and $inspection.result.result.layout.safeForDirectInstall) 'inspect accepts the generated archive'
    Assert-True (@($inspection.result.result.files.path) -contains 'SKSE/Plugins/Example.dll') 'Data-root content is at archive root'
    Assert-True (@($inspection.result.result.files.path) -contains 'docs/LICENSE.txt') 'documentation is isolated below docs'

    $wrapperZip = Join-Path $fixture 'wrapper.zip'
    New-TestZip $wrapperZip @{ 'My Mod/SKSE/Plugins/Example.dll' = 'dll' }
    $wrapper = Invoke-Control @('inspect', '-ArchivePath', $wrapperZip)
    Assert-True ($wrapper.result.result.layout.classification -eq 'single-wrapper-flatten-dependent') 'single wrapper is identified as flatten-dependent'
    Assert-True ($wrapper.result.result.layout.recommendedSourceRoot -eq 'My Mod') 'wrapper source-root correction is reported'

    $blockedZip = Join-Path $fixture 'blocked.zip'
    New-TestZip $blockedZip @{ 'My Mod/SKSE/Plugins/Example.dll' = 'dll'; 'LICENSE.txt' = 'license' }
    $blocked = Invoke-Control @('inspect', '-ArchivePath', $blockedZip)
    Assert-True ($blocked.result.result.layout.classification -eq 'wrapper-blocked-by-siblings') 'wrapper plus sibling documentation is classified as blocked'

    $dataDocsZip = Join-Path $fixture 'data-docs.zip'
    New-TestZip $dataDocsZip @{ 'Data/SKSE/Plugins/Example.dll' = 'dll'; 'README.md' = 'readme' }
    $dataDocs = Invoke-Control @('inspect', '-ArchivePath', $dataDocsZip)
    Assert-True ($dataDocs.result.result.layout.classification -eq 'data-wrapper-with-supported-docs') 'Data plus supported root docs is classified explicitly'

    $wrongRoot = Invoke-Control @('package', '-DataRoot', $fixture, '-OutputPath', (Join-Path $fixture '..\wrong.zip'))
    Assert-True ($wrongRoot.exitCode -ne 0 -and -not $wrongRoot.result.ok) 'packager rejects a parent/wrapper directory'

    $traversalZip = Join-Path $fixture 'traversal.zip'
    New-TestZip $traversalZip @{ '../escape.dll' = 'bad' }
    $traversal = Invoke-Control @('inspect', '-ArchivePath', $traversalZip)
    Assert-True ($traversal.exitCode -ne 0 -and -not $traversal.result.ok) 'inspect rejects traversal members'

    [pscustomobject]@{ ok = $true; assertions = $assertions } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
