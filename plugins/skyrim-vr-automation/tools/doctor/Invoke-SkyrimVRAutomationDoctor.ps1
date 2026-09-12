# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'init')]
    [string]$Command = 'inspect',

    [string]$ConfigPath,
    [string]$SourceConfigPath,
    [string]$UserConfigPath,
    [string]$SteamVRSettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',
    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$EvidenceDirectory,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 60,
    [switch]$WhatIf,
    [switch]$Compact,

    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mo2Root = Join-Path $repositoryRoot 'tools\mo2-control'
$boundedProcessTool = Join-Path $repositoryRoot 'tools\process-control\Invoke-BoundedProcess.ps1'
Import-Module (Join-Path $mo2Root 'ConfigResolution.psm1') -Force

function New-DoctorCheck([string]$Name, [string]$Status, [string]$Message, $Data = $null) {
    [pscustomobject][ordered]@{ name = $Name; status = $Status; message = $Message; data = $Data }
}

function Get-DoctorAvailableProfiles($Validation) {
    if ($null -eq $Validation -or -not $Validation.PSObject.Properties['data'] -or $null -eq $Validation.data -or -not $Validation.data.PSObject.Properties['profiles']) {
        return @()
    }
    return @($Validation.data.profiles)
}

try {
    $targetPath = if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { Get-MO2ControlUserConfigPath } else { [IO.Path]::GetFullPath($UserConfigPath) }
    if ($Command -eq 'init') {
        $source = if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) {
            [IO.Path]::GetFullPath($SourceConfigPath)
        } else {
            Join-Path $mo2Root 'config\machine.example.json'
        }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Configuration source does not exist: $source" }
        if (Test-Path -LiteralPath $targetPath) { throw "Configuration target already exists; it was not overwritten: $targetPath" }

        $created = $false
        if (-not $WhatIf) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $targetPath
            $created = $true
        }
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1; ok = $true; command = 'init'; timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($created) { 'created' } else { 'dry-run' }
            checks = @(); warnings = @(); errors = @()
            data = [pscustomobject][ordered]@{ source = $source; target = $targetPath; created = $created; sha256 = if ($created) { (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash } else { $null } }
        }
    }
    else {
        $checks = [System.Collections.Generic.List[object]]::new()
        $resolution = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot $mo2Root -UserConfigPath $targetPath
        $checks.Add((New-DoctorCheck 'powershell' $(if ($PSVersionTable.PSVersion.Major -ge 7) { 'pass' } else { 'fail' }) "PowerShell $($PSVersionTable.PSVersion)"))
        $checks.Add((New-DoctorCheck 'platform' $(if ($IsWindows) { 'pass' } else { 'fail' }) $(if ($IsWindows) { 'Windows detected.' } else { 'The bundled controllers currently require Windows.' })))
        $checks.Add((New-DoctorCheck 'mo2-config' $(if ($resolution.exists) { 'pass' } else { 'fail' }) "MO2 config source '$($resolution.source)': $($resolution.path)" $resolution))

        $mo2Validation = $null
        if ($resolution.exists) {
            $boundedParameters = @{
                FilePath = (Get-Process -Id $PID).Path
                ArgumentList = @('-NoProfile', '-File', (Join-Path $mo2Root 'Invoke-MO2Control.ps1'), 'validate', '-ConfigPath', [string]$resolution.path, '-Compact')
                WorkingDirectory = $repositoryRoot; TimeoutSeconds = $TimeoutSeconds; MaxAttempts = 1; NoExit = $true; Compact = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $boundedParameters.EvidenceDirectory = $EvidenceDirectory }
            $boundedValidation = & $boundedProcessTool @boundedParameters | ConvertFrom-Json -Depth 40
            if ($boundedValidation.ok -and @($boundedValidation.attempts).Count -eq 1) {
                try { $mo2Validation = ([string]$boundedValidation.attempts[0].stdout) | ConvertFrom-Json -Depth 30 } catch { $mo2Validation = [pscustomobject]@{ ok = $false; raw = @($boundedValidation.attempts[0].stdout); boundedProcess = $boundedValidation } }
            }
            else { $mo2Validation = [pscustomobject]@{ ok = $false; boundedProcess = $boundedValidation } }
            $checks.Add((New-DoctorCheck 'mo2-validation' $(if ($mo2Validation.ok) { 'pass' } else { 'fail' }) $(if ($mo2Validation.ok) { 'MO2 configuration validates.' } else { 'MO2 configuration validation failed.' }) $mo2Validation))
            try {
                $machineConfig = Get-Content -LiteralPath $resolution.path -Raw | ConvertFrom-Json
                $primeProfile = if ($machineConfig.defaults.PSObject.Properties['testProfileSource']) { [string]$machineConfig.defaults.testProfileSource } else { '' }
                if ([string]::IsNullOrWhiteSpace($primeProfile)) {
                    $checks.Add((New-DoctorCheck 'prime-profile-launch-readiness' 'fail' 'The maintained source profile is not configured. Set defaults.testProfileSource to one exact launch-capable profile.' ([pscustomobject][ordered]@{
                        configurationProperty = 'defaults.testProfileSource'
                        configuredProfile = $null
                        availableProfiles = @(Get-DoctorAvailableProfiles -Validation $mo2Validation)
                    })))
                }
                else {
                    $primeArguments = @('-NoProfile', '-File', (Join-Path $mo2Root 'Invoke-MO2Control.ps1'), 'validate', '-ConfigPath', [string]$resolution.path, '-Profile', $primeProfile, '-Compact', '-NoExit')
                    if ($machineConfig.defaults.PSObject.Properties['executable'] -and -not [string]::IsNullOrWhiteSpace([string]$machineConfig.defaults.executable)) {
                        $primeArguments += @('-Executable', [string]$machineConfig.defaults.executable)
                    }
                    $primeParameters = @{
                        FilePath = (Get-Process -Id $PID).Path
                        ArgumentList = $primeArguments
                        WorkingDirectory = $repositoryRoot; TimeoutSeconds = $TimeoutSeconds; MaxAttempts = 1; NoExit = $true; Compact = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $primeParameters.EvidenceDirectory = $EvidenceDirectory }
                    $boundedPrime = & $boundedProcessTool @primeParameters | ConvertFrom-Json -Depth 40
                    $primeValidation = $null
                    if ($boundedPrime.ok -and @($boundedPrime.attempts).Count -eq 1) {
                        try { $primeValidation = ([string]$boundedPrime.attempts[0].stdout) | ConvertFrom-Json -Depth 30 } catch { $primeValidation = [pscustomobject]@{ ok = $false; raw = @($boundedPrime.attempts[0].stdout); boundedProcess = $boundedPrime } }
                    }
                    else { $primeValidation = [pscustomobject]@{ ok = $false; boundedProcess = $boundedPrime } }
                    $profileChecks = @(if ($primeValidation.PSObject.Properties['checks']) { $primeValidation.checks | Where-Object name -in @('requested-profile', 'registered-executable', 'registered-binary', 'registered-binary-owner-mod') })
                    $failedProfileChecks = @($profileChecks | Where-Object status -eq 'fail')
                    $primeReady = $profileChecks.Count -ge 3 -and $failedProfileChecks.Count -eq 0
                    $primeEvidence = [pscustomobject][ordered]@{
                        configurationProperty = 'defaults.testProfileSource'
                        configuredProfile = $primeProfile
                        availableProfiles = @(Get-DoctorAvailableProfiles -Validation $primeValidation)
                        profileChecks = $profileChecks
                        validation = $primeValidation
                    }
                    $primeMessage = if ($primeReady) {
                        "The maintained source profile '$primeProfile' exists and its registered executable provider is available."
                    }
                    else {
                        "The profile configured by defaults.testProfileSource ('$primeProfile') is missing or not launch-capable. Update that field or use an exact profile from data.availableProfiles."
                    }
                    $checks.Add((New-DoctorCheck 'prime-profile-launch-readiness' $(if ($primeReady) { 'pass' } else { 'fail' }) $primeMessage $primeEvidence))
                }
                $fixtureInput = if ($machineConfig.defaults.PSObject.Properties['newGameFixtureManifest']) { [string]$machineConfig.defaults.newGameFixtureManifest } else { '' }
                if ([string]::IsNullOrWhiteSpace($fixtureInput)) {
                    $checks.Add((New-DoctorCheck 'prime-profile-world-entry-integrity' 'fail' 'The maintained source profile has no configured world-entry save. Set defaults.newGameFixtureManifest and verify its default fixture before creating task profiles.' ([pscustomobject][ordered]@{
                        configurationProperty = 'defaults.newGameFixtureManifest'
                        exampleManifestPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'tools\mo2-workspace-control\save-fixtures.example.json'))
                    })))
                }
                else {
                    $fixtureParameters = @{
                        FilePath = (Get-Process -Id $PID).Path
                        ArgumentList = @('-NoProfile', '-File', (Join-Path $repositoryRoot 'tools\mo2-workspace-control\Invoke-MO2WorkspaceControl.ps1'), 'fixture-status', '-ConfigPath', [string]$resolution.path, '-Compact', '-NoExit')
                        WorkingDirectory = $repositoryRoot; TimeoutSeconds = $TimeoutSeconds; MaxAttempts = 1; NoExit = $true; Compact = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $fixtureParameters.EvidenceDirectory = $EvidenceDirectory }
                    $boundedFixture = & $boundedProcessTool @fixtureParameters | ConvertFrom-Json -Depth 40
                    $fixtureStatus = $null
                    if ($boundedFixture.ok -and @($boundedFixture.attempts).Count -eq 1) {
                        try { $fixtureStatus = ([string]$boundedFixture.attempts[0].stdout) | ConvertFrom-Json -Depth 30 } catch { $fixtureStatus = [pscustomobject]@{ ok = $false; raw = @($boundedFixture.attempts[0].stdout); boundedProcess = $boundedFixture } }
                    }
                    else { $fixtureStatus = [pscustomobject]@{ ok = $false; boundedProcess = $boundedFixture } }
                    $fixtureValid = $fixtureStatus.ok -and [string]$fixtureStatus.state -eq 'fixture-valid' -and [bool]$fixtureStatus.data.valid
                    $fixtureEvidence = [pscustomobject][ordered]@{
                        configurationProperty = 'defaults.newGameFixtureManifest'
                        configuredPath = [IO.Path]::GetFullPath($fixtureInput)
                        exampleManifestPath = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'tools\mo2-workspace-control\save-fixtures.example.json'))
                        fixtureStatus = $fixtureStatus
                    }
                    $checks.Add((New-DoctorCheck 'prime-profile-world-entry-integrity' $(if ($fixtureValid) { 'pass' } else { 'fail' }) $(if ($fixtureValid) { "The maintained source profile has an integrity-verified world-entry save fixture '$($fixtureStatus.data.fixtureId)'. No live-load qualification is inferred." } else { 'The maintained source profile world-entry save is missing, stale, or invalid. Run fixture-status and repair or refresh it before creating task profiles.' }) $fixtureEvidence))
                }
            }
            catch {
                $checks.Add((New-DoctorCheck 'prime-profile-world-entry-integrity' 'fail' "Could not verify the maintained source profile world-entry save integrity: $($_.Exception.Message)"))
            }
        }

        $nullProfile = Join-Path $repositoryRoot 'profiles\steamvr-null.profile.json'
        $checks.Add((New-DoctorCheck 'null-profile' $(if (Test-Path -LiteralPath $nullProfile -PathType Leaf) { 'pass' } else { 'fail' }) $nullProfile))
        $checks.Add((New-DoctorCheck 'steamvr-settings' $(if (Test-Path -LiteralPath $SteamVRSettingsPath -PathType Leaf) { 'pass' } else { 'warn' }) $SteamVRSettingsPath))
        $checks.Add((New-DoctorCheck 'steamvr-root' $(if (Test-Path -LiteralPath $SteamVRRoot -PathType Container) { 'pass' } else { 'warn' }) $SteamVRRoot))
        $checks.Add((New-DoctorCheck 'devbench-runtime' $(if ([string]::IsNullOrWhiteSpace($RuntimePath)) { 'info' } elseif (Test-Path -LiteralPath $RuntimePath -PathType Leaf) { 'pass' } else { 'warn' }) $(if ([string]::IsNullOrWhiteSpace($RuntimePath)) { 'Optional DevBench runtime path is not configured.' } else { $RuntimePath })))

        $failed = @($checks | Where-Object status -eq 'fail')
        $result = [pscustomobject][ordered]@{
            schemaVersion = 1; ok = $failed.Count -eq 0; command = 'inspect'; timestampUtc = [DateTime]::UtcNow.ToString('o')
            state = if ($failed.Count -eq 0) { 'ready' } else { 'configuration-required' }
            checks = @($checks); warnings = @($checks | Where-Object status -eq 'warn' | ForEach-Object message); errors = @($failed | ForEach-Object message)
            data = [pscustomobject][ordered]@{ repositoryRoot = $repositoryRoot; configuration = $resolution; userConfigPath = $targetPath }
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{ schemaVersion = 1; ok = $false; command = $Command; timestampUtc = [DateTime]::UtcNow.ToString('o'); state = 'tool-error'; checks = @(); warnings = @(); errors = @($_.Exception.Message); data = $null }
}

$json = @{ InputObject = $result; Depth = 40 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
