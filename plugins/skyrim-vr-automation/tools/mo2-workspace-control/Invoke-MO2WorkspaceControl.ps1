# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('create', 'resume', 'list-task', 'inspect', 'fixture-status', 'refresh-fixture', 'prepare-source', 'complete-output', 'create-mod', 'register-mod', 'ensure-mod-wins', 'retire', 'release')]
    [string]$Command,

    [string]$ConfigPath,
    [string]$AccessId,
    [string]$WorkspaceId,
    [string]$TaskId,
    [string]$Label = 'task',
    [string]$SourceProfile,
    [ValidateSet('MainMenuOnly', 'FreshGame', 'VerifiedFixture')]
    [string]$SavePolicy = 'MainMenuOnly',
    [string]$FixtureManifestPath,
    [string]$FixtureId,
    [string]$ModName,
    [string]$ModDirectory,
    [ValidateSet('End', 'Before', 'After')]
    [string]$Placement = 'End',
    [string]$RelativeToMod,
    [string[]]$WinningPaths,
    [string]$WinningPathsFile,
    [switch]$RegisterEnabled,
    [switch]$CleanupOwnedMods,
    [ValidateRange(100, 60000)]
    [int]$TransactionLockTimeoutMilliseconds = 10000,
    [ValidateRange(1, 100000)]
    [int]$MaxProfileFiles = 20000,
    [ValidateRange(1, 20000)]
    [int]$MaxProfileDirectories = 4096,
    [ValidateRange(1, 64)]
    [int]$MaxProfileDepth = 16,
    [ValidateRange(1048576, 137438953472)]
    [long]$MaxProfileBytes = 34359738368,
    [ValidateRange(5, 600)]
    [int]$TreeOperationTimeoutSeconds = 120,
    [ValidateSet('', 'selected-profile-before-cas', 'tree-operation-deadline', 'owner-marker-before-claim')]
    [string]$InternalTestFailurePoint = '',
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'mo2-control\ConfigResolution.psm1') -Force
Import-Module (Join-Path $toolRoot 'mo2-control\MO2Control.psm1') -Force

function Resolve-WorkspaceWinningPaths([string[]]$Inline, [string]$File) {
    $values = [Collections.Generic.List[string]]::new()
    foreach ($value in @($Inline)) { if (-not [string]::IsNullOrWhiteSpace($value)) { $values.Add($value.Trim()) } }
    if (-not [string]::IsNullOrWhiteSpace($File)) {
        $resolved = [IO.Path]::GetFullPath($File)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "WinningPathsFile does not exist: $resolved" }
        $raw = Get-Content -LiteralPath $resolved -Raw
        $parsed = $null
        $jsonArray = $raw.TrimStart().StartsWith('[')
        try { $parsed = $raw | ConvertFrom-Json -Depth 5 -ErrorAction Stop } catch { if ($jsonArray) { throw 'WinningPathsFile begins as JSON but is not a valid JSON string array.' } }
        $entries = if ($jsonArray) { @($parsed) } else { @($raw -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) }
        foreach ($entry in $entries) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) { throw 'WinningPathsFile must contain a JSON string array or one relative path per line.' }
            $values.Add($entry.Trim())
        }
    }
    return @($values | Select-Object -Unique)
}

$resolvedWinningPaths = @(Resolve-WorkspaceWinningPaths -Inline $WinningPaths -File $WinningPathsFile)

function New-WorkspaceApprovalMetadata([string]$Subcommand) {
    $hostExecutable = [string][Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) { $hostExecutable = [string](Get-Process -Id $PID -ErrorAction Stop).Path }
    $entryPoint = [IO.Path]::GetFullPath($PSCommandPath)
    $oneShotCommands = @('refresh-fixture', 'complete-output', 'retire', 'release')
    return [pscustomobject][ordered]@{
        hostExecutable = $hostExecutable; entryPoint = $entryPoint; subcommand = $Subcommand
        reusablePrefix = @($hostExecutable, '-NoProfile', '-NonInteractive', '-File', $entryPoint, $Subcommand)
        reusableApprovalEligible = $Subcommand -notin $oneShotCommands
        escalationUsuallyRequired = $Subcommand -notin @('inspect', 'fixture-status', 'list-task', 'prepare-source')
        oneShotReason = if ($Subcommand -eq 'refresh-fixture') { 'Shared fixture replacement must remain a one-shot approval.' } elseif ($Subcommand -eq 'complete-output') { 'Restoring the exact pre-task MO2 Overwrite backup tree must remain a one-shot approval.' } elseif ($Subcommand -in @('retire', 'release')) { 'Recursive owned-workspace removal must remain a one-shot approval.' } else { $null }
        invocationRule = 'Use this literal prefix directly. Put changing access, workspace, mod, and evidence arguments afterward; do not hide the prefix in variables, -Command, pipelines, or a command string.'
    }
}

function Write-WorkspaceJsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function New-WorkspaceOutputOwnerMarker([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "MO2 Overwrite root does not exist: $parent" }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12))
    $expectedHash = Get-WorkspaceBytesSha256 -Bytes $bytes
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $expectedHash) {
        throw 'MO2 Overwrite owner marker did not persist with its exact claimed bytes.'
    }
    return $expectedHash
}

function Assert-WorkspaceOutputOwnerMarker(
    [string]$Path,
    [string]$ExpectedSha256,
    [string]$WorkspaceId,
    [string]$OwnershipId,
    [string]$OverwritePath
) {
    if ($ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Workspace output ownership lacks an exact owner-marker hash.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The task-owned MO2 Overwrite marker is missing: $Path" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $ExpectedSha256) { throw 'MO2 Overwrite owner marker changed after ownership was claimed.' }
    try { $marker = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20 }
    catch { throw "MO2 Overwrite owner marker is unreadable: $($_.Exception.Message)" }
    foreach ($required in @('workspaceId', 'ownershipId', 'mode', 'overwritePath')) {
        if (-not $marker.PSObject.Properties[$required]) { throw "MO2 Overwrite owner marker lacks '$required'." }
    }
    if ([string]$marker.workspaceId -cne $WorkspaceId -or
        [string]$marker.ownershipId -cne $OwnershipId -or
        [string]$marker.mode -cne 'mo2-overwrite-output' -or
        -not (Test-WorkspaceSamePath ([string]$marker.overwritePath) $OverwritePath)) {
        throw 'MO2 Overwrite owner marker belongs to a different workspace transaction.'
    }
    return $marker
}

function Remove-WorkspaceCreatedOutputTree([string]$Path, [string]$OverwritePath, [string]$Purpose) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($OverwritePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolvedPath.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-WorkspaceSamePath (Split-Path -Parent $resolvedPath) $resolvedRoot)) {
        throw "$Purpose cleanup target is not an exact child of MO2 Overwrite: $resolvedPath"
    }
    Assert-NoWorkspaceReparsePoint -Path $resolvedPath -Purpose $Purpose
    $inventory = Get-BoundedTreeInventory -Path $resolvedPath -Purpose "$Purpose absence restoration"
    if ($inventory.fileCount -ne 0 -or $inventory.directoryCount -ne 0) {
        throw "$Purpose was absent before the task but is not empty after baseline restoration."
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Resolve-WorkspaceCommunityShadersBuildBinding([string]$ProfilePath, [string]$ModsPath, [string]$TransactionTool) {
    $relativePluginPath = 'SKSE\Plugins\CommunityShaders.dll'
    $providers = & $TransactionTool providers -ProfilePath $ProfilePath -ModsPath $ModsPath -RelativeCachePath $relativePluginPath -NoExit -Confirm:$false | ConvertFrom-Json -Depth 40
    if (-not $providers.ok) { throw "Could not inspect the winning Community Shaders provider: $($providers.errors -join '; ')" }
    $winner = $providers.data.effectiveWinnerAmongEnabledMods
    if ($null -eq $winner -or [string]$winner.providerType -cne 'file') { throw 'The task profile has no exact enabled loose-file CommunityShaders.dll winner.' }
    $pluginPath = [IO.Path]::GetFullPath([string]$winner.providerPath)
    $manifestPath = Join-Path ([string]$winner.modRoot) 'SKSE\Plugins\CSX.BuildManifest.json'
    if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The winning Community Shaders provider lacks its DLL or CSX.BuildManifest.json.'
    }
    try { $buildManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 40 }
    catch { throw "The winning Community Shaders build manifest is invalid JSON: $($_.Exception.Message)" }
    $buildId = if ($buildManifest.PSObject.Properties['buildId']) { [string]$buildManifest.buildId } else { '' }
    $artifact = if ($buildManifest.PSObject.Properties['artifact']) { $buildManifest.artifact } else { $null }
    $artifactHash = if ($null -ne $artifact -and $artifact.PSObject.Properties['sha256']) { [string]$artifact.sha256 } else { '' }
    $artifactBytes = if ($null -ne $artifact -and $artifact.PSObject.Properties['sizeBytes']) { [long]$artifact.sizeBytes } else { -1 }
    $identity = if ($buildManifest.PSObject.Properties['identity']) { $buildManifest.identity } else { $null }
    $shaderCache = if ($null -ne $identity -and $identity.PSObject.Properties['shaderCache']) { $identity.shaderCache } else { $null }
    $shaderCacheAbi = if ($null -ne $shaderCache -and $shaderCache.PSObject.Properties['abiId']) { [string]$shaderCache.abiId } else { '' }
    if ([string]::IsNullOrWhiteSpace($buildId) -or $artifactHash -notmatch '^[0-9A-Fa-f]{64}$' -or [string]::IsNullOrWhiteSpace($shaderCacheAbi)) {
        throw 'The winning Community Shaders build manifest lacks an exact build ID, DLL hash, or shader-cache ABI.'
    }
    $plugin = Get-Item -LiteralPath $pluginPath
    $actualHash = (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    if ($actualHash -cne $artifactHash -or ($artifactBytes -ge 0 -and [long]$plugin.Length -ne $artifactBytes)) {
        throw 'The winning Community Shaders DLL does not match its build manifest.'
    }
    return [pscustomobject][ordered]@{
        mode = 'mo2-winning-loose-plugin-provider'; profilePath = [string]$providers.data.profilePath
        profileSha256 = [string]$providers.data.profileSha256; modsPath = [string]$providers.data.modsPath
        relativePluginPath = $relativePluginPath; modName = [string]$winner.modName
        modRoot = [string]$winner.modRoot; pluginPath = $pluginPath; manifestPath = [IO.Path]::GetFullPath($manifestPath)
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        buildId = $buildId; artifactSha256 = $actualHash; artifactBytes = [long]$plugin.Length
        shaderCacheAbi = $shaderCacheAbi
    }
}

function Test-WorkspaceCommunityShadersBuildBinding($Expected, $Current) {
    if ($null -eq $Expected -or $null -eq $Current) { return $false }
    foreach ($required in @('profilePath', 'profileSha256', 'modsPath', 'modName', 'pluginPath', 'manifestPath', 'manifestSha256', 'buildId', 'artifactSha256', 'artifactBytes', 'shaderCacheAbi')) {
        if (-not $Expected.PSObject.Properties[$required] -or -not $Current.PSObject.Properties[$required]) { return $false }
    }
    return (Test-WorkspaceSamePath ([string]$Expected.profilePath) ([string]$Current.profilePath)) -and
        [string]$Expected.profileSha256 -ceq [string]$Current.profileSha256 -and
        (Test-WorkspaceSamePath ([string]$Expected.modsPath) ([string]$Current.modsPath)) -and
        [string]$Expected.modName -ceq [string]$Current.modName -and
        (Test-WorkspaceSamePath ([string]$Expected.pluginPath) ([string]$Current.pluginPath)) -and
        (Test-WorkspaceSamePath ([string]$Expected.manifestPath) ([string]$Current.manifestPath)) -and
        [string]$Expected.manifestSha256 -ceq [string]$Current.manifestSha256 -and
        [string]$Expected.buildId -ceq [string]$Current.buildId -and
        [string]$Expected.artifactSha256 -ceq [string]$Current.artifactSha256 -and
        [long]$Expected.artifactBytes -eq [long]$Current.artifactBytes -and
        [string]$Expected.shaderCacheAbi -ceq [string]$Current.shaderCacheAbi
}

function Get-SafeName([string]$Value) {
    $safe = (($Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-+|-+$)', '')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'task' }
    if ($safe.Length -gt 32) { return $safe.Substring(0, 32).TrimEnd('-') }
    return $safe
}

function Get-CollisionResistantSafeName([string]$Value) {
    $readable = Get-SafeName -Value $Value
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Value))).ToLowerInvariant()
    return "$readable-$($digest.Substring(0, 8))"
}

function Test-WorkspaceSamePath([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    return [string]::Equals(
        [IO.Path]::GetFullPath($Left).TrimEnd('\', '/'),
        [IO.Path]::GetFullPath($Right).TrimEnd('\', '/'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Remove-WorkspaceCustomOverwrite([string]$SettingsPath, [string]$Executable) {
    if ($Executable -match '[\r\n=]') {
        throw 'Executable name must be safe INI key text.'
    }
    $text = if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8)
    }
    else { '' }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @([regex]::Split($text, '\r\n|\n|\r'))) { $lines.Add($line) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Length -eq 0) { $lines.RemoveAt($lines.Count - 1) }

    $sectionIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -ieq '[custom_overwrites]') { $sectionIndexes += $index }
    }
    if ($sectionIndexes.Count -gt 1) { throw 'Task profile settings contain duplicate [custom_overwrites] sections.' }
    $sectionStart = if ($sectionIndexes.Count -eq 1) { [int]$sectionIndexes[0] } else { -1 }
    $sectionEnd = $lines.Count
    if ($sectionStart -ge 0) {
        for ($index = $sectionStart + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index].Trim() -match '^\[.+\]$') { $sectionEnd = $index; break }
        }
    }
    if ($sectionStart -ge 0) {
        for ($index = $sectionEnd - 1; $index -gt $sectionStart; $index--) {
            $separator = $lines[$index].IndexOf('=')
            if ($separator -gt 0 -and $lines[$index].Substring(0, $separator).Trim() -ieq $Executable) {
                $lines.RemoveAt($index)
                $sectionEnd--
            }
        }
    }
    Write-WorkspaceBytesAtomic -Path $SettingsPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($lines -join $newline) + $newline))
}

function Assert-NoWorkspaceReparsePoint([string]$Path, [string]$Purpose) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Purpose traverses a reparse point and is not qualified for workspace mutation: $($item.FullName)" }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Get-WorkspaceBytesSha256([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Assert-TreeOperationBudget([string]$Purpose) {
    if ($null -eq $script:TreeOperationDeadlineUtc) { $script:TreeOperationDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TreeOperationTimeoutSeconds) }
    if ([DateTime]::UtcNow -ge $script:TreeOperationDeadlineUtc) { throw "$Purpose exceeded the shared $TreeOperationTimeoutSeconds-second tree-operation deadline." }
}

function Get-BoundedTreeInventory([string]$Path, [string]$Purpose) {
    $resolvedRoot = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) { throw "$Purpose directory does not exist: $resolvedRoot" }
    Assert-NoWorkspaceReparsePoint -Path $resolvedRoot -Purpose $Purpose
    Assert-TreeOperationBudget -Purpose $Purpose
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ path = $resolvedRoot; depth = 0 })
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[object]]::new()
    [long]$bytes = 0
    while ($queue.Count -gt 0) {
        Assert-TreeOperationBudget -Purpose "$Purpose traversal"
        $current = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath ([string]$current.path) -Force) {
            Assert-TreeOperationBudget -Purpose "$Purpose traversal"
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Purpose contains a reparse point: $($item.FullName)" }
            $relative = [IO.Path]::GetRelativePath($resolvedRoot, $item.FullName)
            if ($item.PSIsContainer) {
                $depth = [int]$current.depth + 1
                if ($depth -gt $MaxProfileDepth) { throw "$Purpose exceeds maximum depth $MaxProfileDepth at '$relative'." }
                if ($directories.Count + 1 -gt $MaxProfileDirectories) { throw "$Purpose exceeds maximum directory count $MaxProfileDirectories." }
                $record = [pscustomobject][ordered]@{ path = $relative; fullPath = $item.FullName; depth = $depth }
                $directories.Add($record)
                $queue.Enqueue([pscustomobject]@{ path = $item.FullName; depth = $depth })
            }
            else {
                if ($files.Count + 1 -gt $MaxProfileFiles) { throw "$Purpose exceeds maximum file count $MaxProfileFiles." }
                $bytes += [long]$item.Length
                if ($bytes -gt $MaxProfileBytes) { throw "$Purpose exceeds maximum byte count $MaxProfileBytes." }
                $files.Add([pscustomobject][ordered]@{ path = $relative; fullPath = $item.FullName; bytes = [long]$item.Length })
            }
        }
    }
    return [pscustomobject][ordered]@{
        root = $resolvedRoot; files = @($files | Sort-Object path); directories = @($directories | Sort-Object depth, path)
        fileCount = $files.Count; directoryCount = $directories.Count; bytes = $bytes
        limits = [pscustomobject][ordered]@{ maxFiles = $MaxProfileFiles; maxDirectories = $MaxProfileDirectories; maxDepth = $MaxProfileDepth; maxBytes = $MaxProfileBytes; timeoutSeconds = $TreeOperationTimeoutSeconds }
    }
}

