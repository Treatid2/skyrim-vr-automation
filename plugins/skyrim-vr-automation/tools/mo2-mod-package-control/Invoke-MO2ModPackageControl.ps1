# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('inspect', 'package')]
    [string]$Command,

    [string]$ArchivePath,

    [string]$DataRoot,

    [string]$OutputPath,

    [string[]]$DocumentationFiles,

    [switch]$AllowUnrecognizedPayload,

    [switch]$Force,

    [ValidateRange(1, 100000)]
    [int]$MaximumEntries = 10000,

    [ValidateRange(1, 100000)]
    [int]$MaximumDirectories = 10000,

    [ValidateRange(1, 256)]
    [int]$MaximumDepth = 64,

    [ValidateRange(1, 1099511627776)]
    [long]$MaximumUncompressedBytes = 4294967296,

    [switch]$NoExit,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression

$script:KnownDataDirectories = @(
    'asi', 'calientetools', 'interface', 'meshes', 'mcm', 'music',
    'netScriptFramework', 'root', 'scripts', 'seq', 'shadersfx', 'skse',
    'sound', 'strings', 'textures', 'tools', 'video'
)
$script:KnownRootFileExtensions = @('.bsa', '.esl', '.esm', '.esp')
$script:DocumentationExtensions = @('.bmp', '.jpeg', '.jpg', '.md', '.pdf', '.png', '.txt')

function Write-Result([object]$Result, [int]$ExitCode) {
    $json = if ($Compact) { $Result | ConvertTo-Json -Depth 20 -Compress } else { $Result | ConvertTo-Json -Depth 20 }
    Write-Output $json
    if (-not $NoExit) { exit $ExitCode }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-TextAtomically([string]$Path, [string]$Text) {
    $temporary = Join-Path (Split-Path -Parent $Path) ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Assert-NoReparsePointPath([string]$Path, [string]$Purpose) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Purpose traverses a reparse point and is not qualified: $($item.FullName)"
        }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function ConvertTo-NormalizedArchivePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw 'Archive member paths must be non-empty and contain no NUL characters.'
    }
    $normalized = $Path.Replace('\', '/').TrimStart('/')
    if ($Path.StartsWith('/') -or $Path.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        throw "Archive member path is rooted: $Path"
    }
    $segments = @($normalized.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '..' -or $_ -eq '.' }).Count -gt 0) {
        throw "Archive member path is not a safe relative path: $Path"
    }
    if ($segments.Count -gt $MaximumDepth) { throw "Archive member path exceeds depth limit $MaximumDepth`: $Path" }
    foreach ($segment in $segments) {
        if ($segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            throw "Archive member path is not safe for Windows extraction: $Path"
        }
        $baseName = [IO.Path]::GetFileNameWithoutExtension($segment)
        if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Archive member path uses a reserved Windows device name: $Path"
        }
    }
    return $segments -join '/'
}

function Test-DocumentationPath([string]$Path) {
    return $script:DocumentationExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Test-DirectDataPath([string]$Path) {
    $normalized = ConvertTo-NormalizedArchivePath $Path
    $segments = @($normalized.Split('/'))
    $top = $segments[0]
    if ($segments.Count -gt 1 -and $script:KnownDataDirectories -contains $top.ToLowerInvariant()) { return $true }
    return $segments.Count -eq 1 -and $script:KnownRootFileExtensions -contains [IO.Path]::GetExtension($top).ToLowerInvariant()
}

function Get-CommonDirectoryPrefix([string[]]$Paths) {
    if ($Paths.Count -eq 0) { return @() }
    $split = [Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        $segments = @($path -split '/')
        # Capture the whole conditional so a root-level file retains an empty
        # array instead of PowerShell unrolling the branch result to $null.
        $directories = @(if ($segments.Count -gt 1) { $segments[0..($segments.Count - 2)] })
        $split.Add($directories)
    }
    $minimum = [int]::MaxValue
    foreach ($directories in $split) { $minimum = [Math]::Min($minimum, @($directories).Count) }
    if ($minimum -le 0) { return @() }
    $prefix = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $minimum; $index++) {
        $candidate = [string]$split[0][$index]
        $mismatch = $false
        foreach ($directories in $split) {
            if (-not [string]::Equals([string]$directories[$index], $candidate, [StringComparison]::OrdinalIgnoreCase)) { $mismatch = $true; break }
        }
        if ($mismatch) { break }
        $prefix.Add($candidate)
    }
    return @($prefix)
}

