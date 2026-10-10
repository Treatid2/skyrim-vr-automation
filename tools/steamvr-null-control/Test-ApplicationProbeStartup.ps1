# SPDX-License-Identifier: GPL-3.0-or-later
# Full public apply/start transactions. Only process, log, package and shared-state
# boundaries are synthetic; native executables and live runtime are never called.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('application-probe-startup-' + [guid]::NewGuid().ToString('N'))
$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$priorTransactionRoot = $env:CSX_STEAMVR_TRANSACTION_ROOT
$passed = 0
$caseResults = @()
function Assert-Startup([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
try {
    if (-not ([IO.Path]::GetFullPath($fixture)).StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped OS temporary storage.' }
    $nullRoot = Join-Path $fixture 'tools/steamvr-null-control'
    $processRoot = Join-Path $fixture 'tools/process-control'
    $authorityRoot = Join-Path $fixture 'tools/steamvr-head-pose-control'
    foreach ($path in @($nullRoot,$processRoot,$authorityRoot)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $processRoot 'ProcessLaunchInterop.ps1'), '# Fixture loader: normal launch boundary supplied below, never native.')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../steamvr-head-pose-control/DriverPackageAuthority.ps1') -Destination $authorityRoot
    $entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
    $source = [IO.File]::ReadAllText($entry)
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw 'Production entry parse failed.' }
    # Actual Get-ApplicationHeadPose/Get-NullRuntimeEvidence, gate, public startup
    # loop, confirmation, failure classification, cleanup and receipt writer are
    # never replaced. Actual package continuity identity/checker is also retained.
    $dependencyStubs = @'
function Get-SteamVRProcesses {
    $statePath = Join-Path $SteamVRRoot 'launch.json'
    if (Test-Path -LiteralPath $statePath) {
        $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($s.live) { [pscustomobject]@{name='vrserver';id=12345;path=(Join-Path $SteamVRRoot 'bin/win64/vrserver.exe');startTimeUtc=([DateTimeOffset]$s.startedUtc).UtcDateTime.ToString('o')} }
    }
}
function Get-NullProviderAuthority {
    param([DateTime]$DeadlineUtc = [DateTime]::MaxValue)
    $countPath = Join-Path $HeadPoseDriverRoot 'dispatch-count.txt'
    $count = if (Test-Path -LiteralPath $countPath) { @(Get-Content -LiteralPath $countPath).Count } else { 0 }
    $case = Get-Content -LiteralPath (Join-Path $HeadPoseDriverRoot 'case.txt') -Raw
    $marker = if ($case -ceq 'package-drift' -and $count -eq 1) { 'b' * 64 } else { 'a' * 64 }
    $artifacts = @{}
    foreach ($relative in (Get-HeadPoseArtifactPaths).Values) { $artifacts[$relative] = 'c' * 64 }
    [pscustomobject]@{verified=$true;errors=@();root=$HeadPoseDriverRoot;provenanceSha256=('d'*64);markerSha256=$marker;transactionId='fixture-install';sourceCommit='synthetic-fixture-source';artifacts=$artifacts}
}
function Get-HeadPoseSharedState {
    param($Contract)
    $statePath = Join-Path $SteamVRRoot 'launch.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return [pscustomobject]@{qualified=$false} }
    $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if (-not $s.live) { return [pscustomobject]@{qualified=$false} }
    $case = Get-Content -LiteralPath (Join-Path $HeadPoseDriverRoot 'case.txt') -Raw
    $countPath = Join-Path $HeadPoseDriverRoot 'dispatch-count.txt'
    $count = if (Test-Path -LiteralPath $countPath) { @(Get-Content -LiteralPath $countPath).Count } else { 0 }
    $pollPath = Join-Path $HeadPoseDriverRoot 'provider-polls.txt'
    if ($count -eq 0) {
        [IO.File]::AppendAllText($pollPath,"poll`n")
        if ($case -ceq 'delayed-provider' -and @(Get-Content -LiteralPath $pollPath).Count -eq 1) { return [pscustomobject]@{qualified=$false} }
    }
    $start = ([DateTimeOffset]$s.startedUtc).UtcDateTime.ToFileTimeUtc()
    $nonce = if ($case -ceq 'continuity' -and $count -eq 1) { 99 } else { 1 }
    [pscustomobject]@{
        qualified=$true;driverCreatorPid=12345;driverStartedFileTimeUtc=$start;driverInstanceNonce=$nonce
        writerNonce=1;acknowledgedWriterNonce=1;requestedSequence=2;appliedSequence=2
        creatorAuthority=[pscustomobject]@{verified=$true;pid=12345;processStartFileTimeUtc=$start;executablePath=(Join-Path $SteamVRRoot 'bin/win64/vrserver.exe');loadedModulePath=(Join-Path $HeadPoseDriverRoot 'bin/win64/driver_codex_head_pose.dll')}
    }
}
function Get-SharedTextTail {
    param($Path,$Count,$MaxBytes,$DeadlineUtc)
    $s = Get-Content -LiteralPath (Join-Path $SteamVRRoot 'launch.json') -Raw | ConvertFrom-Json
    $prefix = ([DateTimeOffset]$s.startedUtc).LocalDateTime.ToString('ddd MMM d yyyy HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)+' [Info] - '
    $script:SharedTextTailState=@{fixture=[pscustomobject]@{stable=$true;usable=$true;continuitySha256='synthetic-log-proof';continuityOffset=0;continuityLength=700;bytesRead=700;hashBytesRead=700;incremental=$false;resynchronized=$false}}
    $prefix+'Loaded server driver null from driver_null.dll'
    $prefix+('Active HMD set to null.'+[string]$Profile['driver_null']['serialNumber'])
    $prefix+'Loaded server driver codex_head_pose from driver_codex_head_pose.dll'
    $prefix+'codex_head_pose: registered synthetic head-pose device at configured standing pose'
}
function Get-NullStartupLogProof {
    param($Path,$Server,$SerialNumber,$MaxBytes,$DeadlineUtc)
    $prefix=[string]$Server.startTimeUtc
    @{
        stable=$true;complete=$true
        driverLoaded=[pscustomobject]@{timestampUtc=$prefix;line='synthetic null log'}
        activeHmd=[pscustomobject]@{timestampUtc=$prefix;line='synthetic active HMD log'}
        headPoseDriverLoaded=[pscustomobject]@{timestampUtc=$prefix;line='synthetic pose driver log'}
        headPoseDeviceRegistered=[pscustomobject]@{timestampUtc=$prefix;line='synthetic pose registration log'}
    }
}
'@
    $stubAst = [Management.Automation.Language.Parser]::ParseInput($dependencyStubs,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw 'Dependency stub parse failed.' }
    $replacements = @(foreach ($name in @('Get-SteamVRProcesses','Get-NullProviderAuthority','Get-HeadPoseSharedState','Get-SharedTextTail','Get-NullStartupLogProof')) {
        $target = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if ($name -eq 'Get-NullStartupLogProof' -and $target.Count -eq 0) { continue }
        if ($target.Count -ne 1) { throw "Missing/ambiguous dependency: $name" }
        $stub = @($stubAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if ($stub.Count -ne 1) { throw "Missing/ambiguous stub: $name" }
        @{start=$target[0].Extent.StartOffset;length=$target[0].Extent.EndOffset-$target[0].Extent.StartOffset;text=$stub[0].Extent.Text;name=$name}
    })
    foreach ($replacement in ($replacements | Sort-Object start -Descending)) { $source=$source.Remove($replacement.start,$replacement.length).Insert($replacement.start,$replacement.text) }
    # Integrated source has a separate startup-prefix reader and restoration
    # module. Isolate only the former log boundary; preserve real restore code.
    $externalLogStub=$false
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'StartupLogProof.ps1')){
        $stub=@($stubAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-NullStartupLogProof'},$true))[0].Extent.Text
        [IO.File]::WriteAllText((Join-Path $nullRoot 'StartupLogProof.ps1'),('$script:NullStartupLogProofState=@{}'+[Environment]::NewLine+$stub),[Text.UTF8Encoding]::new($false))
        $externalLogStub=$true
    }
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'DesktopUIRestore.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'DesktopUIRestore.ps1') -Destination $nullRoot}
    $fixtureEntry = Join-Path $nullRoot 'Invoke-SteamVRNullControl.ps1'
    [IO.File]::WriteAllText($fixtureEntry,$source,[Text.UTF8Encoding]::new($false))
    $boundedStub = @'
param($FilePath,$ArgumentList,$WorkingDirectory,$MaxAttempts,$TimeoutSeconds,$TerminationGraceMilliseconds,$StreamDrainGraceMilliseconds,[switch]$NoExit,[switch]$Compact)
if($MaxAttempts -ne 1 -or $ArgumentList -cne '--require-controllers' -or $TimeoutSeconds -gt 10 -or $TerminationGraceMilliseconds -ne 100 -or $StreamDrainGraceMilliseconds -ne 100){throw 'Production bounded dispatch contract changed.'}
$root=Split-Path -Parent $WorkingDirectory
$countPath=Join-Path $root 'dispatch-count.txt'
[IO.File]::AppendAllText($countPath,"one`n")
$count=@(Get-Content -LiteralPath $countPath).Count
$case=Get-Content -LiteralPath (Join-Path $root 'case.txt') -Raw
$payload=@{ok=$true;standing=@{connected=$true;valid=$true;position=@(0,1.68,0)};controllers=@{required=$true;valid=$true;leftIndex=1;rightIndex=2;neutralSamples=100;inputEvents=0}}
$stdout=$payload|ConvertTo-Json -Depth 8 -Compress
$ok=$true;$code=0;$timedOut=$false;$errors=@();$drained=$true;$stderr='first native stderr'
# Every first-failure case would succeed on a second call. This is intentional:
# a faulty outer retry must make the public test fail by accepting the attempt.
if($count -eq 1){
    switch($case){
        'empty' {$stdout=''}
        'undrained' {$ok=$false;$drained=$false;$stdout=$null;$stderr=$null;$errors=@('synthetic stream drain incomplete')}
        'malformed' {$stdout='{not-json'}
        'exit' {$ok=$false;$code=23;$errors=@('synthetic native exit failure')}
        'timeout' {$ok=$false;$timedOut=$true;$stdout='partial native stdout'}
        'unqualified' {$payload.standing.valid=$false;$stdout=$payload|ConvertTo-Json -Depth 8 -Compress}
    }
}
if($case -ceq 'confirmation-malformed' -and $count -eq 2){$stdout='{confirmation-invalid'}
@{ok=$ok;errors=$errors;attempts=@(@{timedOut=$timedOut;stdout=$stdout;stderr=$stderr;exitCode=$code;exitVerified=$true;jobQuiescent=$true;streamDrainComplete=$drained})}|ConvertTo-Json -Depth 10 -Compress
'@
    [IO.File]::WriteAllText((Join-Path $processRoot 'Invoke-BoundedProcess.ps1'),$boundedStub,[Text.UTF8Encoding]::new($false))
    # Process effects are mocked at their native API boundary. Production exact
    # root/start-time target filtering and post-stop verification remain real.
    function Start-NormalInteractiveProcess {
        [CmdletBinding()]param($FilePath,$DeadlineUtc)
        if ($DeadlineUtc -le [DateTime]::UtcNow -or $FilePath -cne (Join-Path $SteamVRRoot 'bin/win64/vrstartup.exe')) { throw 'Unexpected fixture launch.' }
        [IO.File]::WriteAllText((Join-Path $SteamVRRoot 'launch.json'),(@{live=$true;startedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress))
        [pscustomobject]@{Id=12345;interactiveLaunch=@{normalUserAccessVerified=$true;method='synthetic-fixture'}}
    }
    function Stop-Process {
        [CmdletBinding()]param([int]$Id,[switch]$Force)
        if($Id -ne 12345 -or -not $Force){throw 'Unexpected fixture stop target.'}
        [IO.File]::AppendAllText((Join-Path $SteamVRRoot 'stopped.txt'),"$Id`n")
        [IO.File]::WriteAllText((Join-Path $SteamVRRoot 'launch.json'),'{"live":false}')
    }
    function Get-Process {
        [CmdletBinding()]param([int]$Id)
        if($Id -ne 12345){throw 'Unexpected fixture process query.'}
        $s=Get-Content -LiteralPath (Join-Path $SteamVRRoot 'launch.json') -Raw|ConvertFrom-Json
        if($s.live){[pscustomobject]@{Id=12345}}
    }
    $kinds=@{empty='empty-output';undrained='stream-drain-incomplete';malformed='malformed-output';'package-drift'='provider-package-drift';continuity='continuity-failed';exit='bounded-process-failure';timeout='timeout';unqualified='observation-unqualified';'confirmation-malformed'='malformed-output'}
    foreach ($case in @('empty','undrained','malformed','package-drift','continuity','exit','timeout','unqualified','confirmation-malformed','success','delayed-provider','insufficient-budget')) {
        $caseRoot=Join-Path $fixture $case
        $script:currentSteamRoot=Join-Path $caseRoot 'SteamVR'
        $provider=Join-Path $caseRoot 'provider'
        $evidence=Join-Path $caseRoot 'evidence'
        foreach($path in @((Join-Path $script:currentSteamRoot 'bin/win64'),(Join-Path $provider 'tools'),$evidence)){[IO.Directory]::CreateDirectory($path)|Out-Null}
        [IO.File]::WriteAllText((Join-Path $script:currentSteamRoot 'bin/win64/vrstartup.exe'),'Never executed.')
        [IO.File]::WriteAllText((Join-Path $provider 'tools/csx_openvr_pose_probe.exe'),'Never executed.')
        [IO.File]::WriteAllText((Join-Path $provider 'driver.vrdrivermanifest'),'{"name":"codex_head_pose","alwaysActivate":true,"redirectsDisplay":false}')
        [IO.File]::WriteAllText((Join-Path $provider 'case.txt'),$case)
        $settings=Join-Path $caseRoot 'steamvr.vrsettings'
        $profile=Join-Path $caseRoot 'profile.json'
        $openVR=Join-Path $caseRoot 'openvrpaths.vrpath'
        $log=Join-Path $caseRoot 'vrserver.txt'
        [IO.File]::WriteAllText($settings,'{"unrelated":{"retained":true}}')
        [IO.File]::WriteAllText($log,'Synthetic log only.')
        [IO.File]::WriteAllText($openVR,(@{version=1;external_drivers=@($provider)}|ConvertTo-Json -Compress))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../profiles/steamvr-null.profile.json') -Destination $profile
        $env:CSX_STEAMVR_TRANSACTION_ROOT=Join-Path $caseRoot 'transactions'
        $parameters=@{SettingsPath=$settings;NullProfilePath=$profile;SteamVRRoot=$script:currentSteamRoot;HeadPoseDriverRoot=$provider;ServerLogPath=$log;OpenVRPathsPath=$openVR;EvidenceDirectory=$evidence;Compact=$true;NoExit=$true}
        $apply=& $fixtureEntry apply @parameters|ConvertFrom-Json -Depth 80
        Assert-Startup ($apply.ok -and $apply.state -ceq 'null-applied') "$case real temporary apply transaction"
        $startupSeconds=if($case -ceq 'insufficient-budget'){5}else{20}
        $result=& $fixtureEntry start @parameters -StartupTimeoutSeconds $startupSeconds|ConvertFrom-Json -Depth 80
        if(-not $result.data.PSObject.Properties['runtimeReceiptPath']){throw "Public start did not reach attempt receipt: $($result|ConvertTo-Json -Depth 20 -Compress)"}
        $receipt=Get-Content -LiteralPath $result.data.runtimeReceiptPath -Raw|ConvertFrom-Json -Depth 80
        $countPath=Join-Path $provider 'dispatch-count.txt'
        $count=if(Test-Path -LiteralPath $countPath){@(Get-Content -LiteralPath $countPath).Count}else{0}
        if($case -ceq 'insufficient-budget'){
            $application=$result.data.runtime.applicationHeadPose
            Assert-Startup (-not $result.ok -and $result.state -ceq 'application-pose-probe-insufficient-budget' -and $receipt.admissionState -ceq $result.state) 'budget refusal public state/receipt agree'
            Assert-Startup ($count -eq 0 -and -not $application.probeAttempted -and -not $application.timedOut -and $null -eq $application.boundedProcess -and $application.failureKind -ceq 'insufficient-probe-budget') 'public late budget never dispatches or claims timeout'
            Assert-Startup ($application.probeBudget.deadlineUtc -ceq $receipt.qualificationDeadlineUtc -and $application.probeBudget.requiredMilliseconds -eq 11450 -and -not $application.probeBudget.admitted) 'probe admission excludes final verification reserve'
            Assert-Startup (-not $receipt.runtimeAccepted -and $null -eq $receipt.acceptedUtc -and -not $receipt.runtimeConfirmationAttempted -and $result.data.startupCleanup.verified) 'budget refusal preserves failed receipt/exact cleanup without confirmation'
        }elseif($case -in @('success','delayed-provider')){
            Assert-Startup ($result.ok -and $receipt.runtimeAccepted -and $result.data.runtime.headPoseReady -and $result.data.runtime.controllersReady) "$case successful production qualification retained"
            Assert-Startup ($count -eq 2 -and $receipt.runtimeConfirmationAttempted) "$case independent success confirmation retained"
            Assert-Startup (-not $result.data.runtime.applicationHeadPose.terminalFailure -and $null -eq $result.data.runtime.applicationHeadPose.failureKind) "$case success disposition"
            if($case -ceq 'delayed-provider'){Assert-Startup ($receipt.runtimeProbeAttempts -ge 3) 'not-yet-admitted provider remains pollable'}
        }else{
            $expectedCount=if($case -ceq 'confirmation-malformed'){2}else{1}
            $expectedState=if($case -ceq 'timeout'){'application-pose-probe-timeout'}else{'application-pose-probe-failed'}
            $application=$result.data.runtime.applicationHeadPose
            Assert-Startup (-not $result.ok -and $result.state -ceq $expectedState -and $receipt.admissionState -ceq $expectedState) "$case explicit failed-probe state returned and persisted"
            Assert-Startup ($count -eq $expectedCount -and $receipt.runtimeProbeAttempts -eq $expectedCount) "$case no failed-observation replay despite available next success"
            Assert-Startup ($receipt.runtimeConfirmationAttempted -eq ($case -ceq 'confirmation-malformed') -and -not $receipt.runtimeConfirmationTimedOut) "$case no unexpected confirmation"
            Assert-Startup ($application.probeAttempted -and $application.terminalFailure -and $application.failureKind -ceq $kinds[$case]) "$case precise terminal disposition"
            Assert-Startup ($application.timedOut -eq ($case -ceq 'timeout')) "$case accurate timeout flag"
            Assert-Startup (-not $result.data.runtime.headPoseReady -and -not $result.data.runtime.controllersReady -and -not $result.data.inputContract.measurementReady) "$case no qualification from activation"
            Assert-Startup (($application.boundedProcess|ConvertTo-Json -Depth 40 -Compress) -ceq ($receipt.runtime.applicationHeadPose.boundedProcess|ConvertTo-Json -Depth 40 -Compress)) "$case full bounded outcome byte-equivalent returned/persisted"
            $expectedStderr=if($case -ceq 'undrained'){$null}else{'first native stderr'}
            Assert-Startup ($application.boundedProcess.attempts[0].stderr -ceq $expectedStderr -and $application.boundedProcess.attempts[0].exitVerified -and $application.boundedProcess.attempts[0].jobQuiescent) "$case stderr and native child cleanup retained"
            $expectedStdout=switch($case){empty {''} undrained {$null} malformed {'{not-json'} timeout {'partial native stdout'} 'confirmation-malformed' {'{confirmation-invalid'} default {$application.observation|ConvertTo-Json -Depth 8 -Compress}}
            Assert-Startup ($application.boundedProcess.attempts[0].stdout -ceq $expectedStdout) "$case exact first stdout retained"
            if($case -ceq 'undrained'){
                Assert-Startup (-not $application.boundedProcess.attempts[0].streamDrainComplete -and $null -eq $application.boundedProcess.attempts[0].stdout -and $null -eq $application.boundedProcess.attempts[0].stderr -and $null -eq $application.observation) 'unknown output is not empty or a parsed observation'
                Assert-Startup ($application.failureKind -cne 'empty-output' -and $receipt.runtime.applicationHeadPose.failureKind -ceq 'stream-drain-incomplete' -and -not $receipt.runtimeConfirmationAttempted) 'unavailable output disposition persists without confirmation'
            }
            Assert-Startup (-not [string]::IsNullOrWhiteSpace($application.error) -and $receipt.lastRuntimeProbeError -ceq $application.error -and $result.data.admission.lastRuntimeProbeError -ceq $application.error) "$case exact error retained in admission and receipt"
            Assert-Startup (-not $receipt.runtimeAccepted -and $null -eq $receipt.acceptedUtc -and $receipt.attemptId -ceq $result.data.runtimeAttemptId -and $result.data.runtimeReceiptPersisted) "$case failed attempt cannot publish accepted authority"
            Assert-Startup ($result.data.startupCleanup.verified -and @($result.data.startupCleanup.requested).Count -eq 1 -and $result.data.startupCleanup.requested[0].id -eq 12345 -and @($result.data.startupCleanup.remaining).Count -eq 0 -and @(Get-Content -LiteralPath (Join-Path $script:currentSteamRoot 'stopped.txt')).Count -eq 1) "$case actual exact-attempt cleanup dispatch/verification: $($result.data.startupCleanup|ConvertTo-Json -Depth 8 -Compress)"
        }
        $caseResults+=@{case=$case;dispatches=$count;state=$result.state;runtimeProbeAttempts=$receipt.runtimeProbeAttempts;confirmation=$receipt.runtimeConfirmationAttempted;accepted=$receipt.runtimeAccepted}
    }
    @{ok=$true;passed=$passed;liveRuntimeUsed=$false;cases=$caseResults;replacedDependencies=@($replacements.name);externalStartupLogStub=$externalLogStub;productionStartLoopRetained=$true;productionProbeRetained=$true;productionContinuityRetained=$true;productionCleanupRetained=$true}|ConvertTo-Json -Depth 10 -Compress
} finally {
    $env:CSX_STEAMVR_TRANSACTION_ROOT=$priorTransactionRoot
    foreach($name in @('Start-NormalInteractiveProcess','Stop-Process','Get-Process')){Remove-Item -LiteralPath ("Function:\$name") -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved)).StartsWith('application-probe-startup-')){throw 'Refusing cleanup outside exact temporary fixture.'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

