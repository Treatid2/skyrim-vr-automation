# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-driver-authority-' + [guid]::NewGuid().ToString('N'))
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($fixture)).StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped temporary storage.' }
$priorControl = $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT
$passed = 0
function Assert-Authority([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Get-Process {
    [CmdletBinding(DefaultParameterSetName='Name')]
    param([Parameter(ParameterSetName='Name')][string[]]$Name, [Parameter(ParameterSetName='Id')][int[]]$Id)
    if ($PSCmdlet.ParameterSetName -eq 'Name' -and @($Name).Count -gt 0 -and @($Name | Where-Object { $_ -notin @('vrserver','vrmonitor','vrcompositor','vrstartup') }).Count -eq 0) { return }
    if ($global:CSXAuthorityTestCreator -and $PSCmdlet.ParameterSetName -eq 'Id' -and $Id[0] -eq $PID) { return $global:CSXAuthorityTestCreator }
    return Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
}
$global:CSXAuthorityTestCreator = $null
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT = Join-Path $fixture 'owner-control'
    $bundle = Join-Path $PSScriptRoot '..\..\drivers\codex_head_pose'
    $entry = Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1'
    $root = Join-Path $fixture 'owned'
    $registration = Join-Path $fixture 'openvrpaths.vrpath'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.csx-vr-automation-driver.json'), '{"schemaVersion":1,"driverName":"codex_head_pose"}')
    function Write-Registration([string[]]$Roots) {
        [IO.File]::WriteAllText($registration, (@{external_drivers=$Roots} | ConvertTo-Json -Compress))
    }
    Write-Registration @($root)
    $installed = & $entry install -DriverPackagePath $bundle -InstallRoot $root -OpenVRPathsPath $registration -VRPathRegPath $entry -Upgrade -Compact -NoExit | ConvertFrom-Json
    Assert-Authority $installed.ok 'real serialized installer commits temporary package without executing a native artifact'
    . (Join-Path $PSScriptRoot 'DriverPackageAuthority.ps1')
    $bundledProvenance = Join-Path $bundle 'build-provenance.json'
    function Read-Authority { Get-HeadPosePackageAuthority -Root $root -RegistrationPath $registration -BundledProvenancePath $bundledProvenance }
    $proof = Read-Authority
    Assert-Authority ($proof.verified -and $proof.artifacts.Count -eq 6) 'unchanged owned package enforces six exact artifact hashes and committed journal'
    Assert-Authority ($installed.data.openVrApiSha256 -eq $proof.artifacts['tools/openvr_api.dll'] -and $installed.data.markerSha256 -eq $proof.markerSha256) 'installer receipt carries runtime DLL and exact marker custody'
    foreach ($member in (Get-HeadPoseArtifactPaths).Values) {
        $path = Join-Path $root $member
        $before = [IO.File]::ReadAllBytes($path)
        [IO.File]::WriteAllBytes($path, [byte[]]@(1,2,3))
        $drift = Read-Authority
        Assert-Authority (-not $drift.verified) "post-install drift rejected: $member"
        [IO.File]::WriteAllBytes($path, $before)
    }
    $markerPath = Join-Path $root '.csx-vr-automation-driver.json'
    $markerBytes = [IO.File]::ReadAllBytes($markerPath)
    $retainedMarker = Join-Path $root 'marker.retained'
    Move-Item -LiteralPath $markerPath -Destination $retainedMarker
    Assert-Authority (-not (Read-Authority).verified) 'missing marker rejected'
    Move-Item -LiteralPath $retainedMarker -Destination $markerPath
    [IO.File]::WriteAllText($markerPath, '{malformed')
    Assert-Authority (-not (Read-Authority).verified) 'malformed marker rejected'
    [IO.File]::WriteAllBytes($markerPath, $markerBytes)
    $journalPath = Get-HeadPoseInstallJournalPath $root $registration
    $journalBytes = [IO.File]::ReadAllBytes($journalPath)
    $journal = Read-HeadPoseAuthorityJson $journalPath
    $journal.phase = 'registered-uncommitted'
    [IO.File]::WriteAllText($journalPath, ($journal | ConvertTo-Json -Depth 20))
    Assert-Authority (-not (Read-Authority).verified) 'uncommitted install cannot supply runtime authority'
    [IO.File]::WriteAllBytes($journalPath, $journalBytes)
    $wrong = Join-Path $fixture 'same-name-wrong-root'
    [IO.Directory]::CreateDirectory($wrong) | Out-Null
    [IO.File]::WriteAllText((Join-Path $wrong 'driver.vrdrivermanifest'), '{"name":"codex_head_pose"}')
    Write-Registration @($wrong)
    Assert-Authority (-not (Read-Authority).verified) 'single same-name driver at wrong root rejected'
    Write-Registration @($root, $root)
    Assert-Authority (-not (Read-Authority).verified) 'duplicate exact-root registration rejected'
    Write-Registration @($root, $wrong)
    Assert-Authority (-not (Read-Authority).verified) 'duplicate same-name roots rejected'
    Write-Registration @($root)
    $custom = Join-Path $fixture 'custom-package'
    Copy-Item -LiteralPath $bundle -Destination $custom -Recurse
    $customProvenancePath = Join-Path $custom 'build-provenance.json'
    $customProvenance = Read-HeadPoseAuthorityJson $customProvenancePath
    $customProvenance['qualificationFixture'] = 'explicit independent digest; same binary bytes'
    [IO.File]::WriteAllText($customProvenancePath, ($customProvenance | ConvertTo-Json -Depth 20))
    $customHash = (Get-FileHash -LiteralPath $customProvenancePath).Hash
    $customInstalled = & $entry install -DriverPackagePath $custom -InstallRoot $root -OpenVRPathsPath $registration -VRPathRegPath $entry -Upgrade -Compact -NoExit | ConvertFrom-Json
    Assert-Authority $customInstalled.ok 'custom package receives a distinct committed installation authority'
    Assert-Authority (-not (Read-Authority).verified) 'custom provenance not silently attributed to bundled build'
    $customProof = Get-HeadPosePackageAuthority -Root $root -RegistrationPath $registration -BundledProvenancePath $bundledProvenance -ExpectedProvenanceSha256 $customHash
    Assert-Authority ($customProof.verified -and $customProof.authority -ceq 'explicit-custom-provenance-digest') 'explicit digest qualifies independently authorized custom package'
    $expired = Get-HeadPosePackageAuthority -Root $root -RegistrationPath $registration -BundledProvenancePath $bundledProvenance -ExpectedProvenanceSha256 $customHash -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))
    Assert-Authority (-not $expired.verified -and ($expired.errors -match 'deadline')) 'expired outer budget cannot qualify artifacts'
    $steamRoot = Join-Path $fixture 'SteamVR'
    $timestamp = [uint64][DateTime]::UtcNow.ToFileTimeUtc()
    $creator = Get-HeadPoseCreatorAuthority -CreatorPid $PID -DriverStartedFileTimeUtc $timestamp -SteamVRRoot $steamRoot -DriverRoot $root
    Assert-Authority (-not $creator.verified) 'real unrelated live PowerShell PID cannot forge creator authority'
    $global:CSXAuthorityTestCreator = [pscustomobject]@{
        Path=(Join-Path $steamRoot 'bin/win64/vrserver.exe'); StartTime=[DateTime]::UtcNow.AddMinutes(-1)
        HasExited=$false; Modules=@([pscustomobject]@{ModuleName='driver_codex_head_pose.dll';FileName=(Join-Path $root 'bin/win64/driver_codex_head_pose.dll')})
    }
    $global:CSXAuthorityTestCreator | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
    $exactCreator = Get-HeadPoseCreatorAuthority -CreatorPid $PID -DriverStartedFileTimeUtc $timestamp -SteamVRRoot $steamRoot -DriverRoot $root
    Assert-Authority ($exactCreator.verified -and $exactCreator.processStartFileTimeUtc -gt 0) 'bounded process/module seam retains exact PID/start and loaded root'
    $global:CSXAuthorityTestCreator.Modules[0].FileName = Join-Path $wrong 'bin/win64/driver_codex_head_pose.dll'
    $wrongModule = Get-HeadPoseCreatorAuthority -CreatorPid $PID -DriverStartedFileTimeUtc $timestamp -SteamVRRoot $steamRoot -DriverRoot $root
    Assert-Authority (-not $wrongModule.verified) 'same DLL basename from wrong loaded root rejected'
    $global:CSXAuthorityTestCreator.Modules=@()
    Assert-Authority (-not (Get-HeadPoseCreatorAuthority -CreatorPid $PID -DriverStartedFileTimeUtc $timestamp -SteamVRRoot $steamRoot -DriverRoot $root).verified) 'module absence is unqualified rather than inferred'
    # Public qualify exercises real package/creator guards with an explicit
    # test-owned process observation and a non-native bounded-run stub.
    $global:CSXAuthorityTestCreator.Modules=@([pscustomobject]@{ModuleName='driver_codex_head_pose.dll';FileName=(Join-Path $root 'bin/win64/driver_codex_head_pose.dll')})
    $global:CSXAuthorityProbeStub = Join-Path $fixture 'probe-stub.ps1'
    $counter = Join-Path $fixture 'probe-invocations.txt'
    [IO.File]::WriteAllText($global:CSXAuthorityProbeStub, @'
param($FilePath,$ArgumentList,$WorkingDirectory,$MaxAttempts,$TimeoutSeconds,$RetryPatterns,$EvidenceDirectory,[switch]$NoExit,[switch]$Compact)
$counter = [IO.Path]::Combine($PSScriptRoot, 'probe-invocations.txt')
[IO.File]::AppendAllText($counter, "probe`n")
$payload = @{ok=$true;standing=@{connected=$true;valid=$true;position=@(0,1.68,0)};stereo=@{valid=$true;eyeSeparationMeters=0.064};controllers=@{required=$true;valid=$true;leftIndex=1;rightIndex=2;neutralSamples=100;inputEvents=0}} | ConvertTo-Json -Depth 10 -Compress
@{ok=$true;attempts=@(@{stdout=$payload;exitCode=0;timedOut=$false})} | ConvertTo-Json -Depth 12 -Compress
'@)
    function Join-Path {
        param([Parameter(Position=0)][string]$Path,[Parameter(Position=1)][string]$ChildPath)
        if ($ChildPath -ceq 'process-control\Invoke-BoundedProcess.ps1') { return $global:CSXAuthorityProbeStub }
        return Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
    }
    $mapName = 'Local\CSXVRHeadPose-authority-' + [guid]::NewGuid().ToString('N')
    $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($mapName,128)
    $view = $mapping.CreateViewAccessor(0,128,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    try {
        $view.Write(0,[uint32]0x48505343);$view.Write(4,[uint16]2);$view.Write(6,[uint16]128)
        $view.Write(8,[uint64]2);$view.Write(16,[uint64]2);$view.Write(24,[uint32]1);$view.Write(28,[uint32]1)
        $view.Write(40,[double]1.68);$view.Write(56,[double]1)
        $view.Write(88,[uint64]11);$view.Write(96,[uint64]11);$view.Write(104,[uint64]12)
        $view.Write(112,[uint32]$PID);$view.Write(120,$timestamp);$view.Flush()
        $qualified = & $entry qualify -InstallRoot $root -SteamVRRoot $steamRoot -MapName $mapName -OpenVRPathsPath $registration -ExpectedPackageProvenanceSha256 $customHash -RequireControllers -Compact -NoExit | ConvertFrom-Json
        Assert-Authority ($qualified.ok -and $qualified.data.applicationPose.packageAuthority.verified -and @(Get-Content -LiteralPath $counter).Count -eq 1) 'public qualification passes only exact custom authority plus process/module and independent payload fixtures'
        $probePath = Join-Path $root 'tools/csx_openvr_pose_probe.exe'
        $probeBytes = [IO.File]::ReadAllBytes($probePath)
        [IO.File]::WriteAllBytes($probePath,[byte[]]@(0))
        $drifted = & $entry qualify -InstallRoot $root -SteamVRRoot $steamRoot -MapName $mapName -OpenVRPathsPath $registration -ExpectedPackageProvenanceSha256 $customHash -RequireControllers -Compact -NoExit | ConvertFrom-Json
        Assert-Authority (-not $drifted.ok -and $drifted.data.applicationPose.error -match 'before probe execution' -and @(Get-Content -LiteralPath $counter).Count -eq 1) 'public qualification refuses probe drift without invoking the bounded runner'
        [IO.File]::WriteAllBytes($probePath,$probeBytes)
        $substituted = & $entry qualify -InstallRoot $root -SteamVRRoot $steamRoot -MapName $mapName -OpenVRPathsPath $registration -ExpectedPackageProvenanceSha256 $customHash -PoseProbePath $global:CSXAuthorityProbeStub -RequireControllers -Compact -NoExit | ConvertFrom-Json
        Assert-Authority (-not $substituted.ok -and $substituted.data.applicationPose.error -match 'exact owned package probe' -and @(Get-Content -LiteralPath $counter).Count -eq 1) 'arbitrary PoseProbePath substitution is rejected before execution'
    }
    finally { $view.Dispose();$mapping.Dispose();Remove-Item -LiteralPath Function:\Join-Path }
    $global:CSXAuthorityTestCreator = $null
    # Real public null start refuses artifact/root drift before native startup;
    # it may create only a fixture target lock/journal, not a settings mutation.
    $priorTransactionRoot = $env:CSX_STEAMVR_TRANSACTION_ROOT
    $env:CSX_STEAMVR_TRANSACTION_ROOT = Join-Path $fixture 'null-control'
    try {
        $settings = Join-Path $fixture 'steamvr.vrsettings'
        [IO.File]::WriteAllText($settings, '{}')
        $nullEntry = Join-Path $PSScriptRoot '..\steamvr-null-control\Invoke-SteamVRNullControl.ps1'
        $before = (Get-FileHash -LiteralPath $settings).Hash
        $blocked = & $nullEntry start -SettingsPath $settings -SteamVRRoot $steamRoot -HeadPoseDriverRoot $root -OpenVRPathsPath $registration -Standalone -Compact -NoExit | ConvertFrom-Json
        Assert-Authority (-not $blocked.ok -and $blocked.state -ceq 'head-pose-package-not-qualified') "public null startup rejects independently unauthorized custom package before launch: $($blocked | ConvertTo-Json -Depth 5 -Compress)"
        Write-Registration @($wrong)
        $wrongStart = & $nullEntry start -SettingsPath $settings -SteamVRRoot $steamRoot -HeadPoseDriverRoot $root -OpenVRPathsPath $registration -Standalone -Compact -NoExit | ConvertFrom-Json
        Assert-Authority (-not $wrongStart.ok -and $wrongStart.state -ceq 'head-pose-provider-unavailable') 'public startup refuses same-name wrong-root registration'
        Assert-Authority ((Get-FileHash -LiteralPath $settings).Hash -ceq $before) 'refused startup leaves settings byte-identical'
    }
    finally { $env:CSX_STEAMVR_TRANSACTION_ROOT = $priorTransactionRoot }
    [pscustomobject]@{ok=$true;passed=$passed;scope='isolated fixtures; no native binaries executed and no live SteamVR changes'} | ConvertTo-Json -Compress
}
finally {
    $env:CSX_HEAD_POSE_INSTALL_CONTROL_ROOT = $priorControl
    Remove-Variable -Name CSXAuthorityTestCreator -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name CSXAuthorityProbeStub -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
