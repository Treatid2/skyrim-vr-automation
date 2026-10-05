# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:timingChecks=0
function TCheck($value,$message){if(-not $value){throw ($script:timingMode+': '+$message)};$script:timingChecks++}
$modes=@('healthy','transient','stale','regression','dimensions','sharpness','context','compiler','deadline','off-incomplete','lost-restore','lost-set','spacing-only')
$summaries=[Collections.Generic.List[object]]::new()
foreach($timingMode in $modes){
    $fixture=. (Join-Path $PSScriptRoot 'Test-ColourMeasurementWindow.ps1') -FixtureOnly
    $nativeCall=$fixture.Call;$nativeGuard=$fixture.Guard
    $script:timingMode=$timingMode;$script:timingStatuses=0;$script:timingFrame=61039;$script:timingCleanup=$false
    $script:timingEyes=$null;$script:timingCaptureEyes=$null;$script:timingCaptureFrame=61039
    $plan=$fixture.Plan.Clone();$plan.capturesPerCondition=4
    $plan.burnIn=@{minimumElapsedMilliseconds=20;minimumObservedCpuFrameIdAdvancePerEye=2;minimumDistinctFreshSuccessfulBothEyeObservations=3;maximumElapsedMilliseconds=600}
    if($timingMode -ceq 'deadline'){$plan.burnIn.minimumElapsedMilliseconds=400}
    if($timingMode -ceq 'spacing-only'){$plan.Remove('burnIn');$plan.minimumElapsedMillisecondsBetweenCaptureArms=1000;$plan.capturesPerCondition=2}
    $call={param($name,$argsMap,$mutation,$bound)
        if($script:timingMode -ceq 'lost-set'){$script:mode='lost-set'}
        $reply=& $nativeCall $name $argsMap $mutation $bound
        $p=$reply.content[0]
        if($name -ceq 'communityshaders.fsr_color_contract' -and $argsMap.action -ceq 'status' -and -not $script:timingCleanup){
            $script:timingStatuses++
            $n=$script:timingStatuses
            $frame=61039+$n
            if($script:timingMode -ceq 'stale' -or ($script:timingMode -cin @('off-incomplete','lost-restore') -and -not $script:auto)){$frame=61039}
            if($script:timingMode -ceq 'regression' -and $n -ge 3){$frame=61034}
            foreach($eye in 0,1){
                $d=$p.lastSuccessfulEyeDispatches[$eye]
                $d.frame=$frame;$d.serial=21879+$eye+$n*2;$d.dispatchQpc=21311392938929+$eye*481+$n*1000
                if($n -ge 3){
                    if($script:timingMode -ceq 'dimensions'){$d.renderWidth=1100}
                    if($script:timingMode -ceq 'sharpness'){$d.effectiveSharpness=0.5}
                    if($script:timingMode -ceq 'context'){$d.contextGeneration=3}
                }
            }
            $p.lastSuccessfulDispatch=CloneFixture $p.lastSuccessfulEyeDispatches[1]
            if($script:timingMode -ceq 'context' -and $n -ge 3){$p.runtimeContext.generation=3}
            if($script:timingMode -ceq 'transient' -and $n -eq 3){$p.runtimeContext.valid=$false}
            $script:timingFrame=$frame;$script:timingEyes=CloneFixture $p.lastSuccessfulEyeDispatches
        }
        if($name -ceq 'communityshaders.colour_pipeline_probe'){
            if($argsMap.action -ceq 'arm'){
                $script:timingCaptureFrame=$script:timingFrame+1
                $script:timingCaptureEyes=CloneFixture $script:timingEyes
                foreach($d in $script:timingCaptureEyes){$d.frame=$script:timingCaptureFrame;$d.serial+=2;$d.dispatchQpc+=1000}
            }
            if($argsMap.action -ceq 'status' -and -not $script:reset){$p.cpuFrame=$script:timingCaptureFrame}
            if($argsMap.action -ceq 'read'){
                $p.frame.cpuFrame=$script:timingCaptureFrame;$p.stages[0].frame.cpuFrame=$script:timingCaptureFrame
                $d=$p.dispatch;$eye=$script:timingCaptureEyes[$argsMap.eye]
                $d.frame=$script:timingCaptureFrame;$d.dispatchSerial=$eye.serial
                foreach($field in @('renderWidth','renderHeight','displayWidth','displayHeight','configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled','dispatchQpc')){$d|Add-Member -NotePropertyName $field -NotePropertyValue $eye.$field -Force}
                $p.stages[0].dispatch=CloneFixture $d
            }
        }
        if($script:timingCleanup -and $script:timingMode -ceq 'lost-restore' -and $name -ceq 'communityshaders.fsr_color_contract' -and $argsMap.action -ceq 'set'){throw 'fixture lost accepted original-AE restore'}
        return $reply
    }
    $guard={param($bound)
        $g=& $nativeGuard $bound
        if($script:timingMode -ceq 'compiler' -and $script:timingStatuses -ge 2){$g.health.stateRevision=2}
        return $g
    }
    $cleanup={param($name,$argsMap,$mutation,$bound)$script:timingCleanup=$true;& $call $name $argsMap $mutation $bound}
    $deadline=[datetime]::UtcNow.AddSeconds(25)
    if($timingMode -ceq 'deadline'){$deadline=[datetime]::UtcNow.AddMilliseconds(100)}
    $started=[Diagnostics.Stopwatch]::StartNew()
    $r=Invoke-DevBenchColourMeasurement -Call $call -CompilerGuard $guard -Plan $plan -DeadlineUtc $deadline -CleanupCall $cleanup -CleanupDeadlineUtc $deadline.AddSeconds(2) -PollMilliseconds 10
    $expected=$timingMode -cin @('healthy','transient','spacing-only')
    TCheck ($r.ok -eq $expected) "$timingMode outcome: $($r.errors -join ';')"
    TCheck (-not $r.vendorExposureConvergenceKnown) 'No hidden vendor convergence claim'
    if($expected){
        $expectedCaptures=3*$plan.capturesPerCondition
        TCheck ($r.captures.Count -eq $expectedCaptures -and @($r.captures|Where-Object {-not $_.complete -or -not $_.resetVerified}).Count -eq 0) 'All admitted captures/reset proofs complete'
        TCheck ($r.colourCleanup.verified -and -not $r.colourCleanup.attempted) 'On/off/on already restored original AE, fresh read only'
        TCheck (@($r.captures|ForEach-Object {$_.pages}).Count -eq 10*$expectedCaptures) 'All owned ten-page inventories retained'
        if($plan.Contains('burnIn')){
            TCheck (@($r.conditions|Where-Object {-not $_.burnIn.complete -or $_.burnIn.elapsedMilliseconds -lt 20 -or $_.burnIn.distinctFreshSuccessfulBothEyeObservations -lt 3}).Count -eq 0) 'All engineering coverage thresholds satisfied'
            TCheck (@($r.conditions|ForEach-Object {$_.burnIn.observedCpuFrameIdAdvancePerEye}|Where-Object {$_ -lt 2}).Count -eq 0) 'CPU-frame-ID advance per eye, not serial counts'
            TCheck (@($r.conditions|Where-Object {$null -ne $_.burnIn.successfulEyeFrameCount}).Count -eq 0) 'Unobserved successful frame count remains null'
        }
        if($timingMode -ceq 'transient'){TCheck (@($r.conditions|ForEach-Object {$_.burnIn.observations}|Where-Object {$_.classification -ceq 'transient-unmatched-dispatch'}).Count -ge 1) 'Transient observation retained without successful promotion'}
        if($timingMode -ceq 'spacing-only'){
            TCheck (-not $r.burnInRequested) 'Spacing does not secretly request burn-in'
            foreach($capture in $r.captures){TCheck $capture.spacing.verified 'Inter-arm spacing qualified';if($null -ne $capture.spacing.priorArmAcknowledgedElapsedMilliseconds){TCheck (($capture.spacing.armIntentElapsedMilliseconds-$capture.spacing.priorArmAcknowledgedElapsedMilliseconds) -ge 1000) 'Monotonic floor since previous positive arm acknowledgement'}}
        }
    }else{
        if($timingMode -cne 'lost-set'){TCheck (@($r.conditions|Where-Object {$null -ne $_.burnIn -and -not $_.burnIn.complete}).Count -ge 1) 'Coverage failure separate from captured native dispatch'}
        if($timingMode -cne 'lost-set'){TCheck $r.conditions[-1].nativeDispatchMatched 'Initial matched dispatch is not burn-in completion'}
        if($timingMode -cin @('stale','deadline','regression','dimensions','sharpness','context','compiler')){TCheck ($r.captures.Count -eq 0 -and $r.conditions.Count -eq 1) 'No arm/next condition after coverage failure'}
        if($timingMode -ceq 'stale'){TCheck ($r.conditions[0].burnIn.distinctFreshSuccessfulBothEyeObservations -eq 1 -and $r.conditions[0].burnIn.observedCpuFrameIdAdvancePerEye[0] -eq 0) 'Advancing serial alone never counts stale CPU frames'}
        if($timingMode -cin @('off-incomplete','lost-restore')){
            TCheck ($r.conditions.Count -eq 2 -and $script:setCount -eq 3 -and $r.colourCleanup.attempted) 'One original-AE compensation, not another condition or replay'
            TCheck ($r.colourCleanup.verified -eq ($timingMode -ceq 'off-incomplete')) 'Lost restore remains explicitly unresolved'
            TCheck ($r.indeterminate -eq ($timingMode -ceq 'lost-restore')) 'Verified failed coverage and uncertain cleanup are distinct'
        }
        if($timingMode -ceq 'lost-set'){TCheck ($r.indeterminate -and -not $r.colourCleanup.verified -and $script:setCount -eq 1) 'Lost accepted set never gains speculative compensation'}
        TCheck ($started.Elapsed.TotalSeconds -lt 4) 'Failed coverage exits within declared finite test budget'
    }
    $summaries.Add([pscustomobject]@{case=$timingMode;ok=$r.ok;elapsedMilliseconds=$started.Elapsed.TotalMilliseconds;captures=$r.captures.Count;conditions=$r.conditions.Count;colourRestorationVerified=$r.colourCleanup.verified;indeterminate=$r.indeterminate;errors=$r.errors})
}
$fixture=. (Join-Path $PSScriptRoot 'Test-ColourMeasurementWindow.ps1') -FixtureOnly
$original=$fixture.Plan.Clone();Assert-ColourMeasurementPlan $original
TCheck (-not $original.Contains('burnIn')) 'Original exact six-field plan remains admitted'
$fields=@('minimumElapsedMilliseconds','minimumObservedCpuFrameIdAdvancePerEye','minimumDistinctFreshSuccessfulBothEyeObservations','maximumElapsedMilliseconds')
foreach($field in $fields){foreach($value in @('8',8.5,$true,$null,0,-1)){
    $bad=$original.Clone();$bad.burnIn=@{minimumElapsedMilliseconds=8000;minimumObservedCpuFrameIdAdvancePerEye=180;minimumDistinctFreshSuccessfulBothEyeObservations=6;maximumElapsedMilliseconds=20000};$bad.burnIn[$field]=$value
    $refused=$false;try{Assert-ColourMeasurementPlan $bad}catch{$refused=$true};TCheck $refused "Strict burn-in field $field"
}}
foreach($value in @('1000',1000.5,$true,$null,0,-1,10001)){
    $bad=$original.Clone();$bad.minimumElapsedMillisecondsBetweenCaptureArms=$value
    $refused=$false;try{Assert-ColourMeasurementPlan $bad}catch{$refused=$true};TCheck $refused 'Strict finite spacing field'
}
foreach($kind in @('unknown','missing','max','elapsed','observations','advance')){
    $bad=$original.Clone();$bad.burnIn=@{minimumElapsedMilliseconds=8000;minimumObservedCpuFrameIdAdvancePerEye=180;minimumDistinctFreshSuccessfulBothEyeObservations=6;maximumElapsedMilliseconds=20000}
    switch($kind){'unknown'{$bad.burnIn.arbitrary=$true};'missing'{$bad.burnIn.Remove('minimumElapsedMilliseconds')};'max'{$bad.burnIn.maximumElapsedMilliseconds=20001};'elapsed'{$bad.burnIn.minimumElapsedMilliseconds=20000};'observations'{$bad.burnIn.minimumDistinctFreshSuccessfulBothEyeObservations=2001};'advance'{$bad.burnIn.minimumObservedCpuFrameIdAdvancePerEye=[uint64]4294967296}}
    $refused=$false;try{Assert-ColourMeasurementPlan $bad}catch{$refused=$true};TCheck $refused 'Invalid policy bounds or shape refuse before mutation'
}
[pscustomobject]@{ok=$true;checks=$script:timingChecks;cases=$summaries;scope='offline real-clock typed coverage/spacing/AE cleanup fixtures only; no live or vendor convergence claim'}|ConvertTo-Json -Depth 8 -Compress
