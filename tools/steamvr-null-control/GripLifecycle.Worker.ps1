# SPDX-License-Identifier: GPL-3.0-or-later
param(
    [Parameter(Mandatory)][ValidateSet('session','recovery','publication','native-A','native-B')][string]$Stage,
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][uint64]$DeadlineTickMs,
    [Parameter(Mandatory)][uint64]$PositiveDeadlineTickMs,
    [Parameter(Mandatory)][uint64]$CommonDeadlineTickMs,
    [string]$PlanPath,
    [string]$OfflineCase,
    [string]$CoordinatorFailureBase64
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GripLifecycle.Common.ps1')
$script:phase='preflight'
$script:plan=$null
$script:firstFailure=$null
$script:postErrors=[Collections.Generic.List[object]]::new()
$script:semantic=@()
$script:binding=$null
$script:assayBoundary=$null
$script:probeBoundary=$null
$script:lastControlInterval=$null
$script:beganUtc=[DateTime]::UtcNow.ToString('o')
function Save([string]$Name,$Data){Write-GripJson (Join-Path $Root ($Name+'.json')) $Data $DeadlineTickMs}
function Fail-Once([string]$Reason){if($null -eq $script:firstFailure){$script:firstFailure=@{phase=$script:phase;reason=$Reason;observedTickMs=(Get-GripTick).ToString()};Save 'first-failure' $script:firstFailure}}
function Call-Control([string]$Name,[string]$Command,[hashtable]$Options=@{}){
    $script:phase=$Name+'-'+$Command
    Assert-GripDeadline $DeadlineTickMs
    if($OfflineCase){$data=Invoke-GripFixture $Name $Command $Options}
    else{
        Assert-GripPlan $script:plan
        $path=[string]$script:plan[$Name].path
        $opts=@{NoExit=$true;Compact=$true}
        if($Name -eq 'nullControl'){$opts+=@{SettingsPath=$plan.settingsPath;SteamVRRoot=$plan.steamVRRoot;ServerLogPath=$plan.serverLogPath;OpenVRPathsPath=$plan.openVRPathsPath;HeadPoseDriverRoot=$plan.driverRoot;NullProfilePath=$plan.nullProfile.path};if($Command -in @('apply','start','restore')){$opts.EvidenceDirectory=Join-Path $Root 'runtime'};if($Command -in @('apply','start')){$opts.Standalone=$true}}
        if($Name -eq 'headControl'){$opts+=@{RequireControllers=$true;ProbeTimeoutSeconds=5;PoseProbePath=$plan.poseProbe.path;InstallRoot=$plan.driverRoot;OpenVRPathsPath=$plan.openVRPathsPath}}
        foreach($key in $Options.Keys){$opts[$key]=$Options[$key]}
        $callStart=Get-GripTick
        $data=(& $path $Command @opts) | ConvertFrom-Json -AsHashtable -DateKind String
        $script:lastControlInterval=@{startTickMs=$callStart.ToString();endTickMs=(Get-GripTick).ToString()}
    }
    Save ($script:phase+'-'+[guid]::NewGuid().ToString('N')) $data
    Assert-GripDeadline $DeadlineTickMs
    return $data
}
function Assert-True($Value,[string]$Reason){if($Value -isnot [bool] -or -not $Value){throw $Reason}}
function Verify-Binding($Binding,$Server){
    foreach($key in @('creatorFileTime','driverNonce')){
        [uint64]$parsed=0
        if($Binding[$key] -isnot [string] -or $Binding[$key] -cnotmatch '^[1-9][0-9]*$' -or -not [uint64]::TryParse($Binding[$key],[ref]$parsed)){throw 'Noncanonical uint64 runtime binding'}
    }
    if([int]$Binding.creatorPid -ne [int]$Server.id){throw 'Controller PID differs from admitted vrserver'}
    $fileTime=([DateTimeOffset]::Parse([string]$Server.startTimeUtc)).UtcDateTime.ToFileTimeUtc().ToString()
    if($Binding.creatorFileTime -cne $fileTime){throw 'Controller creation identity differs from admitted vrserver'}
}
function Assert-OwnedInventory($Records){
    foreach($record in $Records){
        if($OfflineCase){Assert-GripFixtureOwner $record;continue}
        $prefix=[IO.Path]::GetFullPath($plan.steamVRRoot).TrimEnd('\')+'\'
        if(-not [IO.Path]::GetFullPath([string]$record.path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [DateTimeOffset]::Parse([string]$record.startTimeUtc) -lt [DateTimeOffset]::Parse($script:beganUtc)){throw 'Runtime survivor is not attributable to this exact closed-baseline session'}
        if($record.name -eq 'vrserver' -and $null -ne $script:binding){Verify-Binding $script:binding $record}
    }
}
function Stop-OwnedRuntime {
    $inventory=Call-Control 'nullControl' 'inspect'
    Assert-OwnedInventory @($inventory.data.runtime.steamVrProcesses)
    $stop=Call-Control 'nullControl' 'stop'
    if(-not $stop.ok){Assert-OwnedInventory @($stop.data.remaining);$stop=Call-Control 'nullControl' 'stop' @{Force=$true}}
    Assert-True $stop.ok 'Owned runtime stop remains unverified'
    $closed=Call-Control 'nullControl' 'inspect'
    if(@($closed.data.runtime.steamVrProcesses).Count -ne 0){throw 'Runtime survivors remain after stop'}
}
function Run-Assay([string]$Mode){
    $script:phase='assay-'+$Mode
    Assert-GripDeadline $PositiveDeadlineTickMs
    $output=Join-Path $Root ($(if($OfflineCase){'injected-assay-'}else{'assay-'})+$Mode+'.json')
    $pwsh=(Get-Process -Id $PID).Path
    $phaseArgs=@('-NoProfile','-File',$PSCommandPath,'-Stage',('native-'+$Mode),'-Root',$Root,'-DeadlineTickMs',$PositiveDeadlineTickMs.ToString(),'-PositiveDeadlineTickMs',$PositiveDeadlineTickMs.ToString(),'-CommonDeadlineTickMs',$CommonDeadlineTickMs.ToString())
    if($OfflineCase){$phaseArgs+=@('-OfflineCase',$OfflineCase,'-PlanPath',$PlanPath);$runner=$PlanPath;$working=$PSScriptRoot}else{$phaseArgs+=@('-PlanPath',$PlanPath);$runner=$plan.boundedProcess.path;$working=Split-Path -Parent $plan.fixture.path}
    $cap=if($Mode -eq 'A'){60}else{7}
    $seconds=[int][Math]::Floor(([Math]::Min([long]$PositiveDeadlineTickMs-[long](Get-GripTick),$cap*1000)-750)/1000)
    if($seconds -lt 1){throw 'No assay budget remains inside common positive ceiling'}
    $launchLower=Get-GripTick
    $raw=& $runner -FilePath $pwsh -ArgumentList $phaseArgs -WorkingDirectory $working -TimeoutSeconds $seconds -MaxAttempts 1 -RetryPatterns @() -TerminationGraceMilliseconds 200 -StreamDrainGraceMilliseconds 200 -NoExit -Compact
    $exitUpper=Get-GripTick
    $receipt=$raw | ConvertFrom-Json -AsHashtable -DateKind String
    Save ('assay-'+$Mode+'-process') $receipt
    if($OfflineCase -eq 'exit-unknown' -and $Mode -eq 'A'){$receipt.attempts[0].jobQuiescent=$false}
    if(@($receipt.attempts).Count -ne 1){throw 'A/B process did not return exactly one owned attempt'}
    $attempt=$receipt.attempts[0]
    foreach($key in @('launched','exitVerified','processTreeOwned','jobQuiescent','jobClosed','streamDrainComplete','deadlineSatisfied')){Assert-True $attempt[$key] ('A/B owned exit field unverified: '+$key)}
    foreach($key in @('timedOut','terminationRequested','unresolvedProcess')){if($attempt[$key] -isnot [bool] -or $attempt[$key]){throw 'Cancelled or unknown A/B worker exit cannot admit a probe'}}
    if($attempt.exitCode -ne 0){throw "Native $Mode diagnostic exited with code $($attempt.exitCode); owned exit/quiescence verified; inspect retained assay result: $output"}
    Assert-True $attempt.ok 'A/B owned attempt reported failure despite zero exit'
    Assert-True $receipt.ok 'A/B process envelope reported failure despite verified zero-exit attempt'
    $body=Read-GripJson $output
    Assert-GripNativeResult $body $Mode $script:binding $PositiveDeadlineTickMs ([bool]$OfflineCase)
    $closeEnd=Convert-GripUInt64 $body.closeBoundary.end.tickMs
    if($closeEnd -lt $launchLower -or $closeEnd -gt $exitUpper){throw 'Native close does not fit the owned worker observation interval'}
    $script:assayBoundary=@{scope='after-shutdown-return-and-worker-exit';externalUnregistrationVerified=$false;shutdownEnd=$body.closeBoundary.end;ownedWorkerPid=$attempt.pid;workerExitObservation=@{lowerTickMs=$closeEnd.ToString();upperTickMs=$exitUpper.ToString();basis='shutdown completed-return through bounded owner return; not exact exit timestamp'};invocationLowerTickMs=$launchLower.ToString();runtimeResponsesSimulated=[bool]$OfflineCase}
    Save ('assay-'+$Mode+'-boundary') $script:assayBoundary
    Assert-GripDeadline $PositiveDeadlineTickMs
    return $body
}
try{
    if($OfflineCase){. (Join-Path $PSScriptRoot 'tests/GripLifecycle.Fixture.ps1')}
    else{$script:plan=Read-GripJson $PlanPath;Assert-GripPlan $script:plan}
    if($Stage -in @('native-A','native-B')){
        Assert-GripDeadline $PositiveDeadlineTickMs
        $mode=if($Stage -eq 'native-A'){'A'}else{'B'}
        if($OfflineCase){$script:binding=Read-GripJson (Join-Path $Root 'binding.json');[void](Invoke-GripFixtureAssay $mode);return}
        $binding=Read-GripJson (Join-Path $Root 'binding.json')
        $nativeArgs=@('-B',$plan.fixture.path,'--live','--mode',$mode,'--output',(Join-Path $Root ('assay-'+$mode+'.json')),'--deadline-tick-ms',$PositiveDeadlineTickMs.ToString(),'--expected-pid',([int]$binding.creatorPid).ToString(),'--expected-creation-filetime',$binding.creatorFileTime,'--expected-driver-nonce',$binding.driverNonce,'--atomics',$plan.atomics.path,'--atomics-sha256',$plan.atomics.sha256)
        # A pinned stable python.cmd is supported through this existing worker,
        # not passed as a non-executable .cmd to native CreateProcess.
        & $plan.python.path @nativeArgs
        if($LASTEXITCODE -ne 0){throw 'Native fixture returned a nonzero diagnostic process exit'}
        return
    }
    elseif($Stage -eq 'session'){
        if(-not $OfflineCase -and @(Get-Process -Name SkyrimVR,sksevr_loader -ErrorAction SilentlyContinue).Count -gt 0){throw 'Standalone runtime transition requires Skyrim and its loader to be closed'}
        $before=Call-Control 'nullControl' 'inspect'
        Assert-True $before.ok 'Baseline inspection failed'
        if($before.state -cne 'null-inactive' -or @($before.data.runtime.steamVrProcesses).Count -ne 0 -or $before.data.effective.active){throw 'A stopped non-null baseline is required; do not adopt another runtime'}
        if($before.data.settingsSha256 -isnot [string] -or $before.data.settingsSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $before.data.externalDrivers.sha256 -isnot [string] -or $before.data.externalDrivers.sha256 -notmatch '^[0-9a-fA-F]{64}$'){throw 'Exact existing settings and registration baseline hashes are required'}
        Save 'before' $before
        Save 'ownership' @{beganUtc=$script:beganUtc;standalone=$true;commonDeadlineTickMs=$CommonDeadlineTickMs.ToString()}
        [void][IO.Directory]::CreateDirectory((Join-Path $Root 'runtime'))
        $preview=Call-Control 'nullControl' 'apply' @{WhatIf=$true};Assert-True $preview.ok 'Apply preview failed'
        $apply=Call-Control 'nullControl' 'apply';Assert-True $apply.ok 'Null apply failed'
        if($apply.state -cne 'null-applied'){throw 'Apply did not create this exact new transaction'}
        $start=Call-Control 'nullControl' 'start' @{StartupTimeoutSeconds=45};Assert-True $start.ok 'Null startup failed'
        if($start.state -cne 'null-runtime-started-head-pose-ready' -or -not $start.data.runtimeReceiptPersisted){throw 'Exact accepted startup receipt is required'}
        $neutral=Call-Control 'headControl' 'qualify';Assert-True $neutral.ok 'Independent initial neutral admission failed'
        $controller=Call-Control 'controllerControl' 'inspect';Assert-True $controller.ok 'Controller identity inspection failed'
        Assert-True $controller.data.provider.inputHealthy 'Controller native input health is unverified'
        if($controller.data.provider.activeOwner -cne '0'){throw 'Another controller input owner is active'}
        $script:binding=$controller.data.binding
        Verify-Binding $script:binding $start.data.runtime.serverProcess
        Save 'binding' $script:binding
        $a=Run-Assay 'A'
        $script:semantic=@($a.semanticMismatches)
        Assert-True $a.controlProtocolValid 'A controller protocol is unverified'
        if($null -ne $a.firstControlFailure){throw 'A reports a first control failure; no after-close dispatch'}
        Assert-True $a.baselineNeutralEstablished 'A independent neutral reset gate failed'
        $aBoundary=$script:assayBoundary
        $fresh=Call-Control 'controllerControl' 'inspect';Assert-True $fresh.ok 'Fresh post-A native inspection failed'
        foreach($key in @('creatorPid','creatorFileTime','driverNonce')){if($fresh.data.binding[$key] -cne $script:binding[$key]){throw 'Runtime instance changed after A'}}
        Assert-True $fresh.data.provider.inputHealthy 'Fresh native input health is unverified'
        [void](Convert-GripUInt64 $fresh.data.provider.activeOwner);[void](Convert-GripUInt64 $fresh.data.provider.deadlineTickMs)
        if($fresh.data.provider.activeOwner -cne '0' -or $fresh.data.provider.deadlineTickMs -cne '0'){throw 'Fresh native lease has not been released'}
        foreach($hand in @('left','right')){
            $pair=$fresh.data.provider.pair[$hand]
            [void](Convert-GripUInt64 $pair.pressed);[void](Convert-GripUInt64 $pair.touched)
            if($pair.pressed -cne '0' -or $pair.touched -cne '0' -or $pair.trackpad.Count -ne 2 -or $pair.stick.Count -ne 2){throw 'Fresh native pair is not neutral'}
            foreach($value in @($pair.trackpad)+@($pair.stick)+@($pair.trigger,$pair.grip)){if($value -isnot [ValueType] -or $value -is [bool] -or [double]$value -ne 0.0){throw 'Fresh native axis is not observed neutral'}}
        }
        Assert-GripDeadline $PositiveDeadlineTickMs
        $script:phase='after-close-probe'
        $probeLower=Get-GripTick
        $probe=Call-Control 'headControl' 'qualify'
        $probeUpper=Get-GripTick
        $script:probeBoundary=@{scope=$aBoundary.scope;externalUnregistrationVerified=$false;shutdownEnd=$aBoundary.shutdownEnd;workerExitObservation=$aBoundary.workerExitObservation;probeInvocation=@{lowerTickMs=$probeLower.ToString();upperTickMs=$probeUpper.ToString()};launchAndInitInterval=@{lowerTickMs=$probeLower.ToString();upperTickMs=$probeUpper.ToString();basis='enclosed by existing qualify invocation; internal launch/init ticks not exposed';exactTicksKnown=$false};shutdownToProbeInvocationMs=($probeLower-[uint64]$aBoundary.shutdownEnd.tickMs).ToString();workerExitUpperToProbeInvocationMs=($probeLower-[uint64]$aBoundary.workerExitObservation.upperTickMs).ToString();runtimeResponsesSimulated=[bool]$OfflineCase}
        Save 'after-close-probe-boundary' $script:probeBoundary
        if(-not $probe.ok){
            # Failure is evidence, not authority to overlap an unclosed observer.
            $probeRun=$probe.data.applicationPose.boundedRun
            if(@($probeRun.attempts).Count -ne 1){throw 'Compiled probe exit evidence is missing; no B dispatch'}
            $probeAttempt=$probeRun.attempts[0]
            foreach($key in @('launched','exitVerified','processTreeOwned','jobQuiescent','jobClosed','streamDrainComplete','deadlineSatisfied')){Assert-True $probeAttempt[$key] ('Compiled probe exit unverified: '+$key)}
            foreach($key in @('timedOut','terminationRequested','unresolvedProcess')){if($probeAttempt[$key] -isnot [bool] -or $probeAttempt[$key]){throw 'Compiled probe cancellation or uncertain exit blocks B'}}
            $b=Run-Assay 'B';Save 'B-summary' $b
        }
    }
    elseif($Stage -eq 'recovery'){
        if(-not (Test-Path -LiteralPath (Join-Path $Root 'ownership.json'))){throw 'No exact session ownership record; recovery is unverified'}
        $ownership=Read-GripJson (Join-Path $Root 'ownership.json');$script:beganUtc=$ownership.beganUtc
        if(Test-Path -LiteralPath (Join-Path $Root 'binding.json')){$script:binding=Read-GripJson (Join-Path $Root 'binding.json')}
        Stop-OwnedRuntime
        $before=Read-GripJson (Join-Path $Root 'before.json')
        $current=Call-Control 'nullControl' 'inspect'
        if($current.state -cne 'null-inactive' -or $current.data.settingsSha256 -cne $before.data.settingsSha256){
            $preview=Call-Control 'nullControl' 'restore' @{WhatIf=$true};Assert-True $preview.ok 'Receipt-bound restore preview failed; no restore dispatch'
            $restore=Call-Control 'nullControl' 'restore';Assert-True $restore.ok 'Receipt-bound settings restore failed'
        }
        $after=Call-Control 'nullControl' 'inspect'
        if($after.state -cne 'null-inactive' -or @($after.data.runtime.steamVrProcesses).Count -ne 0 -or $after.data.settingsSha256 -cne $before.data.settingsSha256 -or $after.data.externalDrivers.sha256 -cne $before.data.externalDrivers.sha256){throw 'Closed runtime and exact settings/registration baseline not verified'}
        Save 'recovery-result' @{verified=$true;beforeSettingsSha256=$before.data.settingsSha256;afterSettingsSha256=$after.data.settingsSha256;registrationSha256=$after.data.externalDrivers.sha256;endedTickMs=(Get-GripTick).ToString()}
    }
    else{
        if($OfflineCase -eq 'publication-stall'){Start-Sleep -Seconds 3600}
        $recovery=if(Test-Path -LiteralPath (Join-Path $Root 'recovery-result.json')){Read-GripJson (Join-Path $Root 'recovery-result.json')}else{@{verified=$false}}
        $primary=if(Test-Path -LiteralPath (Join-Path $Root 'first-failure.json')){Read-GripJson (Join-Path $Root 'first-failure.json')}else{$null}
        if($null -eq $primary -and $CoordinatorFailureBase64){$primary=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CoordinatorFailureBase64)) | ConvertFrom-Json -AsHashtable}
        $group=if(Test-Path -LiteralPath (Join-Path $Root 'session-worker-result.json')){Read-GripJson (Join-Path $Root 'session-worker-result.json')}else{@{completed=$false}}
        $recoveryErrors=if(Test-Path -LiteralPath (Join-Path $Root 'recovery-errors.json')){Read-GripJson (Join-Path $Root 'recovery-errors.json')}else{$null}
        # Never certify a clean state or publish an acceptance pointer. A unique
        # diagnostic result can report both the primary failure and unknown cleanup.
        $report=@{schemaVersion='null-grip-session-result.1';scope=if($OfflineCase){'injected lifecycle with real worker trees'}else{'unqualified live diagnostic'};runtimeResponsesSimulated=[bool]$OfflineCase;firstFailure=$primary;session=$group;recovery=$recovery;recoveryErrors=$recoveryErrors;cleanHandoffVerified=([bool]$recovery.verified);productAcceptancePassed=$false;commonDeadlineTickMs=$CommonDeadlineTickMs.ToString();publicationDeadlineTickMs=$DeadlineTickMs.ToString()}
        Save 'session-result' $report
        @{published=$true;cleanHandoffVerified=[bool]$recovery.verified;resultPath=(Join-Path $Root 'session-result.json')} | ConvertTo-Json -Compress
        return
    }
}catch{
    if($Stage -eq 'session'){Fail-Once $_.Exception.Message}else{$script:postErrors.Add(@{phase=$script:phase;reason=$_.Exception.Message})}
}finally{
    if($Stage -eq 'session'){
        if(Test-Path -LiteralPath (Join-Path $Root 'ownership.json')){try{Stop-OwnedRuntime}catch{$script:postErrors.Add(@{phase='normal-stop';reason=$_.Exception.Message})}}
        Save 'session-worker-result' @{completed=$true;firstFailure=$script:firstFailure;semanticMismatches=$script:semantic;postErrors=$script:postErrors.ToArray();binding=$script:binding;probeBoundary=$script:probeBoundary;externalUnregistrationVerified=$false}
    }
    elseif($Stage -eq 'recovery' -and $script:postErrors.Count -gt 0){Save 'recovery-errors' @{verified=$false;errors=$script:postErrors.ToArray()}}
}
@{completed=$true;stage=$Stage;firstFailure=$script:firstFailure;postErrors=$script:postErrors.ToArray()} | ConvertTo-Json -Depth 5 -Compress
if($Stage -in @('native-A','native-B') -and $script:postErrors.Count -gt 0){exit 2}
