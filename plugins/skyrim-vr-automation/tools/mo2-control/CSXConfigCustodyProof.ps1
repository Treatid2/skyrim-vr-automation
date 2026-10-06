# SPDX-License-Identifier: GPL-3.0-or-later

# Shared by workspace transactions and the durable session controller. These
# functions inspect only; recovery belongs to the closed-state workspace owner.
function Assert-CSXConfigSafePath([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path)
    $cursor = $resolved
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "CSX configuration path contains a reparse point: $cursor" }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $resolved
}

function Get-CSXConfigTree([string]$Path, [DateTime]$DeadlineUtc = [DateTime]::MaxValue) {
    $resolved = Assert-CSXConfigSafePath $Path
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    if ($DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    if ([DateTime]::UtcNow -ge $deadline) { throw 'CSX configuration inventory deadline expired before inspection.' }
    $files = [Collections.Generic.List[object]]::new()
    $dirs = [Collections.Generic.List[string]]::new()
    $bytes = 0L
    $queue = [Collections.Generic.Queue[object]]::new()
    $exists = Test-Path -LiteralPath $resolved -PathType Container
    if ((Test-Path -LiteralPath $resolved) -and -not $exists) { throw 'CSX configuration root is not a directory.' }
    if ($exists) { $queue.Enqueue(@{ path = $resolved; depth = 0 }) }
    while ($queue.Count) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'CSX configuration inventory exceeded its 30-second deadline.' }
        $current = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $current.path -Force) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'CSX configuration inventory exceeded its 30-second deadline.' }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "CSX configuration contains a reparse point: $($item.FullName)" }
            $relative = [IO.Path]::GetRelativePath($resolved, $item.FullName).Replace('/', '\')
            if ($item.PSIsContainer) {
                if ($dirs.Count -ge 128 -or $current.depth -ge 8) { throw 'CSX configuration directory/depth budget exceeded.' }
                $dirs.Add($relative); $queue.Enqueue(@{ path = $item.FullName; depth = $current.depth + 1 })
            }
            else {
                $bytes += [long]$item.Length
                if ($files.Count -ge 256 -or $bytes -gt 16777216) { throw 'CSX configuration file/byte budget exceeded (256 files, 16 MiB).' }
                $files.Add([pscustomobject]@{ relativePath = $relative; bytes = [long]$item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
            }
        }
    }
    $entries = @($files | Sort-Object relativePath)
    $canonical = (@($entries) | ForEach-Object { '{0}|{1}|{2}' -f $_.relativePath, $_.bytes, $_.sha256 }) -join "`n"
    return [pscustomobject]@{
        path = $resolved; exists = $exists; entries = $entries; directories = @($dirs | Sort-Object)
        files = $files.Count; bytes = $bytes
        treeSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
    }
}

function Read-CSXConfigCustodyPlan($Config, $Manifest) {
    if (-not $Manifest.PSObject.Properties['configCustody'] -or $null -eq $Manifest.configCustody) { return $null }
    $binding = $Manifest.configCustody
    if ([string]$binding.generation -notmatch '\A[0-9a-f]{32}\z' -or [string]$Manifest.workspaceId -notmatch '\A[a-z0-9-]+\z') { throw 'Malformed CSX configuration custody identity.' }
    $root = Join-Path (Join-Path ([string]$Config.storage.sessionStaging) 'workspaces') ($Manifest.workspaceId + '-config-' + $binding.generation)
    $planPath = Join-Path $root 'config-custody.plan.json'
    $null = Assert-CSXConfigSafePath $root
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$binding.planPath), [IO.Path]::GetFullPath($planPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'CSX configuration plan path escaped its exact workspace generation.' }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -Depth 40
    if ([string]$plan.schema -cne 'csx.config-custody.1' -or [string]$plan.workspaceId -cne [string]$Manifest.workspaceId -or
        [string]$plan.ownershipId -cne [string]$Manifest.ownershipId -or [string]$plan.ownerTaskId -cne [string]$Manifest.ownerTaskId -or
        [string]$plan.generation -cne [string]$binding.generation) { throw 'CSX configuration plan belongs to another workspace/generation.' }
    $expectedLive = Join-Path ([string]$Config.mo2.overwriteDirectory) 'SKSE\Plugins\CommunityShaders'
    foreach ($pair in @(@('livePath', $expectedLive), @('evidenceRoot', $root), @('workingPath', (Join-Path $root 'working')), @('snapshotRoot', (Join-Path $root 'snapshot')))) {
        if (-not [string]::Equals([IO.Path]::GetFullPath([string]$plan.($pair[0])), [IO.Path]::GetFullPath($pair[1]), [StringComparison]::OrdinalIgnoreCase)) { throw "CSX configuration '$($pair[0])' is not its exact derived path." }
        $null = Assert-CSXConfigSafePath $pair[1]
    }
    return [pscustomobject]@{ path = $planPath; data = $plan }
}

function Assert-CSXConfigCustodyIsolation($Config, $Manifest, [switch]$AllowGrowth) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $markerPath = Join-Path ([string]$Config.mo2.overwriteDirectory) '.codex-csx-config-owner.json'
    if (Test-Path -LiteralPath $markerPath) {
        $null = Assert-CSXConfigSafePath $markerPath
        $owner = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ([string]$owner.workspaceId -cne [string]$Manifest.workspaceId) { throw 'Shared CSX configuration belongs to a different workspace.' }
    }
    $record = Read-CSXConfigCustodyPlan $Config $Manifest
    if ($null -eq $record) { return }
    $plan = $record.data
    if ([string]$plan.phase -cne 'bound') { throw "CSX configuration custody is '$($plan.phase)', not bound; stage/bind or complete recovery before launch." }
    $null = Assert-CSXConfigSafePath $markerPath
    if ((Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash -cne [string]$plan.markerSha256) { throw 'CSX configuration ownership marker changed.' }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ([string]$marker.generation -cne [string]$plan.generation -or [string]$marker.workspaceId -cne [string]$Manifest.workspaceId) { throw 'Foreign CSX configuration owner.' }
    if ((Get-FileHash -LiteralPath (Join-Path ([string]$Manifest.profilePath) 'modlist.txt') -Algorithm SHA256).Hash -cne [string]$plan.profileSha256) { throw 'CSX configuration profile changed after custody preparation.' }
    $live = Get-CSXConfigTree $plan.livePath $deadline
    if (-not $AllowGrowth -and $live.treeSha256 -cne [string]$plan.preparedTreeSha256) { throw 'Prepared CSX configuration bytes changed before first launch.' }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $live.entries) { $null = $paths.Add([string]$entry.relativePath) }
    foreach ($provider in $plan.providers) {
        $current = Get-CSXConfigTree $provider.path $deadline
        if ($current.treeSha256 -cne [string]$provider.treeSha256 -or $current.exists -ne [bool]$provider.exists) { throw 'A lower CSX configuration provider changed while task custody was active.' }
        foreach ($entry in $provider.entries) {
            if (-not $paths.Contains([string]$entry.relativePath)) { throw "CSX configuration lacks a physical Overwrite shadow for '$($entry.relativePath)'." }
        }
    }
}
