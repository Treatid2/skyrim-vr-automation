# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$script:MO2ControlContractVersion = '0.9.0'

function Resolve-MO2ControlPath {
    param([Parameter(Mandatory)][string]$Path)

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function ConvertFrom-MO2JsonText {
    param([Parameter(Mandatory)][string]$Json)

    $parameters = @{
        InputObject = $Json
        ErrorAction = 'Stop'
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $parameters['DateKind'] = 'String'
    }
    return ConvertFrom-Json @parameters
}

function Read-MO2ControlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $resolved = Resolve-MO2ControlPath $ConfigPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "MO2 control configuration does not exist: $resolved"
    }

    try {
        $config = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop)
    }
    catch {
        throw "MO2 control configuration is not valid JSON: $resolved. $($_.Exception.Message)"
    }

    foreach ($property in @('contractVersion', 'machine', 'mo2', 'defaults', 'storage', 'limits', 'session')) {
        if (-not $config.PSObject.Properties[$property]) {
            throw "MO2 control configuration is missing required property '$property': $resolved"
        }
    }

    return $config
}

function Read-MO2IniFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $sections = [ordered]@{}
    $sectionName = ''
    $sections[$sectionName] = [ordered]@{}

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $sectionName = $Matches[1]
            if (-not $sections.Contains($sectionName)) {
                $sections[$sectionName] = [ordered]@{}
            }
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $sections[$sectionName][$key] = $value
    }

    return $sections
}

function ConvertFrom-MO2ByteArrayValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -match '^@ByteArray\((.*)\)$') {
        return $Matches[1]
    }

    return $Value
}

function ConvertTo-MO2WindowsPath {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $path = $Value -replace '/', '\'
    # MO2's INI serializer may retain escaped backslashes. They are accepted by
    # Windows, but canonical paths make comparisons and diagnostics reliable.
    return ($path -replace '\\{2,}', '\')
}

function Find-MO2IniValue {
    param(
        [Parameter(Mandatory)]$Ini,
        [Parameter(Mandatory)][string]$Key
    )

    foreach ($section in $Ini.Keys) {
        if ($Ini[$section].Contains($Key)) {
            return $Ini[$section][$Key]
        }
    }

    return $null
}

function Get-MO2ExecutableCapabilities {
    param([AllowNull()][string]$Binary)

    if ([string]::IsNullOrWhiteSpace($Binary)) { return @() }
    $leaf = [IO.Path]::GetFileName($Binary)
    $capabilities = [Collections.Generic.List[string]]::new()
    if ($leaf -match '(?i)^skse(?:vr)?_loader\.exe$') { $capabilities.Add('skse-loader') }
    if ($leaf -ieq 'SkyrimVR.exe') { $capabilities.Add('plain-game') }
    return @($capabilities)
}

function Get-MO2RegisteredExecutables {
    param([Parameter(Mandatory)]$Ini)

    if (-not $Ini.Contains('customExecutables')) {
        return @()
    }

    $groups = [ordered]@{}
    foreach ($key in $Ini['customExecutables'].Keys) {
        if ($key -notmatch '^(\d+)\\(.+)$') {
            continue
        }

        # OrderedDictionary treats an integer key as a positional index. MO2's
        # executable group number is an identifier, so retain it as a string.
        $index = [string]$Matches[1]
        $field = $Matches[2]
        if (-not $groups.Contains($index)) {
            $groups[$index] = [ordered]@{}
        }
        $groups[$index][$field] = $Ini['customExecutables'][$key]
    }

    $records = @()
    foreach ($index in ($groups.Keys | Sort-Object)) {
        $entry = $groups[$index]
        $binary = if ($entry.Contains('binary')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['binary']) } else { $null }
        $records += [pscustomobject][ordered]@{
            index = [int]$index
            title = if ($entry.Contains('title')) { ConvertFrom-MO2ByteArrayValue $entry['title'] } else { $null }
            binary = $binary
            arguments = if ($entry.Contains('arguments')) { ConvertFrom-MO2ByteArrayValue $entry['arguments'] } else { $null }
            workingDirectory = if ($entry.Contains('workingDirectory')) { ConvertTo-MO2WindowsPath (ConvertFrom-MO2ByteArrayValue $entry['workingDirectory']) } else { $null }
            capabilities = @(Get-MO2ExecutableCapabilities -Binary $binary)
        }
    }

    return @($records)
}

function Get-MO2ExecutableModOwner {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$Binary
    )

    $modsRoot = if ($Config.mo2.PSObject.Properties['modsDirectory']) {
        Resolve-MO2ControlPath ([string]$Config.mo2.modsDirectory)
    }
    else {
        Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.root)) 'mods'
    }
    $resolvedModsRoot = [IO.Path]::GetFullPath($modsRoot).TrimEnd('\')
    $resolvedBinary = [IO.Path]::GetFullPath($Binary)
    $prefix = $resolvedModsRoot + '\'
    if (-not $resolvedBinary.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{ managedByMod = $false; binary = $resolvedBinary; modsRoot = $resolvedModsRoot }
    }

    $relative = [IO.Path]::GetRelativePath($resolvedModsRoot, $resolvedBinary)
    $parts = @($relative -split '[\\/]', 2)
    $modName = $parts[0]
    $profilePath = Join-Path (Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) $Profile) 'modlist.txt'
    $ownerMarkers = @()
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $profilePath) {
            $lineNumber++
            if ($line -notmatch '^(?<marker>[+-])(?<name>.+)$') { continue }
            if ($Matches.name.TrimEnd("`r") -ceq $modName) {
                $ownerMarkers += [pscustomobject][ordered]@{ lineNumber = $lineNumber; marker = $Matches.marker; modName = $modName }
            }
        }
    }
    $state = if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        'profile-missing'
    }
    elseif ($ownerMarkers.Count -eq 0) {
        'missing'
    }
    elseif ($ownerMarkers.Count -gt 1) {
        'ambiguous'
    }
    elseif ($ownerMarkers[0].marker -eq '+') {
        'enabled'
    }
    else {
        'disabled'
    }
    return [pscustomobject][ordered]@{
        managedByMod = $true
        binary = $resolvedBinary
        modsRoot = $resolvedModsRoot
        relativeBinaryPath = $relative
        modName = $modName
        profilePath = $profilePath
        state = $state
        matches = @($ownerMarkers)
    }
}

function Get-MO2ProcessRecords {
    param([string[]]$Names)

    $records = @()
    foreach ($name in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                path = $(try { [IO.Path]::GetFullPath($process.Path) } catch { $null })
                startTime = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                cpuSeconds = $(try { [math]::Round($process.CPU, 3) } catch { $null })
                workingSetBytes = $(try { [long]$process.WorkingSet64 } catch { $null })
            }
        }
    }

    return @($records | Sort-Object name, id)
}

function Get-MO2BoundedDirectoryStats {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaximumFiles
    )

    $result = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Container
        fileCount = 0
        bytes = [long]0
        truncated = $false
        errors = @()
    }

    if (-not $result.exists) {
        return [pscustomobject]$result
    }

    try {
        $enumerator = [System.IO.Directory]::EnumerateFiles(
            $Path,
            '*',
            [System.IO.SearchOption]::AllDirectories
        ).GetEnumerator()

        try {
            while ($enumerator.MoveNext()) {
                if ($result.fileCount -ge $MaximumFiles) {
                    $result.truncated = $true
                    break
                }

                $result.fileCount++
                try {
                    $result.bytes += [System.IO.FileInfo]::new($enumerator.Current).Length
                }
                catch {
                    $result.errors += "Could not stat '$($enumerator.Current)': $($_.Exception.Message)"
                }
            }
        }
        finally {
            if ($enumerator -is [System.IDisposable]) {
                $enumerator.Dispose()
            }
        }
    }
    catch {
        $result.errors += $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Get-MO2OverwriteShaderCacheRecords {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$MaximumFiles
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    $matches = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction Stop | Where-Object { $_.Name -match '^(?i:ShaderCache)(?:[.]|$)' } | Sort-Object FullName)
    $roots = @()
    foreach ($match in $matches) {
        if (@($roots | Where-Object { $match.FullName.StartsWith($_.path + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        $stats = Get-MO2BoundedDirectoryStats -Path $match.FullName -MaximumFiles $MaximumFiles
        $role = switch -Regex ($match.Name) {
            '^(?i:ShaderCache)$' { 'active'; break }
            '^(?i:ShaderCache[.]Previous)$' { 'rollback'; break }
            '^(?i:ShaderCache[.]Swap)$' { 'temporary-swap'; break }
            default { 'legacy-other' }
        }
        $ageHours = [math]::Round(([DateTime]::UtcNow - $match.LastWriteTimeUtc).TotalHours, 2)
        $roots += [pscustomobject][ordered]@{
            name = $match.Name; role = $role; relativePath = [IO.Path]::GetRelativePath($Path, $match.FullName)
            path = $match.FullName; fileCount = $stats.fileCount; bytes = $stats.bytes
            truncated = $stats.truncated; errors = @($stats.errors); lastWriteTimeUtc = $match.LastWriteTimeUtc.ToString('o')
            ageHours = $ageHours; stale = $role -eq 'temporary-swap' -and $ageHours -ge 1
        }
    }
    return @($roots)
}

function Get-MO2JsonRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Archived = $false
    )

    $record = [ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        archived = $Archived
        valid = $false
        bytes = $null
        lastWriteTimeUtc = $null
        error = $null
    }

    if (-not $record.exists) {
        $record.error = 'File does not exist.'
        return [pscustomobject]$record
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $record.bytes = [long]$item.Length
    $record.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')

    if ($Archived) {
        $record.valid = $null
        return [pscustomobject]$record
    }

    try {
        $null = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $record.valid = $true
    }
    catch {
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function Get-MO2RootBuilderRecords {
    param([Parameter(Mandatory)]$Config)

    $active = @()
    $archived = @()

    foreach ($pathValue in @($Config.mo2.rootBuilderDefinitions)) {
        $path = Resolve-MO2ControlPath ([string]$pathValue)
        $active += Get-MO2JsonRecord -Path $path
    }

    $dataRoot = Resolve-MO2ControlPath ([string]$Config.mo2.rootBuilderDataDirectory)
    if (Test-Path -LiteralPath $dataRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '(?i)\.corrupt-') {
                $archived += Get-MO2JsonRecord -Path $file.FullName -Archived $true
            }
            elseif ($file.Name -in @('BuildData.json', 'GameData.json', 'VersionManifest.json')) {
                $active += Get-MO2JsonRecord -Path $file.FullName
            }
        }
    }

    return [pscustomobject][ordered]@{
        dataDirectory = $dataRoot
        active = @($active)
        archived = @($archived)
    }
}

function Get-MO2StorageRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $qualifier = Split-Path -Qualifier $resolved
    $driveRoot = if ($qualifier) { "$qualifier\" } else { $null }

    return [pscustomobject][ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Container
        drive = $qualifier
        driveAvailable = if ($driveRoot) { Test-Path -LiteralPath $driveRoot -PathType Container } else { $false }
    }
}

function Get-MO2SessionLockRecord {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-MO2ControlPath $Path
    $record = [ordered]@{
        path = $resolved
        exists = Test-Path -LiteralPath $resolved -PathType Leaf
        valid = $null
        ownerPid = $null
        ownerRunning = $false
        ownerIdentityMatched = $false
        sessionId = $null
        accessId = $null
        leaseId = $null
        acquisitionMode = $null
        status = $null
        data = $null
        error = $null
    }

    if (-not $record.exists) {
        return [pscustomobject]$record
    }

    try {
        $data = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop)
        $record.valid = $true
        $record.data = $data
        if ($data.PSObject.Properties['ownerPid']) {
            $record.ownerPid = [int]$data.ownerPid
            $ownerProcess = Get-Process -Id $record.ownerPid -ErrorAction SilentlyContinue
            if ($null -ne $ownerProcess) {
                $record.ownerRunning = $true
                if ($data.PSObject.Properties['processStartTime'] -and -not [string]::IsNullOrWhiteSpace([string]$data.processStartTime)) {
                    try {
                        $expectedStart = [DateTimeOffset]::Parse([string]$data.processStartTime, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
                        $actualStart = $ownerProcess.StartTime.ToUniversalTime()
                        $record.ownerIdentityMatched = [math]::Abs(($actualStart - $expectedStart).TotalMilliseconds) -lt 1.0
                        $record.ownerRunning = $record.ownerIdentityMatched
                    }
                    catch {
                        $record.ownerIdentityMatched = $false
                        $record.ownerRunning = $false
                    }
                }
                else {
                    # Compatibility for pre-identity locks. New session owners always persist start time.
                    $record.ownerIdentityMatched = $true
                }
            }
        }
        if ($data.PSObject.Properties['sessionId']) {
            $record.sessionId = [string]$data.sessionId
        }
        if ($data.PSObject.Properties['accessId']) {
            $record.accessId = [string]$data.accessId
        }
        if ($data.PSObject.Properties['leaseId']) {
            $record.leaseId = [string]$data.leaseId
        }
        if ($data.PSObject.Properties['acquisitionMode']) {
            $record.acquisitionMode = [string]$data.acquisitionMode
        }
        if ($data.PSObject.Properties['status']) {
            $record.status = [string]$data.status
        }
    }
    catch {
        $record.valid = $false
        $record.error = $_.Exception.Message
    }

    return [pscustomobject]$record
}

function New-MO2Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'fail', 'info')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        $Details = $null
    )

    return [pscustomobject][ordered]@{
        name = $Name
        status = $Status
        message = $Message
        details = $Details
    }
}

function Get-MO2InspectionData {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$RequestedProfile,
        [string]$RequestedExecutable
    )

    $mo2Root = Resolve-MO2ControlPath ([string]$Config.mo2.root)
    $mo2Exe = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    $mo2Ini = Resolve-MO2ControlPath ([string]$Config.mo2.ini)
    $profilesRoot = Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)
    $overwriteRoot = Resolve-MO2ControlPath ([string]$Config.mo2.overwriteDirectory)

    $ini = if (Test-Path -LiteralPath $mo2Ini -PathType Leaf) { Read-MO2IniFile -Path $mo2Ini } else { [ordered]@{} }
    $selectedProfile = if ($ini.Count -gt 0) { ConvertFrom-MO2ByteArrayValue (Find-MO2IniValue -Ini $ini -Key 'selected_profile') } else { $null }
    $profiles = if (Test-Path -LiteralPath $profilesRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction Stop | Sort-Object Name | ForEach-Object Name)
    }
    else {
        @()
    }
    $executables = if ($ini.Count -gt 0) { @(Get-MO2RegisteredExecutables -Ini $ini) } else { @() }

    $profile = if ([string]::IsNullOrWhiteSpace($RequestedProfile)) { [string]$Config.defaults.profile } else { $RequestedProfile }
    $executable = if ([string]::IsNullOrWhiteSpace($RequestedExecutable)) { [string]$Config.defaults.executable } else { $RequestedExecutable }

    $mo2Processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
    $gameProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.gameProcessNames))
    $runtimeProcesses = @(Get-MO2ProcessRecords -Names @($Config.mo2.runtimeProcessNames))

    $overwrite = Get-MO2BoundedDirectoryStats -Path $overwriteRoot -MaximumFiles ([int]$Config.limits.maxEnumeratedFiles)
    $overwrite | Add-Member -NotePropertyName shaderCaches -NotePropertyValue @(Get-MO2OverwriteShaderCacheRecords -Path $overwriteRoot -MaximumFiles ([int]$Config.limits.maxEnumeratedFiles))

    return [pscustomobject][ordered]@{
        machine = [string]$Config.machine
        config = [pscustomobject][ordered]@{
            inputContractVersion = [string]$Config.contractVersion
            mo2Root = $mo2Root
            mo2Executable = $mo2Exe
            mo2Ini = $mo2Ini
            profilesDirectory = $profilesRoot
        }
        requested = [pscustomobject][ordered]@{
            profile = $profile
            executable = $executable
        }
        selectedProfile = $selectedProfile
        profiles = @($profiles)
        executables = @($executables)
        processes = [pscustomobject][ordered]@{
            mo2 = @($mo2Processes)
            game = @($gameProcesses)
            runtime = @($runtimeProcesses)
        }
        overwrite = $overwrite
        rootBuilder = Get-MO2RootBuilderRecords -Config $Config
        storage = [pscustomobject][ordered]@{
            staging = Get-MO2StorageRecord -Path ([string]$Config.storage.sessionStaging)
            archive = Get-MO2StorageRecord -Path ([string]$Config.storage.archive)
        }
        sessionLock = Get-MO2SessionLockRecord -Path ([string]$Config.session.lockFile)
    }
}

