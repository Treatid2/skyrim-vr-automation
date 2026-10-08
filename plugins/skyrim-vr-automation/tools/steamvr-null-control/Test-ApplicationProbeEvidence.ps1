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
param([string]$Fixture,[switch]$Expired,[switch]$NotReady)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$HeadPoseDriverRoot=Join-Path $Fixture 'provider'
$SteamVRRoot=Join-Path $Fixture 'SteamVR'
$ServerLogPath=Join-Path $Fixture 'vrserver.txt'
$LogTailMaxBytes=262144
$InternalTestFailurePoint=''
$script:SharedTextTailState=@{current=[pscustomobject]@{stable=$true;usable=$true;continuitySha256='new-partial-log';continuityOffset=0;continuityLength=12500;bytesRead=12500;hashBytesRead=12500;incremental=$false;resynchronized=$false}}
$serverStart=[DateTime]::UtcNow.AddSeconds(-1)
function Get-NullProviderAuthority {param($DeadlineUtc) [pscustomobject]@{verified=$true;markerSha256='marker'}}
function New-HeadPoseContinuityIdentity {param($Pose,$PackageAuthority) [pscustomobject]@{identity='same'}}
function Assert-HeadPoseContinuity {param($Before,$After)}
function Get-HeadPoseCanonicalPath {param($Path) [IO.Path]::GetFullPath($Path)}
function Get-HeadPoseSharedState {param($Contract) [pscustomobject]@{qualified=(-not $NotReady);driverCreatorPid=12345;creatorAuthority=[pscustomobject]@{processStartFileTimeUtc=$serverStart.ToFileTimeUtc()}}}
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
    foreach($case in @('timeout','malformed','empty','undrained')){
        $stdout=switch($case){timeout {'partial native progress'} malformed {'{not-json'} empty {''} undrained {$null}}
        $stderr=if($case -eq 'undrained'){$null}else{'retained native stderr'}
        $bounded=@{ok=$false;errors=@('test diagnostic');attempts=@(@{timedOut=($case -eq 'timeout');stdout=$stdout;stderr=$stderr;exitCode=99;exitVerified=$true;jobQuiescent=$true;streamDrainComplete=($case -ne 'undrained')})}
        [IO.File]::WriteAllText((Join-Path $processRoot 'case.json'),($bounded|ConvertTo-Json -Depth 10 -Compress))
        $result=& $harness -Fixture $fixture | ConvertFrom-Json -Depth 50
        Assert-Evidence ($result.active -and $result.serverLogHashLength -eq 12500 -and $null -ne $result.driverLoaded -and $null -ne $result.activeHmd) "$case returns newest partial runtime/log observation"
        Assert-Evidence (-not $result.headPoseReady -and -not $result.controllersReady -and -not $result.applicationHeadPose.qualified) "$case cannot qualify head/controllers"
        Assert-Evidence ($result.applicationHeadPose.boundedProcess.attempts[0].stdout -ceq $stdout -and $result.applicationHeadPose.boundedProcess.attempts[0].stderr -ceq $stderr) "$case preserves exact bounded stdout/stderr"
        Assert-Evidence ($result.applicationHeadPose.boundedProcess.attempts[0].exitVerified -and $result.applicationHeadPose.boundedProcess.attempts[0].jobQuiescent) "$case preserves child cleanup outcome"
        Assert-Evidence ($result.applicationHeadPose.timedOut -eq ($case -eq 'timeout') -and -not [string]::IsNullOrWhiteSpace($result.applicationHeadPose.error)) "$case has accurate timeout flag and error"
        $kind=switch($case){timeout {'timeout'} malformed {'malformed-output'} empty {'empty-output'} undrained {'stream-drain-incomplete'}}
        Assert-Evidence ($result.applicationHeadPose.probeAttempted -and $result.applicationHeadPose.terminalFailure -and $result.applicationHeadPose.failureKind -ceq $kind) "$case is an explicitly terminal admitted failure"
        if($case -eq 'undrained'){
            Assert-Evidence (-not $result.applicationHeadPose.boundedProcess.attempts[0].streamDrainComplete -and $null -eq $result.applicationHeadPose.boundedProcess.attempts[0].stdout -and $null -eq $result.applicationHeadPose.boundedProcess.attempts[0].stderr) 'undrained output remains unknown, not empty'
            Assert-Evidence (($result.applicationHeadPose.boundedProcess|ConvertTo-Json -Depth 10 -Compress) -ceq (($bounded|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json)|ConvertTo-Json -Depth 10 -Compress)) 'undrained complete bounded evidence is unchanged'
        }
    }
    foreach($shape in @('missing-drain','string-drain','no-attempt','multiple-attempts','null-drained-stdout')){
        $attempt=@{timedOut=$false;stdout='';stderr='shape diagnostic';exitCode=0;streamDrainComplete=$true}
        $bounded=@{ok=$false;errors=@('shape diagnostic');attempts=@($attempt)}
        $expectedKind='stream-drain-incomplete'
        switch($shape){
            'missing-drain' {$attempt.Remove('streamDrainComplete')}
            'string-drain' {$attempt.streamDrainComplete='true'}
            'no-attempt' {$bounded.attempts=@();$expectedKind='bounded-attempt-invalid'}
            'multiple-attempts' {$bounded.attempts=@($attempt,$attempt);$expectedKind='bounded-attempt-invalid'}
            'null-drained-stdout' {$attempt.stdout=$null;$expectedKind='output-unavailable'}
        }
        [IO.File]::WriteAllText((Join-Path $processRoot 'case.json'),($bounded|ConvertTo-Json -Depth 10 -Compress))
        $result=& $harness -Fixture $fixture|ConvertFrom-Json -Depth 50
        Assert-Evidence ($result.applicationHeadPose.terminalFailure -and $result.applicationHeadPose.failureKind -ceq $expectedKind -and -not $result.headPoseReady) "$shape cannot manufacture known empty output or qualification"
        Assert-Evidence (($result.applicationHeadPose.boundedProcess|ConvertTo-Json -Depth 10 -Compress) -ceq (($bounded|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json)|ConvertTo-Json -Depth 10 -Compress)) "$shape retains exact bounded evidence"
    }
    $expired=& $harness -Fixture $fixture -Expired | ConvertFrom-Json -Depth 50
    Assert-Evidence ($expired.applicationHeadPose.timedOut -and $null -eq $expired.applicationHeadPose.boundedProcess -and -not $expired.headPoseReady) 'insufficient outer budget retains explicit unexecuted/unknown probe outcome'
    Assert-Evidence (-not $expired.applicationHeadPose.probeAttempted -and $expired.applicationHeadPose.terminalFailure -and $expired.applicationHeadPose.failureKind -ceq 'insufficient-budget') 'budget refusal is terminal but does not claim an executed probe'
    $notReady=& $harness -Fixture $fixture -NotReady | ConvertFrom-Json -Depth 50
    Assert-Evidence (-not $notReady.applicationHeadPose.probeAttempted -and -not $notReady.applicationHeadPose.terminalFailure -and $null -eq $notReady.applicationHeadPose.failureKind) 'pre-admission provider state is not a terminal probe outcome'
    Assert-Evidence (-not $notReady.headPoseReady -and -not $notReady.controllersReady) 'pre-admission observation remains unqualified'
    Remove-Item -LiteralPath (Join-Path $providerRoot 'csx_openvr_pose_probe.exe')
    $missing=& $harness -Fixture $fixture | ConvertFrom-Json -Depth 50
    Assert-Evidence (-not $missing.applicationHeadPose.probeAttempted -and $missing.applicationHeadPose.terminalFailure -and $missing.applicationHeadPose.failureKind -ceq 'probe-unavailable') 'admitted missing probe is terminal without a native dispatch'
    Assert-Evidence ($null -eq $missing.applicationHeadPose.boundedProcess -and -not $missing.headPoseReady) 'missing probe does not manufacture a bounded outcome'
    Assert-Evidence (@(Get-Content -LiteralPath (Join-Path $processRoot 'dispatch-count.txt')).Count -eq 9) 'one dispatch per tested outcome and no dispatch after deadline'
    @{ok=$true;passed=$passed;liveRuntimeUsed=$false}|ConvertTo-Json -Compress
}
finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing fixture cleanup outside temporary storage.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