function Get-ArchiveLayout([object[]]$Files) {
    $paths = @($Files | ForEach-Object { [string]$_.path })
    $payloadPaths = @($paths | Where-Object { -not (Test-DocumentationPath $_) })
    $directPayload = @($payloadPaths | Where-Object { Test-DirectDataPath $_ })
    $topDirectories = @($paths | Where-Object { $_ -like '*/*' } | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
    $topFiles = @($paths | Where-Object { $_ -notlike '*/*' })
    $commonPrefix = @(Get-CommonDirectoryPrefix -Paths $payloadPaths)

    $candidateAfterPrefix = @()
    $selectedPrefix = @()
    $strippedLooksLikeData = $false
    for ($depth = 1; $depth -le $commonPrefix.Count; $depth++) {
        $probePrefix = @($commonPrefix[0..($depth - 1)])
        $prefixText = ($probePrefix -join '/') + '/'
        $probePaths = @($payloadPaths | ForEach-Object { if ($_.StartsWith($prefixText, [StringComparison]::OrdinalIgnoreCase)) { $_.Substring($prefixText.Length) } else { $_ } })
        if (@($probePaths | Where-Object { Test-DirectDataPath $_ }).Count -gt 0) {
            $candidateAfterPrefix = $probePaths
            $selectedPrefix = $probePrefix
            $strippedLooksLikeData = $true
            break
        }
    }

    $classification = 'unrecognized-layout'
    $safeForDirectInstall = $false
    $requiresFlattening = $false
    $recommendedSourceRoot = $null
    $reason = 'No recognized Skyrim Data-root payload was found at archive root.'

    if ($directPayload.Count -gt 0) {
        $classification = 'direct-data-root'
        $safeForDirectInstall = $true
        $reason = 'Recognized Skyrim Data-root payload is present at archive root; installation does not depend on MO2 flattening.'
    }
    elseif ($selectedPrefix.Count -gt 0 -and $strippedLooksLikeData) {
        $requiresFlattening = $true
        $recommendedSourceRoot = $selectedPrefix -join '/'
        if ($topFiles.Count -eq 0 -and $topDirectories.Count -eq 1) {
            $classification = 'single-wrapper-flatten-dependent'
            $reason = 'All payload is below one wrapper directory. MO2 may descend through it, but the archive depends on implicit flattening.'
        }
        elseif ($topDirectories.Count -eq 1 -and [string]::Equals($topDirectories[0], 'Data', [StringComparison]::OrdinalIgnoreCase) -and @($topFiles | Where-Object { -not (Test-DocumentationPath $_) }).Count -eq 0) {
            $classification = 'data-wrapper-with-supported-docs'
            $reason = 'The archive matches MO2 quick-installer special handling for a Data directory plus root documentation/image files, but still depends on installer shaping.'
        }
        else {
            $classification = 'wrapper-blocked-by-siblings'
            $reason = 'A candidate Data root exists below a wrapper, but sibling root entries prevent deterministic flattening.'
        }
    }

    return [pscustomobject][ordered]@{
        classification = $classification
        safeForDirectInstall = $safeForDirectInstall
        requiresInstallerFlattening = $requiresFlattening
        recommendedSourceRoot = $recommendedSourceRoot
        topLevelDirectories = $topDirectories
        topLevelFiles = $topFiles
        reason = $reason
    }
}

function Get-ZipInspection([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Archive does not exist: $resolved" }
    Assert-NoReparsePointPath -Path $resolved -Purpose 'ArchivePath'

    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $entries = @($archive.Entries)
            if ($entries.Count -gt $MaximumEntries) { throw "Archive contains $($entries.Count) entries; limit is $MaximumEntries." }
            $files = [Collections.Generic.List[object]]::new()
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            [long]$total = 0
            foreach ($entry in $entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) { continue }
                $externalAttributes = [uint32]([int64]$entry.ExternalAttributes -band 0xffffffffL)
                $unixMode = ($externalAttributes -shr 16) -band 0xF000
                if ($unixMode -eq 0xA000) { throw "Archive contains a symbolic-link member: $($entry.FullName)" }
                $normalized = ConvertTo-NormalizedArchivePath $entry.FullName
                if (-not $seen.Add($normalized)) { throw "Archive contains a case-insensitive duplicate member path: $normalized" }
                if ([long]$entry.Length -gt ($MaximumUncompressedBytes - $total)) { throw "Archive uncompressed bytes exceed limit $MaximumUncompressedBytes." }
                $total += [long]$entry.Length
                if ($total -gt $MaximumUncompressedBytes) { throw "Archive uncompressed bytes exceed limit $MaximumUncompressedBytes." }
                $files.Add([pscustomobject][ordered]@{
                    path = $normalized
                    compressedBytes = [long]$entry.CompressedLength
                    uncompressedBytes = [long]$entry.Length
                })
            }
            if ($files.Count -eq 0) { throw 'Archive contains no files.' }
            $layout = Get-ArchiveLayout -Files @($files)
            return [pscustomobject][ordered]@{
                archivePath = $resolved
                sha256 = Get-Sha256 $resolved
                fileCount = $files.Count
                uncompressedBytes = $total
                layout = $layout
                files = @($files | Sort-Object path)
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-PackageSourceFiles([string]$Root, [string[]]$Docs) {
    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { throw "DataRoot does not exist: $resolvedRoot" }
    Assert-NoReparsePointPath -Path $resolvedRoot -Purpose 'DataRoot'

    $files = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[object]]::new()
    $pending.Push([pscustomobject]@{ path = $resolvedRoot; depth = 0 })
    $directoryCount = 1
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current.path -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Package source contains a reparse point and is not qualified: $($item.FullName)"
            }
            if ($item -is [IO.DirectoryInfo]) {
                $depth = [int]$current.depth + 1
                if ($depth -gt $MaximumDepth) { throw "Package source exceeds depth limit $MaximumDepth`: $($item.FullName)" }
                $directoryCount++
                if ($directoryCount -gt $MaximumDirectories) { throw "Package source exceeds directory limit $MaximumDirectories." }
                $pending.Push([pscustomobject]@{ path = $item.FullName; depth = $depth })
                continue
            }
            $relative = ConvertTo-NormalizedArchivePath ([IO.Path]::GetRelativePath($resolvedRoot, $item.FullName))
            if (-not $seen.Add($relative)) { throw "Package source contains a case-insensitive path collision: $relative" }
            $files.Add([pscustomobject][ordered]@{ sourcePath = $item.FullName; path = $relative; length = [long]$item.Length })
            if ($files.Count -gt $MaximumEntries) { throw "Package contains more than the $MaximumEntries file limit." }
        }
    }
    foreach ($doc in @($Docs)) {
        if ([string]::IsNullOrWhiteSpace($doc)) { continue }
        $resolvedDoc = [IO.Path]::GetFullPath($doc)
        if (-not (Test-Path -LiteralPath $resolvedDoc -PathType Leaf)) { throw "Documentation file does not exist: $resolvedDoc" }
        Assert-NoReparsePointPath -Path $resolvedDoc -Purpose 'Documentation file'
        $entryPath = ConvertTo-NormalizedArchivePath ('docs/' + [IO.Path]::GetFileName($resolvedDoc))
        if (-not $seen.Add($entryPath)) { throw "Documentation entry collides with another package member: $entryPath" }
        $item = Get-Item -LiteralPath $resolvedDoc
        $files.Add([pscustomobject][ordered]@{ sourcePath = $resolvedDoc; path = $entryPath; length = [long]$item.Length })
    }
    if ($files.Count -eq 0) { throw 'DataRoot and documentation selection contain no files.' }
    [long]$total = 0
    foreach ($file in $files) {
        if ([long]$file.length -gt ($MaximumUncompressedBytes - $total)) { throw "Package source bytes exceed limit $MaximumUncompressedBytes." }
        $total += [long]$file.length
    }
    if ($total -gt $MaximumUncompressedBytes) { throw "Package source bytes exceed limit $MaximumUncompressedBytes." }

    $layout = Get-ArchiveLayout -Files @($files)
    if (-not $layout.safeForDirectInstall -and -not $AllowUnrecognizedPayload) {
        $hint = if ($layout.recommendedSourceRoot) { " Pass the actual Data root instead, likely '$($layout.recommendedSourceRoot)'." } else { '' }
        throw "DataRoot is not a recognized direct Skyrim Data root.$hint Use -AllowUnrecognizedPayload only after independently verifying a non-standard layout."
    }
    return [pscustomobject][ordered]@{ root = $resolvedRoot; files = @($files | Sort-Object path); bytes = $total; layout = $layout }
}