function ConvertTo-MO2Result {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Checks,
        [Parameter(Mandatory)]$Data,
        [string]$PreferredState
    )

    $errors = @($Checks | Where-Object status -eq 'fail' | ForEach-Object message)
    $warnings = @($Checks | Where-Object status -eq 'warn' | ForEach-Object message)
    $ok = $errors.Count -eq 0

    if (-not [string]::IsNullOrWhiteSpace($PreferredState)) {
        $state = $PreferredState
    }
    elseif (-not $ok) {
        $state = 'blocked'
    }
    elseif ($Data.processes.game.Count -gt 0) {
        $state = 'game-running'
    }
    elseif ($Data.processes.mo2.Count -gt 0) {
        $state = 'mo2-running'
    }
    elseif ($warnings.Count -gt 0) {
        $state = 'degraded'
    }
    else {
        $state = 'ready'
    }

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = $Command
        ok = $ok
        state = $state
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @($Checks)
        warnings = @($warnings)
        errors = @($errors)
        data = $Data
    }
}

function Invoke-MO2Inspect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()

    $checks += New-MO2Check -Name 'mo2-root' -Status $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Root -PathType Container) { 'MO2 root exists.' } else { "MO2 root does not exist: $($data.config.mo2Root)" })
    $checks += New-MO2Check -Name 'mo2-executable' -Status $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Executable -PathType Leaf) { 'MO2 executable exists.' } else { "MO2 executable does not exist: $($data.config.mo2Executable)" })
    $checks += New-MO2Check -Name 'mo2-ini' -Status $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'pass' } else { 'fail' }) -Message $(if (Test-Path -LiteralPath $data.config.mo2Ini -PathType Leaf) { 'MO2 INI exists and was read.' } else { "MO2 INI does not exist: $($data.config.mo2Ini)" })
    $checks += New-MO2Check -Name 'process-state' -Status 'info' -Message "MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count), runtime=$($data.processes.runtime.Count)."
    $overwriteNeedsAttention = (
        $data.overwrite.errors.Count -gt 0 -or
        $data.overwrite.shaderCaches.Count -gt 0 -or
        $data.overwrite.truncated -or
        $data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or
        $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes
    )
    $checks += New-MO2Check -Name 'overwrite-scan' -Status $(if ($overwriteNeedsAttention) { 'warn' } else { 'pass' }) -Message $(
        if ($data.overwrite.errors.Count -gt 0) { 'Overwrite inspection completed with filesystem errors.' }
        elseif ($data.overwrite.shaderCaches.Count -gt 0) { "Overwrite contains $($data.overwrite.shaderCaches.Count) forbidden ShaderCache tree(s); run workspace prepare-source before testing." }
        elseif ($data.overwrite.truncated) { "Overwrite inspection stopped at the configured limit of $($Config.limits.maxEnumeratedFiles) files." }
        elseif ($overwriteNeedsAttention) { "Overwrite needs attention: $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
        else { "Overwrite contains $($data.overwrite.fileCount) files using $($data.overwrite.bytes) bytes." }
    ) -Details $data.overwrite

    return ConvertTo-MO2Result -Config $Config -Command 'inspect' -Checks $checks -Data $data
}

function Invoke-MO2Validate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [switch]$RequireSKSE,
        [switch]$RequireClosed,
        [string]$OwnedSessionId,
        [string]$OwnedAccessId
    )

    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $Profile -RequestedExecutable $Executable
    $checks = @()

    foreach ($pathCheck in @(
        @{ Name = 'mo2-root'; Path = $data.config.mo2Root; Type = 'Container' },
        @{ Name = 'mo2-executable'; Path = $data.config.mo2Executable; Type = 'Leaf' },
        @{ Name = 'mo2-ini'; Path = $data.config.mo2Ini; Type = 'Leaf' },
        @{ Name = 'profiles-directory'; Path = $data.config.profilesDirectory; Type = 'Container' }
    )) {
        $exists = Test-Path -LiteralPath $pathCheck.Path -PathType $pathCheck.Type
        $checks += New-MO2Check -Name $pathCheck.Name -Status $(if ($exists) { 'pass' } else { 'fail' }) -Message $(if ($exists) { "$($pathCheck.Name) exists." } else { "$($pathCheck.Name) is missing: $($pathCheck.Path)" })
    }

    $profileExists = $data.profiles -contains $data.requested.profile
    $checks += New-MO2Check -Name 'requested-profile' -Status $(if ($profileExists) { 'pass' } else { 'fail' }) -Message $(if ($profileExists) { "Exact profile exists: $($data.requested.profile)" } else { "Exact profile does not exist: $($data.requested.profile). No fallback is permitted." }) -Details @{ availableProfiles = $data.profiles }

    if ($profileExists -and $data.selectedProfile -ne $data.requested.profile) {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'warn' -Message "MO2 currently selects '$($data.selectedProfile)', not requested '$($data.requested.profile)'."
    }
    else {
        $checks += New-MO2Check -Name 'selected-profile' -Status 'pass' -Message "MO2 selected profile matches the request: $($data.requested.profile)"
    }

    $registered = @($data.executables | Where-Object title -eq $data.requested.executable)
    if ($registered.Count -eq 1) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'pass' -Message "Registered executable exists exactly once: $($data.requested.executable)" -Details $registered[0]
        $binaryExists = -not [string]::IsNullOrWhiteSpace($registered[0].binary) -and (Test-Path -LiteralPath $registered[0].binary -PathType Leaf)
        $checks += New-MO2Check -Name 'registered-binary' -Status $(if ($binaryExists) { 'pass' } else { 'fail' }) -Message $(if ($binaryExists) { "Registered binary exists: $($registered[0].binary)" } else { "Registered binary is missing: $($registered[0].binary)" })
        if ($binaryExists) {
            if ($RequireSKSE) {
                $hasSKSE = @($registered[0].capabilities) -contains 'skse-loader'
                $checks += New-MO2Check -Name 'required-skse-loader' -Status $(if ($hasSKSE) { 'pass' } else { 'fail' }) -Message $(
                    if ($hasSKSE) { "Registered executable is an SKSE loader: $($registered[0].binary)" }
                    else { "DevBench/SKSE-required workflow refused non-SKSE executable: $($registered[0].binary)" }
                ) -Details @{ requiredCapability = 'skse-loader'; observedCapabilities = @($registered[0].capabilities) }
            }
            $owner = Get-MO2ExecutableModOwner -Config $Config -Profile $data.requested.profile -Binary $registered[0].binary
            if ($owner.managedByMod) {
                $ownerEnabled = $owner.state -eq 'enabled'
                $checks += New-MO2Check -Name 'registered-binary-owner-mod' -Status $(if ($ownerEnabled) { 'pass' } else { 'fail' }) -Message $(
                    if ($ownerEnabled) { "Registered binary owner mod is enabled in the exact profile: $($owner.modName)" }
                    else { "Registered binary owner mod '$($owner.modName)' is $($owner.state) in profile '$($data.requested.profile)'." }
                ) -Details $owner
            }
            else {
                $checks += New-MO2Check -Name 'registered-binary-owner-mod' -Status 'info' -Message 'Registered binary is outside the MO2 mods directory; no profile marker applies.' -Details $owner
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($registered[0].workingDirectory)) {
            $workingExists = Test-Path -LiteralPath $registered[0].workingDirectory -PathType Container
            $checks += New-MO2Check -Name 'registered-working-directory' -Status $(if ($workingExists) { 'pass' } else { 'fail' }) -Message $(if ($workingExists) { "Registered working directory exists: $($registered[0].workingDirectory)" } else { "Registered working directory is missing: $($registered[0].workingDirectory)" })
        }
    }
    elseif ($registered.Count -eq 0) {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable does not exist: $($data.requested.executable)" -Details @{ availableExecutables = @($data.executables.title) }
    }
    else {
        $checks += New-MO2Check -Name 'registered-executable' -Status 'fail' -Message "Registered executable is ambiguous ($($registered.Count) matches): $($data.requested.executable)"
    }

    $invalidJson = @($data.rootBuilder.active | Where-Object { -not $_.exists -or $_.valid -ne $true })
    $checks += New-MO2Check -Name 'rootbuilder-json' -Status $(if ($invalidJson.Count -eq 0) { 'pass' } else { 'fail' }) -Message $(if ($invalidJson.Count -eq 0) { "All $($data.rootBuilder.active.Count) active RootBuilder JSON files parse successfully." } else { "$($invalidJson.Count) active RootBuilder JSON file(s) are missing or invalid." }) -Details $invalidJson
    if ($data.rootBuilder.archived.Count -gt 0) {
        $checks += New-MO2Check -Name 'rootbuilder-archives' -Status 'warn' -Message "$($data.rootBuilder.archived.Count) quarantined RootBuilder JSON artifact(s) are retained as diagnostic evidence; they are not active state." -Details $data.rootBuilder.archived
    }

    if (-not $data.overwrite.exists) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite directory does not exist: $($data.overwrite.path)"
    }
    elseif ($data.overwrite.errors.Count -gt 0) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message 'MO2 overwrite inspection encountered filesystem errors.' -Details $data.overwrite
    }
    elseif ($data.overwrite.shaderCaches.Count -gt 0) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite contains forbidden ShaderCache trees. Move them into an enabled stable-profile mod with workspace prepare-source before launch: $($data.overwrite.shaderCaches.relativePath -join ', ')." -Details $data.overwrite
    }
    elseif ($data.overwrite.truncated -or $data.overwrite.fileCount -ge [int]$Config.limits.overwriteBlockFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteBlockBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'fail' -Message "MO2 overwrite exceeds or cannot be proven below the automation safety limit: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes), truncated=$($data.overwrite.truncated)." -Details $data.overwrite
    }
    elseif ($data.overwrite.fileCount -ge [int]$Config.limits.overwriteWarningFiles -or $data.overwrite.bytes -ge [long]$Config.limits.overwriteWarningBytes) {
        $checks += New-MO2Check -Name 'overwrite' -Status 'warn' -Message "MO2 overwrite is above the warning threshold: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }
    else {
        $checks += New-MO2Check -Name 'overwrite' -Status 'pass' -Message "MO2 overwrite is below automation thresholds: files=$($data.overwrite.fileCount), bytes=$($data.overwrite.bytes)." -Details $data.overwrite
    }

    foreach ($storageName in @('staging', 'archive')) {
        $record = $data.storage.$storageName
        if ($record.exists) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'pass' -Message "Storage directory exists: $($record.path)"
        }
        elseif ($record.driveAvailable) {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'warn' -Message "Storage drive is available but the directory has not been created: $($record.path)"
        }
        else {
            $checks += New-MO2Check -Name "storage-$storageName" -Status 'fail' -Message "Storage drive is unavailable: $($record.path)"
        }
    }

    if ($data.sessionLock.exists -and $data.sessionLock.valid -and -not [string]::IsNullOrWhiteSpace($OwnedSessionId) -and $data.sessionLock.sessionId -eq $OwnedSessionId) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message "The requested control session owns the lock: $OwnedSessionId" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists -and $data.sessionLock.valid -and -not [string]::IsNullOrWhiteSpace($OwnedAccessId) -and $data.sessionLock.accessId -eq $OwnedAccessId) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message "The requested access lease owns the lock: $OwnedAccessId" -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists -and $data.sessionLock.valid) {
        $lockOwner = if (Test-MO2HasAccessLease -Lock $data.sessionLock) { "access lease $($data.sessionLock.leaseId)" } else { "session $($data.sessionLock.sessionId)" }
        $checks += New-MO2Check -Name 'session-lock' -Status 'fail' -Message "Another MO2 control $lockOwner owns the lock." -Details $data.sessionLock
    }
    elseif ($data.sessionLock.exists) {
        $checks += New-MO2Check -Name 'session-lock' -Status 'warn' -Message 'A stale or invalid session lock exists and requires documented recovery before mutation.' -Details $data.sessionLock
    }
    else {
        $checks += New-MO2Check -Name 'session-lock' -Status 'pass' -Message 'No active MO2 control session lock exists.'
    }

    if ($RequireClosed) {
        $closed = $data.processes.mo2.Count -eq 0 -and $data.processes.game.Count -eq 0
        $checks += New-MO2Check -Name 'closed-state' -Status $(if ($closed) { 'pass' } else { 'fail' }) -Message $(if ($closed) { 'MO2 and game processes are closed.' } else { 'MO2 or the game is running; closed-state validation failed.' }) -Details $data.processes
    }
    else {
        $checks += New-MO2Check -Name 'closed-state' -Status 'info' -Message "Closed state was not required. MO2=$($data.processes.mo2.Count), game=$($data.processes.game.Count)."
    }

    return ConvertTo-MO2Result -Config $Config -Command 'validate' -Checks $checks -Data $data
}

function ConvertTo-MO2SafeLabel {
    param([Parameter(Mandatory)][string]$Label)

    $safe = ($Label.Trim() -replace '[^A-Za-z0-9._-]+', '-') -replace '-{2,}', '-'
    $safe = $safe.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'automation'
    }
    if ($safe.Length -gt 48) {
        return $safe.Substring(0, 48)
    }
    return $safe
}

function ConvertTo-MO2CommandLineArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Write-MO2JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$CreateNew
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth 16
    $encoding = [System.Text.UTF8Encoding]::new($false)
    if ($CreateNew) {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($stream, $encoding)
            try { $writer.Write($json) } finally { $writer.Dispose() }
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
        return
    }

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, $json, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-WithMO2LeaseTransitionLock {
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][scriptblock]$Action,
        [ValidateRange(100, 60000)][int]$TimeoutMilliseconds = 10000
    )

    $resolvedLockPath = Resolve-MO2ControlPath $LockPath
    $transitionPath = "$resolvedLockPath.transition.lock"
    $parent = Split-Path -Parent $transitionPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [System.IO.File]::Open(
                $transitionPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for the MO2 lease transition lock: $transitionPath"
            }
            Start-Sleep -Milliseconds 50
        }
    }

    try {
        return & $Action
    }
    finally {
        $stream.Dispose()
    }
}

function Get-MO2NextLeaseGeneration {
    param($Lease)

    $current = 0L
    if ($null -ne $Lease -and $Lease.PSObject.Properties['generation']) {
        $current = [long]$Lease.generation
    }
    return $current + 1L
}

function Write-MO2OwnedSessionAtomic {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$Value
    )

    $sessionId = [string]$Owned.sessionId
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'A session-bound lease is required for an owned session update.'
    }

    $updatedRecord = Invoke-WithMO2LeaseTransitionLock -LockPath ([string]$Owned.path) -Action {
        $current = Get-MO2SessionLockRecord -Path ([string]$Owned.path)
        if (-not $current.valid -or $current.sessionId -ne $sessionId -or $current.accessId -ne [string]$Owned.accessId) {
            throw "Session '$sessionId' no longer owns the MO2 lease transition."
        }

        $updated = $Value
        foreach ($propertyName in @('contractVersion', 'accessId', 'leaseId', 'acquisitionMode', 'label', 'requestedUtc', 'lastRenewedUtc', 'estimatedDurationMinutes', 'estimatedReleaseUtc', 'ownerRequestPid', 'ownerRequestStartTime', 'runtimeRoute')) {
            if ($current.data.PSObject.Properties[$propertyName]) {
                $updated | Add-Member -NotePropertyName $propertyName -NotePropertyValue $current.data.$propertyName -Force
            }
        }
        $updated | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $current.data) -Force
        Write-MO2JsonAtomic -Path ([string]$Owned.path) -Value $updated
        return Get-MO2SessionLockRecord -Path ([string]$Owned.path)
    }
    $Owned.data = $updatedRecord.data
    return $updatedRecord
}

function New-MO2DurableSessionController {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionPath,
        [switch]$WhatIf
    )
    $controllerDirectory = Join-Path $SessionPath 'controller'
    $entryPath = Join-Path $controllerDirectory 'Invoke-MO2Control.ps1'
    $configDirectory = Join-Path $controllerDirectory 'config'
    $configPath = Join-Path $configDirectory 'machine.local.json'
    $receiptPath = Join-Path $controllerDirectory 'controller-bundle.json'
    $sourceFiles = @('Invoke-MO2Control.ps1', 'ConfigResolution.psm1', 'MO2Control.psm1')
    if ($WhatIf) {
        return [pscustomobject][ordered]@{ controllerPath = $entryPath; configPath = $configPath; receiptPath = $receiptPath; durable = $true; wouldCopy = $sourceFiles }
    }
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $files = @()
    foreach ($name in $sourceFiles) {
        $source = Join-Path $PSScriptRoot $name
        $target = Join-Path $controllerDirectory $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "MO2 session controller source is missing: $source" }
        Copy-Item -LiteralPath $source -Destination $target
        $files += [pscustomobject][ordered]@{ name = $name; path = $target; sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
    }
    Write-MO2JsonAtomic -Path $configPath -Value $Config -CreateNew
    $files += [pscustomobject][ordered]@{ name = 'config/machine.local.json'; path = $configPath; sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash }
    Write-MO2JsonAtomic -Path $receiptPath -Value ([pscustomobject][ordered]@{
        contractVersion = '1.0.0'; createdUtc = [DateTime]::UtcNow.ToString('o'); durable = $true
        purpose = 'Session-scoped lifecycle controller retained independently of the versioned Codex plugin cache.'
        controllerPath = $entryPath; configPath = $configPath; files = $files
    }) -CreateNew
    return [pscustomobject][ordered]@{ controllerPath = $entryPath; configPath = $configPath; receiptPath = $receiptPath; durable = $true; files = $files }
}

