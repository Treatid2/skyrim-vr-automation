# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([switch]$FixtureOnly,[string]$FixtureMode='healthy')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$requestedFixtureOnly=[bool]$FixtureOnly
$fixture=. (Join-Path $PSScriptRoot 'Test-ColourMeasurementWindow.ps1') -FixtureOnly -FixtureMode $FixtureMode
$native=$fixture.Call;$nativeGuard=$fixture.Guard
$script:baselineMode=$FixtureMode;$script:baselineStatuses=0;$script:baselineEyes=$null
$script:baselineCaptureEyes=$null;$script:baselineFrame=61039;$script:baselineCaptureFrame=61039
$plan=$fixture.Plan.Clone();$plan.autoExposure=$FixtureMode -cne 'healthy-false';$plan.capturesPerCondition=16
$plan.burnIn=@{minimumElapsedMilliseconds=20;minimumObservedCpuFrameIdAdvancePerEye=2;minimumDistinctFreshSuccessfulBothEyeObservations=3;maximumElapsedMilliseconds=600}
$plan.minimumElapsedMillisecondsBetweenCaptureArms=1
if($FixtureMode -cin @('healthy-false','ae-mismatch')){$script:auto=$false}
$call={
    param($name,$argsMap,$mutation,$bound)
    if($name -ceq 'communityshaders.fsr_color_contract' -and $argsMap.action -cne 'status'){throw 'Fixture forbids colour mutation'}
    $reply=& $native $name $argsMap $mutation $bound
    $p=$reply.content[0]
    if($name -ceq 'communityshaders.fsr_color_contract'){
        $script:baselineStatuses++;$n=$script:baselineStatuses
        $script:baselineFrame=61039+$n
        if($script:baselineMode -ceq 'burnin-incomplete'){$script:baselineFrame=61039}
        if($script:baselineMode -ceq 'hdr-mismatch'){$p.requested.highDynamicRangeInput=$false}
        if($script:baselineMode -ceq 'external-ae-drift' -and $n -ge 5){$p.requested.autoExposure=$false}
        foreach($eye in 0,1){$d=$p.lastSuccessfulEyeDispatches[$eye];$d.frame=$script:baselineFrame;$d.serial=21879+$eye+$n*2;$d.dispatchQpc=21311392938929+$eye*481+$n*1000}
        $p.lastSuccessfulDispatch=CloneFixture $p.lastSuccessfulEyeDispatches[1]
        $script:baselineEyes=CloneFixture $p.lastSuccessfulEyeDispatches
    }
    if($name -ceq 'communityshaders.colour_pipeline_probe'){
        if($argsMap.action -ceq 'arm'){
            $script:baselineCaptureFrame=$script:baselineFrame+1
            $script:baselineCaptureEyes=CloneFixture $script:baselineEyes
            foreach($d in $script:baselineCaptureEyes){$d.frame=$script:baselineCaptureFrame;$d.serial+=2;$d.dispatchQpc+=1000}
        }
        if($argsMap.action -ceq 'status' -and -not $script:reset -and $script:baselineMode -cne 'native-failure'){$p.cpuFrame=$script:baselineCaptureFrame}
        if($argsMap.action -ceq 'read'){
            $p.frame.cpuFrame=$script:baselineCaptureFrame;$p.stages[0].frame.cpuFrame=$script:baselineCaptureFrame
            $d=$p.dispatch;$eye=$script:baselineCaptureEyes[$argsMap.eye];$d.frame=$script:baselineCaptureFrame;$d.dispatchSerial=$eye.serial
            foreach($field in @('renderWidth','renderHeight','displayWidth','displayHeight','configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled','dispatchQpc')){$d|Add-Member -NotePropertyName $field -NotePropertyValue $eye.$field -Force}
        }
    }
    $dispatches=if($name -ceq 'communityshaders.fsr_color_contract'){@($p.lastSuccessfulDispatch)+@($p.lastSuccessfulEyeDispatches)}elseif($argsMap.action -ceq 'read'){@($p.dispatch)}else{@()}
    foreach($d in $dispatches){
        $input=[pscustomobject]@{schemaVersion=1;available=$true;reset=$false;jitterOffsetPixels=@(-0.25,0.125);frameTimeDeltaMilliseconds=13.5}
        if($script:baselineMode -ceq 'telemetry-unavailable'){$input.available=$false;$input.reset=$null;$input.jitterOffsetPixels=$null;$input.frameTimeDeltaMilliseconds=$null}
        if($script:baselineMode -ceq 'telemetry-malformed'){$input.reset='false'}
        if($script:baselineMode -ceq 'page-telemetry-unavailable' -and $name -ceq 'communityshaders.colour_pipeline_probe'){$input.available=$false;$input.reset=$null;$input.jitterOffsetPixels=$null;$input.frameTimeDeltaMilliseconds=$null}
        $d|Add-Member -NotePropertyName submittedInputs -NotePropertyValue $input -Force
    }
    if($name -ceq 'communityshaders.colour_pipeline_probe' -and $argsMap.action -ceq 'read'){$p.stages[0].dispatch=CloneFixture $p.dispatch}
    return $reply
}
$cleanup={param($name,$argsMap,$mutation,$bound)$script:cleanupPhase=$true;& $call $name $argsMap $mutation $bound}
if($requestedFixtureOnly){return [pscustomobject]@{Call=$call;Guard=$nativeGuard;Cleanup=$cleanup;Plan=$plan;Producer=$fixture.Producer}}
$script:baselineChecks=0
function BCheck($value,$message){if(-not $value){throw $message};$script:baselineChecks++}
$cases=@('healthy','healthy-false','ae-mismatch','hdr-mismatch','foreign-revision','telemetry-unavailable','telemetry-malformed','page-telemetry-unavailable','partial-page','compiler','lost-arm','lost-reset','native-failure','external-ae-drift','burnin-incomplete')
$summaries=@()
foreach($mode in $cases){
    $f=. $PSCommandPath -FixtureOnly -FixtureMode $mode
    $deadline=[datetime]::UtcNow.AddSeconds(25)
    $r=Invoke-DevBenchColourMeasurement -FixedAutoExposure -Call $f.Call -CompilerGuard $f.Guard -CleanupCall $f.Cleanup -Plan $f.Plan -DeadlineUtc $deadline -CleanupDeadlineUtc $deadline.AddSeconds(2) -PollMilliseconds 10
    $expected=$mode -cin @('healthy','healthy-false')
    BCheck ($r.ok -eq $expected) "$mode outcome: $($r.errors -join ';')"
    BCheck ($script:setCount -eq 0 -and @($script:calls|Where-Object {$_.name -ceq 'communityshaders.fsr_color_contract' -and ($_.arguments.action -cne 'status' -or $_.mutation)}).Count -eq 0) "$mode ZERO colour writes including cleanup"
    BCheck $r.fixedAutoExposureBaseline "$mode typed baseline result"
    if($expected){
        BCheck ($r.conditions.Count -eq 1 -and $r.captures.Count -eq 16 -and @($r.captures|ForEach-Object {$_.pages}).Count -eq 160) "$mode complete single-condition sixteen capture inventory"
        BCheck (@($r.captures|Where-Object {-not $_.complete -or -not $_.resetVerified}).Count -eq 0 -and $r.colourCleanup.verified -and $r.finalRevision -eq 1) "$mode owned resets and unchanged admitted revision"
        BCheck (@($r.captures|ForEach-Object {$_.pages}|Where-Object {-not $_.dispatch.submittedInputs.available -or $_.dispatch.submittedInputs.reset -isnot [bool] -or $_.dispatch.submittedInputs.frameTimeDeltaMilliseconds -ne 13.5}).Count -eq 0) "$mode actual native typed inputs retained"
    }else{
        BCheck ($r.captures.Count -le 1) "$mode no successor capture on invalidation"
        if($mode -cin @('lost-arm','lost-reset')){BCheck ($r.indeterminate -and @($script:calls|Where-Object {$_.arguments.action -ceq $mode.Substring(5)}).Count -eq 1) "$mode lost mutation never replayed"}
        if($mode -cin @('partial-page','page-telemetry-unavailable','native-failure')){BCheck ($r.probeCleanup.verified -and -not $r.captures[0].complete) "$mode partial evidence and owned cleanup separate"}
        if($mode -ceq 'external-ae-drift'){BCheck (-not $r.colourCleanup.verified -and $r.indeterminate) 'Foreign AE drift is not rewritten during cleanup'}
    }
    $summaries+=@{case=$mode;ok=$r.ok;captures=$r.captures.Count;colourWrites=$script:setCount}
}
$f=. $PSCommandPath -FixtureOnly
Assert-ColourMeasurementPlan $f.Plan -FixedAutoExposure
foreach($field in @('autoExposure','burnIn','minimumElapsedMillisecondsBetweenCaptureArms')){
    $bad=$f.Plan.Clone();$bad.Remove($field);$refused=$false
    try{Assert-ColourMeasurementPlan $bad -FixedAutoExposure}catch{$refused=$true};BCheck $refused "Required baseline field $field"
}
foreach($value in @('16',16.5,$true,$null,0,-1,17)){
    $bad=$f.Plan.Clone();$bad.capturesPerCondition=$value;$refused=$false
    try{Assert-ColourMeasurementPlan $bad -FixedAutoExposure}catch{$refused=$true};BCheck $refused 'Strict bounded capture count'
}
foreach($value in @('true',1,$null)){
    $bad=$f.Plan.Clone();$bad.autoExposure=$value;$refused=$false
    try{Assert-ColourMeasurementPlan $bad -FixedAutoExposure}catch{$refused=$true};BCheck $refused 'Actual Boolean AE admission'
}
$bad=$f.Plan.Clone();$bad.inputSetter=@{};$refused=$false
try{Assert-ColourMeasurementPlan $bad -FixedAutoExposure}catch{$refused=$true};BCheck $refused 'No generic inputs or mutation allowlist'
[pscustomobject]@{ok=$true;checks=$script:baselineChecks;cases=$summaries;scope='offline native-shaped fixtures only, no live or scientific acceptance'}|ConvertTo-Json -Depth 6 -Compress