function Get-WorkspaceOutputInventory([string]$Path, [string]$Purpose) {
    $inventory = Get-BoundedTreeInventory -Path $Path -Purpose $Purpose
    $entries = foreach ($file in @($inventory.files)) {
        Assert-TreeOperationBudget -Purpose "$Purpose hashing"
        [pscustomobject][ordered]@{
            relativePath = ([string]$file.path).Replace('/', '\')
            bytes = [long]$file.bytes
            sha256 = (Get-FileHash -LiteralPath ([string]$file.fullPath) -Algorithm SHA256).Hash
        }
    }
    $canonical = (@($entries) | ForEach-Object { '{0}|{1}|{2}' -f $_.relativePath, $_.bytes, $_.sha256 }) -join "`n"
    return [pscustomobject][ordered]@{
        path = [string]$inventory.root
        files = @($entries).Count
        bytes = [long]$inventory.bytes
        treeSha256 = Get-WorkspaceBytesSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
        entries = @($entries)
        limits = $inventory.limits
    }
}

function Copy-WorkspaceProviderTreeShadow($ProviderResult, [string]$TargetPath, [string]$RelativePath, [string]$Purpose) {
    $resolvedTarget = [IO.Path]::GetFullPath($TargetPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path $resolvedTarget -Force | Out-Null

    $selected = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $copied = [Collections.Generic.List[object]]::new()
    $alreadyPresent = [Collections.Generic.List[object]]::new()
    foreach ($provider in @($ProviderResult.data.providers | Where-Object enabled | Sort-Object lineNumber)) {
        if ([string]$provider.providerType -cne 'directory') {
            throw "$Purpose provider is not a directory: $($provider.modName)"
        }
        if ($null -eq $provider.inventory) {
            throw "$Purpose provider lacks the required deep inventory: $($provider.modName)"
        }
        $sourceRoot = [IO.Path]::GetFullPath([string]$provider.providerPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        foreach ($entry in @($provider.inventory.entries | Sort-Object relativePath)) {
            $relative = ([string]$entry.relativePath).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) {
                throw "$Purpose provider exposed an unsafe relative path: '$relative'"
            }
            $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
            $target = [IO.Path]::GetFullPath((Join-Path $resolvedTarget $relative))
            if (-not $source.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                -not $target.StartsWith($resolvedTarget + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$Purpose provider path escapes its declared tree: '$relative'"
            }
            if ($selected.ContainsKey($relative)) { continue }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "$Purpose source disappeared during materialization: $source"
            }
            $sourceHashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            if ($sourceHashBefore -cne [string]$entry.sha256) {
                throw "$Purpose source changed after provider inventory: $source"
            }
            $sourceHashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            if ($sourceHashAfter -cne $sourceHashBefore) {
                throw "$Purpose source changed during materialization: $source"
            }
            $record = [pscustomobject][ordered]@{
                relativePath = $relative; winnerClass = 'copied-provider'; sourceModName = [string]$provider.modName
                source = $source; destination = $target; bytes = [long]$entry.bytes
                sha256 = $sourceHashBefore
            }
            $selected.Add($relative, $record)
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $targetItem = Get-Item -LiteralPath $target
                $alreadyPresent.Add([pscustomobject][ordered]@{
                    relativePath = $relative; winnerClass = 'pre-existing-overwrite'
                    destination = $target; bytes = [long]$targetItem.Length
                    sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                })
                continue
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
            $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($targetHash -cne $sourceHashBefore) {
                throw "$Purpose copy did not preserve a stable source: $source"
            }
            $copied.Add($record)
        }
    }

    $targetInventory = Get-WorkspaceOutputInventory -Path $resolvedTarget -Purpose "$Purpose target verification"
    $targetPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($targetInventory.entries)) { $null = $targetPaths.Add(([string]$entry.relativePath).Replace('/', '\')) }
    $missing = @($selected.Keys | Where-Object { -not $targetPaths.Contains([string]$_) })
    if ($missing.Count -gt 0) { throw "$Purpose target lacks provider paths: $($missing -join ', ')" }
    return [pscustomobject][ordered]@{
        relativePath = $RelativePath; targetPath = $resolvedTarget
        requiredProviderFiles = $selected.Count; copiedFiles = $copied.Count
        alreadyPresentFiles = $alreadyPresent.Count; copied = @($copied)
        alreadyPresent = @($alreadyPresent); targetInventory = $targetInventory
    }
}

function Preserve-WorkspaceRuntimeOutput(
    [string]$Source,
    [string]$EvidenceRoot,
    [string]$WorkspaceId,
    [switch]$WhatIf
) {
    $inventory = Get-WorkspaceOutputInventory -Path $Source -Purpose 'Task runtime-output preservation source'
    $target = Join-Path $EvidenceRoot 'runtime-output'
    $staging = Join-Path $EvidenceRoot ('.runtime-output.incomplete.' + $WorkspaceId)
    $receiptPath = Join-Path $EvidenceRoot 'runtime-output-preservation.receipt.json'
    if ($WhatIf) {
        return [pscustomobject][ordered]@{
            source = $Source; stagingPath = $staging; preservedPath = $target; receiptPath = $receiptPath
            inventory = $inventory; preserved = $false
        }
    }
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    if (Test-Path -LiteralPath $target -PathType Container) {
        $preserved = Get-WorkspaceOutputInventory -Path $target -Purpose 'Previously preserved task runtime-output evidence'
        if ([string]$preserved.treeSha256 -cne [string]$inventory.treeSha256 -or
            [int]$preserved.files -ne [int]$inventory.files -or [long]$preserved.bytes -ne [long]$inventory.bytes) {
            throw "Retained runtime-output evidence already exists with different bytes: $target"
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $staging -PathType Container)) { New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null }
        Assert-NoWorkspaceReparsePoint -Path $staging -Purpose 'Incomplete runtime-output evidence staging'
        $sourceTree = Get-BoundedTreeInventory -Path $Source -Purpose 'Task runtime-output preservation copy'
        $sourceByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in @($sourceTree.files)) { $sourceByPath[[string]$file.path] = $file }
        $stagedTree = Get-BoundedTreeInventory -Path $staging -Purpose 'Incomplete runtime-output evidence recovery'
        foreach ($file in @($stagedTree.files)) {
            $relative = [string]$file.path
            if (-not $sourceByPath.ContainsKey($relative) -or
                (Get-FileHash -LiteralPath ([string]$file.fullPath) -Algorithm SHA256).Hash -cne
                    (Get-FileHash -LiteralPath ([string]$sourceByPath[$relative].fullPath) -Algorithm SHA256).Hash) {
                throw "Incomplete runtime-output staging contains unverified bytes; retain or remove this exact task-owned path before retry: $staging"
            }
        }
        foreach ($directory in @($sourceTree.directories)) {
            New-Item -ItemType Directory -Path (Join-Path $staging ([string]$directory.path)) -Force | Out-Null
        }
        foreach ($file in @($sourceTree.files)) {
            $destination = Join-Path $staging ([string]$file.path)
            if (Test-Path -LiteralPath $destination -PathType Leaf) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath ([string]$file.fullPath) -Destination $destination -ErrorAction Stop
        }
        $staged = Get-WorkspaceOutputInventory -Path $staging -Purpose 'Staged task runtime-output evidence'
        if ([string]$staged.treeSha256 -cne [string]$inventory.treeSha256 -or
            [int]$staged.files -ne [int]$inventory.files -or [long]$staged.bytes -ne [long]$inventory.bytes) {
            throw "Incomplete runtime-output staging did not verify; it remains resumable at: $staging"
        }
        [IO.Directory]::Move($staging, $target)
    }
    $preserved = Get-WorkspaceOutputInventory -Path $target -Purpose 'Preserved task runtime-output evidence'
    if ([string]$preserved.treeSha256 -cne [string]$inventory.treeSha256 -or
        [int]$preserved.files -ne [int]$inventory.files -or
        [long]$preserved.bytes -ne [long]$inventory.bytes) {
        throw 'Retained runtime-output evidence differs from the exact task-owned source.'
    }
    $receipt = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'; operation = 'preserve-task-runtime-output'
        workspaceId = $WorkspaceId; source = $Source; preservedPath = $target
        inventory = $inventory; preservedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-WorkspaceJsonAtomic -Path $receiptPath -Value $receipt
    return [pscustomobject][ordered]@{
        source = $Source; stagingPath = $staging; preservedPath = $target; receiptPath = $receiptPath
        inventory = $inventory; preserved = $true
    }
}

function Get-WorkspaceBlockingProcessNames($Config) {
    $names = @(
        @($Config.mo2.processNames) +
        @($Config.mo2.gameProcessNames) +
        @($Config.mo2.runtimeProcessNames) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
    )
    if ($names.Count -eq 0) { return @('ModOrganizer', 'SkyrimVR', 'sksevr_loader') }
    return $names
}

function Get-WorkspaceCacheCompletionEvidence($Config, $Workspace, [switch]$RequireOwnerMarker) {
    $output = $Workspace.data.runtimeOutput
    if ([string]$output.mode -cne 'mo2-overwrite-output') { throw 'Workspace does not use the MO2 Overwrite output contract.' }
    if ($RequireOwnerMarker) {
        $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
    }
    foreach ($path in @([string]$output.cachePlanPath, [string]$output.cacheCompletionPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required shader-cache evidence is missing: $path" }
    }
    $plan = Get-Content -LiteralPath ([string]$output.cachePlanPath) -Raw | ConvertFrom-Json -Depth 40
    $completion = Get-Content -LiteralPath ([string]$output.cacheCompletionPath) -Raw | ConvertFrom-Json -Depth 40
    foreach ($property in @('state', 'cachePath', 'beforeTreeSha256', 'cacheBinding', 'workingTreeInventory', 'transactionId')) {
        if (-not $plan.PSObject.Properties[$property]) { throw "Shader-cache plan lacks required field '$property'." }
    }
    foreach ($property in @('state', 'planPath', 'cacheBinding', 'workingTree', 'restoredTreeSha256')) {
        if (-not $completion.PSObject.Properties[$property]) { throw "Shader-cache completion lacks required field '$property'." }
    }
    $binding = $plan.cacheBinding
    $completionBinding = $completion.cacheBinding
    foreach ($property in @('mode', 'profilePath', 'profileSha256', 'modsPath', 'overwriteRoot', 'cachePath', 'workspaceId', 'ownershipId', 'ownerMarkerPath', 'ownerMarkerSha256', 'communityShadersPlugin')) {
        if ($null -eq $binding -or -not $binding.PSObject.Properties[$property] -or
            $null -eq $completionBinding -or -not $completionBinding.PSObject.Properties[$property]) {
            throw "Shader-cache ownership binding lacks required field '$property'."
        }
    }
    foreach ($pathProperty in @('profilePath', 'modsPath', 'overwriteRoot', 'cachePath', 'ownerMarkerPath')) {
        if (-not (Test-WorkspaceSamePath ([string]$binding.$pathProperty) ([string]$completionBinding.$pathProperty))) {
            throw "Shader-cache completion changed binding path '$pathProperty'."
        }
    }
    foreach ($identityProperty in @('mode', 'profileSha256', 'workspaceId', 'ownershipId', 'ownerMarkerSha256')) {
        if ([string]$binding.$identityProperty -cne [string]$completionBinding.$identityProperty) {
            throw "Shader-cache completion changed binding identity '$identityProperty'."
        }
    }
    $modListPath = Join-Path ([string]$Workspace.data.profilePath) 'modlist.txt'
    if ([string]$plan.state -cne 'restored' -or [string]$completion.state -cne 'complete' -or
        -not (Test-WorkspaceSamePath ([string]$completion.planPath) ([string]$output.cachePlanPath)) -or
        -not (Test-WorkspaceSamePath ([string]$plan.cachePath) ([string]$output.cachePath)) -or
        [string]$completion.restoredTreeSha256 -cne [string]$plan.beforeTreeSha256 -or
        [string]$binding.mode -cne 'mo2-overwrite-output' -or
        -not (Test-WorkspaceSamePath ([string]$binding.profilePath) $modListPath) -or
        -not (Test-WorkspaceSamePath ([string]$binding.modsPath) ([string]$Config.mo2.modsDirectory)) -or
        -not (Test-WorkspaceSamePath ([string]$binding.overwriteRoot) ([string]$output.overwritePath)) -or
        -not (Test-WorkspaceSamePath ([string]$binding.cachePath) ([string]$output.cachePath)) -or
        [string]$binding.workspaceId -cne [string]$Workspace.data.workspaceId -or
        [string]$binding.ownershipId -cne [string]$Workspace.data.ownershipId -or
        -not (Test-WorkspaceSamePath ([string]$binding.ownerMarkerPath) ([string]$output.ownerMarkerPath)) -or
        [string]$binding.ownerMarkerSha256 -cne [string]$output.ownerMarkerSha256) {
        throw 'Shader-cache completion does not close the exact workspace-owned plan.'
    }
    foreach ($property in @('inventory', 'materializedFiles', 'preservedPath')) {
        if ($null -eq $completion.workingTree -or -not $completion.workingTree.PSObject.Properties[$property]) { throw "Shader-cache working-tree evidence lacks '$property'." }
    }
    if ([int]$completion.workingTree.materializedFiles -lt 1 -or -not (Test-Path -LiteralPath ([string]$completion.workingTree.preservedPath) -PathType Container)) {
        throw 'Shader-cache completion does not retain generated task output.'
    }
    $preserved = Get-WorkspaceOutputInventory -Path ([string]$completion.workingTree.preservedPath) -Purpose 'Preserved shader-cache task output'
    if ([string]$preserved.treeSha256 -cne [string]$completion.workingTree.inventory.treeSha256) {
        throw 'Preserved shader-cache task output changed after completion.'
    }
    $transactionTool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $currentBuild = Resolve-WorkspaceCommunityShadersBuildBinding -ProfilePath $modListPath -ModsPath ([string]$Config.mo2.modsDirectory) -TransactionTool $transactionTool
    if (-not (Test-WorkspaceCommunityShadersBuildBinding -Expected $output.communityShadersPlugin -Current $currentBuild) -or
        -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $binding.communityShadersPlugin -Current $currentBuild) -or
        -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $completionBinding.communityShadersPlugin -Current $currentBuild)) {
        throw 'Shader-cache completion belongs to a different Community Shaders build identity.'
    }
    if (Test-Path -LiteralPath ([string]$output.cachePath) -PathType Container) {
        $restored = Get-WorkspaceOutputInventory -Path ([string]$output.cachePath) -Purpose 'Restored MO2 Overwrite ShaderCache'
        if ([string]$restored.treeSha256 -cne [string]$completion.restoredTreeSha256) { throw 'The restored ShaderCache tree changed after completion.' }
    }
    elseif ([bool]$output.cachePathExistedBefore) { throw 'The pre-existing MO2 Overwrite ShaderCache is missing after completion.' }
    return [pscustomobject][ordered]@{ plan = $plan; completion = $completion; build = $currentBuild }
}

function Complete-WorkspaceBackupOutput($Config, $Workspace, [switch]$WhatIf) {
    $output = $Workspace.data.runtimeOutput
    if ([string]$output.mode -cne 'mo2-overwrite-output') { throw 'Workspace does not use the MO2 Overwrite output contract.' }
    $markerExists = Test-Path -LiteralPath ([string]$output.ownerMarkerPath) -PathType Leaf
    $cacheEvidence = Get-WorkspaceCacheCompletionEvidence -Config $Config -Workspace $Workspace -RequireOwnerMarker:$markerExists
    $completionPath = [string]$output.backupCompletionPath
    if (Test-Path -LiteralPath $completionPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json -Depth 40
        foreach ($property in @('state', 'workspaceId', 'ownershipId', 'ownerMarkerSha256', 'backupPath', 'backupPlanPath', 'cachePlanTransactionId', 'pathExistedBefore', 'workingTree', 'preservedPath', 'restoredTreeSha256', 'communityShadersPlugin')) {
            if (-not $existing.PSObject.Properties[$property]) { throw "Existing backup completion lacks required field '$property'." }
        }
        if ([string]$existing.state -cne 'complete' -or
            [string]$existing.workspaceId -cne [string]$Workspace.data.workspaceId -or
            [string]$existing.ownershipId -cne [string]$Workspace.data.ownershipId -or
            [string]$existing.ownerMarkerSha256 -cne [string]$output.ownerMarkerSha256 -or
            -not (Test-WorkspaceSamePath ([string]$existing.backupPath) ([string]$output.backupPath)) -or
            -not (Test-WorkspaceSamePath ([string]$existing.backupPlanPath) ([string]$output.backupPlanPath)) -or
            [string]$existing.cachePlanTransactionId -cne [string]$cacheEvidence.plan.transactionId -or
            [bool]$existing.pathExistedBefore -ne [bool]$output.backupPathExistedBefore -or
            -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $output.communityShadersPlugin -Current $existing.communityShadersPlugin)) {
            throw "Existing backup completion does not close this workspace output transaction: $completionPath"
        }
        if (-not (Test-Path -LiteralPath ([string]$existing.preservedPath) -PathType Container)) { throw 'Existing backup completion lost its preserved task output.' }
        $preserved = Get-WorkspaceOutputInventory -Path ([string]$existing.preservedPath) -Purpose 'Preserved backup task output'
        if ([string]$preserved.treeSha256 -cne [string]$existing.workingTree.treeSha256) { throw 'Preserved backup task output changed after completion.' }
        if (Test-Path -LiteralPath ([string]$output.backupPath) -PathType Container) {
            $liveBackup = Get-WorkspaceOutputInventory -Path ([string]$output.backupPath) -Purpose 'Restored MO2 Overwrite backup'
            if ([string]$liveBackup.treeSha256 -cne [string]$existing.restoredTreeSha256) { throw 'The restored backup tree changed after completion.' }
        }
        elseif ([bool]$output.backupPathExistedBefore) { throw 'The pre-existing MO2 Overwrite backup is missing after completion.' }
        if (-not $WhatIf -and $markerExists) {
            if (-not [bool]$output.backupPathExistedBefore) {
                $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
                Remove-WorkspaceCreatedOutputTree -Path ([string]$output.backupPath) -OverwritePath ([string]$output.overwritePath) -Purpose 'Task-created backup tree'
            }
            if (-not [bool]$output.cachePathExistedBefore) {
                $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
                Remove-WorkspaceCreatedOutputTree -Path ([string]$output.cachePath) -OverwritePath ([string]$output.overwritePath) -Purpose 'Task-created ShaderCache tree'
            }
            $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
            Remove-Item -LiteralPath ([string]$output.ownerMarkerPath) -Force
        }
        return $existing
    }
    if (-not $markerExists) { throw 'The task-owned MO2 Overwrite marker is missing before backup completion.' }
    $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
    if (-not $output.PSObject.Properties['backupPlanPath'] -or -not (Test-Path -LiteralPath ([string]$output.backupPlanPath) -PathType Leaf)) { throw 'The workspace backup plan is missing.' }
    $backupPlan = Get-Content -LiteralPath ([string]$output.backupPlanPath) -Raw | ConvertFrom-Json -Depth 40
    foreach ($property in @('state', 'workspaceId', 'ownershipId', 'ownerMarkerPath', 'ownerMarkerSha256', 'overwritePath', 'backupPath', 'pathExistedBefore', 'profilePath', 'profileSha256', 'modsPath', 'communityShadersPlugin', 'transactionReceiptPath', 'beforeTreeSha256', 'preparedTreeSha256', 'shadowReceipt')) {
        if (-not $backupPlan.PSObject.Properties[$property]) { throw "Workspace backup plan lacks required field '$property'." }
    }
    $modListPath = Join-Path ([string]$Workspace.data.profilePath) 'modlist.txt'
    if ([string]$backupPlan.state -notin @('prepared', 'completing', 'restored') -or
        [string]$backupPlan.workspaceId -cne [string]$Workspace.data.workspaceId -or
        [string]$backupPlan.ownershipId -cne [string]$Workspace.data.ownershipId -or
        -not (Test-WorkspaceSamePath ([string]$backupPlan.ownerMarkerPath) ([string]$output.ownerMarkerPath)) -or
        [string]$backupPlan.ownerMarkerSha256 -cne [string]$output.ownerMarkerSha256 -or
        -not (Test-WorkspaceSamePath ([string]$backupPlan.overwritePath) ([string]$output.overwritePath)) -or
        -not (Test-WorkspaceSamePath ([string]$backupPlan.backupPath) ([string]$output.backupPath)) -or
        [bool]$backupPlan.pathExistedBefore -ne [bool]$output.backupPathExistedBefore -or
        -not (Test-WorkspaceSamePath ([string]$backupPlan.profilePath) $modListPath) -or
        -not (Test-WorkspaceSamePath ([string]$backupPlan.modsPath) ([string]$Config.mo2.modsDirectory)) -or
        -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $output.communityShadersPlugin -Current $backupPlan.communityShadersPlugin)) {
        throw 'Workspace backup plan does not bind the exact current owner, profile, path, and build.'
    }
    $planShadow = $backupPlan.shadowReceipt
    $manifestShadow = if ($output.PSObject.Properties['shadowReceipt']) { $output.shadowReceipt } else { $null }
    foreach ($property in @('bindingMode', 'profilePath', 'profileSha256', 'targetPath', 'workspaceId', 'ownershipId', 'ownerMarkerPath', 'ownerMarkerSha256', 'transactionReceiptPath', 'beforeTreeSha256', 'preparedInventory', 'communityShadersPlugin')) {
        if ($null -eq $planShadow -or -not $planShadow.PSObject.Properties[$property] -or
            $null -eq $manifestShadow -or -not $manifestShadow.PSObject.Properties[$property]) {
            throw "Workspace backup provider evidence lacks required field '$property'."
        }
    }
    if ($null -eq $planShadow.preparedInventory -or -not $planShadow.preparedInventory.PSObject.Properties['treeSha256']) {
        throw "Workspace backup provider evidence lacks required field 'preparedInventory.treeSha256'."
    }
    if ([string]$planShadow.bindingMode -cne 'mo2-overwrite-output' -or
        -not (Test-WorkspaceSamePath ([string]$planShadow.profilePath) ([string]$backupPlan.profilePath)) -or
        [string]$planShadow.profileSha256 -cne [string]$backupPlan.profileSha256 -or
        -not (Test-WorkspaceSamePath ([string]$planShadow.targetPath) ([string]$backupPlan.backupPath)) -or
        [string]$planShadow.workspaceId -cne [string]$backupPlan.workspaceId -or
        [string]$planShadow.ownershipId -cne [string]$backupPlan.ownershipId -or
        -not (Test-WorkspaceSamePath ([string]$planShadow.ownerMarkerPath) ([string]$backupPlan.ownerMarkerPath)) -or
        [string]$planShadow.ownerMarkerSha256 -cne [string]$backupPlan.ownerMarkerSha256 -or
        -not (Test-WorkspaceSamePath ([string]$planShadow.transactionReceiptPath) ([string]$backupPlan.transactionReceiptPath)) -or
        [string]$planShadow.beforeTreeSha256 -cne [string]$backupPlan.beforeTreeSha256 -or
        [string]$planShadow.preparedInventory.treeSha256 -cne [string]$backupPlan.preparedTreeSha256 -or
        ($planShadow | ConvertTo-Json -Depth 40 -Compress) -cne ($manifestShadow | ConvertTo-Json -Depth 40 -Compress) -or
        -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $backupPlan.communityShadersPlugin -Current $planShadow.communityShadersPlugin)) {
        throw 'Workspace backup provider evidence changed after the exact owner-bound plan was published.'
    }
    if (-not (Test-Path -LiteralPath ([string]$backupPlan.transactionReceiptPath) -PathType Leaf)) { throw 'Workspace backup snapshot receipt is missing.' }
    $snapshotReceipt = Get-Content -LiteralPath ([string]$backupPlan.transactionReceiptPath) -Raw | ConvertFrom-Json -Depth 20
    foreach ($property in @('operation', 'transactionId', 'cachePath', 'beforeTreeSha256')) {
        if (-not $snapshotReceipt.PSObject.Properties[$property]) { throw "Workspace backup snapshot receipt lacks required field '$property'." }
    }
    if ([string]$snapshotReceipt.operation -cne 'snapshot' -or [string]::IsNullOrWhiteSpace([string]$snapshotReceipt.transactionId) -or
        -not (Test-WorkspaceSamePath ([string]$snapshotReceipt.cachePath) ([string]$backupPlan.backupPath)) -or
        [string]$snapshotReceipt.beforeTreeSha256 -cne [string]$backupPlan.beforeTreeSha256) {
        throw 'Workspace backup snapshot receipt no longer binds the exact backup plan.'
    }
    $transactionTool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $currentBuild = Resolve-WorkspaceCommunityShadersBuildBinding -ProfilePath $modListPath -ModsPath ([string]$Config.mo2.modsDirectory) -TransactionTool $transactionTool
    if ([string]$currentBuild.profileSha256 -cne [string]$backupPlan.profileSha256 -or
        -not (Test-WorkspaceCommunityShadersBuildBinding -Expected $backupPlan.communityShadersPlugin -Current $currentBuild)) {
        throw 'Workspace backup plan build or profile identity changed before completion.'
    }
    $blockingProcessNames = @(Get-WorkspaceBlockingProcessNames -Config $Config)
    $current = & $transactionTool inspect -CachePath ([string]$output.backupPath) -RelativeCachePath 'backup' -NoExit -Confirm:$false | ConvertFrom-Json
    if (-not $current.ok) { throw "Could not inspect current MO2 Overwrite backup: $($current.errors -join '; ')" }
    if ($WhatIf) {
        return [pscustomobject][ordered]@{
            state = 'dry-run'; backupPath = [string]$output.backupPath
            workingTree = $current.data; completionPath = $completionPath
        }
    }
    if ($null -eq $backupPlan.workingTreeInventory) {
        $backupPlan.workingTreeInventory = $current.data
        $backupPlan.state = 'completing'
        $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
        Write-WorkspaceJsonAtomic -Path ([string]$output.backupPlanPath) -Value $backupPlan
    }
    elseif ([string]$current.data.treeSha256 -cne [string]$backupPlan.workingTreeInventory.treeSha256 -and
        [string]$current.data.treeSha256 -cne [string]$backupPlan.beforeTreeSha256) {
        throw 'Live backup matches neither the recorded working tree nor the preserved baseline.'
    }
    $restored = $null
    if ([string]$current.data.treeSha256 -ceq [string]$backupPlan.beforeTreeSha256) {
        $restoreMatches = @(Get-ChildItem -LiteralPath ([string]$output.backupEvidenceDirectory) -Filter 'shader-cache-restore.*.receipt.json' -File | ForEach-Object {
            $receipt = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30
            if ([string]$receipt.cachePath -ceq [string]$output.backupPath -and
                [string]$receipt.restoredTreeSha256 -ceq [string]$backupPlan.beforeTreeSha256 -and
                [string]$receipt.displacedTreeSha256 -ceq [string]$backupPlan.workingTreeInventory.treeSha256) {
                [pscustomobject]@{ path = $_.FullName; receipt = $receipt }
            }
        })
        if ($restoreMatches.Count -ne 1) { throw 'Restored backup lacks one exact committed restore receipt for its preserved working tree.' }
        $restored = [pscustomobject]@{ data = [pscustomobject]@{ displacedPath = [string]$restoreMatches[0].receipt.displacedPath; baseline = [pscustomobject]@{ treeSha256 = [string]$restoreMatches[0].receipt.restoredTreeSha256 }; restoreReceiptPath = [string]$restoreMatches[0].path } }
    }
    else {
        $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
        $restored = & $transactionTool restore -CachePath ([string]$output.backupPath) -RelativeCachePath 'backup' -EvidenceDirectory ([string]$output.backupEvidenceDirectory) -BlockingProcessNames $blockingProcessNames -NoExit -Confirm:$false | ConvertFrom-Json
        if (-not $restored.ok) { throw "Could not restore the exact pre-task MO2 Overwrite backup: $($restored.errors -join '; ')" }
    }
    $preserved = Get-WorkspaceOutputInventory -Path ([string]$restored.data.displacedPath) -Purpose 'Preserved backup task output'
    if ([string]$preserved.treeSha256 -cne [string]$backupPlan.workingTreeInventory.treeSha256) { throw 'Preserved backup task output differs from the recorded working tree.' }
    $backupPlan.state = 'restored'; $backupPlan.restoreReceiptPath = [string]$restored.data.restoreReceiptPath
    $backupPlan.restoredTreeSha256 = [string]$restored.data.baseline.treeSha256
    $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
    Write-WorkspaceJsonAtomic -Path ([string]$output.backupPlanPath) -Value $backupPlan
    $completion = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'; state = 'complete'; completedUtc = [DateTime]::UtcNow.ToString('o')
        workspaceId = [string]$Workspace.data.workspaceId; ownershipId = [string]$Workspace.data.ownershipId
        ownerMarkerSha256 = [string]$output.ownerMarkerSha256; backupPath = [string]$output.backupPath
        backupPlanPath = [string]$output.backupPlanPath; cachePlanTransactionId = [string]$cacheEvidence.plan.transactionId
        pathExistedBefore = [bool]$output.backupPathExistedBefore; communityShadersPlugin = $currentBuild
        workingTree = $backupPlan.workingTreeInventory; preservedPath = [string]$restored.data.displacedPath
        restoredTreeSha256 = [string]$restored.data.baseline.treeSha256
        restoreReceiptPath = [string]$restored.data.restoreReceiptPath
    }
    $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
    Write-WorkspaceJsonAtomic -Path $completionPath -Value $completion
    if (-not [bool]$output.backupPathExistedBefore) {
        $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
        Remove-WorkspaceCreatedOutputTree -Path ([string]$output.backupPath) -OverwritePath ([string]$output.overwritePath) -Purpose 'Task-created backup tree'
    }
    if (-not [bool]$output.cachePathExistedBefore) {
        $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
        Remove-WorkspaceCreatedOutputTree -Path ([string]$output.cachePath) -OverwritePath ([string]$output.overwritePath) -Purpose 'Task-created ShaderCache tree'
    }
    $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$output.ownerMarkerPath) -ExpectedSha256 ([string]$output.ownerMarkerSha256) -WorkspaceId ([string]$Workspace.data.workspaceId) -OwnershipId ([string]$Workspace.data.ownershipId) -OverwritePath ([string]$output.overwritePath)
    Remove-Item -LiteralPath ([string]$output.ownerMarkerPath) -Force
    return $completion
}