function Get-MO2OwnedSession {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'SessionId is required for this command.'
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $lock = Get-MO2SessionLockRecord -Path $lockPath
    if (-not $lock.exists) {
        throw "No MO2 control session lock exists: $lockPath"
    }
    if (-not $lock.valid) {
        throw "The MO2 control session lock is invalid: $($lock.error)"
    }
    if ($lock.sessionId -ne $SessionId) {
        throw "Session '$SessionId' does not own the active lock '$($lock.sessionId)'."
    }
    if (-not $lock.data.PSObject.Properties['sessionPath'] -or -not (Test-Path -LiteralPath ([string]$lock.data.sessionPath) -PathType Container)) {
        throw 'The active lock does not reference an existing session directory.'
    }
    return $lock
}

function New-MO2ActionResult {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Data,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $cleanWarnings = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $cleanErrors = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = $cleanWarnings
        errors = $cleanErrors
        data = $Data
    }
}

function Test-MO2HasAccessLease {
    param([Parameter(Mandatory)]$Lock)

    return -not [string]::IsNullOrWhiteSpace([string]$Lock.leaseId) -or
        -not [string]::IsNullOrWhiteSpace([string]$Lock.accessId) -or
        ($Lock.data -and $Lock.data.PSObject.Properties['accessCredentialSha256'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Lock.data.accessCredentialSha256))
}

function Resolve-MO2RuntimeRouteContract {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('OCU', 'SteamVR', 'SteamVRNull')]
        [string]$RuntimeRoute
    )

    switch ($RuntimeRoute) {
        'OCU' {
            return [pscustomobject][ordered]@{
                id = 'OCU'
                runtimeFamily = 'OpenComposite'
                hmdMode = 'live'
                requiresSteamVR = $false
                requiresNullHmd = $false
                incompatibleWith = @('SteamVR', 'SteamVRNull')
            }
        }
        'SteamVR' {
            return [pscustomobject][ordered]@{
                id = 'SteamVR'
                runtimeFamily = 'SteamVR'
                hmdMode = 'live'
                requiresSteamVR = $true
                requiresNullHmd = $false
                incompatibleWith = @('OCU', 'SteamVRNull')
            }
        }
        'SteamVRNull' {
            return [pscustomobject][ordered]@{
                id = 'SteamVRNull'
                runtimeFamily = 'SteamVR'
                hmdMode = 'null'
                requiresSteamVR = $true
                requiresNullHmd = $true
                incompatibleWith = @('OCU', 'SteamVR')
            }
        }
    }
}

function Get-MO2AccessLeaseSummary {
    param([Parameter(Mandatory)]$Lock)

    if (-not $Lock.exists) {
        return [pscustomobject][ordered]@{
            state = 'available'
            lockPath = $Lock.path
            leaseId = $null
            sessionId = $null
            label = $null
            estimatedReleaseUtc = $null
            estimateOverdue = $false
        }
    }
    if (-not $Lock.valid) {
        return [pscustomobject][ordered]@{
            state = 'invalid-lock'
            lockPath = $Lock.path
            leaseId = $null
            sessionId = $null
            label = $null
            estimatedReleaseUtc = $null
            estimateOverdue = $false
            error = $Lock.error
        }
    }

    $estimatedReleaseUtc = if ($Lock.data.PSObject.Properties['estimatedReleaseUtc']) { [string]$Lock.data.estimatedReleaseUtc } else { $null }
    $estimateOverdue = $false
    if (-not [string]::IsNullOrWhiteSpace($estimatedReleaseUtc)) {
        try {
            $estimateOverdue = [DateTimeOffset]::Parse($estimatedReleaseUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime -lt [DateTime]::UtcNow
        }
        catch {
            $estimateOverdue = $false
        }
    }

    return [pscustomobject][ordered]@{
        state = $(if ([string]::IsNullOrWhiteSpace([string]$Lock.sessionId)) { 'access-held' } else { 'session-held' })
        lockPath = $Lock.path
        leaseId = $(if (-not [string]::IsNullOrWhiteSpace([string]$Lock.leaseId)) { $Lock.leaseId } else { 'legacy-access-lease' })
        sessionId = $Lock.sessionId
        label = $(if ($Lock.data.PSObject.Properties['label']) { [string]$Lock.data.label } else { $null })
        ownerTaskId = $(if ($Lock.data.PSObject.Properties['ownerTaskId']) { [string]$Lock.data.ownerTaskId } else { $null })
        acquisitionMode = $Lock.acquisitionMode
        requestedUtc = $(if ($Lock.data.PSObject.Properties['requestedUtc']) { [string]$Lock.data.requestedUtc } else { $null })
        lastRenewedUtc = $(if ($Lock.data.PSObject.Properties['lastRenewedUtc']) { [string]$Lock.data.lastRenewedUtc } else { $null })
        estimatedDurationMinutes = $(if ($Lock.data.PSObject.Properties['estimatedDurationMinutes']) { $Lock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $estimatedReleaseUtc
        estimateOverdue = $estimateOverdue
        ownerRequestPid = $(if ($Lock.data.PSObject.Properties['ownerRequestPid']) { $Lock.data.ownerRequestPid } else { $null })
        ownerRequestStartTime = $(if ($Lock.data.PSObject.Properties['ownerRequestStartTime']) { [string]$Lock.data.ownerRequestStartTime } else { $null })
        runtimeRoute = $(if ($Lock.data.PSObject.Properties['runtimeRoute']) { $Lock.data.runtimeRoute } else { $null })
        generation = $(if ($Lock.data.PSObject.Properties['generation']) { [long]$Lock.data.generation } else { 0L })
    }
}

function Get-MO2OwnedAccessLease {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId
    )

    if ([string]::IsNullOrWhiteSpace($AccessId)) {
        throw 'AccessId is required for this command.'
    }
    $lock = Get-MO2SessionLockRecord -Path (Resolve-MO2ControlPath ([string]$Config.session.lockFile))
    if (-not $lock.exists) {
        throw "No MO2 access lock exists: $($lock.path)"
    }
    if (-not $lock.valid) {
        throw "The MO2 access lock is invalid: $($lock.error)"
    }
    if (-not (Test-MO2HasAccessLease -Lock $lock)) {
        throw 'The active lock predates cooperative access leases and must be completed through its exact SessionId.'
    }
    if ($lock.accessId -ne $AccessId) {
        throw "The supplied access credential does not own lease '$($lock.leaseId)'."
    }
    return $lock
}

function Invoke-MO2RequestAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Label = 'automation',
        [string]$TaskId,
        [Parameter(Mandatory)]
        [ValidateSet('OCU', 'SteamVR', 'SteamVRNull')]
        [string]$RuntimeRoute,
        [Nullable[int]]$EstimatedMinutes,
        [ValidateRange(0, 600)][int]$WaitSeconds = 0,
        [switch]$WhatIf
    )

    if ($null -ne $EstimatedMinutes -and ($EstimatedMinutes -lt 1 -or $EstimatedMinutes -gt 1440)) {
        throw 'EstimatedMinutes must be between 1 and 1440 when supplied.'
    }
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_TASK_ID)) { $env:CODEX_TASK_ID } else { $null }
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskId) -and ($TaskId.Length -gt 256 -or $TaskId -match '[\r\n]')) {
        throw 'TaskId is malformed.'
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $now = [DateTime]::UtcNow
    $accessId = 'access-{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $leaseId = 'lease-{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $estimatedReleaseUtc = if ($null -ne $EstimatedMinutes) { $now.AddMinutes([int]$EstimatedMinutes).ToString('o') } else { $null }
    $runtimeRouteContract = Resolve-MO2RuntimeRouteContract -RuntimeRoute $RuntimeRoute
    $lease = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $accessId
        leaseId = $leaseId
        acquisitionMode = 'explicit-access'
        status = 'access-held'
        label = $safeLabel
        ownerTaskId = $TaskId
        requestedUtc = $now.ToString('o')
        lastRenewedUtc = $now.ToString('o')
        estimatedDurationMinutes = $EstimatedMinutes
        estimatedReleaseUtc = $estimatedReleaseUtc
        ownerRequestPid = $PID
        ownerRequestStartTime = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        runtimeRoute = $runtimeRouteContract
        generation = 1L
        sessionId = $null
        sessionPath = $null
    }

    $existing = Get-MO2SessionLockRecord -Path $lockPath
    if ($WhatIf) {
        $available = -not $existing.exists
        return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $available -State $(if ($available) { 'dry-run' } else { 'access-busy' }) -Data @{ access = $lease; current = Get-MO2AccessLeaseSummary -Lock $existing; requestedRuntimeRoute = $runtimeRouteContract; waitSeconds = $WaitSeconds; wouldCreateLock = $available; estimateIsAdvisory = $true } -Errors $(if ($available) { @() } else { @('MO2 access is already held. The estimate never expires or transfers ownership automatically.') })
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $started = [DateTime]::UtcNow
    while ($true) {
        $attempt = Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
            $current = Get-MO2SessionLockRecord -Path $lockPath
            if ($current.exists) {
                return [pscustomobject]@{ acquired = $false; current = $current }
            }
            Write-MO2JsonAtomic -Path $lockPath -Value $lease -CreateNew
            return [pscustomobject]@{ acquired = $true; current = $null }
        }
        if ($attempt.acquired) {
            return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $true -State 'access-acquired' -Data @{ access = $lease; lockPath = $lockPath; waitedSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3); estimateIsAdvisory = $true }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            return New-MO2ActionResult -Config $Config -Command 'request-access' -Ok $false -State 'access-busy' -Data @{ current = Get-MO2AccessLeaseSummary -Lock $attempt.current; requestedRuntimeRoute = $runtimeRouteContract; waitedSeconds = [math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3); requestedWaitSeconds = $WaitSeconds; retryable = $true; estimateIsAdvisory = $true } -Errors @('MO2 access is already held. Retry later or explicitly recover an abandoned lease; an overdue estimate does not unlock it.')
        }
        Start-Sleep -Milliseconds 500
    }
}

function Invoke-MO2AccessStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$AccessId
    )

    $lock = Get-MO2SessionLockRecord -Path (Resolve-MO2ControlPath ([string]$Config.session.lockFile))
    $summary = Get-MO2AccessLeaseSummary -Lock $lock
    if (-not $lock.exists) {
        return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $true -State 'available' -Data @{ access = $summary }
    }
    if (-not $lock.valid) {
        return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $false -State 'invalid-lock' -Data @{ access = $summary } -Errors @('The lock is invalid and requires explicit classification before recovery.')
    }
    $owned = -not [string]::IsNullOrWhiteSpace($AccessId) -and $lock.accessId -eq $AccessId
    $state = if ($owned) { 'access-owned' } elseif (-not (Test-MO2HasAccessLease -Lock $lock)) { 'legacy-session-held' } else { 'access-busy' }
    return New-MO2ActionResult -Config $Config -Command 'access-status' -Ok $true -State $state -Data @{ access = $summary; credentialSupplied = -not [string]::IsNullOrWhiteSpace($AccessId); owned = $owned; estimateIsAdvisory = $true }
}

function Invoke-MO2RenewAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [Nullable[int]]$EstimatedMinutes,
        [switch]$WhatIf
    )

    if ($null -ne $EstimatedMinutes -and ($EstimatedMinutes -lt 1 -or $EstimatedMinutes -gt 1440)) {
        throw 'EstimatedMinutes must be between 1 and 1440 when supplied.'
    }
    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'renew-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldGeneration = (Get-MO2NextLeaseGeneration -Lease $owned.data); estimateIsAdvisory = $true }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        $updated = $current.data
        $now = [DateTime]::UtcNow
        $updated | Add-Member -NotePropertyName lastRenewedUtc -NotePropertyValue ($now.ToString('o')) -Force
        if ($null -ne $EstimatedMinutes) {
            $updated | Add-Member -NotePropertyName estimatedDurationMinutes -NotePropertyValue $EstimatedMinutes -Force
            $updated | Add-Member -NotePropertyName estimatedReleaseUtc -NotePropertyValue ($now.AddMinutes([int]$EstimatedMinutes).ToString('o')) -Force
        }
        $updated | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $updated) -Force
        Write-MO2JsonAtomic -Path $current.path -Value $updated
        return New-MO2ActionResult -Config $Config -Command 'renew-access' -Ok $true -State 'access-renewed' -Data @{ access = Get-MO2AccessLeaseSummary -Lock (Get-MO2SessionLockRecord -Path $current.path); estimateIsAdvisory = $true }
    }
}

function Invoke-MO2ReleaseAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if (-not [string]::IsNullOrWhiteSpace([string]$owned.sessionId)) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'session-release-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned } -Errors @('The access lease still has a bound session. Stop MO2/the game and release that exact SessionId first.')
    }
    $inspection = Get-MO2InspectionData -Config $Config
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($inspection.processes.mo2.Count -gt 0 -or $inspection.processes.game.Count -gt 0 -or $activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; processes = $inspection.processes; activeBuildData = $activeBuildData } -Errors @('Access cannot be released while MO2, the game, or a RootBuilder deployment transaction remains active.')
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldRemoveLock = $true }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$current.sessionId)) {
            return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $false -State 'session-release-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $current } -Errors @('The access lease acquired a session before release; release that exact SessionId first.')
        }
        Remove-Item -LiteralPath $current.path -Force
        return New-MO2ActionResult -Config $Config -Command 'release-access' -Ok $true -State 'access-released' -Data @{ accessId = $AccessId; lockPath = $current.path; lockRemoved = $true }
    }
}

function Invoke-MO2RecoverAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$AccessId,
        [string]$Label = 'abandoned-access-recovery',
        [switch]$ConfirmAbandoned,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
    if (-not $ConfirmAbandoned) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $false -State 'confirmation-required' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; requiredSwitch = 'ConfirmAbandoned' } -Errors @('Recovery never infers abandonment from an elapsed estimate. Supply -ConfirmAbandoned only after classifying the owning task as abandoned.')
    }
    $inspection = Get-MO2InspectionData -Config $Config
    $activeBuildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($inspection.processes.mo2.Count -gt 0 -or $inspection.processes.game.Count -gt 0 -or $activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; processes = $inspection.processes; activeBuildData = $activeBuildData } -Errors @('Abandoned access recovery requires closed MO2/game state and no active RootBuilder deployment transaction.')
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $true -State 'dry-run' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $owned; wouldRemoveLock = $true; wouldMarkSessionAbandoned = -not [string]::IsNullOrWhiteSpace([string]$owned.sessionId) }
    }
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    return Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
        $current = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$current.sessionId) -and -not [string]::IsNullOrWhiteSpace([string]$current.data.sessionPath)) {
            $manifestPath = Join-Path ([string]$current.data.sessionPath) 'session.json'
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
                $manifest.status = 'abandoned'
                $manifest | Add-Member -NotePropertyName abandonedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
                $manifest | Add-Member -NotePropertyName abandonmentReason -NotePropertyValue (ConvertTo-MO2SafeLabel $Label) -Force
                Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
            }
        }
        Remove-Item -LiteralPath $current.path -Force
        return New-MO2ActionResult -Config $Config -Command 'recover-access' -Ok $true -State 'access-recovered' -Data @{ accessId = $AccessId; lockPath = $current.path; lockRemoved = $true; reason = ConvertTo-MO2SafeLabel $Label }
    }
}

function Test-MO2ExactProcessPath {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    if ([string]::IsNullOrWhiteSpace([string]$Record.path)) {
        return $false
    }
    return [string]::Equals(
        [IO.Path]::GetFullPath([string]$Record.path).TrimEnd('\'),
        [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Initialize-MO2UiAutomation {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Initialize-MO2NativeWindowAccess {
    if ('MO2Control.NativeWindows' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace MO2Control {
    public static class NativeWindows {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maximum);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maximum);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")]
        private static extern IntPtr GetShellWindow();

        public static IntPtr[] GetTopLevelWindows(int processId) {
            var windows = new List<IntPtr>();
            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner == (uint)processId) windows.Add(hWnd);
                return true;
            }, IntPtr.Zero);
            return windows.ToArray();
        }

        public static string GetTitle(IntPtr hWnd) {
            var value = new StringBuilder(2048);
            GetWindowText(hWnd, value, value.Capacity);
            return value.ToString();
        }

        public static string GetClass(IntPtr hWnd) {
            var value = new StringBuilder(512);
            GetClassName(hWnd, value, value.Capacity);
            return value.ToString();
        }

        public static bool IsVisible(IntPtr hWnd) { return IsWindowVisible(hWnd); }
        public static bool RequestClose(IntPtr hWnd) { return PostMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero); }
        public static bool HasInteractiveShell() { return GetShellWindow() != IntPtr.Zero; }
    }
}
'@
}

