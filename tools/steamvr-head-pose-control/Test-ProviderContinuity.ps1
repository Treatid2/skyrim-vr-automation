# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$checks=0
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$root=Microsoft.PowerShell.Management\Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('provider-continuity-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$probe=Microsoft.PowerShell.Management\Join-Path $root 'tools/csx_openvr_pose_probe.exe'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $probe))
[IO.File]::WriteAllText($probe,'fixture bytes only; never executed')
$stub=Microsoft.PowerShell.Management\Join-Path $root 'bounded-fixture.ps1'
[IO.File]::WriteAllText($stub,@'
param($FilePath,[string[]]$ArgumentList,$WorkingDirectory,$MaxAttempts,$TimeoutSeconds,$TerminationGraceMilliseconds,$StreamDrainGraceMilliseconds,$RetryPatterns,$EvidenceDirectory,[switch]$NoExit,[switch]$Compact)
$global:AutoContinuityDispatches++
@{ok=$true;argumentsReceived=@($ArgumentList);attempts=@(@{exitCode=0;timedOut=$false;stdout='{"ok":true,"standing":{"connected":true,"valid":true,"position":[0,1.68,0]},"stereo":{"valid":true,"eyeSeparationMeters":0.064},"controllers":{"required":true,"valid":true,"leftIndex":1,"rightIndex":2,"neutralSamples":100,"inputEvents":0}}'})}|ConvertTo-Json -Depth 8 -Compress
'@)
function Join-Path {
    param([string]$Path,[string]$ChildPath)
    if($ChildPath -eq 'process-control\Invoke-BoundedProcess.ps1'){return $stub}
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
function Clone($Value){$Value|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10 -AsHashtable}
$repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$PoseProbePath=$probe;$InstallRoot=$root;$HeadPoseDriverRoot=$root
$OpenVRPathsPath=Join-Path $root 'registration.json'
$SteamVRRoot=Join-Path $root 'SteamVR'
$ExpectedPackageProvenanceSha256=$null;$HeadPoseExpectedProvenanceSha256=$null
$ProbeTimeoutSeconds=3;$EvidenceDirectory=$root;$RequireControllers=$true
$MinimumEyeHeightMeters=1.0;$MaximumEyeHeightMeters=2.5
$ServerLogPath=Join-Path $root 'server.log';[IO.File]::WriteAllText($ServerLogPath,'fixture log')
$LogTailMaxBytes=65536;$InternalTestFailurePoint=''
$script:SharedTextTailState=@{}
$profile=@{driver_null=@{serialNumber='fixture-null'};headPoseProviderContract=@{poseProbeRelativePath='tools/csx_openvr_pose_probe.exe';minimumQualifiedEyeHeightMeters=1.0;maximumQualifiedEyeHeightMeters=2.5};dashboard=@{enableDashboard=$false}}
try {
    . (Microsoft.PowerShell.Management\Join-Path $PSScriptRoot 'DriverPackageAuthority.ps1')
    # Full production helper retains exact canonical paths; only OS/package
    # observation/probe transport is replaced by explicit finite fixtures.
    function Get-HeadPosePackageAuthority { $global:AutoContinuityPackageReads++;if($global:AutoContinuityPackageReads -eq 1){$global:AutoContinuityPackageBefore}else{$global:AutoContinuityPackageAfter} }
    function Get-NullProviderAuthority {param($DeadlineUtc);Get-HeadPosePackageAuthority}
    function Read-PoseState {$global:AutoContinuityPoseAfter}
    function Get-HeadPoseSharedState {param($Contract);$global:AutoContinuityPoseReads++;if($global:AutoContinuityPoseReads -eq 1){$global:AutoContinuityPoseBefore}else{$global:AutoContinuityPoseAfter}}
    function Get-SharedTextTail {
        param($Path,$Count,$MaxBytes,$DeadlineUtc)
        $script:SharedTextTailState['fixture']=[pscustomobject]@{stable=$true;usable=$true;continuitySha256=('7'*64);continuityOffset=0;continuityLength=100;bytesRead=100;hashBytesRead=100;incremental=$false;resynchronized=$false}
        $stamp=[datetime]::Now.ToString('ddd MMM d yyyy HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
        @("$stamp [Info] Loaded server driver null fixture driver_null.dll","$stamp [Info] Active HMD set to null.fixture-null","$stamp [Info] Loaded server driver codex_head_pose fixture driver_codex_head_pose.dll","$stamp [Info] codex_head_pose: registered synthetic head-pose device at configured standing pose")
    }
    function Get-NullStartupLogProof {
        param($Path,$Server,$SerialNumber,$MaxBytes,$DeadlineUtc)
        $lines = @(Get-SharedTextTail -Path $Path -Count 2000 -MaxBytes $MaxBytes -DeadlineUtc $DeadlineUtc)
        [pscustomobject]@{stable=$true;complete=$true;driverLoaded=$lines[0];activeHmd=$lines[1];headPoseDriverLoaded=$lines[2];headPoseDeviceRegistered=$lines[3]}
    }
    $script:NullStartupLogProofState=@{}
    foreach($lane in @('head','null')){
        $entry=if($lane -eq 'head'){Microsoft.PowerShell.Management\Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1'}else{Microsoft.PowerShell.Management\Join-Path $repositoryRoot 'tools/steamvr-null-control/Invoke-SteamVRNullControl.ps1'}
        $tokens=$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
        Require (@($errors).Count -eq 0) "$lane source parses"
        $names=if($lane -eq 'head'){@('Invoke-PoseProbe','Test-PassiveControllerProbeObservation','Get-HashOrNull')}else{@('Get-ApplicationHeadPose','Test-PassiveControllerProbeObservation','Get-NullRuntimeEvidence','Get-LogTimestampUtc','Get-RuntimeInputContract')}
        foreach($name in $names){$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0];$declarationRoot=(Split-Path -Parent $entry).Replace("'","''");Invoke-Expression ($node.Extent.Text.Replace('$PSScriptRoot',"'$declarationRoot'"))}
        foreach($case in @('unchanged','pose-refresh','driver-nonce','creator-pid','creator-start','driver-start','module-path','executable-path','writer-nonce','pose-sequence','package-root','provenance','artifact','transaction','whole-restart')){
            $acceptExpected=$case -in @('unchanged','pose-refresh')
            $artifacts=@{};foreach($relative in (Get-HeadPoseArtifactPaths).Values){$artifacts[$relative]='1'*64}
            $global:AutoContinuityPackageBefore=[pscustomobject]@{verified=$true;root=$root;provenanceSha256=('2'*64);markerSha256=('3'*64);transactionId='fixture-committed';sourceCommit=('4'*40);artifacts=$artifacts}
            $global:AutoContinuityPackageAfter=Clone $global:AutoContinuityPackageBefore
            $start=[datetime]::UtcNow.AddSeconds(-10)
            $global:AutoContinuityPoseBefore=[pscustomobject]@{qualified=$true;driverCreatorPid=123;driverStartedFileTimeUtc=[uint64]$start.AddSeconds(1).ToFileTimeUtc();driverInstanceNonce=[uint64]200;writerNonce=[uint64]300;acknowledgedWriterNonce=[uint64]300;requestedSequence=[uint64]2;appliedSequence=[uint64]2;creatorAuthority=[pscustomobject]@{verified=$true;pid=123;processStartFileTimeUtc=[uint64]$start.ToFileTimeUtc();executablePath=(Join-Path $SteamVRRoot 'bin/win64/vrserver.exe');loadedModulePath=(Join-Path $root 'bin/win64/driver_codex_head_pose.dll')}}
            $global:AutoContinuityPoseAfter=Clone $global:AutoContinuityPoseBefore
            if($case -eq 'pose-refresh'){
                $global:AutoContinuityPoseBefore | Add-Member -NotePropertyName observedPose -NotePropertyValue @{position=@(0.0,1.68,0.0);sample='before'}
                $global:AutoContinuityPoseAfter.observedPose=@{position=@(0.25,1.72,-0.5);sample='after'}
                $global:AutoContinuityPackageBefore | Add-Member -NotePropertyName observationPhase -NotePropertyValue 'before'
                $global:AutoContinuityPackageAfter.observationPhase='after'
            }
            switch($case){
                driver-nonce {$global:AutoContinuityPoseAfter.driverInstanceNonce++}
                creator-pid {$global:AutoContinuityPoseAfter.driverCreatorPid++;$global:AutoContinuityPoseAfter.creatorAuthority.pid++}
                creator-start {$global:AutoContinuityPoseAfter.creatorAuthority.processStartFileTimeUtc++}
                driver-start {$global:AutoContinuityPoseAfter.driverStartedFileTimeUtc++}
                module-path {$global:AutoContinuityPoseAfter.creatorAuthority.loadedModulePath=Join-Path $root 'other/driver_codex_head_pose.dll'}
                executable-path {$global:AutoContinuityPoseAfter.creatorAuthority.executablePath=Join-Path $SteamVRRoot 'other/vrserver.exe'}
                writer-nonce {$global:AutoContinuityPoseAfter.writerNonce++;$global:AutoContinuityPoseAfter.acknowledgedWriterNonce++}
                pose-sequence {$global:AutoContinuityPoseAfter.requestedSequence+=2;$global:AutoContinuityPoseAfter.appliedSequence+=2}
                package-root {$global:AutoContinuityPackageAfter.root=Join-Path $root 'other'}
                provenance {$global:AutoContinuityPackageAfter.provenanceSha256='8'*64}
                artifact {$global:AutoContinuityPackageAfter.artifacts.'bin/win64/driver_codex_head_pose.dll'='8'*64}
                transaction {$global:AutoContinuityPackageAfter.transactionId='new-install'}
                whole-restart {$global:AutoContinuityPoseAfter.driverInstanceNonce++;$global:AutoContinuityPoseAfter.driverCreatorPid++;$global:AutoContinuityPoseAfter.creatorAuthority.pid++;$global:AutoContinuityPoseAfter.creatorAuthority.processStartFileTimeUtc++;$global:AutoContinuityPoseAfter.driverStartedFileTimeUtc++}
            }
            $global:AutoContinuityPackageReads=0;$global:AutoContinuityPoseReads=0;$global:AutoContinuityDispatches=0
            if($lane -eq 'head'){
                $observation=Invoke-PoseProbe -PreProbePose $global:AutoContinuityPoseBefore
            }else{
                $processes=@([pscustomobject]@{name='vrserver';id=123;path=$global:AutoContinuityPoseBefore.creatorAuthority.executablePath;startTimeUtc=$start.ToString('o')})
                $runtime=Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                $observation=$runtime.applicationHeadPose
                $contract=Get-RuntimeInputContract -BaseContract @{} -Effective @{active=$true;controllerInactivitySuppressed=$true} -Runtime $runtime -ExternalDrivers @{errors=@();conflicts=@()}
                Require ($runtime.headPoseReady -eq $acceptExpected) "null head readiness $case"
                Require ($runtime.controllersReady -eq $acceptExpected) "null controller readiness $case"
                Require ($contract.measurementReady -eq $acceptExpected) "null measurement admission $case"
                if($acceptExpected){
                    Require ($contract.providerContinuity.sha256 -ceq $runtime.providerContinuity.sha256) 'measurement receipt carries exact tuple'
                    Require ([object]::ReferenceEquals($runtime.headPoseState,$observation.poseAfterProbe)) 'null current pose is the validated post-probe snapshot'
                    Require ([object]::ReferenceEquals($runtime.packageAuthority,$observation.packageAuthority)) 'null current package is the validated post-probe authority'
                    Require ($runtime.serverProcessEvidence -ceq 'validated-post-probe-creator-authority') 'accepted server observation has explicit post-probe provenance'
                    Require ($runtime.serverProcess.id -eq $runtime.headPoseState.creatorAuthority.pid -and $runtime.serverProcess.path -ceq $runtime.headPoseState.creatorAuthority.executablePath -and [DateTime]::Parse($runtime.serverProcess.startTimeUtc).ToUniversalTime().ToFileTimeUtc() -eq $runtime.headPoseState.creatorAuthority.processStartFileTimeUtc) 'accepted server identity is bound to post-probe creator'
                    Require ($runtime.steamVrProcessesEvidence -ceq 'pre-probe-process-inventory') 'historical process inventory explicitly labelled'
                    if($case -eq 'pose-refresh'){
                        Require ($runtime.headPoseState.observedPose.sample -ceq 'after' -and $runtime.packageAuthority.observationPhase -ceq 'after') 'nonidentity post-probe fields replace earlier authority'
                        Require (-not [object]::ReferenceEquals($runtime.headPoseState,$global:AutoContinuityPoseBefore)) 'pre-probe pose is not published as current'
                        # Production start embeds this runtime object; serialized receipt
                        # must retain post-pose and the same measurement tuple.
                        $receipt=@{accepted=$true;runtime=$runtime;inputContract=$contract}|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30
                        Require ($receipt.runtime.headPoseState.observedPose.sample -ceq 'after') 'serialized start runtime carries post-pose'
                        Require ($receipt.inputContract.providerContinuity.sha256 -ceq $receipt.runtime.providerContinuity.sha256) 'serialized measurement binds same post-probe tuple'
                        Require (($receipt.runtime.headPoseState|ConvertTo-Json -Depth 20 -Compress) -ceq ($receipt.runtime.applicationHeadPose.poseAfterProbe|ConvertTo-Json -Depth 20 -Compress)) 'serialized outward and application post-pose value parity'
                    }
                }
            }
            Require ($observation.qualified -eq $acceptExpected) "$lane continuity admission ${case}: $($observation | ConvertTo-Json -Depth 8 -Compress)"
            $expectedDispatches=if($lane -eq 'null' -and $case -in @('package-root','provenance','artifact','transaction')){0}else{1}
            Require ($global:AutoContinuityDispatches -eq $expectedDispatches) "$lane no replay/predispatch custody $case"
            if($acceptExpected){
                Require ($observation.providerContinuity.verified -and $observation.providerContinuity.sha256 -match '^[a-f0-9]{64}$') "$lane immutable tuple receipt"
                $immutable=$observation.providerContinuity.canonicalJson
                $global:AutoContinuityPoseAfter.driverInstanceNonce++
                Require ($observation.providerContinuity.canonicalJson -ceq $immutable) "$lane tuple independent of mutable source"
            }else{
                Require (-not $observation.PSObject.Properties['providerContinuity']) "$lane no accepted continuity receipt $case"
            }
        }
    }
    [pscustomobject]@{ok=$true;checks=$checks;casesPerLane=15;publicLanes=2;nativeExecuted=$false;runtimeChanged=$false;scope='Exact production probe/runtime admission functions; OS observations/transport are finite fixtures, not live startup acceptance'}|ConvertTo-Json -Compress
} finally {
    foreach($name in @('AutoContinuityDispatches','AutoContinuityPoseBefore','AutoContinuityPoseAfter','AutoContinuityPackageBefore','AutoContinuityPackageAfter','AutoContinuityPackageReads','AutoContinuityPoseReads')){Remove-Variable -Scope Global -Name $name -ErrorAction SilentlyContinue}
}