function Assert-WorkspaceRuntimeOutputReadyForRetirement($Config, $Workspace, [string]$AccessId) {
    if (-not $Workspace.data.PSObject.Properties['runtimeOutput'] -or $null -eq $Workspace.data.runtimeOutput) {
        return $null
    }
    $output = $Workspace.data.runtimeOutput
    $isolation = Get-MO2TaskWorkspaceIsolation -Config $Config -Profile ([string]$Workspace.data.profile) -Executable ([string]$output.executable) -AccessId $AccessId -AllowPreparedCacheGrowth
    if (-not $isolation.ok) {
        throw "Task runtime-output isolation is no longer valid; refusing retirement: $($isolation.errors -join '; ')"
    }
    $planPath = [string]$output.cachePlanPath
    $completionPath = [string]$output.cacheCompletionPath
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $completionPath -PathType Leaf)) {
            throw "The task shader-cache transaction is still open. Complete it after game/MO2 shutdown before retiring the workspace: $planPath"
        }
        $completion = Get-Content -LiteralPath $completionPath -Raw | ConvertFrom-Json -Depth 40
        $completionBinding = if ($completion.PSObject.Properties['cacheBinding']) { $completion.cacheBinding } else { $null }
        $materializedFiles = if ($completion.PSObject.Properties['workingTree'] -and $completion.workingTree.PSObject.Properties['materializedFiles']) { [int]$completion.workingTree.materializedFiles } else { 0 }
        if ([string]$completion.state -cne 'complete' -or
            -not (Test-WorkspaceSamePath ([string]$completion.planPath) $planPath) -or
            $null -eq $completionBinding -or
            ([string]$output.mode -cne 'mo2-overwrite-output' -and [string]$completionBinding.modName -cne [string]$output.modName) -or
            ([string]$output.mode -ceq 'mo2-overwrite-output' -and [string]$completionBinding.mode -cne 'mo2-overwrite-output') -or
            -not (Test-WorkspaceSamePath ([string]$completionBinding.cachePath) ([string]$output.cachePath)) -or
            $materializedFiles -lt 1) {
            throw "Shader-cache completion does not close the exact task plan: $completionPath"
        }
    }
    else {
        if ([string]$output.mode -ceq 'mo2-overwrite-output') { throw 'The task MO2 Overwrite ShaderCache was never prepared and completed; refusing workspace retirement.' }
        $unprepared = Get-WorkspaceOutputInventory -Path ([string]$output.modPath) -Purpose 'Unprepared task runtime-output classification'
        $allowed = @('.codex-workspace-owner.json', 'ShaderCache\.codex-vfs-sentinel.txt')
        $unclassified = @($unprepared.entries | Where-Object { [string]$_.relativePath -notin $allowed -and -not ([string]$_.relativePath).StartsWith('backup\', [StringComparison]::OrdinalIgnoreCase) })
        if ($unclassified.Count -gt 0) { throw 'The task runtime-output mod contains generated files without a shader-cache prepare/completion transaction.' }
    }
    if ([string]$output.mode -ceq 'mo2-overwrite-output' -and -not (Test-Path -LiteralPath ([string]$output.backupCompletionPath) -PathType Leaf)) {
        throw "The task MO2 Overwrite backup transaction is still open. Run complete-output after game/MO2 shutdown before retiring the workspace: $($output.backupCompletionPath)"
    }
    return $isolation
}

function Get-WorkspaceControlRoot($Config) {
    return Join-Path ([IO.Path]::GetFullPath([string]$Config.storage.sessionStaging)) 'workspaces'
}

function Invoke-WithWorkspaceTransactionLock($Config, [scriptblock]$Action) {
    $root = Get-WorkspaceControlRoot -Config $Config
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $lockPath = Join-Path $root '.workspace.transaction.lock'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TransactionLockTimeoutMilliseconds)
    $stream = $null
    while ($null -eq $stream) {
        try { $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for the workspace transaction lock: $lockPath" }
            Start-Sleep -Milliseconds 50
        }
    }
    try {
        $null = Resolve-PendingSelectedProfileJournals -Config $Config
        $null = Resolve-PendingWorkspaceJournals -Config $Config
        return & $Action
    }
    finally { $stream.Dispose() }
}

function Get-WorkspaceCreationJournalPath($Config, [string]$Id) {
    return Join-Path (Get-WorkspaceControlRoot -Config $Config) ($Id + '.creation.journal.json')
}

function Get-WorkspaceOperationJournalPath($Config, [string]$Id, [string]$Operation, [string]$OperationId) {
    return Join-Path (Get-WorkspaceControlRoot -Config $Config) ("$Id.$Operation.$OperationId.journal.json")
}

function Get-WorkspaceOwnerMarkerPath([string]$ModPath) {
    return Join-Path $ModPath '.codex-workspace-owner.json'
}

function Assert-WorkspaceOwnerMarker($Workspace, [string]$ModName, [string]$ModPath) {
    $markerPath = Get-WorkspaceOwnerMarkerPath -ModPath $ModPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw "Task mod lacks its workspace ownership marker: $ModName" }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ([string]$marker.workspaceId -cne [string]$Workspace.data.workspaceId -or [string]$marker.ownershipId -cne [string]$Workspace.data.ownershipId -or [string]$marker.modName -cne $ModName -or [string]$marker.modPath -cne $ModPath) {
        throw "Task mod ownership marker does not match this workspace: $ModName"
    }
    return [pscustomobject]@{ path = $markerPath; data = $marker; sha256 = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash }
}

function Resolve-DirectProfilePath([string]$ProfilesRoot, [string]$ProfileName) {
    if ([string]::IsNullOrWhiteSpace($ProfileName) -or $ProfileName -in @('.', '..')) {
        throw 'SourceProfile is missing or malformed.'
    }
    if ($ProfileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $ProfileName.Contains([IO.Path]::DirectorySeparatorChar) -or $ProfileName.Contains([IO.Path]::AltDirectorySeparatorChar)) {
        throw 'SourceProfile is malformed; it must be one direct profile-directory name.'
    }
    $resolvedRoot = [IO.Path]::GetFullPath($ProfilesRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $ProfileName))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($resolvedPath), $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'SourceProfile must resolve to a direct child of the configured profiles directory.'
    }
    return $resolvedPath
}

function Get-ProfileSnapshot([string]$Path) {
    $inventory = Get-BoundedTreeInventory -Path $Path -Purpose 'MO2 profile'
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @($inventory.files)) {
        Assert-TreeOperationBudget -Purpose 'MO2 profile hashing'
        $relative = [string]$file.path
        if ($relative -match '^(?i:saves)[\\/]') { continue }
        $records.Add([pscustomobject][ordered]@{ path = $relative; bytes = [long]$file.bytes; sha256 = (Get-FileHash -LiteralPath ([string]$file.fullPath) -Algorithm SHA256).Hash })
        Assert-TreeOperationBudget -Purpose 'MO2 profile hashing'
    }
    $canonical = $records | ConvertTo-Json -Compress -Depth 4
    $hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    return [pscustomobject][ordered]@{ files = @($records); sha256 = [Convert]::ToHexString($hashBytes); traversal = $inventory.limits }
}

function Get-SaveTreeSnapshot([string]$ProfilePath) {
    $savesPath = [IO.Path]::GetFullPath((Join-Path $ProfilePath 'saves'))
    $records = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $savesPath -PathType Container) {
        $inventory = Get-BoundedTreeInventory -Path $savesPath -Purpose 'MO2 profile saves'
        foreach ($file in @($inventory.files)) {
            Assert-TreeOperationBudget -Purpose 'MO2 save-tree hashing'
            $records.Add([pscustomobject][ordered]@{
                path = [string]$file.path
                bytes = [long]$file.bytes
                sha256 = (Get-FileHash -LiteralPath ([string]$file.fullPath) -Algorithm SHA256).Hash
            })
            Assert-TreeOperationBudget -Purpose 'MO2 save-tree hashing'
        }
    }
    $canonical = ConvertTo-Json -InputObject @($records) -Compress -Depth 4
    $hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
    return [pscustomobject][ordered]@{
        path = $savesPath
        exists = Test-Path -LiteralPath $savesPath -PathType Container
        fileCount = @($records).Count
        bytes = [long](($records | Measure-Object -Property bytes -Sum).Sum)
        sha256 = [Convert]::ToHexString($hashBytes)
        files = @($records)
    }
}

function Write-WorkspaceBytesAtomic([string]$Path, [byte[]]$Bytes) {
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-SelectedProfileFromBytes([byte[]]$Bytes) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $matches = [regex]::Matches($text, '(?im)^(?<prefix>\s*selected_profile\s*=\s*)(?<value>[^\r\n]*)\r?$')
    if ($matches.Count -ne 1) { throw "Expected exactly one selected_profile entry in MO2 INI; found $($matches.Count)." }
    $raw = $matches[0].Groups['value'].Value.Trim()
    $byteArray = [regex]::Match($raw, '^@ByteArray\((.*)\)$')
    return [pscustomobject][ordered]@{
        text = $text; match = $matches[0]
        value = if ($byteArray.Success) { $byteArray.Groups[1].Value } else { $raw }
    }
}

function Write-SelectedProfileReceipt([Collections.IDictionary]$Journal) {
    $receipt = [pscustomobject][ordered]@{
        contractVersion = '2.0.0'; operation = [string]$Journal['operation']; iniPath = [string]$Journal['iniPath']
        targetProfile = [string]$Journal['targetProfile']; selectedProfileBefore = [string]$Journal['selectedProfileBefore']
        selectedProfileAfter = [string]$Journal['targetProfile']; backupPath = [string]$Journal['backupPath']
        beforeSha256 = [string]$Journal['beforeSha256']; resultSha256 = [string]$Journal['resultSha256']
        changedUtc = [DateTime]::UtcNow.ToString('o'); journalPath = [string]$Journal['journalPath']
    }
    Write-WorkspaceJsonAtomic -Path ([string]$Journal['receiptPath']) -Value $receipt
    return $receipt
}

function Resolve-SelectedProfileJournal($Config, [string]$JournalPath) {
    $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json -AsHashtable
    $phase = [string]$journal['phase']
    if ($phase -in @('committed', 'recovered-committed', 'rolled-back', 'recovered-preimage', 'aborted-before-mutation', 'compensated-by-parent')) { return $journal }
    $expectedIni = [IO.Path]::GetFullPath([string]$Config.mo2.ini)
    if (-not $journal.ContainsKey('iniPath') -or -not [string]::Equals([IO.Path]::GetFullPath([string]$journal['iniPath']), $expectedIni, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Selected-profile recovery journal targets an unexpected MO2 INI: $JournalPath"
    }
    $backupPath = [IO.Path]::GetFullPath([string]$journal['backupPath'])
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Selected-profile recovery backup is missing: $backupPath" }
    if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -cne [string]$journal['beforeSha256']) { throw "Selected-profile recovery backup hash differs from its journal: $JournalPath" }
    $liveHash = (Get-FileHash -LiteralPath $expectedIni -Algorithm SHA256).Hash
    if ($liveHash -ceq [string]$journal['resultSha256']) {
        $selected = Get-SelectedProfileFromBytes -Bytes ([IO.File]::ReadAllBytes($expectedIni))
        if ([string]$selected.value -cne [string]$journal['targetProfile']) { throw "Selected-profile recovery result hash matched but target value did not: $JournalPath" }
        if (-not (Test-Path -LiteralPath ([string]$journal['receiptPath']) -PathType Leaf)) { $null = Write-SelectedProfileReceipt -Journal $journal }
        $journal['phase'] = 'recovered-committed'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
        return $journal
    }
    if ($liveHash -ceq [string]$journal['beforeSha256']) {
        $journal['phase'] = 'recovered-preimage'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
        return $journal
    }
    $journal['phase'] = 'recovery-required'; $journal['recoveryError'] = 'Live MO2 INI matches neither the exact preimage nor the planned result.'
    Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
    throw "Selected-profile recovery requires manual review because the live MO2 INI has unclassified drift: $JournalPath"
}

function Resolve-PendingSelectedProfileJournals($Config) {
    $root = Get-WorkspaceControlRoot -Config $Config
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $inventory = Get-BoundedTreeInventory -Path $root -Purpose 'Workspace selected-profile journal discovery'
    $resolved = @()
    foreach ($file in @($inventory.files | Where-Object { [IO.Path]::GetFileName([string]$_.path) -like '*.selected-profile.journal.json' })) {
        $resolved += Resolve-SelectedProfileJournal -Config $Config -JournalPath ([string]$file.fullPath)
    }
    return @($resolved)
}

function Restore-MO2SelectedProfileTransaction($Transaction) {
    $iniPath = [IO.Path]::GetFullPath([string]$Transaction.iniPath)
    $backupPath = [IO.Path]::GetFullPath([string]$Transaction.backupPath)
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Selected-profile rollback backup is missing: $backupPath" }
    $beforeHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    if ($beforeHash -cne [string]$Transaction.beforeSha256) { throw 'Selected-profile rollback backup differs from its transaction evidence.' }
    $liveHash = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash
    if ($liveHash -cne $beforeHash) {
        if ($liveHash -cne [string]$Transaction.resultSha256) { throw 'Selected-profile rollback refused to overwrite live INI drift outside the transaction result.' }
        Write-WorkspaceBytesAtomic -Path $iniPath -Bytes ([IO.File]::ReadAllBytes($backupPath))
        if ((Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash -cne $beforeHash) { throw 'Selected-profile rollback did not restore the exact preimage.' }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Transaction.journalPath) -and (Test-Path -LiteralPath ([string]$Transaction.journalPath) -PathType Leaf)) {
        $journal = Get-Content -LiteralPath ([string]$Transaction.journalPath) -Raw | ConvertFrom-Json -AsHashtable
        $journal['phase'] = 'compensated-by-parent'; $journal['compensatedUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path ([string]$Transaction.journalPath) -Value $journal
    }
}

function Restore-ParentSelectedProfileTransaction([string]$JournalPath) {
    if ([string]::IsNullOrWhiteSpace($JournalPath) -or -not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) { return $null }
    $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
    if ([string]$journal.phase -in @('committed', 'recovered-committed')) {
        Restore-MO2SelectedProfileTransaction -Transaction $journal
    }
    return $journal
}

function Assert-WorkspaceRecoveryPath([string]$Path, [string]$Root, [string]$Purpose) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $expectedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolved.StartsWith($expectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "$Purpose escaped its configured root: $resolved" }
    return $resolved
}