function Test-MO2InteractiveDesktop {
    Initialize-MO2NativeWindowAccess
    return [MO2Control.NativeWindows]::HasInteractiveShell()
}

function Get-MO2NativeWindows {
    param([Parameter(Mandatory)][int]$ProcessId)

    Initialize-MO2NativeWindowAccess
    $records = @()
    foreach ($handle in @([MO2Control.NativeWindows]::GetTopLevelWindows($ProcessId))) {
        $records += [pscustomobject][ordered]@{
            processId = $ProcessId
            handle = [int64]$handle
            title = [MO2Control.NativeWindows]::GetTitle($handle)
            className = [MO2Control.NativeWindows]::GetClass($handle)
            visible = [MO2Control.NativeWindows]::IsVisible($handle)
        }
    }
    return @($records)
}

function Get-MO2AutomationWindows {
    param([Parameter(Mandatory)][int]$ProcessId)

    if (-not (Initialize-MO2UiAutomation)) {
        return @()
    }
    $windows = @()
    foreach ($record in @(Get-MO2NativeWindows -ProcessId $ProcessId | Where-Object visible)) {
        try {
            $windows += [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$record.handle)
        }
        catch {
            # Native window inventory remains available even when a provider does
            # not expose this particular Qt window to UI Automation.
        }
    }
    return @($windows)
}

function Get-MO2UnlockButtons {
    param([Parameter(Mandatory)]$Window)

    return @(Get-MO2NamedButtons -Window $Window -Name 'Unlock')
}

function Invoke-MO2UiAutomationFindAll {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Scope,
        [Parameter(Mandatory)]$Condition,
        [ValidateRange(1, 3)][int]$MaxAttempts = 2,
        [ValidateRange(0, 1000)][int]$RetryDelayMilliseconds = 100
    )

    $failures = [Collections.Generic.List[string]]::new()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return @($Window.FindAll($Scope, $Condition))
        }
        catch {
            $failures.Add("attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -lt $MaxAttempts -and $RetryDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
            }
        }
    }
    throw "UI Automation descendant enumeration failed after $MaxAttempts bounded attempts: $($failures -join '; ')"
}

function Get-MO2NamedButtons {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Name
    )

    $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name,
        [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
    )
    $condition = [System.Windows.Automation.AndCondition]::new($buttonCondition, $nameCondition)
    return @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)
}

function Get-MO2WindowTextElements {
    param([Parameter(Mandatory)]$Window)

    $condition = [System.Windows.Automation.OrCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text
        ),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document
        )
    )
    $values = [Collections.Generic.List[string]]::new()
    foreach ($element in @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)) {
        $name = ConvertTo-MO2ControlName ([string]$element.Current.Name)
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $values.Contains($name)) {
            $values.Add($(if ($name.Length -gt 512) { $name.Substring(0, 512) } else { $name }))
        }
        if ($values.Count -ge 32) { break }
    }
    return @($values)
}

function Get-MO2KnownDialogKind {
    param(
        [AllowNull()][string]$Title,
        [AllowEmptyCollection()][string[]]$Texts = @(),
        [AllowEmptyCollection()][object[]]$Buttons = @()
    )
    $buttonNames = @($Buttons | ForEach-Object {
        if ($_ -is [string]) { ConvertTo-MO2ControlName ([string]$_) }
        elseif ($_.PSObject.Properties['name']) { ConvertTo-MO2ControlName ([string]$_.name) }
        else { '' }
    })
    if (@($buttonNames | Where-Object { $_ -ieq 'Unlock' }).Count -eq 1) { return 'unlock-required' }
    $combined = ((@($Title) + @($Texts)) -join "`n")
    if ($combined -match '(?i)failed to write settings') { return 'failed-to-write-settings' }
    if ($combined -match '(?i)failed to (run|start|launch)') { return 'failed-to-run' }
    return $null
}

function Get-MO2NamedMenuItems {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$Name
    )

    $menuCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::MenuItem
    )
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name,
        [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase
    )
    $condition = [System.Windows.Automation.AndCondition]::new($menuCondition, $nameCondition)
    return @(Invoke-MO2UiAutomationFindAll -Window $Window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $condition)
}

function Expand-MO2AutomationMenu {
    param([Parameter(Mandatory)]$MenuItem)

    $pattern = $null
    if ($MenuItem.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.ExpandCollapsePattern]$pattern).Expand()
        return $true
    }
    return $false
}

function ConvertTo-MO2ControlName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    return (($Name -replace '&', '').Trim() -replace '\s+', ' ')
}

function Get-MO2WindowSnapshot {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes)

    $records = @()
    foreach ($processRecord in $Processes) {
        $automationByHandle = @{}
        foreach ($window in @(Get-MO2AutomationWindows -ProcessId ([int]$processRecord.id))) {
            $automationByHandle[[string][int64]$window.Current.NativeWindowHandle] = $window
        }
        foreach ($native in @(Get-MO2NativeWindows -ProcessId ([int]$processRecord.id))) {
            $buttons = @()
            $texts = @()
            $window = $automationByHandle[[string][int64]$native.handle]
            $automationId = $(if ($window) { [string]$window.Current.AutomationId } else { $null })
            if ($window -and $native.visible -and $automationId -ine 'MainWindow') {
                $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Button
                )
                foreach ($button in @(Invoke-MO2UiAutomationFindAll -Window $window -Scope ([System.Windows.Automation.TreeScope]::Descendants) -Condition $buttonCondition)) {
                    $buttons += [pscustomobject][ordered]@{
                        name = ConvertTo-MO2ControlName ([string]$button.Current.Name)
                        automationId = [string]$button.Current.AutomationId
                        enabled = [bool]$button.Current.IsEnabled
                    }
                }
                $texts = @(Get-MO2WindowTextElements -Window $window)
            }
            $dialogKind = Get-MO2KnownDialogKind -Title ([string]$native.title) -Texts $texts -Buttons $buttons
            $records += [pscustomobject][ordered]@{
                processId = [int]$processRecord.id
                handle = [int64]$native.handle
                title = [string]$native.title
                className = [string]$native.className
                visible = [bool]$native.visible
                automationAvailable = $null -ne $window
                automationId = $automationId
                buttons = @($buttons)
                texts = @($texts)
                dialogKind = $dialogKind
            }
        }
    }
    return @($records)
}

function Invoke-MO2AutomationButton {
    param(
        [Parameter(Mandatory)]$Button,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    if (-not $Button.Current.IsEnabled -or (ConvertTo-MO2ControlName ([string]$Button.Current.Name)) -ine $ExpectedName) {
        return $false
    }
    $pattern = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
        return $true
    }
    $pattern = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.LegacyIAccessiblePattern]$pattern).DoDefaultAction()
        return $true
    }
    return $false
}

function Request-MO2AutomationWindowClose {
    param([Parameter(Mandatory)]$Window)

    $pattern = $null
    if ($Window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)) {
        ([System.Windows.Automation.WindowPattern]$pattern).Close()
        return $true
    }
    Initialize-MO2NativeWindowAccess
    return [MO2Control.NativeWindows]::RequestClose([IntPtr][int64]$Window.Current.NativeWindowHandle)
}

function Invoke-MO2RetainedSessionDialogCleanup {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    if ($Processes.Count -eq 0) {
        return [pscustomobject][ordered]@{ cleared = $true; before = @(); actions = @(); remaining = @(); needsAttention = @() }
    }
    Assert-MO2ExactProcessTargets -Config $Config -Processes $Processes
    $before = @(Get-MO2WindowSnapshot -Processes $Processes)
    $actions = [Collections.Generic.List[object]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $handled = $false
        foreach ($record in $Processes) {
            foreach ($window in @(Get-MO2AutomationWindows -ProcessId ([int]$record.id))) {
                if ([string]$window.Current.AutomationId -eq 'MainWindow') { continue }
                $kind = Get-MO2KnownDialogKind -Title ([string]$window.Current.Name) -Texts @(Get-MO2WindowTextElements -Window $window)
                if ($kind -ne 'failed-to-run') { continue }
                $accepted = $false
                foreach ($name in @('OK', 'Close')) {
                    foreach ($button in @(Get-MO2NamedButtons -Window $window -Name $name)) {
                        $accepted = (Invoke-MO2AutomationButton -Button $button -ExpectedName $name) -or $accepted
                    }
                }
                if (-not $accepted) { $accepted = Request-MO2AutomationWindowClose -Window $window }
                $actions.Add([pscustomobject][ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString('o'); processId = [int]$record.id
                    windowHandle = [int64]$window.Current.NativeWindowHandle; windowTitle = [string]$window.Current.Name
                    dialogKind = $kind; action = 'acknowledge-retained-failed-to-run'; accepted = [bool]$accepted
                })
                $handled = $true
            }
        }
        if (-not $handled) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $remaining = @(Get-MO2WindowSnapshot -Processes $Processes)
    $remainingKnown = @($remaining | Where-Object { $_.visible -and $_.dialogKind -eq 'failed-to-run' })
    $needsAttention = @($remaining | Where-Object {
        $_.visible -and $_.automationId -ine 'MainWindow' -and $_.dialogKind -ne 'unlock-required' -and $_.dialogKind -ne 'failed-to-run'
    })
    return [pscustomobject][ordered]@{
        cleared = $remainingKnown.Count -eq 0; before = $before; actions = @($actions)
        remaining = $remaining; remainingKnown = $remainingKnown; needsAttention = $needsAttention
    }
}

function Assert-MO2ExactProcessTargets {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Processes
    )

    $expectedPath = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    $invalid = @($Processes | Where-Object { -not (Test-MO2ExactProcessPath -Record $_ -ExpectedPath $expectedPath) })
    if ($invalid.Count -gt 0) {
        $identities = @($invalid | ForEach-Object { "PID $($_.id) path '$($_.path)'" }) -join '; '
        throw "Refusing to control a process that cannot be proven to be the configured MO2 executable '$expectedPath': $identities"
    }
}

function Invoke-MO2CooperativeCloseCore {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$InitialProcesses,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90
    )

    Assert-MO2ExactProcessTargets -Config $Config -Processes $InitialProcesses
    $targetIds = @($InitialProcesses | ForEach-Object { [int]$_.id } | Select-Object -Unique)
    $actions = [System.Collections.Generic.List[object]]::new()
    $beforeWindows = @(Get-MO2WindowSnapshot -Processes $InitialProcesses)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    do {
        $liveRecords = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames) | Where-Object { $targetIds -contains [int]$_.id })
        if ($liveRecords.Count -eq 0) { break }
        Assert-MO2ExactProcessTargets -Config $Config -Processes $liveRecords

        foreach ($record in $liveRecords) {
            $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
            if (-not $process) { continue }
            $nativeVisibility = @{}
            foreach ($native in @(Get-MO2NativeWindows -ProcessId ([int]$record.id))) {
                $nativeVisibility[[string][int64]$native.handle] = [bool]$native.visible
            }
            $windows = @(Get-MO2AutomationWindows -ProcessId ([int]$record.id) | Where-Object {
                $nativeVisibility[[string][int64]$_.Current.NativeWindowHandle]
            })

            # Process.MainWindowHandle can temporarily point at a modal warning
            # or the VFS Unlock dialog. Prefer MO2's stable UIA identity so that
            # those windows remain eligible for exact dialog handling.
            $automationMain = @($windows | Where-Object {
                [string]$_.Current.AutomationId -eq 'MainWindow'
            } | Select-Object -First 1)
            $mainHandle = if ($automationMain.Count -gt 0) {
                [int64]$automationMain[0].Current.NativeWindowHandle
            }
            else {
                [int64]$process.MainWindowHandle
            }
            $exitRequested = $false
            foreach ($window in $windows) {
                $unlockButtons = @(Get-MO2UnlockButtons -Window $window)
                if ($unlockButtons.Count -gt 0) {
                    foreach ($button in $unlockButtons) {
                        $invoked = Invoke-MO2AutomationButton -Button $button -ExpectedName 'Unlock'
                        $actions.Add([pscustomobject][ordered]@{
                            timestampUtc = [DateTime]::UtcNow.ToString('o')
                            processId = [int]$record.id
                            windowHandle = [int64]$window.Current.NativeWindowHandle
                            windowTitle = [string]$window.Current.Name
                            action = 'invoke-exact-unlock'
                            accepted = $invoked
                        })
                    }
                    continue
                }
                foreach ($menuItem in @(Get-MO2NamedMenuItems -Window $window -Name 'Exit')) {
                    $invoked = Invoke-MO2AutomationButton -Button $menuItem -ExpectedName 'Exit'
                    $exitRequested = $exitRequested -or $invoked
                    $actions.Add([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                        processId = [int]$record.id
                        windowHandle = [int64]$window.Current.NativeWindowHandle
                        windowTitle = [string]$window.Current.Name
                        action = 'invoke-exact-exit'
                        accepted = $invoked
                    })
                }
                if ($mainHandle -ne 0 -and [int64]$window.Current.NativeWindowHandle -eq $mainHandle) {
                    if (-not $exitRequested) {
                        foreach ($fileMenu in @(Get-MO2NamedMenuItems -Window $window -Name 'File')) {
                            $expanded = Expand-MO2AutomationMenu -MenuItem $fileMenu
                            $exitRequested = $exitRequested -or $expanded
                            $actions.Add([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString('o')
                                processId = [int]$record.id
                                windowHandle = [int64]$window.Current.NativeWindowHandle
                                windowTitle = [string]$window.Current.Name
                                action = 'expand-exact-file-menu'
                                accepted = $expanded
                            })
                        }
                    }
                    if ($exitRequested) {
                        Start-Sleep -Milliseconds 100
                        foreach ($menuItem in @(Get-MO2NamedMenuItems -Window $window -Name 'Exit')) {
                            $invoked = Invoke-MO2AutomationButton -Button $menuItem -ExpectedName 'Exit'
                            $exitRequested = $exitRequested -or $invoked
                            $actions.Add([pscustomobject][ordered]@{
                                timestampUtc = [DateTime]::UtcNow.ToString('o')
                                processId = [int]$record.id
                                windowHandle = [int64]$window.Current.NativeWindowHandle
                                windowTitle = [string]$window.Current.Name
                                action = 'invoke-exact-exit-after-expand'
                                accepted = $invoked
                            })
                        }
                    }
                    continue
                }
                $dialogKind = Get-MO2KnownDialogKind -Title ([string]$window.Current.Name) -Texts @(Get-MO2WindowTextElements -Window $window)
                if ($dialogKind -eq 'failed-to-write-settings') {
                    foreach ($button in @(Get-MO2NamedButtons -Window $window -Name 'OK')) {
                        $invoked = Invoke-MO2AutomationButton -Button $button -ExpectedName 'OK'
                        $actions.Add([pscustomobject][ordered]@{
                            timestampUtc = [DateTime]::UtcNow.ToString('o')
                            processId = [int]$record.id
                            windowHandle = [int64]$window.Current.NativeWindowHandle
                            windowTitle = [string]$window.Current.Name
                            action = 'acknowledge-failed-to-write-settings'
                            accepted = $invoked
                        })
                    }
                }
            }

            if ($windows.Count -gt 0) {
                $secondary = @($windows | Where-Object {
                    [int64]$_.Current.NativeWindowHandle -ne $mainHandle -and @(Get-MO2UnlockButtons -Window $_).Count -eq 0
                })
                foreach ($window in $secondary) {
                    $requested = Request-MO2AutomationWindowClose -Window $window
                    $actions.Add([pscustomobject][ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString('o')
                        processId = [int]$record.id
                        windowHandle = [int64]$window.Current.NativeWindowHandle
                        windowTitle = [string]$window.Current.Name
                        action = 'request-modal-window-close'
                        accepted = $requested
                    })
                }
            }

            if (-not $exitRequested) {
                $accepted = $process.CloseMainWindow()
                $actions.Add([pscustomobject][ordered]@{
                    timestampUtc = [DateTime]::UtcNow.ToString('o')
                    processId = [int]$record.id
                    windowHandle = [int64]$process.MainWindowHandle
                    windowTitle = [string]$process.MainWindowTitle
                    action = 'request-main-window-close-fallback'
                    accepted = [bool]$accepted
                })
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames) | Where-Object { $targetIds -contains [int]$_.id })
    if ($remaining.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $remaining
    }
    return [pscustomobject][ordered]@{
        closed = $remaining.Count -eq 0
        targetProcessIds = @($targetIds)
        beforeWindows = @($beforeWindows)
        actions = @($actions)
        remaining = @($remaining)
        remainingWindows = @(Get-MO2WindowSnapshot -Processes $remaining)
        forceTermination = $false
        unrelatedProcessesTouched = @()
    }
}

