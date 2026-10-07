# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('application-probe-evidence-' + [guid]::NewGuid().ToString('N'))
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($fixture)).StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped temporary storage.' }
$passed = 0
function Assert-Evidence([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
try {
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw 'Production entry point parse failed.' }
    $names=@('Get-ApplicationHeadPose','Get-NullRuntimeEvidence','Get-LogTimestampUtc','Test-PassiveControllerProbeObservation')
    $definitions=@(foreach($name in $names){
        $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        if($nodes.Count -ne 1){throw "Missing/ambiguous production function: $name"}
        $nodes[0].Extent.Text
    }) -join "`n"
    $nullRoot=Join-Path $fixture 'tools/steamvr-null-control'
    $processRoot=Join-Path $fixture 'tools/process-control'
    $providerRoot=Join-Path $fixture 'provider/tools'
    foreach($directory in @($nullRoot,$processRoot,$providerRoot)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
    [IO.File]::WriteAllText((Join-Path $providerRoot 'csx_openvr_pose_probe.exe'),'Never executed: bounded controller is a test fixture.')
    $boundedStub=@'
param($FilePath,$ArgumentList,$WorkingDirectory,$MaxAttempts,$TimeoutSeconds,$TerminationGraceMilliseconds,$StreamDrainGraceMilliseconds,[switch]$NoExit,[switch]$Compact)
if($MaxAttempts -ne 1 -or $ArgumentList -cne '--require-controllers' -or $TimeoutSeconds -gt 10 -or $TerminationGraceMilliseconds -ne 100 -or $StreamDrainGraceMilliseconds -ne 100){throw 'Production probe dispatch contract changed.'}
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'dispatch-count.txt'),"one`n")
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.json') -Raw
'@
    [IO.File]::WriteAllText((Join-Path $processRoot 'Invoke-BoundedProcess.ps1'),$boundedStub)
    $setup=@'
param([string]$Fixture,[switch]$Expired)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$HeadPoseDriverRoot=Join-Path $Fixture 'provider'
$SteamVRRoot=Join-Path $Fixture 'SteamVR'
$ServerLogPath=Join-Path $Fixture 'vrserver.txt'
$LogTailMaxBytes=262144
$InternalTestFailurePoint=''
$script:SharedTextTailState=@{current=[pscustomobject]@{stable=$true;usable=$true;continuitySha256='new-partial-log';continuityOffset=0;continuityLength=12500;bytesRead=12500;hashBytesRead=12500;incremental=$false;resynchronized=$false}}
$serverStart=[DateTime]::UtcNow.AddSeconds(-1)
$script:NullStartupLogProofState=@{}
# Integrated builds use a separate startup-prefix reader. Like the tail reader
# below, isolate it with synthetic activation facts; this suite tests probe
# evidence propagation, not the independently covered log identity protocol.
function Get-NullStartupLogProof {param($Path,$Server,$SerialNumber,$MaxBytes,$DeadlineUtc)
 $lines=@(Get-SharedTextTail -Path $Path -Count 2000 -MaxBytes $MaxBytes -DeadlineUtc $DeadlineUtc)
 $facts=@($lines|ForEach-Object{[pscustomobject]@{timestampUtc=$serverStart.ToString('o');line=$_}})
 [pscustomobject]@{stable=$true;complete=$true;driverLoaded=$facts[0];activeHmd=$facts[1];headPoseDriverLoaded=$facts[2];headPoseDeviceRegistered=$facts[3]}
}
function Get-NullProviderAuthority {param($DeadlineUtc) [pscustomobject]@{verified=$true;markerSha256='marker'}}
function New-HeadPoseContinuityIdentity {param($Pose,$PackageAuthority) [pscustomobject]@{identity='same'}}
function Assert-HeadPoseContinuity {param($Before,$After)}
function Get-HeadPoseCanonicalPath {param($Path) [IO.Path]::GetFullPath($Path)}
function Get-HeadPoseSharedState {param($Contract) [pscustomobject]@{qualified=$true;driverCreatorPid=12345;creatorAuthority=[pscustomobject]@{processStartFileTimeUtc=$serverStart.ToFileTimeUtc()}}}
function Get-SharedTextTail {param($Path,$Count,$MaxBytes,$DeadlineUtc)
 $prefix=$serverStart.ToLocalTime().ToString('ddd MMM d yyyy HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)+' [Info] - '
 $prefix+'Loaded server driver null from driver_null.dll'
 $prefix+'Active HMD set to null.Fixture'
 $prefix+'Loaded server driver codex_head_pose from driver_codex_head_pose.dll'
 $prefix+'codex_head_pose: registered synthetic head-pose device at configured standing pose'
}
'@
    $run=@'
$profile=@{driver_null=@{serialNumber='Fixture'};dashboard=@{enableDashboard=$false};headPoseProviderContract=@{poseProbeRelativePath='tools/csx_openvr_pose_probe.exe';minimumQualifiedEyeHeightMeters=1;maximumQualifiedEyeHeightMeters=2.5}}
$deadline=if($Expired){[DateTime]::UtcNow.AddSeconds(-1)}else{[DateTime]::UtcNow.AddSeconds(90)}
$process=[pscustomobject]@{name='vrserver';id=12345;path=(Join-Path $SteamVRRoot 'vrserver.exe');startTimeUtc=$serverStart.ToString('o')}
Get-NullRuntimeEvidence -Processes @($process) -Profile $profile -DeadlineUtc $deadline | ConvertTo-Json -Depth 50 -Compress
'@
    $harness=Join-Path $nullRoot 'harness.ps1'
    [IO.File]::WriteAllText($harness,($setup+"`n"+$definitions+"`n"+$run))
    [IO.File]::WriteAllText((Join-Path $fixture 'vrserver.txt'),'Synthetic log fixture, no live runtime.')
    foreach($case in @('timeout','malformed','empty')){
        $stdout=switch($case){timeout {'partial native progress'} malformed {'{not-json'} empty {''}}
        $bounded=@{ok=$false;errors=@('test diagnostic');attempts=@(@{timedOut=($case -eq 'timeout');stdout=$stdout;stderr='retained native stderr';exitCode=99;exitVerified=$true;jobQuiescent=$true;streamDrainComplete=$true})}
        [IO.File]::WriteAllText((Join-Path $processRoot 'case.json'),($bounded|ConvertTo-Json -Depth 10 -Compress))
        $result=& $harness -Fixture $fixture | ConvertFrom-Json -Depth 50
        Assert-Evidence ($result.active -and $result.serverLogHashLength -eq 12500 -and $null -ne $result.driverLoaded -and $null -ne $result.activeHmd) "$case returns newest partial runtime/log observation"
        Assert-Evidence (-not $result.headPoseReady -and -not $result.controllersReady -and -not $result.applicationHeadPose.qualified) "$case cannot qualify head/controllers"
        Assert-Evidence ($result.applicationHeadPose.boundedProcess.attempts[0].stdout -ceq $stdout -and $result.applicationHeadPose.boundedProcess.attempts[0].stderr -ceq 'retained native stderr') "$case preserves exact bounded stdout/stderr"
        Assert-Evidence ($result.applicationHeadPose.boundedProcess.attempts[0].exitVerified -and $result.applicationHeadPose.boundedProcess.attempts[0].jobQuiescent) "$case preserves child cleanup outcome"
        Assert-Evidence ($result.applicationHeadPose.timedOut -eq ($case -eq 'timeout') -and -not [string]::IsNullOrWhiteSpace($result.applicationHeadPose.error)) "$case has accurate timeout flag and error"
    }
    $expired=& $harness -Fixture $fixture -Expired | ConvertFrom-Json -Depth 50
    Assert-Evidence ($expired.applicationHeadPose.timedOut -and $null -eq $expired.applicationHeadPose.boundedProcess -and -not $expired.headPoseReady) 'insufficient outer budget retains explicit unexecuted/unknown probe outcome'
    Assert-Evidence (@(Get-Content -LiteralPath (Join-Path $processRoot 'dispatch-count.txt')).Count -eq 3) 'one dispatch per tested outcome and no dispatch after deadline'
    @{ok=$true;passed=$passed;liveRuntimeUsed=$false}|ConvertTo-Json -Compress
}
finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing fixture cleanup outside temporary storage.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