function Resolve-PendingWorkspaceJournal($Config, [string]$JournalPath) {
    $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$journal['phase'] -in @('committed', 'rolled-back', 'recovered-committed', 'recovered-preimage')) { return $journal }
    $profilesRoot = [IO.Path]::GetFullPath([string]$Config.mo2.profilesDirectory)
    $controlRoot = [IO.Path]::GetFullPath((Get-WorkspaceControlRoot -Config $Config))
    $operation = [string]$journal['operation']
    if ($operation -notin @('create', 'resume', 'retire')) { throw "Unknown nonterminal workspace operation in $JournalPath" }

    $manifestPath = Assert-WorkspaceRecoveryPath -Path ([string]$journal['manifestPath']) -Root $controlRoot -Purpose 'Workspace manifest recovery target'
    $profilePath = if ($journal.ContainsKey('profilePath')) { Assert-WorkspaceRecoveryPath -Path ([string]$journal['profilePath']) -Root $profilesRoot -Purpose 'Workspace profile recovery target' } else { $null }
    $selectedJournalPath = if ($journal.ContainsKey('selectedProfileJournalPath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['selectedProfileJournalPath'])) {
        Assert-WorkspaceRecoveryPath -Path ([string]$journal['selectedProfileJournalPath']) -Root $controlRoot -Purpose 'Selected-profile recovery journal'
    } else { $null }

    if ($operation -eq 'create') {
        $runtimeOutputPath = if ($journal.ContainsKey('runtimeOutputPath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['runtimeOutputPath'])) {
            Assert-WorkspaceRecoveryPath -Path ([string]$journal['runtimeOutputPath']) -Root ([string]$Config.mo2.modsDirectory) -Purpose 'Workspace runtime-output recovery target'
        } else { $null }
        $overwriteMarkerPath = if ($journal.ContainsKey('overwriteOwnerMarkerPath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['overwriteOwnerMarkerPath'])) {
            Assert-WorkspaceRecoveryPath -Path ([string]$journal['overwriteOwnerMarkerPath']) -Root ([string]$Config.mo2.overwriteDirectory) -Purpose 'Workspace Overwrite owner marker'
        } else { $null }
        $backupEvidenceDirectory = if ($journal.ContainsKey('backupEvidenceDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$journal['backupEvidenceDirectory'])) {
            Assert-WorkspaceRecoveryPath -Path ([string]$journal['backupEvidenceDirectory']) -Root $controlRoot -Purpose 'Workspace Overwrite backup evidence'
        } else { $null }
        $cachePath = if ($journal.ContainsKey('cachePath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['cachePath'])) {
            Assert-WorkspaceRecoveryPath -Path ([string]$journal['cachePath']) -Root ([string]$Config.mo2.overwriteDirectory) -Purpose 'Workspace Overwrite ShaderCache recovery target'
        } else { Join-Path ([string]$Config.mo2.overwriteDirectory) 'ShaderCache' }
        $backupPath = if ($journal.ContainsKey('backupPath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['backupPath'])) {
            Assert-WorkspaceRecoveryPath -Path ([string]$journal['backupPath']) -Root ([string]$Config.mo2.overwriteDirectory) -Purpose 'Workspace Overwrite backup recovery target'
        } else { Join-Path ([string]$Config.mo2.overwriteDirectory) 'backup' }
        $cacheExistedBefore = if ($journal.ContainsKey('cachePathExistedBefore')) { [bool]$journal['cachePathExistedBefore'] } else { $true }
        $backupExistedBefore = if ($journal.ContainsKey('backupPathExistedBefore')) { [bool]$journal['backupPathExistedBefore'] } else { $true }
        $markerSha256 = if ($journal.ContainsKey('overwriteOwnerMarkerSha256')) { [string]$journal['overwriteOwnerMarkerSha256'] } else { '' }
        $committable = $false
        if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-Path -LiteralPath $profilePath -PathType Container)) {
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $runtimeReady = if ([string]$manifest.runtimeOutput.mode -ceq 'mo2-overwrite-output') {
                    $null -ne $overwriteMarkerPath -and
                    $null -ne (Assert-WorkspaceOutputOwnerMarker -Path $overwriteMarkerPath -ExpectedSha256 $markerSha256 -WorkspaceId ([string]$journal['workspaceId']) -OwnershipId ([string]$journal['ownershipId']) -OverwritePath ([string]$Config.mo2.overwriteDirectory))
                } else {
                    $null -ne $runtimeOutputPath -and (Test-Path -LiteralPath $runtimeOutputPath -PathType Container)
                }
                $committable = [string]$manifest.workspaceId -ceq [string]$journal['workspaceId'] -and [string]$manifest.ownershipId -ceq [string]$journal['ownershipId'] -and [string]$manifest.status -ceq 'ready' -and [IO.Path]::GetFullPath([string]$manifest.profilePath) -ceq $profilePath -and $runtimeReady
            }
            catch { $committable = $false }
        }
        if ($committable) {
            $journal['phase'] = 'committed'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
            Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
            return $journal
        }
        $null = Restore-ParentSelectedProfileTransaction -JournalPath $selectedJournalPath
        if (Test-Path -LiteralPath $profilePath -PathType Container) { Assert-NoWorkspaceReparsePoint -Path $profilePath -Purpose 'Interrupted workspace profile'; Remove-Item -LiteralPath $profilePath -Recurse -Force }
        if ($null -ne $runtimeOutputPath -and (Test-Path -LiteralPath $runtimeOutputPath -PathType Container)) { Assert-NoWorkspaceReparsePoint -Path $runtimeOutputPath -Purpose 'Interrupted workspace runtime-output mod'; Remove-Item -LiteralPath $runtimeOutputPath -Recurse -Force }
        if ($null -ne $backupEvidenceDirectory -and (Test-Path -LiteralPath (Join-Path $backupEvidenceDirectory 'shader-cache-transaction.receipt.json') -PathType Leaf)) {
            if ($null -eq $overwriteMarkerPath) { throw 'Interrupted workspace backup recovery lacks its exact owner-marker path.' }
            $null = Assert-WorkspaceOutputOwnerMarker -Path $overwriteMarkerPath -ExpectedSha256 $markerSha256 -WorkspaceId ([string]$journal['workspaceId']) -OwnershipId ([string]$journal['ownershipId']) -OverwritePath ([string]$Config.mo2.overwriteDirectory)
            $transactionTool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
            $blockingProcessNames = @(Get-WorkspaceBlockingProcessNames -Config $Config)
            $restored = & $transactionTool restore -CachePath $backupPath -RelativeCachePath 'backup' -EvidenceDirectory $backupEvidenceDirectory -BlockingProcessNames $blockingProcessNames -NoExit -Confirm:$false | ConvertFrom-Json
            if (-not $restored.ok) { throw "Interrupted workspace backup recovery failed: $($restored.errors -join '; ')" }
        }
        if ($null -ne $overwriteMarkerPath -and -not $backupExistedBefore) {
            $null = Assert-WorkspaceOutputOwnerMarker -Path $overwriteMarkerPath -ExpectedSha256 $markerSha256 -WorkspaceId ([string]$journal['workspaceId']) -OwnershipId ([string]$journal['ownershipId']) -OverwritePath ([string]$Config.mo2.overwriteDirectory)
            Remove-WorkspaceCreatedOutputTree -Path $backupPath -OverwritePath ([string]$Config.mo2.overwriteDirectory) -Purpose 'Interrupted task-created backup tree'
        }
        if ($null -ne $overwriteMarkerPath -and -not $cacheExistedBefore) {
            $null = Assert-WorkspaceOutputOwnerMarker -Path $overwriteMarkerPath -ExpectedSha256 $markerSha256 -WorkspaceId ([string]$journal['workspaceId']) -OwnershipId ([string]$journal['ownershipId']) -OverwritePath ([string]$Config.mo2.overwriteDirectory)
            Remove-WorkspaceCreatedOutputTree -Path $cachePath -OverwritePath ([string]$Config.mo2.overwriteDirectory) -Purpose 'Interrupted task-created ShaderCache tree'
        }
        if ($null -ne $overwriteMarkerPath -and (Test-Path -LiteralPath $overwriteMarkerPath -PathType Leaf)) {
            $null = Assert-WorkspaceOutputOwnerMarker -Path $overwriteMarkerPath -ExpectedSha256 $markerSha256 -WorkspaceId ([string]$journal['workspaceId']) -OwnershipId ([string]$journal['ownershipId']) -OverwritePath ([string]$Config.mo2.overwriteDirectory)
            Remove-Item -LiteralPath $overwriteMarkerPath -Force
        }
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Remove-Item -LiteralPath $manifestPath -Force }
        $journal['phase'] = 'rolled-back'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
        return $journal
    }

    $preimagePath = if ($journal.ContainsKey('manifestPreimagePath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['manifestPreimagePath'])) {
        Assert-WorkspaceRecoveryPath -Path ([string]$journal['manifestPreimagePath']) -Root $controlRoot -Purpose 'Workspace manifest recovery preimage'
    } else { $null }
    if ([string]::IsNullOrWhiteSpace($preimagePath) -or -not (Test-Path -LiteralPath $preimagePath -PathType Leaf) -or (Get-FileHash -LiteralPath $preimagePath -Algorithm SHA256).Hash -cne [string]$journal['manifestPreimageSha256']) {
        throw "Workspace $operation recovery cannot verify its exact manifest preimage: $JournalPath"
    }

    if ($operation -eq 'retire') {
        foreach ($move in @($journal['modMoves'])) {
            $source = Assert-WorkspaceRecoveryPath -Path ([string]$move.source) -Root ([string]$Config.mo2.modsDirectory) -Purpose 'Retirement mod source'
            $quarantine = Assert-WorkspaceRecoveryPath -Path ([string]$move.quarantine) -Root ([string]$Config.mo2.modsDirectory) -Purpose 'Retirement mod quarantine'
            if ((Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $quarantine)) { throw "Retirement recovery found both source and quarantine: $source" }
            if (-not (Test-Path -LiteralPath $source) -and (Test-Path -LiteralPath $quarantine)) { Move-Item -LiteralPath $quarantine -Destination $source -ErrorAction Stop }
        }
        $profileQuarantine = Assert-WorkspaceRecoveryPath -Path ([string]$journal['profileQuarantine']) -Root $profilesRoot -Purpose 'Retirement profile quarantine'
        if ((Test-Path -LiteralPath $profilePath) -and (Test-Path -LiteralPath $profileQuarantine)) { throw 'Retirement recovery found both the profile and its quarantine.' }
        if (-not (Test-Path -LiteralPath $profilePath) -and (Test-Path -LiteralPath $profileQuarantine)) { Move-Item -LiteralPath $profileQuarantine -Destination $profilePath -ErrorAction Stop }
        if ($journal.ContainsKey('overwriteMarkerPreimagePath') -and -not [string]::IsNullOrWhiteSpace([string]$journal['overwriteMarkerPreimagePath'])) {
            $markerPath = Assert-WorkspaceRecoveryPath -Path ([string]$journal['overwriteOwnerMarkerPath']) -Root ([string]$Config.mo2.overwriteDirectory) -Purpose 'Retirement Overwrite owner marker'
            $markerPreimagePath = Assert-WorkspaceRecoveryPath -Path ([string]$journal['overwriteMarkerPreimagePath']) -Root $controlRoot -Purpose 'Retirement Overwrite owner marker preimage'
            if (-not (Test-Path -LiteralPath $markerPreimagePath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $markerPreimagePath -Algorithm SHA256).Hash -cne [string]$journal['overwriteMarkerPreimageSha256']) {
                throw 'Retirement recovery cannot verify its MO2 Overwrite owner marker preimage.'
            }
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                if ((Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash -cne [string]$journal['overwriteMarkerPreimageSha256']) { throw 'Retirement recovery found a foreign MO2 Overwrite owner marker.' }
            }
            else { Write-WorkspaceBytesAtomic -Path $markerPath -Bytes ([IO.File]::ReadAllBytes($markerPreimagePath)) }
        }
    }

    Write-WorkspaceBytesAtomic -Path $manifestPath -Bytes ([IO.File]::ReadAllBytes($preimagePath))
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne [string]$journal['manifestPreimageSha256']) { throw "Workspace $operation recovery failed exact manifest verification." }
    $null = Restore-ParentSelectedProfileTransaction -JournalPath $selectedJournalPath
    $journal['phase'] = 'rolled-back'; $journal['recoveredUtc'] = [DateTime]::UtcNow.ToString('o')
    Write-WorkspaceJsonAtomic -Path $JournalPath -Value $journal
    return $journal
}

function Resolve-PendingWorkspaceJournals($Config) {
    $root = Get-WorkspaceControlRoot -Config $Config
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $inventory = Get-BoundedTreeInventory -Path $root -Purpose 'Workspace operation journal discovery'
    $resolved = @()
    foreach ($file in @($inventory.files | Where-Object { [IO.Path]::GetFileName([string]$_.path) -match '\.(creation|resume\.[^.]+|retire\.[^.]+)\.journal\.json$' })) {
        $resolved += Resolve-PendingWorkspaceJournal -Config $Config -JournalPath ([string]$file.fullPath)
    }
    return @($resolved)
}

function Set-MO2SelectedProfile($Config, [string]$TargetProfile, [string]$Operation, [string]$EvidenceRoot, [switch]$WhatIf) {
    $iniPath = [IO.Path]::GetFullPath([string]$Config.mo2.ini)
    if (-not (Test-Path -LiteralPath $iniPath -PathType Leaf)) { throw "MO2 INI does not exist: $iniPath" }
    $beforeBytes = [IO.File]::ReadAllBytes($iniPath)
    $selection = Get-SelectedProfileFromBytes -Bytes $beforeBytes
    $beforeValue = [string]$selection.value
    $replacement = $selection.match.Groups['prefix'].Value + '@ByteArray(' + $TargetProfile + ')'
    $afterText = $selection.text.Remove($selection.match.Index, $selection.match.Length).Insert($selection.match.Index, $replacement)
    $afterBytes = [Text.Encoding]::UTF8.GetBytes($afterText)
    $beforeHash = Get-WorkspaceBytesSha256 -Bytes $beforeBytes
    $resultHash = Get-WorkspaceBytesSha256 -Bytes $afterBytes
    $backupPath = Join-Path $EvidenceRoot 'ModOrganizer.before.ini'
    $receiptPath = Join-Path $EvidenceRoot ('selected-profile-' + (Get-SafeName $Operation) + '.receipt.json')
    $journalPath = Join-Path $EvidenceRoot ('selected-profile-' + (Get-SafeName $Operation) + '.selected-profile.journal.json')
    $record = [pscustomobject][ordered]@{
        iniPath = $iniPath; selectedProfileBefore = $beforeValue; selectedProfileAfter = $TargetProfile
        backupPath = $backupPath; receiptPath = $receiptPath; journalPath = $journalPath; beforeSha256 = $beforeHash; resultSha256 = $resultHash; changed = $beforeValue -cne $TargetProfile
    }
    if ($WhatIf) { return $record }
    if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null }
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { throw "Refusing to overwrite the exact MO2 INI backup: $backupPath" }
    [IO.File]::WriteAllBytes($backupPath, $beforeBytes)
    $journal = [ordered]@{
        contractVersion = '2.0.0'; operation = $Operation; phase = 'prepared'; iniPath = $iniPath
        targetProfile = $TargetProfile; selectedProfileBefore = $beforeValue; backupPath = $backupPath
        receiptPath = $receiptPath; journalPath = $journalPath; beforeSha256 = $beforeHash; resultSha256 = $resultHash
        preparedUtc = [DateTime]::UtcNow.ToString('o'); rollback = $null
    }
    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
    $mutationApplied = $false
    try {
        if ($beforeValue -cne $TargetProfile) {
            if ($InternalTestFailurePoint -eq 'selected-profile-before-cas') { [IO.File]::AppendAllText($iniPath, "; injected concurrent drift`r`n", [Text.UTF8Encoding]::new($false)) }
            $livePreimage = [IO.File]::ReadAllBytes($iniPath)
            if ($livePreimage.Length -ne $beforeBytes.Length -or [Convert]::ToBase64String($livePreimage) -cne [Convert]::ToBase64String($beforeBytes)) {
                throw 'MO2 INI changed after planning and before replacement; no selected-profile mutation was applied.'
            }
            Write-WorkspaceBytesAtomic -Path $iniPath -Bytes $afterBytes
            $mutationApplied = $true
            $journal['phase'] = 'selection-applied-uncommitted'; Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
        }
        $verifiedBytes = [IO.File]::ReadAllBytes($iniPath)
        $verified = [string](Get-SelectedProfileFromBytes -Bytes $verifiedBytes).value
        if ($verified -cne $TargetProfile) { throw "MO2 selected profile postcondition did not match '$TargetProfile'." }
        if ((Get-WorkspaceBytesSha256 -Bytes $verifiedBytes) -cne $resultHash) { throw 'MO2 selected profile result bytes differ from the planned result.' }
        $null = Write-SelectedProfileReceipt -Journal $journal
        $journal['phase'] = 'committed'; $journal['committedUtc'] = [DateTime]::UtcNow.ToString('o')
        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
    }
    catch {
        $failure = $_.Exception.Message
        if ($mutationApplied) {
            Write-WorkspaceBytesAtomic -Path $iniPath -Bytes $beforeBytes
            $journal['phase'] = 'rolled-back'; $journal['rollback'] = [ordered]@{ verified = (Get-FileHash -LiteralPath $iniPath -Algorithm SHA256).Hash -ceq $beforeHash; completedUtc = [DateTime]::UtcNow.ToString('o') }
            try { Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal } catch {}
            throw "MO2 selected profile transaction '$Operation' failed after mutation; the exact INI bytes were restored. $failure"
        }
        $journal['phase'] = 'aborted-before-mutation'; $journal['abortedUtc'] = [DateTime]::UtcNow.ToString('o'); $journal['failure'] = $failure
        try { Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal } catch {}
        throw "MO2 selected profile transaction '$Operation' failed before mutation; live INI bytes were not overwritten. $failure"
    }
    return $record
}