function Invoke-MO2CooperativeClose {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$InitialProcesses,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90
    )

    $directWindows = @(Get-MO2WindowSnapshot -Processes $InitialProcesses)
    if ($directWindows.Count -eq 0) {
        return [pscustomobject][ordered]@{
            closed = $false
            route = 'interactive-desktop-required'
            targetProcessIds = @($InitialProcesses | ForEach-Object { [int]$_.id })
            beforeWindows = @()
            actions = @()
            remaining = @($InitialProcesses)
            remainingWindows = @()
            requiresInteractiveDesktop = $true
            requiredIdentity = 'logged-on user owning the MO2 desktop'
            forceTermination = $false
            unrelatedProcessesTouched = @()
        }
    }
    $close = Invoke-MO2CooperativeCloseCore -Config $Config -InitialProcesses $InitialProcesses -TimeoutSeconds $TimeoutSeconds
    $close | Add-Member -NotePropertyName route -NotePropertyValue 'current-interactive-desktop' -Force
    return $close
}

function Set-MO2OwnedSessionStatus {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$TimestampProperty
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    $Owned.data.status = $Status
    if ($Owned.data.PSObject.Properties[$TimestampProperty]) {
        $Owned.data.$TimestampProperty = $timestamp
    }
    else {
        $Owned.data | Add-Member -NotePropertyName $TimestampProperty -NotePropertyValue $timestamp
    }
    $null = Write-MO2OwnedSessionAtomic -Owned $Owned -Value $Owned.data

    $manifestPath = Join-Path ([string]$Owned.data.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest.status = $Status
    if ($manifest.PSObject.Properties[$TimestampProperty]) {
        $manifest.$TimestampProperty = $timestamp
    }
    else {
        $manifest | Add-Member -NotePropertyName $TimestampProperty -NotePropertyValue $timestamp
    }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
}

function Set-MO2OwnedSessionOwner {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$ProcessRecord,
        [Parameter(Mandatory)][string]$Reason
    )

    $previousOwnerPid = if ($Owned.data.PSObject.Properties['ownerPid']) { [int]$Owned.data.ownerPid } else { 0 }
    $adoption = [pscustomobject][ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        previousOwnerPid = $previousOwnerPid
        ownerPid = [int]$ProcessRecord.id
        processPath = [string]$ProcessRecord.path
        processStartTime = [string]$ProcessRecord.startTime
        reason = $Reason
    }
    if ($Owned.data.PSObject.Properties['ownerPid']) {
        $Owned.data.ownerPid = [int]$ProcessRecord.id
    }
    else {
        $Owned.data | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$ProcessRecord.id)
    }
    [object[]]$adoptions = @()
    if ($Owned.data.PSObject.Properties['ownerAdoptions']) {
        $adoptions = @($Owned.data.ownerAdoptions)
    }
    [object[]]$updatedAdoptions = @($adoptions)
    $updatedAdoptions += $adoption
    if ($Owned.data.PSObject.Properties['ownerAdoptions']) {
        $Owned.data.ownerAdoptions = $updatedAdoptions
    }
    else {
        $Owned.data | Add-Member -NotePropertyName ownerAdoptions -NotePropertyValue @($adoption)
    }
    $null = Write-MO2OwnedSessionAtomic -Owned $Owned -Value $Owned.data

    $manifestPath = Join-Path ([string]$Owned.data.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    if ($manifest.PSObject.Properties['ownerPid']) {
        $manifest.ownerPid = [int]$ProcessRecord.id
    }
    else {
        $manifest | Add-Member -NotePropertyName ownerPid -NotePropertyValue ([int]$ProcessRecord.id)
    }
    [object[]]$manifestAdoptions = @()
    if ($manifest.PSObject.Properties['ownerAdoptions']) {
        $manifestAdoptions = @($manifest.ownerAdoptions)
    }
    [object[]]$updatedManifestAdoptions = @($manifestAdoptions)
    $updatedManifestAdoptions += $adoption
    if ($manifest.PSObject.Properties['ownerAdoptions']) {
        $manifest.ownerAdoptions = $updatedManifestAdoptions
    }
    else {
        $manifest | Add-Member -NotePropertyName ownerAdoptions -NotePropertyValue @($adoption)
    }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
    return $adoption
}

function Resolve-MO2OwnedProcessTarget {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [switch]$AdoptDetachedOwner
    )

    $ownerPid = if ($Owned.data.PSObject.Properties['ownerPid']) { [int]$Owned.data.ownerPid } else { 0 }
    $ownedTargets = @($Processes | Where-Object { [int]$_.id -eq $ownerPid })
    if ($Processes.Count -eq 0 -or $ownedTargets.Count -eq 1) {
        return [pscustomobject][ordered]@{
            ok = $true
            ownerPid = $ownerPid
            targets = @($ownedTargets)
            adopted = $false
            adoption = $null
            reason = $(if ($Processes.Count -eq 0) { 'already-closed' } else { 'recorded-owner' })
        }
    }
    if (-not $AdoptDetachedOwner -or $Processes.Count -ne 1 -or $ownedTargets.Count -ne 0) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'ambiguous-process-set' }
    }
    if ($ownerPid -gt 0 -and $null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'recorded-owner-still-running' }
    }

    $candidate = $Processes[0]
    Assert-MO2ExactProcessTargets -Config $Config -Processes @($candidate)
    $createdText = [string]$Owned.data.createdUtc
    $startedText = [string]$candidate.startTime
    try {
        $createdUtc = [DateTimeOffset]::Parse($createdText, [Globalization.CultureInfo]::InvariantCulture)
        $startedUtc = [DateTimeOffset]::Parse($startedText, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'candidate-time-unavailable'; createdUtc = $createdText; processStartTime = $startedText; detail = $_.Exception.Message }
    }
    if ($startedUtc.UtcDateTime -lt $createdUtc.UtcDateTime.AddSeconds(-5)) {
        return [pscustomobject][ordered]@{ ok = $false; ownerPid = $ownerPid; targets = @(); adopted = $false; adoption = $null; reason = 'candidate-predates-session'; createdUtc = $createdUtc.ToString('o'); processStartTime = $startedUtc.ToString('o') }
    }

    $adoption = Set-MO2OwnedSessionOwner -Owned $Owned -ProcessRecord $candidate -Reason 'adopted exact detached MO2 process after recorded owner exited'
    return [pscustomobject][ordered]@{
        ok = $true
        ownerPid = [int]$candidate.id
        targets = @($candidate)
        adopted = $true
        adoption = $adoption
        reason = 'detached-owner-adopted'
    }
}

function Invoke-MO2Prepare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Profile,
        [string]$Executable,
        [switch]$RequireSKSE,
        [string]$Label = 'automation',
        [string]$AccessId,
        [switch]$WhatIf
    )

    $validation = Invoke-MO2Validate -Config $Config -Profile $Profile -Executable $Executable -RequireSKSE:$RequireSKSE -RequireClosed -OwnedAccessId $AccessId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ validation = $validation } -Warnings $validation.warnings -Errors $validation.errors
    }

    $profileName = [string]$validation.data.requested.profile
    $executableName = [string]$validation.data.requested.executable
    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $sessionId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $safeLabel, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $stagingRoot = Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)
    $sessionPath = Join-Path $stagingRoot $sessionId
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $arguments = @('--profile', $profileName, 'run', '--executable', $executableName)
    $explicitAccess = -not [string]::IsNullOrWhiteSpace($AccessId)
    $accessLock = $null
    $runtimeRoute = $null
    if ($explicitAccess) {
        $accessLock = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$accessLock.sessionId)) {
            return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock } -Errors @('The access lease already has a bound session. Release that session before preparing another one.')
        }
        if (-not $accessLock.data.PSObject.Properties['runtimeRoute']) {
            return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock } -Errors @('The access lease predates the required runtime-route contract. Release it and request a new lease with -RuntimeRoute OCU, SteamVR, or SteamVRNull.')
        }
        $runtimeRoute = $accessLock.data.runtimeRoute
    }
    else {
        $AccessId = 'access-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0, 12))
    }

    $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath -WhatIf
    $profileDirectory = Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) $profileName
    $manifest = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $sessionId
        label = $safeLabel
        createdUtc = [DateTime]::UtcNow.ToString('o')
        status = 'prepared'
        profile = $profileName
        profileName = $profileName
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = $executableName
        requirements = [pscustomobject][ordered]@{ skseLoader = [bool]$RequireSKSE }
        runtimeRoute = $runtimeRoute
        mo2Path = [string]$validation.data.config.mo2Executable
        arguments = $arguments
        selectedProfileBefore = [string]$validation.data.selectedProfile
        launcherPid = $null
        launchedUtc = $null
        stoppedUtc = $null
        accessId = $AccessId
        acquisitionMode = $(if ($explicitAccess) { 'explicit-access' } else { 'implicit-session' })
        controllerPath = [string]$controller.controllerPath
        controllerConfigPath = [string]$controller.configPath
        controllerReceiptPath = [string]$controller.receiptPath
    }
    $lock = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $AccessId
        acquisitionMode = $(if ($explicitAccess) { 'explicit-access' } else { 'implicit-session' })
        label = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['label']) { [string]$accessLock.data.label } else { $safeLabel })
        requestedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['requestedUtc']) { [string]$accessLock.data.requestedUtc } else { $manifest.createdUtc })
        lastRenewedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['lastRenewedUtc']) { [string]$accessLock.data.lastRenewedUtc } else { $manifest.createdUtc })
        estimatedDurationMinutes = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedDurationMinutes']) { $accessLock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedReleaseUtc']) { $accessLock.data.estimatedReleaseUtc } else { $null })
        ownerRequestPid = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['ownerRequestPid']) { $accessLock.data.ownerRequestPid } else { $PID })
        generation = $(if ($explicitAccess) { Get-MO2NextLeaseGeneration -Lease $accessLock.data } else { 1L })
        sessionId = $sessionId
        sessionPath = $sessionPath
        status = 'prepared'
        createdUtc = $manifest.createdUtc
        profile = $profileName
        profileName = $profileName
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = $executableName
        requirements = [pscustomobject][ordered]@{ skseLoader = [bool]$RequireSKSE }
        runtimeRoute = $runtimeRoute
        controllerPath = [string]$controller.controllerPath
        ownerPid = $PID
    }

    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'dry-run' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath; accessId = $AccessId; explicitAccess = $explicitAccess; controller = $controller; controllerPath = [string]$controller.controllerPath; wouldCreate = @($sessionPath, (Join-Path $sessionPath 'session.json'), [string]$controller.controllerPath); wouldCreateLock = -not $explicitAccess; wouldBindAccessLock = $explicitAccess } -Warnings $validation.warnings
    }

    if (-not $explicitAccess -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $false -State 'blocked' -Data @{ lock = Get-MO2SessionLockRecord -Path $lockPath } -Errors @("An MO2 control session lock already exists: $lockPath")
    }

    New-Item -ItemType Directory -Path $sessionPath -ErrorAction Stop | Out-Null
    try {
        $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath
        Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $manifest -CreateNew
        Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
            if ($explicitAccess) {
                $currentAccess = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
                if (-not [string]::IsNullOrWhiteSpace([string]$currentAccess.sessionId)) {
                    throw 'The access lease acquired a session before this prepare could bind it.'
                }
                $bound = $currentAccess.data
                foreach ($propertyName in @('sessionId', 'sessionPath', 'status', 'createdUtc', 'profile', 'profileName', 'profileDirectory', 'modListPath', 'executable', 'requirements', 'controllerPath', 'ownerPid')) {
                    $bound | Add-Member -NotePropertyName $propertyName -NotePropertyValue $lock.$propertyName -Force
                }
                $bound | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $currentAccess.data) -Force
                Write-MO2JsonAtomic -Path $lockPath -Value $bound
            }
            else {
                Write-MO2JsonAtomic -Path $lockPath -Value $lock -CreateNew
            }
        } | Out-Null
    }
    catch {
        throw "Failed to prepare session '$sessionId'. The evidence directory is retained at '$sessionPath'. $($_.Exception.Message)"
    }

    return New-MO2ActionResult -Config $Config -Command 'prepare' -Ok $true -State 'prepared' -Data @{ session = $manifest; sessionPath = $sessionPath; lockPath = $lockPath; accessId = $AccessId; explicitAccess = $explicitAccess; controller = $controller; controllerPath = [string]$controller.controllerPath } -Warnings $validation.warnings
}

