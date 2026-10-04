# SPDX-License-Identifier: GPL-3.0-or-later
# Shared qualification authority. Reads only finite, exact package members.
function Get-HeadPoseArtifactPaths {
    return [ordered]@{
        manifestSha256 = 'driver.vrdrivermanifest'
        dllSha256 = 'bin/win64/driver_codex_head_pose.dll'
        poseProbeSha256 = 'tools/csx_openvr_pose_probe.exe'
        openVrApiSha256 = 'tools/openvr_api.dll'
        defaultSettingsSha256 = 'resources/settings/default.vrsettings'
        passiveControllerInputProfileSha256 = 'resources/input/passive_controller_profile.json'
    }
}

function Get-HeadPoseCanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw 'An absolute package authority path is required.' }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $cursor = $resolved
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package authority refuses reparse paths: $cursor" }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $resolved
}

function Read-HeadPoseAuthorityJson([string]$Path) {
    $null = Get-HeadPoseCanonicalPath $Path
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 262144) { throw "Authority JSON is missing, non-file or exceeds 256 KiB: $Path" }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -isnot [Collections.IDictionary]) { throw "Authority JSON must be an object: $Path" }
    return $value
}

function Get-HeadPoseInstallJournalPath([string]$Root, [string]$RegistrationPath) {
    $identity = "$($Root.TrimEnd('\').ToLowerInvariant())`n$($RegistrationPath.TrimEnd('\').ToLowerInvariant())"
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    $controlRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CSX-VR-Automation\SteamVR\install-transactions'
    if ($env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT) {
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $candidate = Get-HeadPoseCanonicalPath $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT
        if (-not ($Root + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not ($candidate + '\').StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture install authority must remain inside OS temporary storage.' }
        $controlRoot = $candidate
    }
    return Join-Path (Join-Path $controlRoot $key) 'install.journal.json'
}

function Get-HeadPosePackageAuthority {
    param([string]$Root, [string]$RegistrationPath, [string]$BundledProvenancePath,
        [string]$ExpectedProvenanceSha256, [DateTime]$DeadlineUtc = [DateTime]::MaxValue)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    if ($DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    $proof = [ordered]@{ verified = $false; root = $Root; artifacts = @{}; errors = @(); authority = $null }
    try {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Package authority deadline exceeded before inspection.' }
        $rootPath = Get-HeadPoseCanonicalPath $Root
        $registration = Get-HeadPoseCanonicalPath $RegistrationPath
        $proof.root = $rootPath
        $markerPath = Join-Path $rootPath '.csx-vr-automation-driver.json'
        $marker = Read-HeadPoseAuthorityJson $markerPath
        if ($marker['schemaVersion'] -ne 3 -or $marker['driverName'] -cne 'codex_head_pose' -or
            (Get-HeadPoseCanonicalPath ([string]$marker['installRoot'])) -ne $rootPath) { throw 'Missing, legacy, malformed or wrong-root installation marker; upgrade the exact owned installation.' }
        $journalPath = Get-HeadPoseInstallJournalPath $rootPath $registration
        $journal = Read-HeadPoseAuthorityJson $journalPath
        $markerHash = (Get-FileHash -LiteralPath $markerPath -Algorithm SHA256).Hash
        if ($journal['phase'] -cne 'committed' -or $journal['transactionId'] -cne $marker['transactionId'] -or
            (Get-HeadPoseCanonicalPath ([string]$journal['target'])) -ne $rootPath -or
            (Get-HeadPoseCanonicalPath ([string]$journal['openVrPathsPath'])) -ne $registration -or
            $journal['installedMarkerSha256'] -ne $markerHash) { throw 'Installation marker is not bound to its exact committed owner journal.' }
        $provenancePath = Join-Path $rootPath 'build-provenance.json'
        $provenance = Read-HeadPoseAuthorityJson $provenancePath
        $provenanceHash = (Get-FileHash -LiteralPath $provenancePath -Algorithm SHA256).Hash
        if ($ExpectedProvenanceSha256) {
            if ($ExpectedProvenanceSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Custom-package authority requires an explicit SHA-256 digest.' }
            $expected = $ExpectedProvenanceSha256
            $proof.authority = 'explicit-custom-provenance-digest'
        }
        else {
            $null = Read-HeadPoseAuthorityJson $BundledProvenancePath
            $expected = (Get-FileHash -LiteralPath $BundledProvenancePath -Algorithm SHA256).Hash
            $proof.authority = 'bundled-provenance-digest'
        }
        if ($provenanceHash -ne $expected -or $marker['buildProvenanceSha256'] -ne $expected -or $journal['sourceProvenance']['buildProvenanceSha256'] -ne $expected -or
            $provenance['driverName'] -cne 'codex_head_pose') { throw 'Installed build provenance does not match selected independent package authority.' }
        $proof.provenanceSha256 = $provenanceHash
        $proof.markerSha256 = $markerHash
        $proof.journalPath = $journalPath
        $proof.transactionId = $marker['transactionId']
        $proof.sourceCommit = $provenance['sourceCommit']
        $paths = Read-HeadPoseAuthorityJson $registration
        $entries = @($paths['external_drivers'])
        if ($entries.Count -gt 128) { throw 'OpenVR driver inventory exceeds 128 registrations.' }
        $exact = 0; $named = 0
        foreach ($entry in $entries) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Package authority deadline exceeded.' }
            $registeredRoot = Get-HeadPoseCanonicalPath ([string]$entry)
            if ($registeredRoot -eq $rootPath) { $exact++ }
            $manifest = Read-HeadPoseAuthorityJson (Join-Path $registeredRoot 'driver.vrdrivermanifest')
            if ($manifest['name'] -ceq 'codex_head_pose') { $named++ }
        }
        if ($exact -ne 1 -or $named -ne 1) { throw "Provider registration must identify exactly one canonical root and one same-name driver (exact=$exact, named=$named)." }
        $bytes = 0L
        foreach ($member in (Get-HeadPoseArtifactPaths).GetEnumerator()) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Package authority deadline exceeded.' }
            $path = Get-HeadPoseCanonicalPath (Join-Path $rootPath $member.Value)
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            $bytes += $item.Length
            if ($item.PSIsContainer -or $bytes -gt 67108864) { throw 'Package authority exceeds the 64 MiB six-artifact budget.' }
            $expectedArtifact = [string]$provenance['artifacts'][$member.Value]
            $observed = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($expectedArtifact -notmatch '^[a-fA-F0-9]{64}$' -or $observed -ne $expectedArtifact -or
                $marker[$member.Key] -ne $observed -or $journal['sourceProvenance'][$member.Key] -ne $observed) { throw "Installed artifact drift or missing authority: $($member.Value)" }
            $proof.artifacts[$member.Value] = $observed
        }
        $manifest = Read-HeadPoseAuthorityJson (Join-Path $rootPath 'driver.vrdrivermanifest')
        if ($manifest['name'] -cne 'codex_head_pose') { throw 'Selected manifest does not identify the exact provider.' }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Package authority deadline exceeded.' }
        $proof.verified = $true
    }
    catch { $proof.errors = @($_.Exception.Message) }
    return [pscustomobject]$proof
}

function Get-HeadPoseCreatorAuthority {
    param([uint32]$CreatorPid, [uint64]$DriverStartedFileTimeUtc, [string]$SteamVRRoot, [string]$DriverRoot)
    $proof = [ordered]@{ verified = $false; pid = $CreatorPid; processStartFileTimeUtc = $null; executablePath = $null; loadedModulePath = $null; error = $null }
    try {
        if ($CreatorPid -eq 0 -or $DriverStartedFileTimeUtc -eq 0) { throw 'Missing shared-memory creator identity.' }
        $expectedExecutable = Get-HeadPoseCanonicalPath (Join-Path $SteamVRRoot 'bin/win64/vrserver.exe')
        $expectedModule = Get-HeadPoseCanonicalPath (Join-Path $DriverRoot 'bin/win64/driver_codex_head_pose.dll')
        $process = Get-Process -Id $CreatorPid -ErrorAction Stop
        $start = [uint64]$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        $path = Get-HeadPoseCanonicalPath ([string]$process.Path)
        if ($path -ne $expectedExecutable -or $start -gt $DriverStartedFileTimeUtc -or
            $DriverStartedFileTimeUtc -gt [uint64][DateTime]::UtcNow.ToFileTimeUtc()) { throw 'Creator is not the exact current configured vrserver process.' }
        $modules = @($process.Modules)
        if ($modules.Count -gt 1024) { throw 'Creator module inventory exceeds 1024 entries.' }
        $matches = @($modules | Where-Object { $_.ModuleName -ieq 'driver_codex_head_pose.dll' })
        if ($matches.Count -ne 1 -or (Get-HeadPoseCanonicalPath ([string]$matches[0].FileName)) -ne $expectedModule) { throw 'Creator has not loaded the exact owned driver module.' }
        $process.Refresh()
        if ($process.HasExited -or [uint64]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $start) { throw 'Creator process identity changed during module qualification.' }
        $proof.processStartFileTimeUtc = $start; $proof.executablePath = $path
        $proof.loadedModulePath = $expectedModule; $proof.verified = $true
    }
    catch { $proof.error = $_.Exception.Message }
    return [pscustomobject]$proof
}