function Get-WorkspaceManifestPath($Config, [string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[a-z0-9-]+$') { throw 'WorkspaceId is missing or malformed.' }
    return Join-Path (Join-Path ([string]$Config.storage.sessionStaging) 'workspaces') ($Id + '.json')
}

function Resolve-VerifiedSaveFixture($Config, [string]$SourceName, [string]$SourcePath, $SourceSnapshot, [string]$RequestedManifestPath, [string]$RequestedFixtureId) {
    $configuredManifest = if ($Config.defaults.PSObject.Properties['newGameFixtureManifest']) { [string]$Config.defaults.newGameFixtureManifest } else { '' }
    $manifestInput = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { $RequestedManifestPath } else { $configuredManifest }
    if ([string]::IsNullOrWhiteSpace($manifestInput)) { throw 'VerifiedFixture requires -FixtureManifestPath or defaults.newGameFixtureManifest.' }
    $manifestPath = [IO.Path]::GetFullPath($manifestInput)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Fixture manifest does not exist: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.PSObject.Properties['profileFingerprintSha256'] -or [string]$manifest.profileFingerprintSha256 -cne [string]$SourceSnapshot.sha256) { throw 'Verified fixture profile fingerprint does not match the stable source profile.' }
    if ($manifest.PSObject.Properties['sourceProfile'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.sourceProfile) -and [string]$manifest.sourceProfile -cne $SourceName) { throw 'Verified fixture sourceProfile does not match the exact stable source profile.' }
    $fixtures = @($manifest.fixtures)
    if ($fixtures.Count -eq 0) { throw 'Verified fixture manifest contains no fixtures.' }
    $selectedId = if (-not [string]::IsNullOrWhiteSpace($RequestedFixtureId)) { $RequestedFixtureId } elseif ($manifest.PSObject.Properties['defaultFixtureId']) { [string]$manifest.defaultFixtureId } else { '' }
    if ([string]::IsNullOrWhiteSpace($selectedId)) { throw 'Verified fixture selection requires -FixtureId or manifest.defaultFixtureId.' }
    $matches = @($fixtures | Where-Object { [string]$_.id -ceq $selectedId })
    if ($matches.Count -ne 1) { throw "Expected exactly one fixture named '$selectedId'; found $($matches.Count)." }
    $selected = $matches[0]
    $files = @($selected.files)
    if ($files.Count -eq 0) { throw "Verified fixture '$selectedId' contains no files." }
    $sourceSaves = [IO.Path]::GetFullPath((Join-Path $SourcePath 'saves'))
    $verifiedFiles = @()
    $essCount = 0
    foreach ($file in $files) {
        Assert-TreeOperationBudget -Purpose 'World-entry fixture hashing'
        $relative = [string]$file.relativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { throw "Fixture '$selectedId' contains a missing or rooted relativePath." }
        $sourceFile = [IO.Path]::GetFullPath((Join-Path $sourceSaves $relative))
        if (-not $sourceFile.StartsWith($sourceSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture file escapes the source saves directory: $relative" }
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { throw "Fixture source file does not exist: $sourceFile" }
        $item = Get-Item -LiteralPath $sourceFile
        $hash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
        Assert-TreeOperationBudget -Purpose 'World-entry fixture hashing'
        if (-not $file.PSObject.Properties['sha256'] -or $hash -cne [string]$file.sha256) { throw "Fixture source hash does not match for '$relative'." }
        if ($file.PSObject.Properties['bytes'] -and [long]$file.bytes -ne [long]$item.Length) { throw "Fixture source byte count does not match for '$relative'." }
        if ([IO.Path]::GetExtension($relative) -ieq '.ess') { $essCount++ }
        $verifiedFiles += [pscustomobject][ordered]@{ relativePath = $relative; sourcePath = $sourceFile; bytes = [long]$item.Length; sha256 = $hash }
    }
    if ($essCount -ne 1) { throw "Verified fixture '$selectedId' must contain exactly one .ess save; found $essCount." }
    return [pscustomobject][ordered]@{
        manifestPath = $manifestPath
        manifestContractVersion = [string]$manifest.contractVersion
        id = $selectedId
        label = if ($selected.PSObject.Properties['label']) { [string]$selected.label } else { $selectedId }
        location = if ($selected.PSObject.Properties['location']) { [string]$selected.location } else { $null }
        loadName = if ($selected.PSObject.Properties['loadName']) { [string]$selected.loadName } else { [IO.Path]::GetFileNameWithoutExtension([string](@($verifiedFiles | Where-Object { [IO.Path]::GetExtension($_.relativePath) -ieq '.ess' })[0].relativePath)) }
        files = @($verifiedFiles)
    }
}

function Get-VerifiedSaveFixtureStatus($Config, [string]$SourceName, [string]$SourcePath, $SourceSnapshot, [string]$RequestedManifestPath, [string]$RequestedFixtureId) {
    $configuredManifest = if ($Config.defaults.PSObject.Properties['newGameFixtureManifest']) { [string]$Config.defaults.newGameFixtureManifest } else { '' }
    $manifestInput = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { $RequestedManifestPath } else { $configuredManifest }
    $manifestSource = if (-not [string]::IsNullOrWhiteSpace($RequestedManifestPath)) { 'parameter' } elseif (-not [string]::IsNullOrWhiteSpace($configuredManifest)) { 'configuration' } else { 'none' }
    $exampleManifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'save-fixtures.example.json'))
    $guidance = @(
        'Live-load one known-good save in the maintained source profile before declaring or refreshing the fixture.',
        'Copy and adapt tools/mo2-workspace-control/save-fixtures.example.json outside the checkout.',
        'Set defaults.newGameFixtureManifest in the stable per-user machine configuration, or pass -FixtureManifestPath explicitly.',
        'Declare one .ess save plus any matching co-save files, then run fixture-status again to validate exact hashes and the stable-profile fingerprint.',
        'Fresh workspace creation is blocked until the manifest default fixture is valid.'
    )
    if ([string]::IsNullOrWhiteSpace($manifestInput)) {
        return [pscustomobject][ordered]@{
            configured = $false; discoveryState = 'manifest-not-configured'; manifestSource = $manifestSource
            manifestPath = $null; manifestExists = $false; exampleManifestPath = $exampleManifestPath
            configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
            sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
            actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256; valid = $false
        }
    }
    $manifestPath = [IO.Path]::GetFullPath($manifestInput)
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            configured = $true; discoveryState = 'manifest-missing'; manifestSource = $manifestSource
            manifestPath = $manifestPath; manifestExists = $false; exampleManifestPath = $exampleManifestPath
            configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
            sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
            actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256; valid = $false
        }
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $fixtures = @($manifest.fixtures)
    $selectedId = if (-not [string]::IsNullOrWhiteSpace($RequestedFixtureId)) { $RequestedFixtureId } elseif ($manifest.PSObject.Properties['defaultFixtureId']) { [string]$manifest.defaultFixtureId } else { '' }
    if ([string]::IsNullOrWhiteSpace($selectedId)) { throw 'Fixture inspection requires -FixtureId or manifest.defaultFixtureId.' }
    $matches = @($fixtures | Where-Object { [string]$_.id -ceq $selectedId })
    if ($matches.Count -ne 1) { throw "Expected exactly one fixture named '$selectedId'; found $($matches.Count)." }
    $selected = $matches[0]
    $sourceSaves = [IO.Path]::GetFullPath((Join-Path $SourcePath 'saves'))
    $fileStatus = @()
    $essCount = 0
    foreach ($file in @($selected.files)) {
        Assert-TreeOperationBudget -Purpose 'World-entry fixture status hashing'
        $relative = [string]$file.relativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative)) { throw "Fixture '$selectedId' contains a missing or rooted relativePath." }
        $sourceFile = [IO.Path]::GetFullPath((Join-Path $sourceSaves $relative))
        if (-not $sourceFile.StartsWith($sourceSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture file escapes the source saves directory: $relative" }
        $exists = Test-Path -LiteralPath $sourceFile -PathType Leaf
        $actualBytes = if ($exists) { [long](Get-Item -LiteralPath $sourceFile).Length } else { $null }
        $actualHash = if ($exists) { (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash } else { $null }
        Assert-TreeOperationBudget -Purpose 'World-entry fixture status hashing'
        $expectedHash = if ($file.PSObject.Properties['sha256']) { [string]$file.sha256 } else { $null }
        $expectedBytes = if ($file.PSObject.Properties['bytes']) { [long]$file.bytes } else { $null }
        if ([IO.Path]::GetExtension($relative) -ieq '.ess') { $essCount++ }
        $fileStatus += [pscustomobject][ordered]@{
            relativePath = $relative; sourcePath = $sourceFile; exists = $exists
            expectedSha256 = $expectedHash; actualSha256 = $actualHash
            expectedBytes = $expectedBytes; actualBytes = $actualBytes
            hashMatches = $exists -and -not [string]::IsNullOrWhiteSpace($expectedHash) -and $actualHash -ceq $expectedHash
            bytesMatch = $exists -and ($null -eq $expectedBytes -or $actualBytes -eq $expectedBytes)
        }
    }
    $expectedFingerprint = if ($manifest.PSObject.Properties['profileFingerprintSha256']) { [string]$manifest.profileFingerprintSha256 } else { $null }
    $sourceProfileMatches = -not $manifest.PSObject.Properties['sourceProfile'] -or [string]::IsNullOrWhiteSpace([string]$manifest.sourceProfile) -or [string]$manifest.sourceProfile -ceq $SourceName
    $allFilesMatch = @($fileStatus | Where-Object { -not $_.exists -or -not $_.hashMatches -or -not $_.bytesMatch }).Count -eq 0
    return [pscustomobject][ordered]@{
        configured = $true; discoveryState = 'manifest-ready'; manifestSource = $manifestSource; manifestExists = $true
        exampleManifestPath = $exampleManifestPath; configurationProperty = 'defaults.newGameFixtureManifest'; guidance = $guidance
        manifestPath = $manifestPath; manifest = $manifest; fixture = $selected; fixtureId = $selectedId
        sourceProfileName = $SourceName; sourceProfileDirectory = $SourcePath
        expectedProfileFingerprintSha256 = $expectedFingerprint; actualProfileFingerprintSha256 = [string]$SourceSnapshot.sha256
        profileFingerprintMatches = -not [string]::IsNullOrWhiteSpace($expectedFingerprint) -and $expectedFingerprint -ceq [string]$SourceSnapshot.sha256
        sourceProfileMatches = $sourceProfileMatches; files = @($fileStatus); allFilesMatch = $allFilesMatch
        essCount = $essCount
        valid = $sourceProfileMatches -and $allFilesMatch -and $essCount -eq 1 -and -not [string]::IsNullOrWhiteSpace($expectedFingerprint) -and $expectedFingerprint -ceq [string]$SourceSnapshot.sha256
    }
}

function Resolve-TaskId([string]$RequestedTaskId, [switch]$Required) {
    $resolved = $RequestedTaskId
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = [Environment]::GetEnvironmentVariable('CODEX_THREAD_ID') }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = [Environment]::GetEnvironmentVariable('CODEX_TASK_ID') }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        if ($Required) { throw 'A stable task identity is required. Pass -TaskId or set CODEX_THREAD_ID/CODEX_TASK_ID.' }
        return $null
    }
    $resolved = $resolved.Trim()
    if ($resolved.Length -gt 256 -or $resolved -match '[\r\n]') { throw 'TaskId is malformed.' }
    return $resolved
}

function Read-Workspace($Config, [string]$Id) {
    $path = Get-WorkspaceManifestPath -Config $Config -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Workspace does not exist: $Id" }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([string]$manifest.workspaceId -cne $Id) { throw 'Workspace manifest identity does not match its filename.' }
    if (-not $manifest.PSObject.Properties['ownershipId'] -or [string]::IsNullOrWhiteSpace([string]$manifest.ownershipId)) { throw 'Workspace predates immutable creation ownership and must be recreated.' }
    $expectedProfileName = 'Codex Task - ' + $Id
    $profilesRoot = [IO.Path]::GetFullPath([string]$Config.mo2.profilesDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $expectedProfilePath = [IO.Path]::GetFullPath((Join-Path $profilesRoot $expectedProfileName))
    if ([string]$manifest.profileName -cne $expectedProfileName -or [IO.Path]::GetFullPath([string]$manifest.profilePath) -cne $expectedProfilePath) { throw 'Workspace profile identity is not the exact derived task profile.' }
    $journalPath = Get-WorkspaceCreationJournalPath -Config $Config -Id $Id
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'Workspace creation journal is missing.' }
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
    if ([string]$journal.phase -cne 'committed' -or [string]$journal.workspaceId -cne $Id -or [string]$journal.ownershipId -cne [string]$manifest.ownershipId -or [string]$journal.profilePath -cne $expectedProfilePath) { throw 'Workspace creation journal does not authorize this manifest.' }
    return [pscustomobject]@{ path = $path; data = $manifest }
}

function Assert-WorkspaceTaskOwner($Workspace, [string]$ResolvedTaskId) {
    if (-not $Workspace.data.PSObject.Properties['ownerTaskId']) { throw 'Workspace predates durable task ownership and cannot be resumed. Create a fresh task workspace.' }
    if ([string]$Workspace.data.ownerTaskId -cne $ResolvedTaskId) { throw 'Workspace belongs to a different task identity.' }
}

function Read-OwnedWorkspace($Config, [string]$Id, [string]$OwnedAccessId, [string]$ResolvedTaskId) {
    $workspace = Read-Workspace -Config $Config -Id $Id
    Assert-WorkspaceTaskOwner -Workspace $workspace -ResolvedTaskId $ResolvedTaskId
    $manifest = $workspace.data
    if ([string]$manifest.accessId -cne $OwnedAccessId) { throw 'Workspace is owned by a different MO2 access lease.' }
    return $workspace
}

function Get-TaskWorkspaces($Config, [string]$ResolvedTaskId) {
    $root = Join-Path ([string]$Config.storage.sessionStaging) 'workspaces'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Force | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($manifest.PSObject.Properties['ownerTaskId'] -and [string]$manifest.ownerTaskId -ceq $ResolvedTaskId) {
                $profilePath = [IO.Path]::GetFullPath([string]$manifest.profilePath)
                $items += [pscustomobject][ordered]@{
                    workspaceId = [string]$manifest.workspaceId; status = [string]$manifest.status
                    profileName = [string]$manifest.profileName; profileDirectory = $profilePath
                    profileExists = Test-Path -LiteralPath $profilePath -PathType Container
                    resumable = ([string]$manifest.status -in @('ready', 'retained')) -and (Test-Path -LiteralPath $profilePath -PathType Container)
                    sourceProfile = [string]$manifest.sourceProfile; accessId = [string]$manifest.accessId
                    createdUtc = [string]$manifest.createdUtc; lastResumedUtc = if ($manifest.PSObject.Properties['lastResumedUtc']) { [string]$manifest.lastResumedUtc } else { $null }
                    manifestPath = $file.FullName
                }
            }
        }
        catch { }
    }
    return @($items)
}

