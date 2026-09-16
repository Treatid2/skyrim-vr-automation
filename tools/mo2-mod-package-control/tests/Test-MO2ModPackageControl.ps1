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
    $jsonLines = @($output | ForEach-Object { [string]$_ })
    $jsonStart = 0
    while ($jsonStart -lt $jsonLines.Count -and -not $jsonLines[$jsonStart].TrimStart().StartsWith('{')) { $jsonStart++ }
    if ($jsonStart -eq $jsonLines.Count) { throw "Controller returned no JSON: $text" }
    $parsed = ($jsonLines[$jsonStart..($jsonLines.Count - 1)] -join "`n") | ConvertFrom-Json -Depth 30
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

    # Root plugins/archives have no directory segments. Exercise both public
    # commands, including singleton and mixed root/nested payload cardinality.
    $rootCases = @(
        @{ name = 'esp-only'; members = @{ 'Example.esp' = 'esp' } },
        @{ name = 'bsa-only'; members = @{ 'Example.bsa' = 'bsa' } },
        @{ name = 'root-pair'; members = @{ 'Example.esp' = 'esp'; 'Example.bsa' = 'bsa' } },
        @{ name = 'mixed'; members = @{ 'Example.esp' = 'esp'; 'Example.bsa' = 'bsa'; 'SKSE/Plugins/Example.dll' = 'dll'; 'Interface/VR/menu.swf' = 'swf' } }
    )
    foreach ($case in $rootCases) {
        $caseRoot = Join-Path $fixture $case.name
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        foreach ($member in $case.members.Keys) {
            $memberPath = Join-Path $caseRoot $member
            New-Item -ItemType Directory -Path (Split-Path -Parent $memberPath) -Force | Out-Null
            [IO.File]::WriteAllText($memberPath, $case.members[$member])
        }
        $caseArchive = Join-Path $fixture ($case.name + '.zip')
        $planned = Invoke-Control @('package', '-DataRoot', $caseRoot, '-OutputPath', $caseArchive, '-WhatIf')
        # WhatIf emits its standard informational line before the JSON result.
        Assert-True ($planned.exitCode -eq 0 -and $planned.result.result.state -eq 'planned') "$($case.name): WhatIf plans a direct root"
        Assert-True (-not (Test-Path -LiteralPath $caseArchive) -and -not (Test-Path -LiteralPath ($caseArchive + '.receipt.json'))) "$($case.name): WhatIf creates no package or receipt"
        $created = Invoke-Control @('package', '-DataRoot', $caseRoot, '-OutputPath', $caseArchive)
        Assert-True ($created.exitCode -eq 0 -and $created.result.ok) "$($case.name): package succeeds"
        $inspected = Invoke-Control @('inspect', '-ArchivePath', $caseArchive)
        Assert-True ($inspected.exitCode -eq 0 -and $inspected.result.result.layout.classification -eq 'direct-data-root') "$($case.name): inspect recognizes direct Data root"
        Assert-True (-not $inspected.result.result.layout.requiresInstallerFlattening -and $null -eq $inspected.result.result.layout.recommendedSourceRoot) "$($case.name): no wrapper recommendation or flattening dependency"
        Assert-True (@(Compare-Object @($case.members.Keys | Sort-Object) @($inspected.result.result.files.path | Sort-Object)).Count -eq 0) "$($case.name): member paths are preserved"
        $caseReceipt = Get-Content -LiteralPath ($caseArchive + '.receipt.json') -Raw | ConvertFrom-Json
        Assert-True ($caseReceipt.fileCount -eq $case.members.Count -and $caseReceipt.archiveSha256 -eq $inspected.result.result.sha256) "$($case.name): receipt matches archive"
        foreach ($sourceFile in $caseReceipt.sourceFiles) {
            Assert-True ($sourceFile.sha256 -eq (Get-FileHash -LiteralPath (Join-Path $caseRoot $sourceFile.path) -Algorithm SHA256).Hash.ToLowerInvariant()) "$($case.name): receipt source hash matches $($sourceFile.path)"
        }
    }

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