function Set-MO2OwnedSessionGameProcesses {
    param(
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes
    )
    $records = @($Processes | ForEach-Object {
        [pscustomobject][ordered]@{ id = [int]$_.id; name = [string]$_.name; path = [string]$_.path; startTime = [string]$_.startTime }
    })
    $timestamp = [DateTime]::UtcNow.ToString('o')
    $Owned.data | Add-Member -NotePropertyName gameProcesses -NotePropertyValue $records -Force
    $Owned.data | Add-Member -NotePropertyName gameProcessesRecordedUtc -NotePropertyValue $timestamp -Force
    $null = Write-MO2OwnedSessionAtomic -Owned $Owned -Value $Owned.data
    $manifestPath = Join-Path ([string]$Owned.data.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest | Add-Member -NotePropertyName gameProcesses -NotePropertyValue $records -Force
    $manifest | Add-Member -NotePropertyName gameProcessesRecordedUtc -NotePropertyValue $timestamp -Force
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
    return $records
}

function Invoke-MO2UnlockOnly {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$MO2Processes,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90
    )
    Assert-MO2ExactProcessTargets -Config $Config -Processes $MO2Processes
    $targetIds = @($MO2Processes | ForEach-Object { [int]$_.id })
    $actions = [Collections.Generic.List[object]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $inspection = Get-MO2InspectionData -Config $Config
        $buildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
        if ($buildData.Count -eq 0) { break }
        $live = @($inspection.processes.mo2 | Where-Object { $targetIds -contains [int]$_.id })
        foreach ($record in $live) {
            foreach ($window in @(Get-MO2AutomationWindows -ProcessId ([int]$record.id))) {
                foreach ($button in @(Get-MO2UnlockButtons -Window $window)) {
                    $invoked = Invoke-MO2AutomationButton -Button $button -ExpectedName 'Unlock'
                    $actions.Add([pscustomobject][ordered]@{ timestampUtc=[DateTime]::UtcNow.ToString('o'); processId=[int]$record.id; windowTitle=[string]$window.Current.Name; action='invoke-exact-unlock'; accepted=$invoked })
                }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    $final = Get-MO2InspectionData -Config $Config
    $remainingBuildData = @($final.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    return [pscustomobject][ordered]@{ restored = $remainingBuildData.Count -eq 0; actions=@($actions); remainingBuildData=@($remainingBuildData | ForEach-Object path); mo2Processes=@($final.processes.mo2); gameProcesses=@($final.processes.game) }
}

function Test-MO2OpeningReady {
    param(
        [Parameter(Mandatory)]$Owned,
        [AllowNull()]$OwnershipResolution,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MO2Processes,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GameProcesses,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Windows
    )

    if ([string]$Owned.data.status -cne 'opening' -or $GameProcesses.Count -ne 0 -or $MO2Processes.Count -ne 1) { return $false }
    if ($null -eq $OwnershipResolution -or -not [bool]$OwnershipResolution.ok -or @($OwnershipResolution.targets).Count -ne 1) { return $false }
    return @($Windows | Where-Object { $_.visible -and [string]$_.automationId -ceq 'MainWindow' }).Count -eq 1
}

function Invoke-MO2Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SessionId
    )

    $requestedProfile = $null
    $requestedExecutable = $null
    $owned = $null
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $requestedProfile = [string]$owned.data.profile
        $requestedExecutable = [string]$owned.data.executable
    }
    $data = Get-MO2InspectionData -Config $Config -RequestedProfile $requestedProfile -RequestedExecutable $requestedExecutable
    $ownershipResolution = $null
    if ($owned -and $data.processes.mo2.Count -gt 0) {
        $ownershipResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($data.processes.mo2) -AdoptDetachedOwner
        if ($ownershipResolution.adopted) { $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId }
    }
    $buildData = @($data.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    $windows = if ($data.processes.mo2.Count -gt 0) { @(Get-MO2WindowSnapshot -Processes @($data.processes.mo2)) } else { @() }
    $openingCompleted = $false
    if ($owned -and (Test-MO2OpeningReady -Owned $owned -OwnershipResolution $ownershipResolution -MO2Processes @($data.processes.mo2) -GameProcesses @($data.processes.game) -Windows @($windows))) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-open' -TimestampProperty 'openCompletedUtc'
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $openingCompleted = $true
    }
    $headlessMO2 = $data.processes.mo2.Count -gt 0 -and @($windows | Where-Object visible).Count -eq 0
    $launchGraceSeconds = 30
    if ($Config.limits.PSObject.Properties['launchPendingGraceSeconds']) {
        $launchGraceSeconds = [math]::Max(5, [math]::Min(120, [int]$Config.limits.launchPendingGraceSeconds))
    }
    $launchStartedUtc = $null
    $launchElapsedSeconds = $null
    if ($owned -and [string]$owned.data.status -eq 'launching' -and $owned.data.PSObject.Properties['launchedUtc']) {
        try {
            $launchStartedUtc = [DateTimeOffset]::Parse([string]$owned.data.launchedUtc, [Globalization.CultureInfo]::InvariantCulture)
            $launchElapsedSeconds = [math]::Max(0, ([DateTimeOffset]::UtcNow - $launchStartedUtc).TotalSeconds)
        }
        catch { $launchStartedUtc = $null }
    }
    $launchPending = $null -ne $launchStartedUtc -and $launchElapsedSeconds -lt $launchGraceSeconds
    $state = if ($data.processes.game.Count -gt 0) {
        'game-running'
    }
    elseif ($launchPending) {
        'launch-pending'
    }
    elseif ($buildData.Count -gt 0 -and ($headlessMO2 -or $data.processes.mo2.Count -eq 0)) {
        'rootbuilder-recovery-required'
    }
    elseif ($data.processes.mo2.Count -gt 0) {
        'mo2-running'
    }
    elseif ($data.sessionLock.exists) {
        [string]$data.sessionLock.status
    }
    else { 'closed' }
    $data | Add-Member -NotePropertyName controller -NotePropertyValue ([pscustomobject][ordered]@{
        sessionId = if ($owned) { $SessionId } else { $null }
        sessionPath = if ($owned) { [string]$owned.data.sessionPath } else { $null }
        lockStatus = if ($owned) { [string]$owned.data.status } else { $null }
        windows = @($windows)
        headlessMO2 = $headlessMO2
        activeBuildData = @($buildData | ForEach-Object path)
        ownershipResolution = $ownershipResolution
        openingCompleted = $openingCompleted
        launchPending = $launchPending
        launchElapsedSeconds = $launchElapsedSeconds
        launchGraceSeconds = $launchGraceSeconds
        launchGraceRemainingSeconds = if ($launchPending) { [math]::Max(0, [math]::Round($launchGraceSeconds - $launchElapsedSeconds, 3)) } else { 0 }
        recoveryCommand = if ($buildData.Count -gt 0 -and $owned -and -not $launchPending) { "recover-rootbuilder -SessionId $SessionId" } else { $null }
    }) -Force
    return New-MO2ActionResult -Config $Config -Command 'status' -Ok $true -State $state -Data $data
}

function Invoke-MO2Launch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$RootBuilderRecovery,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $lockData = $owned.data
    $acceptedStatuses = @('prepared', 'launch-failed', 'game-stopped', 'stop-incomplete', 'mo2-open')
    if ($RootBuilderRecovery) { $acceptedStatuses += @('mo2-closed', 'rootbuilder-recovery-required', 'launching', 'opening', 'open-incomplete') }
    if ([string]$lockData.status -notin $acceptedStatuses) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ lock = $owned } -Errors @("Session status '$($lockData.status)' cannot be launched.")
    }

    $resumeExistingMO2 = [string]$lockData.status -in @('game-stopped', 'stop-incomplete', 'mo2-open')
    $requireSKSE = $lockData.PSObject.Properties['requirements'] -and $lockData.requirements.PSObject.Properties['skseLoader'] -and [bool]$lockData.requirements.skseLoader
    $validation = Invoke-MO2Validate -Config $Config -Profile ([string]$lockData.profile) -Executable ([string]$lockData.executable) -RequireSKSE:$requireSKSE -RequireClosed:(-not $resumeExistingMO2) -OwnedSessionId $SessionId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned } -Warnings $validation.warnings -Errors $validation.errors
    }
    if ($resumeExistingMO2) {
        $mo2Processes = @($validation.data.processes.mo2)
        $ownerPid = if ($lockData.PSObject.Properties['ownerPid']) { [int]$lockData.ownerPid } else { 0 }
        $ownedMO2 = @($mo2Processes | Where-Object { [int]$_.id -eq $ownerPid })
        if ($validation.data.processes.game.Count -gt 0 -or $mo2Processes.Count -ne 1 -or $ownedMO2.Count -ne 1) {
            return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'blocked' -Data @{ processes = $validation.data.processes; lock = $owned } -Errors @('Resume requires no game process and exactly one MO2 process matching the session owner PID.')
        }
    }

    $mo2Path = [string]$validation.data.config.mo2Executable
    $arguments = @('--profile', [string]$lockData.profile, 'run', '--executable', [string]$lockData.executable)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-MO2CommandLineArgument ([string]$_) }) -join ' '
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'dry-run' -Data @{ path = $mo2Path; arguments = $arguments; argumentLine = $argumentLine; workingDirectory = (Split-Path -Parent $mo2Path); sessionId = $SessionId; startOnly = [bool]$StartOnly; rootBuilderRecovery = [bool]$RootBuilderRecovery }
    }

    $launchStartedPath = Join-Path ([string]$lockData.sessionPath) 'mo2-launch-started.json'
    $launchStarted = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $SessionId
        mo2Path = $mo2Path
        arguments = $arguments
        argumentLine = $argumentLine
        timeoutSeconds = $TimeoutSeconds
        startOnly = [bool]$StartOnly
        rootBuilderRecovery = [bool]$RootBuilderRecovery
        requestedPid = $null
        startedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-MO2JsonAtomic -Path $launchStartedPath -Value $launchStarted
    $process = Start-Process -FilePath $mo2Path -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $mo2Path) -WindowStyle Hidden -PassThru
    $launchStarted.requestedPid = $process.Id
    Write-MO2JsonAtomic -Path $launchStartedPath -Value $launchStarted
    $lockData.status = 'launching'
    if (-not $resumeExistingMO2) {
        if ($lockData.PSObject.Properties['ownerPid']) { $lockData.ownerPid = $process.Id } else { $lockData | Add-Member -NotePropertyName ownerPid -NotePropertyValue $process.Id }
    }
    if ($lockData.PSObject.Properties['latestLauncherPid']) { $lockData.latestLauncherPid = $process.Id } else { $lockData | Add-Member -NotePropertyName latestLauncherPid -NotePropertyValue $process.Id }
    if ($lockData.PSObject.Properties['launchedUtc']) { $lockData.launchedUtc = [DateTime]::UtcNow.ToString('o') } else { $lockData | Add-Member -NotePropertyName launchedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $lockData
    $lockData = $owned.data

    $manifestPath = Join-Path ([string]$lockData.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest.status = 'launching'
    $manifest.launcherPid = $process.Id
    $manifest.launchedUtc = $lockData.launchedUtc
    if ($manifest.PSObject.Properties['launchStartedReceiptPath']) { $manifest.launchStartedReceiptPath = $launchStartedPath } else { $manifest | Add-Member -NotePropertyName launchStartedReceiptPath -NotePropertyValue $launchStartedPath }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
    if ($StartOnly) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'launching' -Data @{ sessionId = $SessionId; launcherPid = $process.Id; launchStartedReceiptPath = $launchStartedPath; sessionPath = $lockData.sessionPath; pollWith = "status -SessionId $SessionId"; rootBuilderRecovery = [bool]$RootBuilderRecovery }
    }

    $primaryGameProcessName = [string]@($Config.mo2.gameProcessNames)[0]
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $status = $null
    $blockingDialog = $null
    do {
        Start-Sleep -Milliseconds 500
        $status = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$lockData.profile) -RequestedExecutable ([string]$lockData.executable)
        if (@($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0) { break }
        $blockingDialog = @(Get-MO2WindowSnapshot -Processes @($status.processes.mo2) | Where-Object { $_.dialogKind -eq 'failed-to-write-settings' } | Select-Object -First 1)
        if ($blockingDialog.Count -gt 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $gameObserved = @($status.processes.game | Where-Object { $_.name -ieq $primaryGameProcessName }).Count -gt 0
    $ownerResolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($status.processes.mo2) -AdoptDetachedOwner
    if ($ownerResolution.adopted) {
        $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
        $lockData = $owned.data
    }
    if ($gameObserved) { $null = Set-MO2OwnedSessionGameProcesses -Owned $owned -Processes @($status.processes.game) }
    $lockData.status = if ($gameObserved) { 'running' } elseif ($blockingDialog.Count -gt 0) { 'launch-blocked-dialog' } else { 'launch-failed' }
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $lockData
    $lockData = $owned.data
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest.status = $lockData.status
    $manifest.launcherPid = $process.Id
    $manifest.launchedUtc = $lockData.launchedUtc
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    if ($blockingDialog.Count -gt 0) {
        $dialogReceiptPath = Join-Path ([string]$lockData.sessionPath) 'mo2-launch-blocked-dialog.json'
        $dialogReceipt = [pscustomobject][ordered]@{
            contractVersion = $script:MO2ControlContractVersion
            sessionId = $SessionId
            classification = 'failed-to-write-settings'
            observedUtc = [DateTime]::UtcNow.ToString('o')
            dialog = $blockingDialog[0]
            processes = $status.processes
            safeCloseAction = 'close or stop will acknowledge only the exact OK button, then continue cooperative shutdown'
        }
        Write-MO2JsonAtomic -Path $dialogReceiptPath -Value $dialogReceipt
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'launch-blocked-dialog' -Data @{ sessionId = $SessionId; launcherPid = $process.Id; launchStartedReceiptPath = $launchStartedPath; dialogReceiptPath = $dialogReceiptPath; dialog = $blockingDialog[0]; processes = $status.processes; sessionPath = $lockData.sessionPath } -Errors @('MO2 reported Failed to write settings. The launch was classified immediately; use close/stop to acknowledge the exact dialog and shut down cooperatively.')
    }

    if (-not $gameObserved) {
        return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $false -State 'launch-failed' -Data @{ launcherPid = $process.Id; launcherExited = $process.HasExited; launcherExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; sessionPath = $lockData.sessionPath; launchStartedReceiptPath = $launchStartedPath } -Errors @("The primary game process '$primaryGameProcessName' was not observed within $TimeoutSeconds seconds. A launcher helper exit is non-terminal because an existing MO2 instance can accept the request asynchronously.")
    }
    return New-MO2ActionResult -Config $Config -Command 'launch' -Ok $true -State 'game-running' -Data @{ launcherPid = $process.Id; ownerPid = $ownerResolution.ownerPid; ownershipResolution = $ownerResolution; primaryGameProcessName = $primaryGameProcessName; processes = $status.processes; sessionPath = $lockData.sessionPath; launchStartedReceiptPath = $launchStartedPath; rootBuilderRecovery = [bool]$RootBuilderRecovery }
}

function Invoke-MO2RecoverRootBuilder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0 -or $inspection.processes.mo2.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $false -State 'blocked' -Data @{ sessionId = $SessionId; processes = $inspection.processes; sessionPath = $owned.data.sessionPath } -Errors @('RootBuilder recovery requires MO2 and the game/loader to be closed. Use close or recover-close first.')
    }
    $buildData = @($inspection.rootBuilder.active | Where-Object { [IO.Path]::GetFileName([string]$_.path) -ieq 'BuildData.json' })
    if ($buildData.Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $true -State 'no-recovery-required' -Data @{ sessionId = $SessionId; activeBuildData = @(); sessionPath = $owned.data.sessionPath }
    }
    if ($buildData.Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'recover-rootbuilder' -Ok $false -State 'blocked' -Data @{ sessionId = $SessionId; activeBuildData = @($buildData | ForEach-Object path); sessionPath = $owned.data.sessionPath } -Errors @('RootBuilder recovery requires exactly one active BuildData.json; multiple deployment records require manual classification.')
    }

    if (-not $WhatIf) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'rootbuilder-recovery-required' -TimestampProperty 'recoveryStartedUtc'
    }
    $result = Invoke-MO2Launch -Config $Config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -StartOnly:$StartOnly -RootBuilderRecovery -WhatIf:$WhatIf
    $result.command = 'recover-rootbuilder'
    $result.data | Add-Member -NotePropertyName recovery -NotePropertyValue ([pscustomobject][ordered]@{
        buildDataPath = [string]$buildData[0].path
        buildDataBytes = [long]$buildData[0].bytes
        strategy = 'one exact-profile launch followed by normal stop/Unlock so RootBuilder can restore its recorded deployment'
        destructiveCleanup = $false
    }) -Force
    return $result
}

function Invoke-MO2Open {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$StartOnly,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false } -Errors @('Opening visible MO2 requires execution as the logged-on user on the interactive desktop. Rerun this exact command through the approved elevated execution path.')
    }
    if ([string]$owned.data.status -notin @('prepared', 'mo2-closed', 'stopped')) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'blocked' -Data @{ lock = $owned } -Errors @("Session status '$($owned.data.status)' cannot open MO2.")
    }
    $validation = Invoke-MO2Validate -Config $Config -Profile ([string]$owned.data.profile) -Executable ([string]$owned.data.executable) -RequireClosed -OwnedSessionId $SessionId
    if (-not $validation.ok) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'blocked' -Data @{ validation = $validation; lock = $owned } -Warnings $validation.warnings -Errors $validation.errors
    }

    $mo2Path = [string]$validation.data.config.mo2Executable
    $arguments = @('--profile', [string]$owned.data.profile)
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-MO2CommandLineArgument ([string]$_) }) -join ' '
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; path = $mo2Path; arguments = $arguments; argumentLine = $argumentLine; workingDirectory = (Split-Path -Parent $mo2Path); wouldOpenGame = $false; startOnly = [bool]$StartOnly }
    }

    $process = Start-Process -FilePath $mo2Path -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $mo2Path) -PassThru
    $openStartedPath = Join-Path ([string]$owned.data.sessionPath) 'mo2-open-started.json'
    $openStarted = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $SessionId
        requestedPid = $process.Id
        mo2Path = $mo2Path
        arguments = $arguments
        argumentLine = $argumentLine
        timeoutSeconds = $TimeoutSeconds
        startedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-MO2JsonAtomic -Path $openStartedPath -Value $openStarted
    Set-MO2OwnedSessionStatus -Owned $owned -Status 'opening' -TimestampProperty 'openedUtc'
    if ($StartOnly) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'opening' -Data @{ sessionId = $SessionId; requestedPid = $process.Id; openStartedReceiptPath = $openStartedPath; sessionPath = $owned.data.sessionPath; pollWith = "status -SessionId $SessionId"; gameOpened = $false }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observed = $null
    do {
        Start-Sleep -Milliseconds 250
        $records = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        $observed = @($records | Where-Object { [int]$_.id -eq $process.Id }) | Select-Object -First 1
        if ($observed) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $observed) {
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'open-failed' -Data @{ requestedPid = $process.Id; launcherExited = $process.HasExited; launcherExitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); openStartedReceiptPath = $openStartedPath; processes = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames)); sessionPath = $owned.data.sessionPath } -Errors @('The exact newly started MO2 process was not observed within the bounded timeout. The durable start receipt and opening session state allow a later status or recover-close call to adopt the exact process.')
    }
    Assert-MO2ExactProcessTargets -Config $Config -Processes @($observed)
    $null = Set-MO2OwnedSessionOwner -Owned $owned -ProcessRecord $observed -Reason 'exact MO2 process observed after open'
    $visibleMainWindow = $null
    do {
        # Process.MainWindowHandle is not a readiness signal: during startup it
        # can point at MessageDialog, the VFS Unlock prompt, or even a tooltip.
        # Only MO2's stable UIA identity proves that its actual main window is
        # ready. Other windows remain available to cooperative close/recovery.
        $visibleMainWindow = @(Get-MO2WindowSnapshot -Processes @($observed) | Where-Object {
            $_.visible -and $_.automationAvailable -and $_.automationId -eq 'MainWindow'
        }) | Select-Object -First 1
        if ($visibleMainWindow) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $visibleMainWindow) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'open-incomplete' -TimestampProperty 'openedUtc'
        return New-MO2ActionResult -Config $Config -Command 'open' -Ok $false -State 'open-incomplete' -Data @{ ownerPid = $process.Id; openStartedReceiptPath = $openStartedPath; process = $observed; windows = @(Get-MO2WindowSnapshot -Processes @($observed)); sessionPath = $owned.data.sessionPath } -Errors @('The exact MO2 process started, but its visible MainWindow was not ready within the bounded timeout. The durable start receipt and adopted owner PID remain available for cooperative recovery.')
    }
    Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-open' -TimestampProperty 'openedUtc'
    return New-MO2ActionResult -Config $Config -Command 'open' -Ok $true -State 'mo2-open' -Data @{ sessionId = $SessionId; ownerPid = $process.Id; openStartedReceiptPath = $openStartedPath; process = $observed; mainWindow = $visibleMainWindow; sessionPath = $owned.data.sessionPath; gameOpened = $false }
}