function Assert-AccessAndClosed($Config, [string]$OwnedAccessId, [string]$Profile, [switch]$AllowOverwriteShaderCaches) {
    if ([string]::IsNullOrWhiteSpace($OwnedAccessId)) { throw '-AccessId is required for workspace mutation.' }
    $access = Invoke-MO2AccessStatus -Config $Config -AccessId $OwnedAccessId
    if (-not $access.ok -or -not $access.data.owned) { throw 'The exact MO2 access lease is not owned by this task.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$access.data.access.sessionId)) { throw 'Release the active MO2 evidence session before mutating a test workspace.' }
    $validation = Invoke-MO2Validate -Config $Config -Profile $Profile -RequireClosed -OwnedAccessId $OwnedAccessId
    if (-not $validation.ok) {
        $failedChecks = @($validation.checks | Where-Object status -eq 'fail')
        $onlyExpectedCaches = $AllowOverwriteShaderCaches -and $failedChecks.Count -eq 1 -and $failedChecks[0].name -eq 'overwrite' -and @($validation.data.overwrite.shaderCaches).Count -gt 0
        if (-not $onlyExpectedCaches) { throw "MO2 closed-state validation failed: $($validation.errors -join '; ')" }
    }
    return $validation
}

function Get-OverwriteShaderCacheDirectories($Config) {
    $overwriteRoot = [IO.Path]::GetFullPath([string]$Config.mo2.overwriteDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $overwriteRoot -PathType Container)) { return @() }
    $matches = @(Get-ChildItem -LiteralPath $overwriteRoot -Directory -Recurse -Force | Where-Object { $_.Name -match '^(?i:ShaderCache)(?:[.]|$)' } | Sort-Object FullName)
    $roots = @()
    foreach ($match in $matches) {
        $nested = @($roots | Where-Object { $match.FullName.StartsWith($_.FullName + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $nested) { $roots += $match }
    }
    return @($roots)
}

$resolvedConfig = $null
try {
    $script:TreeOperationDeadlineUtc = if ($InternalTestFailurePoint -eq 'tree-operation-deadline') { [DateTime]::UtcNow.AddMilliseconds(-1) } else { [DateTime]::UtcNow.AddSeconds($TreeOperationTimeoutSeconds) }
    $resolvedConfig = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control')
    if (-not $resolvedConfig.exists) { throw "MO2 configuration was not found: $($resolvedConfig.path)" }
    $config = Read-MO2ControlConfig -ConfigPath $resolvedConfig.path
    $profilesRoot = [IO.Path]::GetFullPath([string]$config.mo2.profilesDirectory)
    $modsRoot = [IO.Path]::GetFullPath([string]$config.mo2.modsDirectory)

    if (-not $WhatIfPreference) {
        # Recovery precedes command-specific reads so an interrupted operation can never be
        # mistaken for a stable workspace merely because the next command is read-oriented.
        Invoke-WithWorkspaceTransactionLock -Config $config -Action { $null } | Out-Null
    }

    if ($Command -eq 'release') {
        throw 'Workspace release is intentionally unavailable because it previously deleted retained task state. Yield scarce MO2 access with Invoke-MO2Control.ps1 release-access; destroy a finished workspace only with the explicit retire command.'
    }

    if ($Command -eq 'list-task') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $allWorkspaces = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId)
        $workspaces = @($allWorkspaces | Where-Object resumable)
        $result = [pscustomobject][ordered]@{
            ok = $true; command = $Command; state = $(if ($workspaces.Count -eq 0) { 'no-retained-workspaces' } else { 'retained-workspaces-found' })
            data = [pscustomobject][ordered]@{
                ownerTaskId = $resolvedTaskId; count = $workspaces.Count; workspaces = $workspaces
                unavailableWorkspaces = @($allWorkspaces | Where-Object { -not $_.resumable })
                guidance = if ($workspaces.Count -eq 0) { 'This task has no retained workspace. After acquiring MO2 access, explicitly create a fresh workspace.' } else { 'After acquiring MO2 access, explicitly resume one listed WorkspaceId or explicitly create a fresh workspace.' }
            }
        }
    }
    elseif ($Command -in @('fixture-status', 'refresh-fixture')) {
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required for fixture control.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        if ($Command -eq 'refresh-fixture') { $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName -AllowOverwriteShaderCaches }
        $sourceSnapshot = Get-ProfileSnapshot -Path $sourcePath
        $status = Get-VerifiedSaveFixtureStatus -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $sourceSnapshot -RequestedManifestPath $FixtureManifestPath -RequestedFixtureId $FixtureId
        if ($Command -eq 'fixture-status') {
            $fixtureState = if ([string]$status.discoveryState -eq 'manifest-not-configured') { 'fixture-not-configured' } elseif ([string]$status.discoveryState -eq 'manifest-missing') { 'fixture-manifest-missing' } elseif ($status.valid) { 'fixture-valid' } else { 'fixture-stale' }
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $fixtureState; data = $status }
        }
        else {
            if ([string]$status.discoveryState -ne 'manifest-ready') { throw "Fixture refresh requires an existing manifest. $(@($status.guidance)[0])" }
            if (-not $status.sourceProfileMatches) { throw 'Fixture sourceProfile does not match the exact stable source profile; refusing refresh.' }
            if ($status.essCount -ne 1) { throw "Fixture '$($status.fixtureId)' must contain exactly one .ess save before refresh; found $($status.essCount)." }
            if (@($status.files | Where-Object { -not $_.exists }).Count -gt 0) { throw 'Fixture refresh requires every declared source save file to exist.' }
            $manifest = $status.manifest
            $manifest.profileFingerprintSha256 = [string]$sourceSnapshot.sha256
            $selected = @($manifest.fixtures | Where-Object { [string]$_.id -ceq [string]$status.fixtureId })[0]
            foreach ($file in @($selected.files)) {
                $actual = @($status.files | Where-Object { [string]$_.relativePath -ceq [string]$file.relativePath })[0]
                if ($file.PSObject.Properties['bytes']) { $file.bytes = [long]$actual.actualBytes } else { $file | Add-Member -NotePropertyName bytes -NotePropertyValue ([long]$actual.actualBytes) }
                if ($file.PSObject.Properties['sha256']) { $file.sha256 = [string]$actual.actualSha256 } else { $file | Add-Member -NotePropertyName sha256 -NotePropertyValue ([string]$actual.actualSha256) }
            }
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $evidenceRoot = Join-Path (Split-Path -Parent ([string]$status.manifestPath)) ('.fixture-refresh-' + $status.fixtureId + '-' + $stamp)
            $backupPath = Join-Path $evidenceRoot 'manifest.before.json'
            $receiptPath = Join-Path $evidenceRoot 'fixture-refresh.receipt.json'
            if ($PSCmdlet.ShouldProcess([string]$status.manifestPath, "refresh exact fixture '$($status.fixtureId)' fingerprints from stable profile '$sourceName'")) {
                New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
                Copy-Item -LiteralPath ([string]$status.manifestPath) -Destination $backupPath
                Write-WorkspaceJsonAtomic -Path ([string]$status.manifestPath) -Value $manifest
                $verifiedSnapshot = Get-ProfileSnapshot -Path $sourcePath
                $verified = Get-VerifiedSaveFixtureStatus -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $verifiedSnapshot -RequestedManifestPath ([string]$status.manifestPath) -RequestedFixtureId ([string]$status.fixtureId)
                if (-not $verified.valid) {
                    Copy-Item -LiteralPath $backupPath -Destination ([string]$status.manifestPath) -Force
                    throw 'Fixture refresh postcondition failed; the exact manifest backup was restored.'
                }
                Write-WorkspaceJsonAtomic -Path $receiptPath -Value ([pscustomobject][ordered]@{
                    contractVersion = '1.0.0'; operation = 'refresh-fixture'; fixtureId = [string]$status.fixtureId
                    sourceProfileName = $sourceName; sourceProfileDirectory = $sourcePath; manifestPath = [string]$status.manifestPath
                    backupPath = $backupPath; beforeSha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
                    resultSha256 = (Get-FileHash -LiteralPath ([string]$status.manifestPath) -Algorithm SHA256).Hash
                    expectedFingerprintBefore = [string]$status.expectedProfileFingerprintSha256
                    actualFingerprint = [string]$verified.actualProfileFingerprintSha256; refreshedUtc = [DateTime]::UtcNow.ToString('o')
                })
                $status = $verified
            }
            $status | Add-Member -NotePropertyName backupPath -NotePropertyValue $backupPath -Force
            $status | Add-Member -NotePropertyName receiptPath -NotePropertyValue $receiptPath -Force
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'fixture-refreshed' }); data = $status }
        }
    }
    elseif ($Command -eq 'prepare-source') {
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required for source preparation.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName -AllowOverwriteShaderCaches
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        $preparation = [pscustomobject][ordered]@{
            state = 'overwrite-preserved'; sourceProfile = $sourceName; sourceProfilePath = $sourcePath
            overwritePath = [IO.Path]::GetFullPath([string]$config.mo2.overwriteDirectory)
            shaderCacheDirectories = @(Get-OverwriteShaderCacheDirectories -Config $config | Select-Object -ExpandProperty FullName)
            guidance = 'Source preparation no longer moves generated cache content. Workspace prepare snapshots and binds the exact MO2 Overwrite trees.'
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$preparation.state; data = $preparation }
    }
    elseif ($Command -eq 'create') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $sourceName = if (-not [string]::IsNullOrWhiteSpace($SourceProfile)) { $SourceProfile } elseif ($config.defaults.PSObject.Properties['testProfileSource']) { [string]$config.defaults.testProfileSource } else { throw 'defaults.testProfileSource is required; test workspaces never infer a stable source from the ordinary session default.' }
        $sourcePath = Resolve-DirectProfilePath -ProfilesRoot $profilesRoot -ProfileName $sourceName
        $validation = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile $sourceName -AllowOverwriteShaderCaches
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Stable source profile does not exist: $sourceName" }
        $workspaceId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ').ToLowerInvariant()), (Get-SafeName $Label), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $ownershipId = [guid]::NewGuid().ToString('N')
        $profileName = 'Codex Task - ' + $workspaceId
        $profilePath = Join-Path $profilesRoot $profileName
        $manifestPath = Get-WorkspaceManifestPath -Config $config -Id $workspaceId
        $creationJournalPath = Get-WorkspaceCreationJournalPath -Config $config -Id $workspaceId
        if (Test-Path -LiteralPath $profilePath) { throw "Generated profile already exists: $profilePath" }
        if (Test-Path -LiteralPath $manifestPath) { throw "Generated workspace already exists: $manifestPath" }
        $sourceSnapshot = Get-ProfileSnapshot -Path $sourcePath
        $sourceSaveSnapshot = Get-SaveTreeSnapshot -ProfilePath $sourcePath
        $initialMods = @(Get-ChildItem -LiteralPath $modsRoot -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object)
        $runtimeOutputPath = [IO.Path]::GetFullPath([string]$config.mo2.overwriteDirectory)
        $runtimeCachePath = Join-Path $runtimeOutputPath 'ShaderCache'
        $runtimeBackupPath = Join-Path $runtimeOutputPath 'backup'
        $runtimeMarkerPath = Join-Path $runtimeOutputPath '.codex-workspace-output-owner.json'
        $cacheEvidenceDirectory = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-shader-cache')
        $backupEvidenceDirectory = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-backup')
        $runtimeExecutable = [string]$config.defaults.executable
        if ([string]::IsNullOrWhiteSpace($runtimeExecutable)) { throw 'defaults.executable is required for task runtime-output isolation.' }
        if (Test-Path -LiteralPath $runtimeMarkerPath -PathType Leaf) { throw "MO2 Overwrite is already owned by another task workspace: $runtimeMarkerPath" }
        try {
            # Every fresh clone must inherit one known-good route into the game
            # world. SavePolicy controls later test authorization, not whether
            # the maintained source has exact static integrity evidence to seed
            # task profiles. Runtime world-entry qualification is a separate
            # observation and is never inferred from hashes alone.
            $worldEntryFixture = Resolve-VerifiedSaveFixture -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $sourceSnapshot -RequestedManifestPath $FixtureManifestPath -RequestedFixtureId ''
        }
        catch {
            throw "Fresh workspace creation requires a valid default world-entry save in the maintained source profile. Run fixture-status and repair defaults.newGameFixtureManifest before cloning. $($_.Exception.Message)"
        }
        $fixture = $null
        if ($SavePolicy -eq 'VerifiedFixture') {
            $fixture = if ([string]::IsNullOrWhiteSpace($FixtureId)) {
                $worldEntryFixture
            } else {
                Resolve-VerifiedSaveFixture -Config $config -SourceName $sourceName -SourcePath $sourcePath -SourceSnapshot $sourceSnapshot -RequestedManifestPath $FixtureManifestPath -RequestedFixtureId $FixtureId
            }
        }
        $manifest = [pscustomobject][ordered]@{
            contractVersion = '2.4.0'; workspaceId = $workspaceId; ownershipId = $ownershipId; ownerTaskId = $resolvedTaskId; accessId = $AccessId; status = 'creating'; acquisitionDisposition = 'fresh-clone'
            leaseHistory = @([pscustomobject][ordered]@{ accessId = $AccessId; acquiredForWorkspaceUtc = [DateTime]::UtcNow.ToString('o'); disposition = 'created' })
            label = $Label; createdUtc = [DateTime]::UtcNow.ToString('o'); sourceProfile = $sourceName
            sourceProfileName = $sourceName; sourceProfilePath = $sourcePath; sourceProfileDirectory = $sourcePath; sourceSnapshot = $sourceSnapshot
            profile = $profileName; profilePath = $profilePath; profileName = $profileName; profileDirectory = $profilePath; modListPath = (Join-Path $profilePath 'modlist.txt')
            savePolicy = $SavePolicy; fixtureManifestPath = [string]$worldEntryFixture.manifestPath
            worldEntryFixture = $worldEntryFixture; sourceIntegrity = [pscustomobject][ordered]@{
                integrityVerified = $true; runtimeQualified = $false; scope = 'fresh-clone-source'; fixtureId = [string]$worldEntryFixture.id
                profileFingerprintSha256 = [string]$sourceSnapshot.sha256; cloneVerifiedUtc = [DateTime]::UtcNow.ToString('o')
                runtimeQualificationEvidence = $null
                warranty = 'Exact source and save bytes were verified at clone creation. This does not assert a live game load. Resumed task profiles are preserved as-is and are not reverified after task edits.'
            }
            saveFixture = $fixture; sourceSaveSnapshot = $sourceSaveSnapshot; initialModNames = $initialMods; protectedSharedModNames = $initialMods; createdMods = @(); registeredMods = @(); inheritedSaves = $true
            creationJournalPath = $creationJournalPath
            runtimeOutput = [pscustomobject][ordered]@{
                state = 'planned'; mode = 'mo2-overwrite-output'; executable = $runtimeExecutable
                overwritePath = $runtimeOutputPath; cachePath = $runtimeCachePath; backupPath = $runtimeBackupPath
                ownerMarkerPath = $runtimeMarkerPath; ownerMarkerSha256 = $null
                cachePathExistedBefore = $null; backupPathExistedBefore = $null
                communityShadersPlugin = $null
                cacheEvidenceDirectory = $cacheEvidenceDirectory
                cachePlanPath = (Join-Path $cacheEvidenceDirectory 'shader-cache-task.plan.json')
                cacheCompletionPath = (Join-Path $cacheEvidenceDirectory 'shader-cache-task.completion.json')
                cachePrepareArguments = [pscustomobject][ordered]@{
                    CachePath = $runtimeCachePath; ProfilePath = (Join-Path $profilePath 'modlist.txt')
                    ModsPath = $modsRoot; BindToOverwrite = $true; EvidenceDirectory = $cacheEvidenceDirectory
                    RequireMaterializedOutput = $true; BuildId = $null; ShaderCacheAbi = $null
                    WorkspaceId = $workspaceId; OwnershipId = $ownershipId
                    OwnerMarkerPath = $runtimeMarkerPath; OwnerMarkerSha256 = $null
                }
                backupEvidenceDirectory = $backupEvidenceDirectory
                backupPlanPath = (Join-Path $backupEvidenceDirectory 'backup-task.plan.json')
                backupTransactionReceiptPath = (Join-Path $backupEvidenceDirectory 'shader-cache-transaction.receipt.json')
                backupCompletionPath = (Join-Path $backupEvidenceDirectory 'backup-task.completion.json')
                shadowedLoosePaths = @('ShaderCache', 'backup'); shadowReceipt = $null
            }
            saveGuidance = 'Every fresh clone requires and copies an integrity-verified default world-entry fixture plus the complete source saves tree. Static integrity does not assert a successful live load. MainMenuOnly and FreshGame still describe test authorization; use VerifiedFixture for an exact declared load target. Resumed profiles are preserved without save reverification. See docs/BREEZEHOME-SAVE.md.'
            ownershipRule = 'The workspace may change only its cloned profile, task-owned mods, and the exact snapshotted MO2 Overwrite ShaderCache and backup transactions. Existing shared mod directories are immutable.'
        }
        if ($PSCmdlet.ShouldProcess($profilePath, "clone stable MO2 profile '$sourceName' including its complete saves tree")) {
            Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                if ((Test-Path -LiteralPath $profilePath) -or (Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath $creationJournalPath)) { throw 'Workspace creation target appeared after planning; no clone was started.' }
                Assert-NoWorkspaceReparsePoint -Path $sourcePath -Purpose 'Stable source profile'
                if ([string](Get-ProfileSnapshot -Path $sourcePath).sha256 -cne [string]$sourceSnapshot.sha256) { throw 'Stable source profile changed after planning; no clone was started.' }
                $selectionEvidence = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-create-select')
                $selectedProfileJournalPath = Join-Path $selectionEvidence ('selected-profile-' + (Get-SafeName 'select-created-task-workspace') + '.selected-profile.journal.json')
                $journal = [pscustomobject][ordered]@{
                    contractVersion = '2.0.0'; operation = 'create'; phase = 'prepared'; workspaceId = $workspaceId; ownershipId = $ownershipId
                    ownerTaskId = $resolvedTaskId; sourceProfile = $sourceName; sourceProfilePath = $sourcePath; sourceSnapshotSha256 = [string]$sourceSnapshot.sha256
                    profileName = $profileName; profilePath = $profilePath; manifestPath = $manifestPath
                    overwriteOwnerMarkerPath = $runtimeMarkerPath; backupEvidenceDirectory = $backupEvidenceDirectory
                    cachePath = $runtimeCachePath; backupPath = $runtimeBackupPath
                    cachePathExistedBefore = $null; backupPathExistedBefore = $null
                    overwriteOwnerMarkerSha256 = $null; communityShadersPlugin = $null
                    preparedUtc = [DateTime]::UtcNow.ToString('o')
                    selectedProfileJournalPath = $selectedProfileJournalPath; selectedProfileTransaction = $null; rollback = $null; committedUtc = $null
                }
                Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                $profileCreated = $false; $runtimeMarkerCreated = $false; $backupSnapshotCreated = $false; $selection = $null
                $cachePathExistedBefore = $false; $backupPathExistedBefore = $false
                try {
                    New-Item -ItemType Directory -Path $profilePath -ErrorAction Stop | Out-Null
                    $profileCreated = $true
                    $journal.phase = 'profile-copy-uncommitted'; Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                    $copyInventory = Get-BoundedTreeInventory -Path $sourcePath -Purpose 'Stable source profile copy'
                    foreach ($directory in @($copyInventory.directories)) {
                        New-Item -ItemType Directory -Path (Join-Path $profilePath ([string]$directory.path)) -Force | Out-Null
                    }
                    foreach ($file in @($copyInventory.files)) {
                        Assert-TreeOperationBudget -Purpose 'Stable source profile copy'
                        $target = Join-Path $profilePath ([string]$file.path)
                        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                        Copy-Item -LiteralPath ([string]$file.fullPath) -Destination $target
                        Assert-TreeOperationBudget -Purpose 'Stable source profile copy'
                    }
                    New-Item -ItemType Directory -Path (Join-Path $profilePath 'saves') -Force | Out-Null
                    $profileSaveSnapshot = Get-SaveTreeSnapshot -ProfilePath $profilePath
                    if ([string]$profileSaveSnapshot.sha256 -cne [string]$sourceSaveSnapshot.sha256 -or [int]$profileSaveSnapshot.fileCount -ne [int]$sourceSaveSnapshot.fileCount) { throw 'Complete source save-tree copy verification failed.' }
                    $manifest | Add-Member -NotePropertyName profileSaveSnapshot -NotePropertyValue $profileSaveSnapshot -Force
                    $fixturesToVerify = @($worldEntryFixture)
                    if ($fixture -and [string]$fixture.id -cne [string]$worldEntryFixture.id) { $fixturesToVerify += $fixture }
                    foreach ($copyFixture in $fixturesToVerify) {
                        $targetSaves = [IO.Path]::GetFullPath((Join-Path $profilePath 'saves'))
                        foreach ($file in @($copyFixture.files)) {
                            Assert-TreeOperationBudget -Purpose 'Copied world-entry fixture verification'
                            $target = [IO.Path]::GetFullPath((Join-Path $targetSaves ([string]$file.relativePath)))
                            if (-not $target.StartsWith($targetSaves + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Fixture target escapes the task saves directory: $($file.relativePath)" }
                            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Verified fixture was not present in the complete copied save tree: $target" }
                            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne [string]$file.sha256) { throw "Copied fixture verification failed: $target" }
                            Assert-TreeOperationBudget -Purpose 'Copied world-entry fixture verification'
                        }
                    }
                    $manifest | Add-Member -NotePropertyName copiedWorldEntrySave -NotePropertyValue $true -Force
                    if ($fixture) { $manifest | Add-Member -NotePropertyName copiedVerifiedSaves -NotePropertyValue $true -Force }

                    foreach ($outputPath in @($runtimeCachePath, $runtimeBackupPath)) {
                        if ((Test-Path -LiteralPath $outputPath) -and -not (Test-Path -LiteralPath $outputPath -PathType Container)) {
                            throw "MO2 Overwrite output path is not a directory: $outputPath"
                        }
                    }
                    $cachePathExistedBefore = Test-Path -LiteralPath $runtimeCachePath -PathType Container
                    $backupPathExistedBefore = Test-Path -LiteralPath $runtimeBackupPath -PathType Container
                    $runtimeMarker = [pscustomobject][ordered]@{
                        contractVersion = '1.1.0'; workspaceId = $workspaceId; ownershipId = $ownershipId
                        ownerTaskId = $resolvedTaskId; mode = 'mo2-overwrite-output'; overwritePath = $runtimeOutputPath
                        createdUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    if ($InternalTestFailurePoint -eq 'owner-marker-before-claim') {
                        $null = New-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -Value ([pscustomobject][ordered]@{
                            contractVersion = '1.1.0'; workspaceId = 'competing-workspace'; ownershipId = 'competing-owner'
                            ownerTaskId = 'competing-task'; mode = 'mo2-overwrite-output'; overwritePath = $runtimeOutputPath
                            createdUtc = [DateTime]::UtcNow.ToString('o')
                        })
                    }
                    $runtimeMarkerHash = New-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -Value $runtimeMarker
                    $runtimeMarkerCreated = $true
                    $manifest.runtimeOutput.ownerMarkerSha256 = $runtimeMarkerHash
                    $manifest.runtimeOutput.cachePrepareArguments.OwnerMarkerSha256 = $runtimeMarkerHash
                    $manifest.runtimeOutput.cachePathExistedBefore = $cachePathExistedBefore
                    $manifest.runtimeOutput.backupPathExistedBefore = $backupPathExistedBefore
                    $journal.overwriteOwnerMarkerSha256 = $runtimeMarkerHash
                    $journal.cachePathExistedBefore = $cachePathExistedBefore
                    $journal.backupPathExistedBefore = $backupPathExistedBefore
                    $journal.phase = 'output-owner-claimed'
                    Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal

                    if (-not $cachePathExistedBefore) { New-Item -ItemType Directory -Path $runtimeCachePath -ErrorAction Stop | Out-Null }
                    if (-not $backupPathExistedBefore) { New-Item -ItemType Directory -Path $runtimeBackupPath -ErrorAction Stop | Out-Null }
                    Remove-WorkspaceCustomOverwrite -SettingsPath (Join-Path $profilePath 'settings.ini') -Executable $runtimeExecutable
                    Remove-WorkspaceCustomOverwrite -SettingsPath (Join-Path $profilePath 'settings.ini') -Executable 'Synthesis'

                    $transactionTool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
                    $blockingProcessNames = @(Get-WorkspaceBlockingProcessNames -Config $config)
                    $communityShadersPlugin = Resolve-WorkspaceCommunityShadersBuildBinding -ProfilePath (Join-Path $profilePath 'modlist.txt') -ModsPath $modsRoot -TransactionTool $transactionTool
                    $manifest.runtimeOutput.communityShadersPlugin = $communityShadersPlugin
                    $manifest.runtimeOutput.cachePrepareArguments.BuildId = [string]$communityShadersPlugin.buildId
                    $manifest.runtimeOutput.cachePrepareArguments.ShaderCacheAbi = [string]$communityShadersPlugin.shaderCacheAbi
                    $journal.communityShadersPlugin = $communityShadersPlugin
                    Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    $backupSnapshot = & $transactionTool snapshot -CachePath $runtimeBackupPath -RelativeCachePath 'backup' -EvidenceDirectory $backupEvidenceDirectory -BlockingProcessNames $blockingProcessNames -NoExit -Confirm:$false | ConvertFrom-Json
                    if (-not $backupSnapshot.ok) { throw "Could not snapshot MO2 Overwrite backup: $($backupSnapshot.errors -join '; ')" }
                    $backupSnapshotCreated = $true
                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    $backupProviders = & $transactionTool providers -ProfilePath (Join-Path $profilePath 'modlist.txt') -ModsPath $modsRoot -RelativeCachePath 'backup' -DeepInventory -NoExit -Confirm:$false | ConvertFrom-Json
                    if (-not $backupProviders.ok) { throw "Could not inspect the task profile's backup providers: $($backupProviders.errors -join '; ')" }
                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    $backupShadow = Copy-WorkspaceProviderTreeShadow -ProviderResult $backupProviders -TargetPath $runtimeBackupPath -RelativePath 'backup' -Purpose 'MO2 Overwrite backup provider union'
                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    $preparedBackup = & $transactionTool inspect -CachePath $runtimeBackupPath -RelativeCachePath 'backup' -NoExit -Confirm:$false | ConvertFrom-Json
                    if (-not $preparedBackup.ok) { throw "Could not verify prepared MO2 Overwrite backup: $($preparedBackup.errors -join '; ')" }

                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    $shadowReceipt = [pscustomobject][ordered]@{
                        contractVersion = '3.0.0'; relativePath = 'backup'; state = 'materialized'
                        bindingMode = 'mo2-overwrite-output'; profilePath = [string]$backupProviders.data.profilePath
                        profileSha256 = [string]$backupProviders.data.profileSha256
                        modsPath = [string]$backupProviders.data.modsPath; targetPath = $runtimeBackupPath
                        workspaceId = $workspaceId; ownershipId = $ownershipId
                        ownerMarkerPath = $runtimeMarkerPath; ownerMarkerSha256 = $runtimeMarkerHash
                        pathExistedBefore = $backupPathExistedBefore; communityShadersPlugin = $communityShadersPlugin
                        transactionReceiptPath = [string]$backupSnapshot.data.receiptPath
                        beforeTreeSha256 = [string]$backupSnapshot.data.inventory.treeSha256
                        requiredProviderFiles = [int]$backupShadow.requiredProviderFiles
                        copiedFiles = [int]$backupShadow.copiedFiles
                        alreadyPresentFiles = [int]$backupShadow.alreadyPresentFiles
                        copied = @($backupShadow.copied); alreadyPresent = @($backupShadow.alreadyPresent)
                        preparedInventory = $preparedBackup.data; workspaceInventory = $backupShadow.targetInventory
                        completedUtc = [DateTime]::UtcNow.ToString('o')
                    }
                    $backupPlan = [pscustomobject][ordered]@{
                        contractVersion = '1.0.0'; state = 'prepared'; workspaceId = $workspaceId; ownershipId = $ownershipId
                        ownerMarkerPath = $runtimeMarkerPath; ownerMarkerSha256 = $runtimeMarkerHash
                        overwritePath = $runtimeOutputPath; backupPath = $runtimeBackupPath
                        pathExistedBefore = $backupPathExistedBefore; profilePath = [string]$backupProviders.data.profilePath
                        profileSha256 = [string]$backupProviders.data.profileSha256; modsPath = [string]$backupProviders.data.modsPath
                        communityShadersPlugin = $communityShadersPlugin; transactionReceiptPath = [string]$backupSnapshot.data.receiptPath
                        beforeTreeSha256 = [string]$backupSnapshot.data.inventory.treeSha256
                        preparedTreeSha256 = [string]$preparedBackup.data.treeSha256; shadowReceipt = $shadowReceipt
                        workingTreeInventory = $null; restoreReceiptPath = $null; restoredTreeSha256 = $null
                    }
                    $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                    Write-WorkspaceJsonAtomic -Path ([string]$manifest.runtimeOutput.backupPlanPath) -Value $backupPlan
                    $manifest.runtimeOutput.state = 'ready'
                    $manifest.runtimeOutput.ownerMarkerSha256 = $runtimeMarkerHash
                    $manifest.runtimeOutput.shadowReceipt = $shadowReceipt
                    $manifest | Add-Member -NotePropertyName profileSnapshot -NotePropertyValue (Get-ProfileSnapshot -Path $profilePath) -Force
                    $selection = Set-MO2SelectedProfile -Config $config -TargetProfile $profileName -Operation 'select-created-task-workspace' -EvidenceRoot $selectionEvidence
                    $journal.phase = 'selection-applied-uncommitted'; $journal.selectedProfileTransaction = $selection; Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                    $manifest | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue $selection -Force
                    $manifest.status = 'ready'
                    $journal.phase = 'manifest-write-uncommitted'; Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                    Write-WorkspaceJsonAtomic -Path $manifestPath -Value $manifest
                    $journal.phase = 'committed'; $journal.committedUtc = [DateTime]::UtcNow.ToString('o'); $journal.selectedProfileTransaction = $selection
                    Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal
                }
                catch {
                    $failure = $_.Exception.Message; $rollbackErrors = @()
                    if ($selection) {
                        try { Restore-MO2SelectedProfileTransaction -Transaction $selection } catch { $rollbackErrors += "selected-profile: $($_.Exception.Message)" }
                    }
                    if ($profileCreated -and (Test-Path -LiteralPath $profilePath -PathType Container)) {
                        try { Assert-NoWorkspaceReparsePoint -Path $profilePath -Purpose 'Failed task profile'; Remove-Item -LiteralPath $profilePath -Recurse -Force } catch { $rollbackErrors += "profile: $($_.Exception.Message)" }
                    }
                    if ($runtimeMarkerCreated) {
                        try { $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath }
                        catch { $rollbackErrors += "overwrite-owner-marker: $($_.Exception.Message)" }
                    }
                    if ($backupSnapshotCreated) {
                        try {
                            $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                            $restoredBackup = & $transactionTool restore -CachePath $runtimeBackupPath -RelativeCachePath 'backup' -EvidenceDirectory $backupEvidenceDirectory -BlockingProcessNames $blockingProcessNames -NoExit -Confirm:$false | ConvertFrom-Json
                            if (-not $restoredBackup.ok) { throw ($restoredBackup.errors -join '; ') }
                            if (-not $backupPathExistedBefore) { Remove-WorkspaceCreatedOutputTree -Path $runtimeBackupPath -OverwritePath $runtimeOutputPath -Purpose 'Task-created backup tree' }
                        }
                        catch { $rollbackErrors += "overwrite-backup: $($_.Exception.Message)" }
                    }
                    elseif ($runtimeMarkerCreated -and -not $backupPathExistedBefore) {
                        try {
                            $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                            Remove-WorkspaceCreatedOutputTree -Path $runtimeBackupPath -OverwritePath $runtimeOutputPath -Purpose 'Task-created backup tree'
                        }
                        catch { $rollbackErrors += "overwrite-backup: $($_.Exception.Message)" }
                    }
                    if ($runtimeMarkerCreated -and -not $cachePathExistedBefore) {
                        try {
                            $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                            Remove-WorkspaceCreatedOutputTree -Path $runtimeCachePath -OverwritePath $runtimeOutputPath -Purpose 'Task-created ShaderCache tree'
                        }
                        catch { $rollbackErrors += "overwrite-shader-cache: $($_.Exception.Message)" }
                    }
                    if ($runtimeMarkerCreated -and (Test-Path -LiteralPath $runtimeMarkerPath -PathType Leaf)) {
                        try {
                            $null = Assert-WorkspaceOutputOwnerMarker -Path $runtimeMarkerPath -ExpectedSha256 $runtimeMarkerHash -WorkspaceId $workspaceId -OwnershipId $ownershipId -OverwritePath $runtimeOutputPath
                            Remove-Item -LiteralPath $runtimeMarkerPath -Force
                        }
                        catch { $rollbackErrors += "overwrite-owner-marker: $($_.Exception.Message)" }
                    }
                    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { try { Remove-Item -LiteralPath $manifestPath -Force } catch { $rollbackErrors += "manifest: $($_.Exception.Message)" } }
                    $journal.phase = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
                    $journal.rollback = [pscustomobject]@{ verified = $rollbackErrors.Count -eq 0; errors = $rollbackErrors; completedUtc = [DateTime]::UtcNow.ToString('o') }
                    try { Write-WorkspaceJsonAtomic -Path $creationJournalPath -Value $journal } catch { $rollbackErrors += "journal: $($_.Exception.Message)" }
                    if ($rollbackErrors.Count -gt 0) { throw "Workspace creation failed and rollback requires recovery. $failure Rollback: $($rollbackErrors -join '; ')" }
                    throw "Workspace creation failed; exact pre-state restored. $failure"
                }
            } | Out-Null
        }
        elseif ($WhatIfPreference) {
            $selectionEvidence = Join-Path (Split-Path -Parent $manifestPath) ($workspaceId + '-create-select')
            $manifest | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue (Set-MO2SelectedProfile -Config $config -TargetProfile $profileName -Operation 'select-created-task-workspace' -EvidenceRoot $selectionEvidence -WhatIf)
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-ready' }); data = $manifest }
    }
    elseif ($Command -eq 'complete-output') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile) -AllowOverwriteShaderCaches
        if ([string]$owned.data.runtimeOutput.mode -cne 'mo2-overwrite-output') { throw 'Workspace does not use the MO2 Overwrite output contract.' }
        $approved = $PSCmdlet.ShouldProcess([string]$owned.data.runtimeOutput.backupPath, 'preserve task output and restore the exact pre-task MO2 Overwrite backup')
        $completion = if ($approved) {
            Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                $current = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
                $markerExists = Test-Path -LiteralPath ([string]$current.data.runtimeOutput.ownerMarkerPath) -PathType Leaf
                if ($markerExists) {
                    $null = Assert-WorkspaceOutputOwnerMarker -Path ([string]$current.data.runtimeOutput.ownerMarkerPath) -ExpectedSha256 ([string]$current.data.runtimeOutput.ownerMarkerSha256) -WorkspaceId ([string]$current.data.workspaceId) -OwnershipId ([string]$current.data.ownershipId) -OverwritePath ([string]$current.data.runtimeOutput.overwritePath)
                }
                elseif (-not (Test-Path -LiteralPath ([string]$current.data.runtimeOutput.backupCompletionPath) -PathType Leaf)) {
                    throw 'The task-owned MO2 Overwrite marker is missing before output completion.'
                }
                $isolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile ([string]$current.data.profile) -Executable ([string]$current.data.runtimeOutput.executable) -AccessId $AccessId -AllowPreparedCacheGrowth
                if (-not $isolation.ok) { throw "Task runtime-output isolation changed before completion: $($isolation.errors -join '; ')" }
                $null = Get-WorkspaceCacheCompletionEvidence -Config $config -Workspace $current -RequireOwnerMarker:$markerExists
                Complete-WorkspaceBackupOutput -Config $config -Workspace $current
            }
        }
        else { Complete-WorkspaceBackupOutput -Config $config -Workspace $owned -WhatIf }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$completion.state; data = @{ workspaceId = $WorkspaceId; completion = $completion } }
    }
    elseif ($Command -eq 'resume') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
            $available = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId)
            throw "resume requires an exact -WorkspaceId. Available retained workspaces for this task: $((@($available.workspaceId) -join ', ') ?? '<none>')."
        }
        $workspace = Read-Workspace -Config $config -Id $WorkspaceId
        Assert-WorkspaceTaskOwner -Workspace $workspace -ResolvedTaskId $resolvedTaskId
        if ([string]$workspace.data.status -notin @('ready', 'retained')) { throw "Workspace '$WorkspaceId' is not resumable; status is '$($workspace.data.status)'." }
        $profilePath = [IO.Path]::GetFullPath([string]$workspace.data.profilePath)
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
            $available = @(Get-TaskWorkspaces -Config $config -ResolvedTaskId $resolvedTaskId | Where-Object profileExists)
            throw "Retained workspace '$WorkspaceId' has no profile directory at '$profilePath'. Valid retained workspaces: $((@($available.workspaceId) -join ', ') ?? '<none>'). Request a fresh workspace if none remain."
        }
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$workspace.data.profile) -AllowOverwriteShaderCaches
        $approved = $PSCmdlet.ShouldProcess($profilePath, "bind retained workspace to access '$AccessId' and select profile '$($workspace.data.profile)'")
        if ($approved) {
            $resume = Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                $current = Read-Workspace -Config $config -Id $WorkspaceId
                Assert-WorkspaceTaskOwner -Workspace $current -ResolvedTaskId $resolvedTaskId
                if ([string]$current.data.status -notin @('ready', 'retained')) { throw "Workspace '$WorkspaceId' ceased to be resumable before commit." }
                $operationId = [guid]::NewGuid().ToString('N')
                $journalPath = Get-WorkspaceOperationJournalPath -Config $config -Id $WorkspaceId -Operation 'resume' -OperationId $operationId
                $resumeEvidence = Join-Path (Split-Path -Parent $current.path) ($WorkspaceId + '-resume-' + $operationId)
                $manifestPreimage = [IO.File]::ReadAllBytes($current.path)
                $manifestPreimagePath = Join-Path (Get-WorkspaceControlRoot -Config $config) ($WorkspaceId + '.resume.' + $operationId + '.manifest-preimage.bin')
                Write-WorkspaceBytesAtomic -Path $manifestPreimagePath -Bytes $manifestPreimage
                $manifestPreimageSha256 = Get-WorkspaceBytesSha256 -Bytes $manifestPreimage
                if ((Get-FileHash -LiteralPath $manifestPreimagePath -Algorithm SHA256).Hash -cne $manifestPreimageSha256) { throw 'Workspace resume manifest preimage did not persist exactly.' }
                $selectedProfileJournalPath = Join-Path $resumeEvidence ('selected-profile-' + (Get-SafeName 'resume-retained-task-workspace') + '.selected-profile.journal.json')
                $journal = [pscustomobject][ordered]@{
                    contractVersion = '2.0.0'; operation = 'resume'; phase = 'prepared'; operationId = $operationId
                    workspaceId = $WorkspaceId; ownershipId = [string]$current.data.ownershipId; manifestPath = $current.path
                    manifestPreimagePath = $manifestPreimagePath; manifestPreimageSha256 = $manifestPreimageSha256
                    profilePath = [string]$current.data.profilePath; selectedProfileJournalPath = $selectedProfileJournalPath
                    targetAccessId = $AccessId; targetProfile = [string]$current.data.profile; preparedUtc = [DateTime]::UtcNow.ToString('o')
                    selectedProfileTransaction = $null; rollback = $null; committedUtc = $null
                }
                Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                $selection = $null
                try {
                    $selection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$current.data.profile) -Operation 'resume-retained-task-workspace' -EvidenceRoot $resumeEvidence
                    $journal.phase = 'selection-applied-uncommitted'; $journal.selectedProfileTransaction = $selection
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    $priorAccessId = [string]$current.data.accessId
                    $createdNames = @($current.data.createdMods | ForEach-Object { [string]$_.name })
                    $protectedNames = if ($current.data.PSObject.Properties['protectedSharedModNames']) { @($current.data.protectedSharedModNames) } else { @($current.data.initialModNames) }
                    $currentSharedNames = @(Get-ChildItem -LiteralPath $modsRoot -Directory -Force | Select-Object -ExpandProperty Name | Where-Object { $_ -notin $createdNames })
                    $current.data.accessId = $AccessId
                    $current.data.status = 'ready'
                    $current.data | Add-Member -NotePropertyName acquisitionDisposition -NotePropertyValue 'retained-resume' -Force
                    $current.data | Add-Member -NotePropertyName protectedSharedModNames -NotePropertyValue @($protectedNames + $currentSharedNames | Sort-Object -Unique) -Force
                    $current.data | Add-Member -NotePropertyName lastResumedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                    $history = if ($current.data.PSObject.Properties['leaseHistory']) { @($current.data.leaseHistory) } else { @() }
                    $current.data | Add-Member -NotePropertyName leaseHistory -NotePropertyValue (@($history) + ,([pscustomobject][ordered]@{ accessId = $AccessId; priorAccessId = $priorAccessId; acquiredForWorkspaceUtc = [DateTime]::UtcNow.ToString('o'); disposition = 'resumed' })) -Force
                    $current.data | Add-Member -NotePropertyName selectedProfileTransaction -NotePropertyValue $selection -Force
                    $journal.phase = 'manifest-write-uncommitted'
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    Write-WorkspaceJsonAtomic -Path $current.path -Value $current.data
                    $journal.phase = 'committed'; $journal.committedUtc = [DateTime]::UtcNow.ToString('o'); $journal.selectedProfileTransaction = $selection
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    return [pscustomobject]@{ workspace = $current; selection = $selection; journalPath = $journalPath }
                }
                catch {
                    $failure = $_.Exception.Message; $rollbackErrors = @()
                    try { Write-WorkspaceBytesAtomic -Path $current.path -Bytes $manifestPreimage } catch { $rollbackErrors += "manifest: $($_.Exception.Message)" }
                    if ($selection) {
                        try { Restore-MO2SelectedProfileTransaction -Transaction $selection } catch { $rollbackErrors += "selected-profile: $($_.Exception.Message)" }
                    }
                    $journal.phase = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
                    $journal.rollback = [pscustomobject]@{ verified = $rollbackErrors.Count -eq 0; errors = $rollbackErrors; completedUtc = [DateTime]::UtcNow.ToString('o') }
                    try { Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal } catch { $rollbackErrors += "journal: $($_.Exception.Message)" }
                    if ($rollbackErrors.Count -gt 0) { throw "Workspace resume failed and rollback requires recovery. $failure Rollback: $($rollbackErrors -join '; ')" }
                    throw "Workspace resume failed; exact manifest and MO2 selection were restored. $failure"
                }
            }
            $workspace = $resume.workspace
            $selection = $resume.selection
        }
        else {
            $selection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$workspace.data.profile) -Operation 'resume-retained-task-workspace' -EvidenceRoot (Join-Path (Split-Path -Parent $workspace.path) ($WorkspaceId + '-resume-dry-run')) -WhatIf
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-resumed' }); data = $workspace.data }
    }
    elseif ($Command -eq 'inspect') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$owned.data.status; data = $owned.data }
    }
    elseif ($Command -eq 'create-mod') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile) -AllowOverwriteShaderCaches
        if ([string]::IsNullOrWhiteSpace($ModName) -or $ModName -in @('.', '..') -or $ModName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $ModName.Contains([IO.Path]::DirectorySeparatorChar) -or $ModName.Contains([IO.Path]::AltDirectorySeparatorChar)) { throw 'create-mod requires one legal direct mod-directory name.' }
        $expectedMod = [IO.Path]::GetFullPath((Join-Path $modsRoot $ModName))
        if (-not [string]::IsNullOrWhiteSpace($ModDirectory) -and [IO.Path]::GetFullPath($ModDirectory) -cne $expectedMod) { throw "ModDirectory must be the exact task-owned MO2 mod path: $expectedMod" }
        $approved = $PSCmdlet.ShouldProcess($expectedMod, "create an empty mod owned by workspace '$WorkspaceId'")
        if ($approved) {
            Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                $current = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
                $protectedNames = if ($current.data.PSObject.Properties['protectedSharedModNames']) { @($current.data.protectedSharedModNames) } else { @($current.data.initialModNames) }
                if (@($protectedNames | Where-Object { $_ -ceq $ModName }).Count -gt 0) { throw "Refusing to create over the protected shared mod '$ModName'." }
                if (Test-Path -LiteralPath $expectedMod) { throw "Refusing to claim a pre-existing mod directory: $expectedMod" }
                $created = $false
                try {
                    New-Item -ItemType Directory -Path $expectedMod -ErrorAction Stop | Out-Null; $created = $true
                    $markerPath = Get-WorkspaceOwnerMarkerPath -ModPath $expectedMod
                    $marker = [pscustomobject][ordered]@{ contractVersion = '1.0.0'; workspaceId = $WorkspaceId; ownershipId = [string]$current.data.ownershipId; ownerTaskId = $resolvedTaskId; modName = $ModName; modPath = $expectedMod; createdUtc = [DateTime]::UtcNow.ToString('o') }
                    Write-WorkspaceJsonAtomic -Path $markerPath -Value $marker
                    $markerHash = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
                    $entry = [pscustomobject][ordered]@{ name = $ModName; path = $expectedMod; markerPath = $markerPath; markerSha256 = $markerHash; createdUtc = [string]$marker.createdUtc; registered = $false }
                    $current.data.createdMods = @($current.data.createdMods) + @($entry)
                    Write-WorkspaceJsonAtomic -Path $current.path -Value $current.data
                    $owned = $current
                }
                catch {
                    if ($created -and (Test-Path -LiteralPath $expectedMod -PathType Container)) { Assert-NoWorkspaceReparsePoint -Path $expectedMod -Purpose 'Failed task mod'; Remove-Item -LiteralPath $expectedMod -Recurse -Force }
                    throw
                }
            } | Out-Null
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'mod-created' }); data = @{ workspaceId = $WorkspaceId; modName = $ModName; modDirectory = $expectedMod } }
    }
    elseif ($Command -eq 'register-mod') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile) -AllowOverwriteShaderCaches
        if ([string]::IsNullOrWhiteSpace($ModName) -or [string]::IsNullOrWhiteSpace($ModDirectory)) { throw 'register-mod requires ModName and ModDirectory.' }
        $protectedNames = if ($owned.data.PSObject.Properties['protectedSharedModNames']) { @($owned.data.protectedSharedModNames) } else { @($owned.data.initialModNames) }
        if (@($protectedNames | Where-Object { $_ -ceq $ModName }).Count -gt 0) { throw "Refusing to register, edit, or claim the protected shared mod '$ModName'." }
        if (@($owned.data.registeredMods | Where-Object { $_.name -ceq $ModName }).Count -gt 0) { throw "Workspace already registered '$ModName'." }
        $resolvedMod = [IO.Path]::GetFullPath($ModDirectory)
        $expectedMod = [IO.Path]::GetFullPath((Join-Path $modsRoot $ModName))
        if ($resolvedMod -cne $expectedMod) { throw "ModDirectory must be the exact task-owned MO2 mod path: $expectedMod" }
        $createdMatches = @($owned.data.createdMods | Where-Object { [string]$_.name -ceq $ModName -and [string]$_.path -ceq $resolvedMod })
        if ($createdMatches.Count -ne 1) { throw "register-mod requires an exact mod first created by this workspace through create-mod: $ModName" }
        $ownershipMarker = Assert-WorkspaceOwnerMarker -Workspace $owned -ModName $ModName -ModPath $resolvedMod
        if ([string]$createdMatches[0].markerSha256 -cne [string]$ownershipMarker.sha256) { throw "Task mod ownership marker changed after create-mod: $ModName" }
        Assert-NoWorkspaceReparsePoint -Path $resolvedMod -Purpose 'Task-owned mod directory'
        $evidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-register-' + (Get-CollisionResistantSafeName $ModName))
        $profileTool = Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1'
        $winning = @($resolvedWinningPaths)
        $arguments = @{
            Command = $(if ($winning.Count -gt 0) { 'register-winning' } else { 'register' }); ProfilePath = (Join-Path ([string]$owned.data.profilePath) 'modlist.txt')
            ModName = $ModName; ModDirectory = $resolvedMod; Placement = $Placement
            EvidenceDirectory = $evidence; BlockingProcessNames = @('MO2WorkspaceImpossibleFixtureProcess')
            Confirm = $false; RegisterEnabled = [bool]$RegisterEnabled; WhatIf = [bool]$WhatIfPreference
        }
        if ($winning.Count -gt 0) { $arguments['ModsDirectory'] = $modsRoot; $arguments['WinningPaths'] = $winning }
        if (-not [string]::IsNullOrWhiteSpace($RelativeToMod)) { $arguments['RelativeToMod'] = $RelativeToMod }
        $registration = & $profileTool @arguments | ConvertFrom-Json
        if (-not $WhatIfPreference) {
            try {
                Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                    $current = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
                    $currentMarker = Assert-WorkspaceOwnerMarker -Workspace $current -ModName $ModName -ModPath $resolvedMod
                    if ([string]$currentMarker.sha256 -cne [string]$ownershipMarker.sha256) { throw 'Task mod ownership marker changed during registration.' }
                    if (@($current.data.registeredMods | Where-Object { [string]$_.name -ceq $ModName }).Count -ne 0) { throw 'Workspace manifest changed during registration.' }
                    $entry = [pscustomobject][ordered]@{ name = $ModName; path = $resolvedMod; ownershipMarkerPath = [string]$currentMarker.path; ownershipMarkerSha256 = [string]$currentMarker.sha256; registeredUtc = [DateTime]::UtcNow.ToString('o'); enabled = [bool]$registration.enabled; placement = $Placement; relativeToMod = $RelativeToMod; winningPaths = $winning; evidenceDirectory = $evidence }
                    $current.data.registeredMods = @($current.data.registeredMods) + @($entry)
                    foreach ($createdMod in @($current.data.createdMods)) { if ([string]$createdMod.name -ceq $ModName) { $createdMod.registered = $true; $createdMod | Add-Member -NotePropertyName registrationReceiptPath -NotePropertyValue ([string]$registration.receiptPath) -Force } }
                    $current.data.profileSnapshot = Get-ProfileSnapshot -Path ([string]$current.data.profilePath)
                    Write-WorkspaceJsonAtomic -Path $current.path -Value $current.data
                    $owned = $current
                } | Out-Null
            }
            catch {
                try { $null = & $profileTool restore -ProfilePath (Join-Path ([string]$owned.data.profilePath) 'modlist.txt') -ModName $ModName -EvidenceDirectory $evidence -BlockingProcessNames @('MO2WorkspaceImpossibleFixtureProcess') -Confirm:$false | ConvertFrom-Json }
                catch { throw "Workspace manifest registration failed and profile rollback also failed. $($_.Exception.Message)" }
                throw
            }
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'mod-registered' }); data = @{ workspaceId = $WorkspaceId; registration = $registration } }
    }
    elseif ($Command -eq 'ensure-mod-wins') {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.profile) -AllowOverwriteShaderCaches
        if ([string]::IsNullOrWhiteSpace($ModName)) { throw 'ensure-mod-wins requires ModName.' }
        $matches = @($owned.data.registeredMods | Where-Object { [string]$_.name -ceq $ModName })
        if ($matches.Count -ne 1) { throw "ensure-mod-wins requires exactly one task-owned registered mod named '$ModName'; found $($matches.Count)." }
        $winning = @($resolvedWinningPaths)
        if ($winning.Count -eq 0) { throw 'ensure-mod-wins requires at least one WinningPaths entry.' }
        $registered = $matches[0]
        $null = Assert-WorkspaceOwnerMarker -Workspace $owned -ModName $ModName -ModPath ([string]$registered.path)
        $evidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-winner-' + (Get-SafeName $ModName) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $profileTool = Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1'
        $winner = & $profileTool ensure-winner -ProfilePath (Join-Path ([string]$owned.data.profilePath) 'modlist.txt') -ModName $ModName -ModDirectory ([string]$registered.path) -ModsDirectory $modsRoot -WinningPaths $winning -EvidenceDirectory $evidence -BlockingProcessNames @('MO2WorkspaceImpossibleFixtureProcess') -Confirm:$false -WhatIf:$WhatIfPreference | ConvertFrom-Json
        if (-not $WhatIfPreference) {
            $registered.enabled = $true
            if ($registered.PSObject.Properties['winningPaths']) { $registered.winningPaths = $winning } else { $registered | Add-Member -NotePropertyName winningPaths -NotePropertyValue $winning }
            $history = if ($registered.PSObject.Properties['winnerEvidenceDirectories']) { @($registered.winnerEvidenceDirectories) } else { @() }
            if ($registered.PSObject.Properties['winnerEvidenceDirectories']) { $registered.winnerEvidenceDirectories = $history + @($evidence) } else { $registered | Add-Member -NotePropertyName winnerEvidenceDirectories -NotePropertyValue ($history + @($evidence)) }
            $owned.data.profileSnapshot = Get-ProfileSnapshot -Path ([string]$owned.data.profilePath)
            Write-WorkspaceJsonAtomic -Path $owned.path -Value $owned.data
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'winner-verified' }); data = @{ workspaceId = $WorkspaceId; winner = $winner; evidenceDirectory = $evidence } }
    }
    else {
        $resolvedTaskId = Resolve-TaskId -RequestedTaskId $TaskId -Required
        $owned = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
        $null = Assert-AccessAndClosed -Config $config -OwnedAccessId $AccessId -Profile ([string]$owned.data.sourceProfile) -AllowOverwriteShaderCaches
        $profilePath = [IO.Path]::GetFullPath([string]$owned.data.profilePath)
        if (-not $profilePath.StartsWith($profilesRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $profilePath -eq [IO.Path]::GetFullPath([string]$owned.data.sourceProfilePath)) { throw 'Workspace profile cleanup target escaped the configured profiles directory or matched the stable source.' }
        $cleanupMods = @()
        foreach ($mod in @($owned.data.createdMods)) {
            $modPath = [IO.Path]::GetFullPath([string]$mod.path)
            $expected = [IO.Path]::GetFullPath((Join-Path $modsRoot ([string]$mod.name)))
            if ($modPath -cne $expected -or -not $modPath.StartsWith($modsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Owned mod cleanup target is unsafe: $modPath" }
            $null = Assert-WorkspaceOwnerMarker -Workspace $owned -ModName ([string]$mod.name) -ModPath $modPath
            Assert-NoWorkspaceReparsePoint -Path $modPath -Purpose 'Task-owned mod cleanup target'
            $cleanupMods += $modPath
        }
        $runtimeIsolation = Assert-WorkspaceRuntimeOutputReadyForRetirement -Config $config -Workspace $owned -AccessId $AccessId
        $runtimeOutputPreservation = $null
        $releaseApproved = $PSCmdlet.ShouldProcess($profilePath, "select stable profile '$($owned.data.sourceProfile)' and remove exact task-owned profile")
        if ($releaseApproved) {
            $retirement = Invoke-WithWorkspaceTransactionLock -Config $config -Action {
                $current = Read-OwnedWorkspace -Config $config -Id $WorkspaceId -OwnedAccessId $AccessId -ResolvedTaskId $resolvedTaskId
                $currentProfilePath = [IO.Path]::GetFullPath([string]$current.data.profilePath)
                if ($currentProfilePath -cne $profilePath) { throw 'Workspace profile identity changed before retirement.' }
                Assert-NoWorkspaceReparsePoint -Path $currentProfilePath -Purpose 'Task profile retirement target'
                $currentRuntimeIsolation = Assert-WorkspaceRuntimeOutputReadyForRetirement -Config $config -Workspace $current -AccessId $AccessId
                $currentCleanupMods = @()
                if ($CleanupOwnedMods) {
                    foreach ($mod in @($current.data.createdMods)) {
                        $modPath = [IO.Path]::GetFullPath([string]$mod.path)
                        $null = Assert-WorkspaceOwnerMarker -Workspace $current -ModName ([string]$mod.name) -ModPath $modPath
                        Assert-NoWorkspaceReparsePoint -Path $modPath -Purpose 'Task-owned mod retirement target'
                        $currentCleanupMods += $modPath
                    }
                }
                $operationId = [guid]::NewGuid().ToString('N')
                $journalPath = Get-WorkspaceOperationJournalPath -Config $config -Id $WorkspaceId -Operation 'retire' -OperationId $operationId
                $profileQuarantine = Join-Path (Split-Path -Parent $currentProfilePath) ('.codex-retired-' + $WorkspaceId + '-' + $operationId)
                $releaseEvidence = Join-Path (Split-Path -Parent $current.path) ($WorkspaceId + '-retire-' + $operationId)
                $selectedProfileJournalPath = Join-Path $releaseEvidence ('selected-profile-' + (Get-SafeName 'select-stable-before-workspace-retirement') + '.selected-profile.journal.json')
                $modMoves = @()
                foreach ($modPath in $currentCleanupMods) {
                    $modMoves += [pscustomobject][ordered]@{ source = $modPath; quarantine = (Join-Path (Split-Path -Parent $modPath) ('.codex-retired-' + (Split-Path -Leaf $modPath) + '-' + $operationId)); moved = $false }
                }
                if ((Test-Path -LiteralPath $profileQuarantine) -or @($modMoves | Where-Object { Test-Path -LiteralPath $_.quarantine }).Count -gt 0) { throw 'A retirement quarantine target already exists.' }
                $manifestPreimage = [IO.File]::ReadAllBytes($current.path)
                $manifestPreimagePath = Join-Path (Get-WorkspaceControlRoot -Config $config) ($WorkspaceId + '.retire.' + $operationId + '.manifest-preimage.bin')
                Write-WorkspaceBytesAtomic -Path $manifestPreimagePath -Bytes $manifestPreimage
                $manifestPreimageSha256 = Get-WorkspaceBytesSha256 -Bytes $manifestPreimage
                if ((Get-FileHash -LiteralPath $manifestPreimagePath -Algorithm SHA256).Hash -cne $manifestPreimageSha256) { throw 'Workspace retirement manifest preimage did not persist exactly.' }
                $overwriteMarkerPath = $null; $overwriteMarkerPreimagePath = $null; $overwriteMarkerPreimageSha256 = $null
                if ([string]$current.data.runtimeOutput.mode -ceq 'mo2-overwrite-output' -and (Test-Path -LiteralPath ([string]$current.data.runtimeOutput.ownerMarkerPath) -PathType Leaf)) {
                    $overwriteMarkerPath = [string]$current.data.runtimeOutput.ownerMarkerPath
                    $overwriteMarkerPreimagePath = Join-Path (Get-WorkspaceControlRoot -Config $config) ($WorkspaceId + '.retire.' + $operationId + '.overwrite-owner-preimage.bin')
                    $overwriteMarkerBytes = [IO.File]::ReadAllBytes($overwriteMarkerPath)
                    Write-WorkspaceBytesAtomic -Path $overwriteMarkerPreimagePath -Bytes $overwriteMarkerBytes
                    $overwriteMarkerPreimageSha256 = Get-WorkspaceBytesSha256 -Bytes $overwriteMarkerBytes
                    if ((Get-FileHash -LiteralPath $overwriteMarkerPreimagePath -Algorithm SHA256).Hash -cne $overwriteMarkerPreimageSha256) { throw 'Workspace retirement Overwrite owner-marker preimage did not persist exactly.' }
                }
                $journal = [pscustomobject][ordered]@{
                    contractVersion = '2.0.0'; operation = 'retire'; phase = 'prepared'; operationId = $operationId
                    workspaceId = $WorkspaceId; ownershipId = [string]$current.data.ownershipId; manifestPath = $current.path
                    manifestPreimagePath = $manifestPreimagePath; manifestPreimageSha256 = $manifestPreimageSha256
                    profilePath = $currentProfilePath; profileQuarantine = $profileQuarantine; modMoves = $modMoves
                    cleanupOwnedMods = [bool]$CleanupOwnedMods; preparedUtc = [DateTime]::UtcNow.ToString('o')
                    selectedProfileJournalPath = $selectedProfileJournalPath; selectedProfileTransaction = $null
                    overwriteOwnerMarkerPath = $overwriteMarkerPath; overwriteMarkerPreimagePath = $overwriteMarkerPreimagePath
                    overwriteMarkerPreimageSha256 = $overwriteMarkerPreimageSha256
                    runtimeOutputPreservation = $null; rollback = $null; committedUtc = $null; cleanupPending = @()
                }
                Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                $profileSelection = $null; $profileMoved = $false; $overwriteMarkerBytes = $(if ($null -ne $overwriteMarkerPreimagePath) { [IO.File]::ReadAllBytes($overwriteMarkerPreimagePath) } else { $null }); $overwriteMarkerRemoved = $false
                try {
                    if ($null -ne $currentRuntimeIsolation) {
                        if ([string]$current.data.runtimeOutput.mode -ceq 'mo2-overwrite-output') {
                            $cacheCompletion = Get-Content -LiteralPath ([string]$current.data.runtimeOutput.cacheCompletionPath) -Raw | ConvertFrom-Json -Depth 40
                            $backupCompletion = Get-Content -LiteralPath ([string]$current.data.runtimeOutput.backupCompletionPath) -Raw | ConvertFrom-Json -Depth 40
                            $runtimeOutputPreservation = [pscustomobject][ordered]@{
                                mode = 'mo2-overwrite-output'; cache = $cacheCompletion.workingTree
                                backup = [pscustomobject]@{ inventory = $backupCompletion.workingTree; preservedPath = [string]$backupCompletion.preservedPath }
                                preserved = $true
                            }
                        }
                        else {
                            $runtimeOutputPreservation = Preserve-WorkspaceRuntimeOutput -Source ([string]$current.data.runtimeOutput.modPath) -EvidenceRoot $releaseEvidence -WorkspaceId $WorkspaceId
                        }
                        $journal.runtimeOutputPreservation = $runtimeOutputPreservation
                        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    }
                    $profileSelection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$current.data.sourceProfile) -Operation 'select-stable-before-workspace-retirement' -EvidenceRoot $releaseEvidence
                    $journal.phase = 'selection-applied-uncommitted'; $journal.selectedProfileTransaction = $profileSelection
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    $journal.phase = 'profile-move-uncommitted'
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    Move-Item -LiteralPath $currentProfilePath -Destination $profileQuarantine -ErrorAction Stop
                    $profileMoved = $true
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    foreach ($move in $modMoves) {
                        Move-Item -LiteralPath ([string]$move.source) -Destination ([string]$move.quarantine) -ErrorAction Stop
                        $move.moved = $true
                        Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    }
                    if ([string]$current.data.runtimeOutput.mode -ceq 'mo2-overwrite-output' -and (Test-Path -LiteralPath ([string]$current.data.runtimeOutput.ownerMarkerPath) -PathType Leaf)) {
                        $markerPath = [string]$current.data.runtimeOutput.ownerMarkerPath
                        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
                            (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash -cne [string]$current.data.runtimeOutput.ownerMarkerSha256) {
                            throw 'MO2 Overwrite owner marker changed before workspace retirement.'
                        }
                        $overwriteMarkerBytes = [IO.File]::ReadAllBytes($markerPath)
                        Remove-Item -LiteralPath $markerPath -Force
                        $overwriteMarkerRemoved = $true
                    }
                    $current.data.status = 'retired'
                    $current.data | Add-Member -NotePropertyName retiredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                    $current.data | Add-Member -NotePropertyName profileRemoved -NotePropertyValue $true -Force
                    $current.data | Add-Member -NotePropertyName ownedModsRemoved -NotePropertyValue ([bool]$CleanupOwnedMods) -Force
                    $current.data | Add-Member -NotePropertyName selectedProfileRelease -NotePropertyValue $profileSelection -Force
                    $current.data | Add-Member -NotePropertyName retirementJournalPath -NotePropertyValue $journalPath -Force
                    if ($null -ne $runtimeOutputPreservation) {
                        $current.data | Add-Member -NotePropertyName runtimeOutputPreservation -NotePropertyValue $runtimeOutputPreservation -Force
                    }
                    $journal.phase = 'manifest-write-uncommitted'
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                    Write-WorkspaceJsonAtomic -Path $current.path -Value $current.data
                    $journal.phase = 'committed'; $journal.committedUtc = [DateTime]::UtcNow.ToString('o'); $journal.selectedProfileTransaction = $profileSelection
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                }
                catch {
                    $failure = $_.Exception.Message; $rollbackErrors = @()
                    if ($overwriteMarkerRemoved) {
                        try { Write-WorkspaceBytesAtomic -Path ([string]$current.data.runtimeOutput.ownerMarkerPath) -Bytes $overwriteMarkerBytes }
                        catch { $rollbackErrors += "overwrite-owner-marker: $($_.Exception.Message)" }
                    }
                    foreach ($move in @($modMoves | Where-Object moved | Sort-Object source -Descending)) {
                        try { if (Test-Path -LiteralPath ([string]$move.quarantine)) { Move-Item -LiteralPath ([string]$move.quarantine) -Destination ([string]$move.source) -ErrorAction Stop } } catch { $rollbackErrors += "mod '$($move.source)': $($_.Exception.Message)" }
                    }
                    if ($profileMoved) { try { if (Test-Path -LiteralPath $profileQuarantine) { Move-Item -LiteralPath $profileQuarantine -Destination $currentProfilePath -ErrorAction Stop } } catch { $rollbackErrors += "profile: $($_.Exception.Message)" } }
                    try { Write-WorkspaceBytesAtomic -Path $current.path -Bytes $manifestPreimage } catch { $rollbackErrors += "manifest: $($_.Exception.Message)" }
                    if ($profileSelection) { try { Restore-MO2SelectedProfileTransaction -Transaction $profileSelection } catch { $rollbackErrors += "selected-profile: $($_.Exception.Message)" } }
                    $journal.phase = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'recovery-required' }
                    $journal.rollback = [pscustomobject]@{ verified = $rollbackErrors.Count -eq 0; errors = $rollbackErrors; completedUtc = [DateTime]::UtcNow.ToString('o') }
                    try { Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal } catch { $rollbackErrors += "journal: $($_.Exception.Message)" }
                    if ($rollbackErrors.Count -gt 0) { throw "Workspace retirement failed and rollback requires recovery. $failure Rollback: $($rollbackErrors -join '; ')" }
                    throw "Workspace retirement failed; exact profile, mods, manifest, and MO2 selection were restored. $failure"
                }
                $cleanupPending = @()
                $quarantines = @($profileQuarantine)
                foreach ($move in $modMoves) { $quarantines += [string]$move.quarantine }
                foreach ($quarantine in $quarantines) {
                    if (Test-Path -LiteralPath $quarantine -PathType Container) {
                        try { Assert-NoWorkspaceReparsePoint -Path $quarantine -Purpose 'Committed retirement quarantine'; Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction Stop }
                        catch { $cleanupPending += $quarantine }
                    }
                }
                if ($cleanupPending.Count -gt 0) {
                    $journal.cleanupPending = $cleanupPending
                    Write-WorkspaceJsonAtomic -Path $journalPath -Value $journal
                }
                return [pscustomobject]@{ workspace = $current; selection = $profileSelection; journalPath = $journalPath; cleanupPending = $cleanupPending; runtimeOutputPreservation = $runtimeOutputPreservation }
            }
            $owned = $retirement.workspace
            $profileSelection = $retirement.selection
            $runtimeOutputPreservation = $retirement.runtimeOutputPreservation
        }
        else {
            $dryRunEvidence = Join-Path (Split-Path -Parent $owned.path) ($WorkspaceId + '-retire-dry-run')
            if ($null -ne $runtimeIsolation) {
                if ([string]$owned.data.runtimeOutput.mode -ceq 'mo2-overwrite-output') {
                    $cacheCompletion = Get-Content -LiteralPath ([string]$owned.data.runtimeOutput.cacheCompletionPath) -Raw | ConvertFrom-Json -Depth 40
                    $backupCompletion = Get-Content -LiteralPath ([string]$owned.data.runtimeOutput.backupCompletionPath) -Raw | ConvertFrom-Json -Depth 40
                    $runtimeOutputPreservation = [pscustomobject][ordered]@{
                        mode = 'mo2-overwrite-output'; cache = $cacheCompletion.workingTree
                        backup = [pscustomobject]@{ inventory = $backupCompletion.workingTree; preservedPath = [string]$backupCompletion.preservedPath }
                        preserved = $true
                    }
                }
                else { $runtimeOutputPreservation = Preserve-WorkspaceRuntimeOutput -Source ([string]$owned.data.runtimeOutput.modPath) -EvidenceRoot $dryRunEvidence -WorkspaceId $WorkspaceId -WhatIf }
            }
            $profileSelection = Set-MO2SelectedProfile -Config $config -TargetProfile ([string]$owned.data.sourceProfile) -Operation 'select-stable-before-workspace-retirement' -EvidenceRoot $dryRunEvidence -WhatIf
        }
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = $(if ($WhatIfPreference) { 'dry-run' } else { 'workspace-retired' }); data = @{
            workspaceId = $WorkspaceId; profile = [string]$owned.data.profile; profilePath = $profilePath
            profileName = [string]$owned.data.profile; profileDirectory = $profilePath; modListPath = (Join-Path $profilePath 'modlist.txt')
            selectedProfileRelease = $profileSelection; wouldOrDidRemoveOwnedMods = [bool]$CleanupOwnedMods
            runtimeOutputPreservation = $runtimeOutputPreservation
            releaseAccessRequired = $true; manifestPath = $owned.path
            deprecatedCommand = $null
        } }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ ok = $false; command = $Command; state = 'tool-error'; errors = @($_.Exception.Message); data = @{} }
}

$result.data | Add-Member -NotePropertyName approval -NotePropertyValue (New-WorkspaceApprovalMetadata -Subcommand $Command) -Force
if ($null -ne $resolvedConfig) {
    $result.data | Add-Member -NotePropertyName configuration -NotePropertyValue ([pscustomobject][ordered]@{
        path = [string]$resolvedConfig.path
        source = [string]$resolvedConfig.source
        exists = [bool]$resolvedConfig.exists
        candidates = @($resolvedConfig.candidates)
    }) -Force
}
$jsonParameters = @{ InputObject = $result; Depth = 18 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