function Write-ZipPackage([object]$Source, [string]$Destination) {
    $resolvedOutput = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetExtension($resolvedOutput) -ine '.zip') { throw 'OutputPath must have a .zip extension.' }
    $outputDirectory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw "Output directory does not exist: $outputDirectory" }
    Assert-NoReparsePointPath -Path $outputDirectory -Purpose 'Output directory'
    if ($resolvedOutput.StartsWith($Source.root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputPath must not be inside DataRoot.'
    }
    $receiptPath = $resolvedOutput + '.receipt.json'
    if (((Test-Path -LiteralPath $resolvedOutput) -or (Test-Path -LiteralPath $receiptPath)) -and -not $Force) { throw "Output or receipt already exists; use -Force to replace the exact package pair: $resolvedOutput" }

    $temporary = Join-Path $outputDirectory ('.' + [IO.Path]::GetFileName($resolvedOutput) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if (-not $PSCmdlet.ShouldProcess($resolvedOutput, "Create deterministic MO2 package from $($Source.root)")) {
            return [pscustomobject][ordered]@{ state = 'planned'; outputPath = $resolvedOutput; fileCount = @($Source.files).Count; uncompressedBytes = $Source.bytes; layout = $Source.layout }
        }
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            try {
                foreach ($file in $Source.files) {
                    $entry = $archive.CreateEntry([string]$file.path, [IO.Compression.CompressionLevel]::Optimal)
                    $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                    $input = [IO.File]::Open([string]$file.sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    try {
                        $output = $entry.Open()
                        try { $input.CopyTo($output) } finally { $output.Dispose() }
                    }
                    finally { $input.Dispose() }
                }
            }
            finally { $archive.Dispose() }
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $resolvedOutput, [bool](Test-Path -LiteralPath $resolvedOutput))

        $inspection = Get-ZipInspection $resolvedOutput
        if (-not $inspection.layout.safeForDirectInstall -and -not $AllowUnrecognizedPayload) {
            throw 'Created archive failed direct-install layout verification.'
        }
        $receipt = [pscustomobject][ordered]@{
            schemaVersion = '1.0'
            operation = 'package'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            dataRoot = $Source.root
            outputPath = $resolvedOutput
            archiveSha256 = $inspection.sha256
            fileCount = $inspection.fileCount
            uncompressedBytes = $inspection.uncompressedBytes
            layout = $inspection.layout
            sourceFiles = @($Source.files | ForEach-Object { [pscustomobject][ordered]@{ path = $_.path; length = $_.length; sha256 = Get-Sha256 $_.sourcePath } })
        }
        try { Write-TextAtomically -Path $receiptPath -Text (($receipt | ConvertTo-Json -Depth 20) + "`n") }
        catch { throw "Package was committed at '$resolvedOutput', but its receipt could not be committed: $($_.Exception.Message)" }
        return [pscustomobject][ordered]@{ state = 'created'; outputPath = $resolvedOutput; receiptPath = $receiptPath; inspection = $inspection }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

try {
    switch ($Command) {
        'inspect' {
            if ([string]::IsNullOrWhiteSpace($ArchivePath)) { throw '-ArchivePath is required for inspect.' }
            $result = [pscustomobject][ordered]@{ ok = $true; command = 'inspect'; result = Get-ZipInspection $ArchivePath }
        }
        'package' {
            if ([string]::IsNullOrWhiteSpace($DataRoot)) { throw '-DataRoot is required for package.' }
            if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw '-OutputPath is required for package.' }
            $source = Get-PackageSourceFiles -Root $DataRoot -Docs $DocumentationFiles
            $result = [pscustomobject][ordered]@{ ok = $true; command = 'package'; result = Write-ZipPackage -Source $source -Destination $OutputPath }
        }
    }
    Write-Result $result 0
}
catch {
    Write-Result ([pscustomobject][ordered]@{ ok = $false; command = $Command; error = $_.Exception.Message }) 1
}