function Invoke-MO2Close {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; lock = $owned } -Errors @('MO2-only close refuses while a game or loader process is running. Use stop for the full owned chain.')
    }

    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($inspection.processes.mo2) -AdoptDetachedOwner
    $ownerPid = [int]$resolution.ownerPid
    $targets = @($resolution.targets)
    if (-not $resolution.ok) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid; ownershipResolution = $resolution; lock = $owned } -Errors @('Cooperative close could not prove a unique MO2 process owned by this session.')
    }
    if (-not $WhatIf -and $targets.Count -gt 0 -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Cooperative MO2 close requires execution as the logged-on user on the interactive desktop. Rerun this exact command through the approved elevated execution path.')
    }
    if ($targets.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    }
    $windows = @(Get-MO2WindowSnapshot -Processes $targets)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; targets = $targets; windows = $windows; ownershipResolution = $resolution; alreadyClosed = $targets.Count -eq 0; wouldInvokeExactControls = @('File', 'Exit', 'Unlock'); wouldRequestModalWindowClose = $targets.Count -gt 0; forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    if ($targets.Count -eq 0) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'mo2-closed' -TimestampProperty 'closedUtc'
        return New-MO2ActionResult -Config $Config -Command 'close' -Ok $true -State 'mo2-closed' -Data @{ sessionId = $SessionId; alreadyClosed = $true; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath }
    }

    $close = Invoke-MO2CooperativeClose -Config $Config -InitialProcesses $targets -EvidenceDirectory ([string]$owned.data.sessionPath) -TimeoutSeconds $TimeoutSeconds
    $status = if ($close.closed) { 'mo2-closed' } else { 'close-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'closedUtc'
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-close.json') -Value $close
    return New-MO2ActionResult -Config $Config -Command 'close' -Ok $close.closed -State $status -Data @{ sessionId = $SessionId; ownershipResolution = $resolution; close = $close; sessionPath = $owned.data.sessionPath } -Errors $(if ($close.closed) { @() } else { @('MO2 still owns one or more exact target processes after cooperative dialogue resolution; no force termination was attempted.') })
}

function Invoke-MO2RecoverClose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$AccessId,
        [string]$Label = 'recovery-close',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $inspection = Get-MO2InspectionData -Config $Config
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @('Recovery close refuses while a game or loader process is running.')
    }
    $explicitAccess = -not [string]::IsNullOrWhiteSpace($AccessId)
    $accessLock = $null
    if ($inspection.sessionLock.exists) {
        if (-not $explicitAccess) {
            return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ lock = $inspection.sessionLock; processes = $inspection.processes } -Errors @('A session lock already exists. Pass its exact access-only AccessId, use close with its exact SessionId, or classify the stale lock before recovery.')
        }
        $accessLock = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
        if (-not [string]::IsNullOrWhiteSpace([string]$accessLock.sessionId)) {
            return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ access = Get-MO2AccessLeaseSummary -Lock $accessLock; processes = $inspection.processes } -Errors @('The access lease already has a bound session. Use close with that exact SessionId.')
        }
    }
    elseif ($explicitAccess) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @("Access lease '$AccessId' does not exist.")
    }
    $targets = @($inspection.processes.mo2)
    if ($targets.Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $true -State 'already-closed' -Data @{ accessId = $AccessId; accessRetained = $explicitAccess; targets = @(); forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    if ($targets.Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'blocked' -Data @{ targets = $targets } -Errors @('Recovery close requires exactly one configured MO2 process; multiple instances require manual classification.')
    }
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $false -State 'interactive-desktop-required' -Data @{ processes = $inspection.processes; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Recovery close requires execution as the logged-on user on the interactive desktop. No recovery session or lock was created; rerun through the approved elevated execution path.')
    }

    $safeLabel = ConvertTo-MO2SafeLabel $Label
    $sessionId = '{0}-{1}-{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $safeLabel, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $sessionPath = Join-Path (Resolve-MO2ControlPath ([string]$Config.storage.sessionStaging)) $sessionId
    $lockPath = Resolve-MO2ControlPath ([string]$Config.session.lockFile)
    $createdUtc = [DateTime]::UtcNow.ToString('o')
    if (-not $explicitAccess) {
        $AccessId = 'access-{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0, 12))
    }
    $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath -WhatIf
    $profileDirectory = Join-Path (Resolve-MO2ControlPath ([string]$Config.mo2.profilesDirectory)) ([string]$inspection.requested.profile)
    $manifest = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        sessionId = $sessionId
        label = $safeLabel
        createdUtc = $createdUtc
        status = 'recovery-closing'
        profile = [string]$inspection.requested.profile
        profileName = [string]$inspection.requested.profile
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = [string]$inspection.requested.executable
        mo2Path = [string]$inspection.config.mo2Executable
        ownerPid = [int]$targets[0].id
        recovery = $true
        accessId = $AccessId
        acquisitionMode = $(if ($explicitAccess) { 'explicit-access' } else { 'implicit-session' })
        processesBefore = $inspection.processes
        windowsBefore = @(Get-MO2WindowSnapshot -Processes $targets)
        controllerPath = [string]$controller.controllerPath
        controllerConfigPath = [string]$controller.configPath
        controllerReceiptPath = [string]$controller.receiptPath
    }
    $lock = [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        accessId = $AccessId
        acquisitionMode = $(if ($explicitAccess) { 'explicit-access' } else { 'implicit-session' })
        label = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['label']) { [string]$accessLock.data.label } else { $safeLabel })
        requestedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['requestedUtc']) { [string]$accessLock.data.requestedUtc } else { $createdUtc })
        lastRenewedUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['lastRenewedUtc']) { [string]$accessLock.data.lastRenewedUtc } else { $createdUtc })
        estimatedDurationMinutes = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedDurationMinutes']) { $accessLock.data.estimatedDurationMinutes } else { $null })
        estimatedReleaseUtc = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['estimatedReleaseUtc']) { $accessLock.data.estimatedReleaseUtc } else { $null })
        ownerRequestPid = $(if ($explicitAccess -and $accessLock.data.PSObject.Properties['ownerRequestPid']) { $accessLock.data.ownerRequestPid } else { $PID })
        generation = $(if ($explicitAccess) { Get-MO2NextLeaseGeneration -Lease $accessLock.data } else { 1L })
        sessionId = $sessionId
        sessionPath = $sessionPath
        status = 'recovery-closing'
        createdUtc = $createdUtc
        profile = [string]$inspection.requested.profile
        profileName = [string]$inspection.requested.profile
        profileDirectory = $profileDirectory
        modListPath = (Join-Path $profileDirectory 'modlist.txt')
        executable = [string]$inspection.requested.executable
        controllerPath = [string]$controller.controllerPath
        ownerPid = [int]$targets[0].id
        recovery = $true
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $true -State 'dry-run' -Data @{ session = $manifest; lockPath = $lockPath; sessionPath = $sessionPath; accessId = $AccessId; explicitAccess = $explicitAccess; controller = $controller; controllerPath = [string]$controller.controllerPath; wouldBindAccessLock = $explicitAccess; targets = $targets; wouldInvokeExactControls = @('File', 'Exit', 'Unlock'); wouldRequestModalWindowClose = $true; forceTermination = $false; unrelatedProcessesTouched = @() }
    }

    New-Item -ItemType Directory -Path $sessionPath -ErrorAction Stop | Out-Null
    try {
        $controller = New-MO2DurableSessionController -Config $Config -SessionPath $sessionPath
        Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $manifest -CreateNew
        Invoke-WithMO2LeaseTransitionLock -LockPath $lockPath -Action {
            if ($explicitAccess) {
                $currentAccess = Get-MO2OwnedAccessLease -Config $Config -AccessId $AccessId
                if (-not [string]::IsNullOrWhiteSpace([string]$currentAccess.sessionId)) {
                    throw 'The access lease acquired a session before recovery close could bind it.'
                }
                $bound = $currentAccess.data
                foreach ($propertyName in @('sessionId', 'sessionPath', 'status', 'createdUtc', 'profile', 'profileName', 'profileDirectory', 'modListPath', 'executable', 'controllerPath', 'ownerPid', 'recovery')) {
                    $bound | Add-Member -NotePropertyName $propertyName -NotePropertyValue $lock.$propertyName -Force
                }
                $bound | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $currentAccess.data) -Force
                Write-MO2JsonAtomic -Path $lockPath -Value $bound
            }
            else {
                Write-MO2JsonAtomic -Path $lockPath -Value $lock -CreateNew
            }
        } | Out-Null
    }
    catch {
        throw "Failed to acquire recovery session '$sessionId'. Evidence is retained at '$sessionPath'. $($_.Exception.Message)"
    }

    $close = Invoke-MO2CooperativeClose -Config $Config -InitialProcesses $targets -EvidenceDirectory $sessionPath -TimeoutSeconds $TimeoutSeconds
    $owned = Get-MO2OwnedSession -Config $Config -SessionId $sessionId
    $status = if ($close.closed) { 'mo2-closed' } else { 'close-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'closedUtc'
    Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'mo2-close.json') -Value $close
    return New-MO2ActionResult -Config $Config -Command 'recover-close' -Ok $close.closed -State $status -Data @{ sessionId = $sessionId; accessId = $AccessId; explicitAccess = $explicitAccess; lockPath = $lockPath; sessionPath = $sessionPath; controller = $controller; controllerPath = [string]$controller.controllerPath; close = $close; releaseRequired = $close.closed } -Errors $(if ($close.closed) { @() } else { @('MO2 remains after cooperative recovery close. The recovery lock and evidence were retained; no force termination was attempted.') })
}

function Wait-MO2RetainedProcessStability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Owned,
        [Parameter(Mandatory)]$InitialInspection,
        [ValidateRange(250, 10000)][int]$StabilityMilliseconds = 2000,
        [ValidateRange(50, 1000)][int]$PollMilliseconds = 250,
        [scriptblock]$InspectionFactory
    )

    $samples = [Collections.Generic.List[object]]::new()
    $current = $InitialInspection
    $ownerPid = if ($Owned.data.PSObject.Properties['ownerPid']) { [int]$Owned.data.ownerPid } else { 0 }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($StabilityMilliseconds)
    do {
        $mo2 = @($current.processes.mo2)
        $ownerPresent = $ownerPid -gt 0 -and @($mo2 | Where-Object { [int]$_.id -eq $ownerPid }).Count -eq 1
        $samples.Add([pscustomobject][ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            mo2ProcessIds = @($mo2 | ForEach-Object { [int]$_.id })
            ownerPid = $ownerPid
            ownerPresent = $ownerPresent
        })
        if (-not $ownerPresent) { break }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
        $current = if ($InspectionFactory) {
            & $InspectionFactory
        }
        else {
            Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$Owned.data.profile) -RequestedExecutable ([string]$Owned.data.executable)
        }
    } while ($true)

    $last = $samples[$samples.Count - 1]
    return [pscustomobject][ordered]@{
        stable = [bool]$last.ownerPresent -and [DateTime]::UtcNow -ge $deadline
        ownerPid = $ownerPid
        stabilityMilliseconds = $StabilityMilliseconds
        pollMilliseconds = $PollMilliseconds
        samples = @($samples)
        finalInspection = $current
    }
}

