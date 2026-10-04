# SPDX-License-Identifier: GPL-3.0-or-later
# Private, byte-preserving plans; writes belong to the profile transaction.
function Assert-InstalledModName([string]$Name, [string]$ModRoot) {
    if ([string]::IsNullOrWhiteSpace($ModRoot) -or [string]::IsNullOrWhiteSpace($Name) -or
        $Name -cne $Name.Trim() -or $Name -in @('.', '..') -or
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Name.Contains('/') -or $Name.Contains('\')) { throw 'Disabled inventory contains an unsafe mod name or missing mods root.' }
    $root = [IO.Path]::GetFullPath($ModRoot)
    $path = [IO.Path]::GetFullPath((Join-Path $root $Name))
    Assert-NoReparsePointPath -Path $root -Purpose 'Disabled inventory mods root'
    Assert-NoReparsePointPath -Path $path -Purpose 'Disabled inventory installed mod'
    if (-not (Test-Path -LiteralPath $path -PathType Container) -or
        -not [string]::Equals((Split-Path -Parent $path), $root.TrimEnd([IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw "Disabled inventory mod is not an installed direct child: $Name" }
}

function Get-DisabledInventoryNames([string]$Text) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($Text.TrimStart([char]0xFEFF) -split "`r?`n")) {
        if ($line -match '^[+-](.+)$' -and -not $names.Add($Matches[1])) { throw 'Disabled inventory refuses duplicate existing mod markers.' }
    }
    return ,$names
}

function Get-DisabledModlistReconciliation([byte[]]$Bytes, [string]$ModRoot, [string]$Operation, [string]$PinnedHash) {
    if ($Bytes.Length -gt 16777216) { throw 'Disabled inventory modlist exceeds 16 MiB.' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($Bytes)
    $originalNames = Get-DisabledInventoryNames $text
    $names = [Collections.Generic.List[string]]::new()
    $after = $Bytes
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    if ($Operation -eq 'recover-disabled-append') {
        if ($PinnedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Disabled suffix recovery requires an exact pinned profile hash.' }
        $pinned = $PinnedHash.ToUpperInvariant()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        while ((Get-BytesSha256 $after) -cne $pinned) {
            if ($names.Count -ge 64 -or [DateTime]::UtcNow -ge $deadline) { throw 'Disabled suffix recovery exceeds its 64-line/30-second budget.' }
            $end = $text.Length
            if ($end -gt 0 -and $text[$end - 1] -eq "`n") { $end--; if ($end -gt 0 -and $text[$end - 1] -eq "`r") { $end-- } }
            $start = if ($end -gt 0) { $text.LastIndexOf("`n", $end - 1) + 1 } else { 0 }
            $line = $text.Substring($start, $end - $start)
            if ($line -notmatch '^-(.+)$') { throw 'Drift is not a bounded disabled-only suffix of the exact pinned bytes.' }
            $name = $Matches[1]
            Assert-InstalledModName $name $ModRoot
            if (-not $seen.Add($name)) { throw 'Disabled suffix contains duplicate mod markers.' }
            $names.Insert(0, $name)
            $text = $text.Substring(0, $start)
            $after = $utf8.GetBytes($text)
        }
        $prefixNames = Get-DisabledInventoryNames $text
        foreach ($name in $names) { if ($prefixNames.Contains($name)) { throw 'Disabled suffix duplicates a marker from the original profile.' } }
    }
    elseif ($Operation -eq 'normalize-installed') {
        if ([string]::IsNullOrWhiteSpace($ModRoot)) { throw 'Disabled inventory requires ModsDirectory.' }
        Assert-NoReparsePointPath -Path $ModRoot -Purpose 'Disabled inventory mods root'
        $count = 0
        foreach ($path in [IO.Directory]::EnumerateDirectories([IO.Path]::GetFullPath($ModRoot))) {
            if (++$count -gt 20000 -or [DateTime]::UtcNow -ge $deadline) { throw 'Disabled inventory exceeds its 20000-directory/30-second budget.' }
            $name = [IO.Path]::GetFileName($path)
            Assert-InstalledModName $name $ModRoot
            if (-not $originalNames.Contains($name)) { $names.Add($name) }
        }
        foreach ($name in @($names | Sort-Object -CaseSensitive)) {
            $after = Add-ModLine -Bytes $after -Name $name -Enabled $false -LinePlacement End -RelativeName ''
            if ($after.Length -gt 16777216 -or [DateTime]::UtcNow -ge $deadline) { throw 'Disabled inventory exceeds its byte/time budget.' }
        }
    }
    else { throw 'Unknown disabled inventory operation.' }
    return [pscustomobject]@{ bytes = $after; sha256 = (Get-BytesSha256 $after); changed = (Get-BytesSha256 $after) -cne (Get-BytesSha256 $Bytes); names = @($names) }
}