function Invoke-MO2StopGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false } -Errors @('Graceful game close requires execution as the logged-on user on the interactive desktop.')
    }
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $targets = @($before.processes.game)
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestClose = $targets; wouldLeaveMO2Running = $true; forceTermination = $false }
    }

    foreach ($record in $targets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if ($process) { $null = $process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    $closed = $after.processes.game.Count -eq 0
    $retention = $null
    if ($closed) {
        $retention = Wait-MO2RetainedProcessStability -Config $Config -Owned $owned -InitialInspection $after
        $after = $retention.finalInspection
        Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-retention-stability.json') -Value $retention
    }
    $dialogCleanup = $null
    $dialogNeedsAttention = $false
    if ($closed -and $after.processes.mo2.Count -gt 0) {
        $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($after.processes.mo2) -AdoptDetachedOwner
        if ($resolution.ok) {
            $dialogCleanup = Invoke-MO2RetainedSessionDialogCleanup -Config $Config -Processes @($resolution.targets)
            $dialogNeedsAttention = -not $dialogCleanup.cleared -or @($dialogCleanup.needsAttention).Count -gt 0
        }
        else {
            $dialogCleanup = [pscustomobject][ordered]@{ cleared = $false; ownershipResolution = $resolution; needsAttention = @('Could not prove one exact retained MO2 owner for dialog cleanup.') }
            $dialogNeedsAttention = $true
        }
        Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-retained-dialog-cleanup.json') -Value $dialogCleanup
    }
    $mo2Retained = $closed -and $retention -and $retention.stable
    $owned.data.status = if (-not $closed) { 'game-stop-incomplete' } elseif (-not $mo2Retained) { 'mo2-exited-after-game-stop' } elseif ($dialogNeedsAttention) { 'game-stopped-needs-attention' } else { 'game-stopped' }
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $owned.data
    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest.status = $owned.data.status
    $manifest.stoppedUtc = [DateTime]::UtcNow.ToString('o')
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

    $ok = $closed -and $mo2Retained -and -not $dialogNeedsAttention
    return New-MO2ActionResult -Config $Config -Command 'stop-game' -Ok $ok -State $owned.data.status -Data @{ before = $before.processes; after = $after.processes; mo2Retained = $mo2Retained; retention = $retention; releaseRequired = $closed -and -not $mo2Retained; retainedDialogCleanup = $dialogCleanup; forceTermination = $false; sessionPath = $owned.data.sessionPath } -Errors $(
        if (-not $closed) { @('The game did not accept a graceful close request; no force termination was attempted.') }
        elseif (-not $mo2Retained) { @('The game stopped, but the exact session-owned MO2 process exited during the retention stability window. Release this session before requesting another; controlled relaunch is unavailable.') }
        elseif ($dialogNeedsAttention) { @('The game stopped, but an unclassified or uncleared retained MO2 dialog needs attention; no unrelated window was touched.') }
        else { @() }
    )
}

function Invoke-MO2TerminateGame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )
    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes @($inspection.processes.mo2) -AdoptDetachedOwner
    if (-not $resolution.ok -or @($resolution.targets).Count -ne 1) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ ownershipResolution=$resolution; processes=$inspection.processes } -Errors @('Exact-session game termination requires one proven MO2 runtime owner so RootBuilder can restore afterward.')
    }
    if (-not $owned.data.PSObject.Properties['gameProcesses'] -or @($owned.data.gameProcesses).Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ processes=$inspection.processes } -Errors @('The session has no launch-recorded game/loader process identities; refusing process-name termination.')
    }
    $targets = @()
    foreach ($recorded in @($owned.data.gameProcesses)) {
        $current = @($inspection.processes.game | Where-Object { [int]$_.id -eq [int]$recorded.id })
        if ($current.Count -eq 0) { continue }
        if ($current.Count -ne 1 -or [string]$current[0].name -cne [string]$recorded.name -or [string]$current[0].path -cne [string]$recorded.path -or [string]$current[0].startTime -cne [string]$recorded.startTime) {
            return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ recorded=$recorded; current=$current } -Errors @('A recorded game PID no longer has the exact recorded name, path, and start time; refusing possible PID reuse.')
        }
        $targets += $current[0]
    }
    if ($inspection.processes.game.Count -gt $targets.Count) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'blocked' -Data @{ recorded=$owned.data.gameProcesses; current=$inspection.processes.game; targets=$targets } -Errors @('An unrecorded game/loader process is present; refusing partial process-name termination.')
    }
    if ($targets.Count -eq 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $true -State 'game-already-stopped' -Data @{ sessionId=$SessionId; mo2Retained=$true; targets=@(); forceTermination=$false }
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $true -State 'dry-run' -Data @{ sessionId=$SessionId; wouldForceTerminateExactRecordedGameProcesses=$targets; wouldRetainMO2=$resolution.targets; wouldInvokeExactControls=@('Unlock'); wouldRequireBuildDataRemoval=$true }
    }
    if (-not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId=$SessionId; targets=$targets } -Errors @('Exact Unlock handling after game termination requires the logged-on interactive desktop.')
    }
    foreach ($target in $targets) { Stop-Process -Id ([int]$target.id) -Force -ErrorAction Stop }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $afterTermination = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if (@($afterTermination.processes.game | Where-Object { @($targets.id) -contains [int]$_.id }).Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($afterTermination.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $false -State 'game-terminate-incomplete' -Data @{ targets=$targets; remaining=$afterTermination.processes.game } -Errors @('One or more exact recorded game processes remained after termination.')
    }
    $remainingSeconds = [math]::Max(1, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
    $rootBuilder = Invoke-MO2UnlockOnly -Config $Config -MO2Processes @($resolution.targets) -TimeoutSeconds $remainingSeconds
    $success = $rootBuilder.restored -and @($rootBuilder.gameProcesses).Count -eq 0 -and @($rootBuilder.mo2Processes | Where-Object { [int]$_.id -eq [int]$resolution.ownerPid }).Count -eq 1
    $state = if ($success) { 'game-terminated-rootbuilder-restored' } else { 'rootbuilder-recovery-pending' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $state -TimestampProperty 'gameTerminatedUtc'
    $receipt = [pscustomobject][ordered]@{ contractVersion=$script:MO2ControlContractVersion; sessionId=$SessionId; terminatedProcesses=$targets; rootBuilder=$rootBuilder; completedUtc=[DateTime]::UtcNow.ToString('o') }
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-terminate-game.json') -Value $receipt
    return New-MO2ActionResult -Config $Config -Command 'terminate-game' -Ok $success -State $state -Data @{ sessionId=$SessionId; terminatedProcesses=$targets; mo2Retained=$success; rootBuilder=$rootBuilder; receiptPath=(Join-Path ([string]$owned.data.sessionPath) 'mo2-terminate-game.json') } -Errors $(if ($success) { @() } else { @('The game ended, but MO2 ownership and RootBuilder BuildData cleanup were not both verified before the timeout.') })
}

function Invoke-MO2Stop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 90,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    if (-not $WhatIf -and -not (Test-MO2InteractiveDesktop)) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'interactive-desktop-required' -Data @{ sessionId = $SessionId; requiresInteractiveDesktop = $true; forceTermination = $false; unrelatedProcessesTouched = @() } -Errors @('Full graceful stop requires execution as the logged-on user on the interactive desktop.')
    }
    $before = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $gameTargets = @($before.processes.game)
    $mo2Targets = @($before.processes.mo2)
    $resolution = Resolve-MO2OwnedProcessTarget -Config $Config -Owned $owned -Processes $mo2Targets -AdoptDetachedOwner
    $ownerPid = [int]$resolution.ownerPid
    $ownedMO2 = @($resolution.targets)
    if (-not $resolution.ok) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'blocked' -Data @{ processes = $before.processes; ownerPid = $ownerPid; ownershipResolution = $resolution; lock = $owned } -Errors @('Full stop could not prove or adopt exactly one MO2 runtime owner.')
    }
    if ($ownedMO2.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $ownedMO2
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldRequestGameClose = $gameTargets; wouldCooperativelyCloseMO2 = $ownedMO2; mo2Windows = @(Get-MO2WindowSnapshot -Processes $ownedMO2); wouldInvokeExactControls = @('File', 'Exit', 'Unlock'); forceTermination = $false; unrelatedProcessesTouched = @() }
    }

    foreach ($record in $gameTargets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        if ($process) { $null = $process.CloseMainWindow() }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $after = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
        if ($after.processes.game.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($after.processes.game.Count -gt 0) {
        Set-MO2OwnedSessionStatus -Owned $owned -Status 'game-stop-incomplete' -TimestampProperty 'stoppedUtc'
        return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $false -State 'game-stop-incomplete' -Data @{ before = $before.processes; after = $after.processes; mo2CloseAttempted = $false; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath } -Errors @('The game did not accept a graceful close request, so MO2 cooperative close was not attempted.')
    }

    $remainingSeconds = [math]::Max(1, [int][math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
    $currentMO2 = @($after.processes.mo2 | Where-Object { [int]$_.id -eq $ownerPid })
    $close = if ($currentMO2.Count -gt 0) {
        Invoke-MO2CooperativeClose -Config $Config -InitialProcesses $currentMO2 -EvidenceDirectory ([string]$owned.data.sessionPath) -TimeoutSeconds $remainingSeconds
    }
    else {
        [pscustomobject][ordered]@{ closed = $true; targetProcessIds = @(); beforeWindows = @(); actions = @(); remaining = @(); remainingWindows = @(); forceTermination = $false; unrelatedProcessesTouched = @() }
    }
    $final = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $closed = $final.processes.game.Count -eq 0 -and $final.processes.mo2.Count -eq 0 -and $close.closed
    $status = if ($closed) { 'stopped' } else { 'stop-incomplete' }
    Set-MO2OwnedSessionStatus -Owned $owned -Status $status -TimestampProperty 'stoppedUtc'
    Write-MO2JsonAtomic -Path (Join-Path ([string]$owned.data.sessionPath) 'mo2-stop.json') -Value $close

    return New-MO2ActionResult -Config $Config -Command 'stop' -Ok $closed -State $status -Data @{ before = $before.processes; afterGameClose = $after.processes; after = $final.processes; mo2Close = $close; forceTermination = $false; unrelatedProcessesTouched = @(); sessionPath = $owned.data.sessionPath } -Errors $(if ($closed) { @() } else { @('One or more exact owned processes remained after graceful game close and cooperative MO2 dialogue resolution; no force termination was attempted.') })
}

function Invoke-MO2Release {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    $closed = $inspection.processes.game.Count -eq 0 -and $inspection.processes.mo2.Count -eq 0
    if (-not $closed) {
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; lock = $owned } -Errors @('The session cannot be released while MO2 or the game is running.')
    }
    if ($WhatIf) {
        $wouldRetainAccess = $owned.acquisitionMode -eq 'explicit-access'
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; lockPath = $owned.path; sessionPath = $owned.data.sessionPath; accessId = $owned.accessId; wouldRemoveLock = -not $wouldRetainAccess; wouldRetainAccess = $wouldRetainAccess; wouldRetainSessionEvidence = $true }
    }

    $sessionPath = [string]$owned.data.sessionPath
    return Invoke-WithMO2LeaseTransitionLock -LockPath $owned.path -Action {
        $current = Get-MO2SessionLockRecord -Path $owned.path
        if (-not $current.valid -or $current.sessionId -ne $SessionId) {
            return New-MO2ActionResult -Config $Config -Command 'release' -Ok $false -State 'blocked' -Data @{ lock = $current; sessionPath = $sessionPath } -Errors @('Lock ownership changed before release; the lock was retained.')
        }

        $manifestPath = Join-Path $sessionPath 'session.json'
        $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.status = 'released'
        $manifest | Add-Member -NotePropertyName releasedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-MO2JsonAtomic -Path $manifestPath -Value $manifest

        if ($current.acquisitionMode -eq 'explicit-access') {
            $accessOnly = $current.data
            $accessOnly.status = 'access-held'
            $accessOnly.sessionId = $null
            $accessOnly.sessionPath = $null
            $accessOnly | Add-Member -NotePropertyName lastSessionId -NotePropertyValue $SessionId -Force
            $accessOnly | Add-Member -NotePropertyName lastSessionReleasedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
            $accessOnly | Add-Member -NotePropertyName generation -NotePropertyValue (Get-MO2NextLeaseGeneration -Lease $current.data) -Force
            if ($accessOnly.PSObject.Properties['ownerPid']) { $accessOnly.PSObject.Properties.Remove('ownerPid') }
            Write-MO2JsonAtomic -Path $owned.path -Value $accessOnly
            return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'session-released-access-retained' -Data @{ sessionId = $SessionId; accessId = $current.accessId; lockPath = $owned.path; sessionPath = $sessionPath; lockRemoved = $false; accessRetained = $true; sessionRetained = $true; releaseAccessRequired = $true }
        }
        Remove-Item -LiteralPath $owned.path -Force
        return New-MO2ActionResult -Config $Config -Command 'release' -Ok $true -State 'released' -Data @{ sessionId = $SessionId; accessId = $current.accessId; lockPath = $owned.path; sessionPath = $sessionPath; lockRemoved = $true; accessRetained = $false; sessionRetained = $true }
    }
}

function Invoke-MO2Terminate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionId,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
        [switch]$WhatIf
    )

    $owned = Get-MO2OwnedSession -Config $Config -SessionId $SessionId
    $inspection = Get-MO2InspectionData -Config $Config -RequestedProfile ([string]$owned.data.profile) -RequestedExecutable ([string]$owned.data.executable)
    if ($inspection.processes.game.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while a game/loader process is running.')
    }
    $rootBuilderData = Resolve-MO2ControlPath ([string]$Config.mo2.rootBuilderDataDirectory)
    $activeBuildData = @()
    if (Test-Path -LiteralPath $rootBuilderData -PathType Container) {
        $activeBuildData = @(Get-ChildItem -LiteralPath $rootBuilderData -Filter 'BuildData.json' -File -Recurse -ErrorAction Stop)
    }
    if ($activeBuildData.Count -gt 0) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ buildData = @($activeBuildData.FullName); processes = $inspection.processes } -Errors @('Refusing forced MO2 termination while RootBuilder BuildData.json remains active.')
    }
    $ownerPid = if ($owned.data.PSObject.Properties['ownerPid']) { [int]$owned.data.ownerPid } else { 0 }
    $targets = @($inspection.processes.mo2 | Where-Object { [int]$_.id -eq $ownerPid })
    if ($inspection.processes.mo2.Count -gt 0 -and ($ownerPid -le 0 -or $targets.Count -ne 1 -or $inspection.processes.mo2.Count -ne 1)) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $false -State 'blocked' -Data @{ processes = $inspection.processes; ownerPid = $ownerPid } -Errors @('Forced termination requires exactly one configured MO2 process matching the session owner PID.')
    }
    if ($targets.Count -gt 0) {
        Assert-MO2ExactProcessTargets -Config $Config -Processes $targets
    }
    if ($WhatIf) {
        return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $true -State 'dry-run' -Data @{ sessionId = $SessionId; wouldForceTerminate = @($targets); gameProcesses = @(); activeRootBuilderBuildData = @() }
    }

    $expectedMO2Path = Resolve-MO2ControlPath ([string]$Config.mo2.executable)
    foreach ($record in $targets) {
        $process = Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue
        $exactPath = Test-MO2ExactProcessPath -Record $record -ExpectedPath $expectedMO2Path
        if ($process -and @($Config.mo2.processNames) -contains $process.ProcessName -and $exactPath) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-MO2ProcessRecords -Names @($Config.mo2.processNames))
        if ($remaining.Count -eq 0) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    $terminated = $remaining.Count -eq 0
    $owned.data.status = if ($terminated) { 'mo2-terminated' } else { 'terminate-incomplete' }
    $null = Write-MO2OwnedSessionAtomic -Owned $owned -Value $owned.data
    $manifestPath = Join-Path ([string]$owned.data.sessionPath) 'session.json'
    $manifest = ConvertFrom-MO2JsonText (Get-Content -LiteralPath $manifestPath -Raw)
    $manifest.status = $owned.data.status
    if ($manifest.PSObject.Properties['terminatedUtc']) { $manifest.terminatedUtc = [DateTime]::UtcNow.ToString('o') } else { $manifest | Add-Member -NotePropertyName terminatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    Write-MO2JsonAtomic -Path $manifestPath -Value $manifest
    return New-MO2ActionResult -Config $Config -Command 'terminate' -Ok $terminated -State $owned.data.status -Data @{ targets = $targets; remaining = $remaining; gameProcesses = @(); activeRootBuilderBuildData = @(); sessionPath = $owned.data.sessionPath } -Errors $(if ($terminated) { @() } else { @('MO2 remained after exact forced termination was requested.') })
}

function Get-MO2ControlHelp {
    param([Parameter(Mandatory)]$Config)

    $data = [pscustomobject][ordered]@{
        commands = @(
            [pscustomobject]@{ name = 'inspect'; mutation = $false; description = 'Inspect MO2 paths, profiles, registered executables, processes, RootBuilder state, overwrite usage, storage and locks.' },
            [pscustomobject]@{ name = 'validate'; mutation = $false; description = 'Validate an exact profile and registered executable. Add -RequireClosed before future state-changing operations.' },
            [pscustomobject]@{ name = 'request-access'; mutation = $true; description = 'Atomically request the shared MO2 access lease for exactly one runtime route: OCU, SteamVR, or SteamVRNull.' },
            [pscustomobject]@{ name = 'access-status'; mutation = $false; description = 'Report whether access is available, held, bound to a session, or owned by the supplied AccessId.' },
            [pscustomobject]@{ name = 'renew-access'; mutation = $true; description = 'Refresh an owned access lease and optionally replace its advisory duration estimate. Never extends an automatic expiry because leases do not expire automatically.' },
            [pscustomobject]@{ name = 'release-access'; mutation = $true; description = 'Release an access-only lease after proving MO2, the game, and RootBuilder deployment are inactive.' },
            [pscustomobject]@{ name = 'recover-access'; mutation = $true; description = 'Explicitly recover a confirmed abandoned access lease after closed-state proof. Requires AccessId and ConfirmAbandoned; estimates never authorize recovery.' },
            [pscustomobject]@{ name = 'prepare'; mutation = $true; description = 'Validate closed state and create a durable evidence session. Pass AccessId to bind an explicit lease; legacy implicit single-session use remains supported.' },
            [pscustomobject]@{ name = 'open'; mutation = $true; description = 'Open only the exact configured MO2 executable and profile in an owned session. Does not launch the game. -StartOnly returns after the durable receipt is written.' },
            [pscustomobject]@{ name = 'launch'; mutation = $true; description = 'Launch one exact registered executable under one exact profile. Requires -SessionId; -StartOnly returns after the durable receipt is written.' },
            [pscustomobject]@{ name = 'status'; mutation = $false; description = 'Report bounded MO2, game and runtime process state, optionally verifying -SessionId ownership.' },
            [pscustomobject]@{ name = 'stop-game'; mutation = $true; description = 'Request graceful game shutdown while retaining the exact owned MO2 process for controlled relaunch. Never force-terminates.' },
            [pscustomobject]@{ name = 'terminate-game'; mutation = $true; description = 'Terminate only launch-recorded exact game/loader PIDs after a deadlock, retain MO2, invoke exact Unlock, and require RootBuilder restoration.' },
            [pscustomobject]@{ name = 'close'; mutation = $true; description = 'Cooperatively close only exact session-owned MO2, including its exact Unlock control and MO2-owned modal windows. Never force-terminates.' },
            [pscustomobject]@{ name = 'recover-close'; mutation = $true; description = 'Adopt one stranded exact-path MO2 into a recorded recovery session, then cooperatively close it. Never targets editor or crash-handler processes.' },
            [pscustomobject]@{ name = 'recover-rootbuilder'; mutation = $true; description = 'Recover one stranded RootBuilder BuildData transaction through one exact-profile launch, followed by the normal stop/Unlock path. Never deletes deployment metadata.' },
            [pscustomobject]@{ name = 'stop'; mutation = $true; description = 'Request graceful game shutdown, then cooperatively close exact owned MO2. Never force-terminates.' },
            [pscustomobject]@{ name = 'terminate'; mutation = $true; description = 'Force-terminate only owned MO2 processes after proving game absence and RootBuilder cleanup. Requires -SessionId and supports -WhatIf.' },
            [pscustomobject]@{ name = 'release'; mutation = $true; description = 'Release an owned session after closed-state proof. Explicit access is retained for release-access; implicit legacy access is removed.' },
            [pscustomobject]@{ name = 'help'; mutation = $false; description = 'Return the command contract.' }
        )
        examples = @(
            '.\Invoke-MO2Control.ps1 inspect',
            '.\Invoke-MO2Control.ps1 request-access -Label "api-test" -RuntimeRoute OCU -EstimatedMinutes 20',
            '.\Invoke-MO2Control.ps1 prepare -AccessId $accessId -Label "api-test-run"',
            '.\Invoke-MO2Control.ps1 validate -RequireClosed',
            '.\Invoke-MO2Control.ps1 validate -Profile "Codex" -Executable "Launch MGO - Do Not Unlock" -Compact'
        )
        runtimeRoutes = @(
            Resolve-MO2RuntimeRouteContract -RuntimeRoute OCU
            Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVR
            Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVRNull
        )
        runtimeRouteRule = 'A lease selects exactly one route. OCU cannot coexist with either SteamVR route; SteamVRNull is the null-HMD mode of SteamVR and cannot coexist with physical SteamVR.'
        note = 'Version 0.9.0 preserves the lifecycle contract and carries one explicit runtime route from access request into prepared session evidence.'
    }

    return [pscustomobject][ordered]@{
        contractVersion = $script:MO2ControlContractVersion
        command = 'help'
        ok = $true
        state = 'informational'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = @()
        errors = @()
        data = $data
    }
}

Export-ModuleMember -Function Read-MO2ControlConfig, Invoke-MO2Inspect, Invoke-MO2Validate, Invoke-MO2RequestAccess, Invoke-MO2AccessStatus, Invoke-MO2RenewAccess, Invoke-MO2ReleaseAccess, Invoke-MO2RecoverAccess, Invoke-MO2Prepare, Invoke-MO2Open, Invoke-MO2Launch, Invoke-MO2Status, Invoke-MO2StopGame, Invoke-MO2TerminateGame, Invoke-MO2Close, Invoke-MO2RecoverClose, Invoke-MO2RecoverRootBuilder, Invoke-MO2Stop, Invoke-MO2Terminate, Invoke-MO2Release, Get-MO2ControlHelp
