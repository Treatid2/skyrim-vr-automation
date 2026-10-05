# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([switch]$FixtureOnly,[string]$FixtureMode='healthy')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ColourMeasurementWindow.psm1') -Force
$checks=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function CloneFixture($Value){return $Value|ConvertTo-Json -Depth 35|ConvertFrom-Json -Depth 35}
$colour=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-fsr-colour-status.json') -Raw|ConvertFrom-Json
$probe=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-colour-probe-status.v3.json') -Raw|ConvertFrom-Json
$probe.producer=CloneFixture $colour.producer
$cases=@('healthy','compiler','foreign-build','foreign-revision','lost-set','lost-arm','lost-reset','bad-set','bad-arm','bad-reset','wrong-page','wrong-generation','partial-page','wrong-frame','wrong-context','wrong-eye-dispatch','unsettled','native-failure','foreign-probe','changed-context','compiler-change')
if($FixtureOnly){$cases=@($FixtureMode)}
foreach($mode in $cases){
    $script:mode=$mode;$script:revision=1;$script:auto=$true;$script:generation=0;$script:id='';$script:reset=$true;$script:guardCount=0;$script:setCount=0
    $script:calls=[Collections.Generic.List[object]]::new()
    $plan=@{expectedBuildId=$colour.producer.buildId;expectedRevision=1;expectedCellFormId=7;highDynamicRangeInput=$true;capturesPerCondition=2;metadata=@{calibratedScene='fixture-owner-calibration'}}
    $guard={param($bound)
        $script:guardCount++
        $health=[pscustomobject]@{admissible=$true;buildId=$colour.producer.buildId;serviceSessionId='fixture-session';stateRevision=1;timestampUtc=[datetimeoffset]::UtcNow.ToString('o');compilation=[pscustomobject]@{totalTasks=10;completedTasks=10;failedTasks=0;currentFailedShaders=0;sourceCompiles=10;diskCacheHits=0;memoryCacheHits=0}}
        if($script:mode -ceq 'compiler-change' -and $script:guardCount -ge 3){$health.stateRevision=2}
        [pscustomobject]@{admissible=($script:mode -cne 'compiler');health=$health}
    }
    $call={param($name,$argsMap,$mutation,$bound)
        $script:calls.Add([pscustomobject]@{name=$name;arguments=$argsMap;mutation=$mutation})
        if([datetime]::UtcNow -ge $bound){throw 'fixture deadline'}
        if($name -ceq 'communityshaders.fsr_color_contract'){
            if($argsMap.action -ceq 'set'){
                $script:setCount++
                Check ($argsMap.expectedRevision -eq $script:revision) 'native CAS uses prior exact revision'
                if($script:auto -cne $argsMap.autoExposure){$script:revision++}
                $script:auto=$argsMap.autoExposure
                if($script:mode -ceq 'lost-set'){throw 'fixture lost accepted set'}
            }
            $p=CloneFixture $colour;$p.requested.revision=$script:revision;$p.requested.autoExposure=$script:auto;$p.runtimeContext.autoExposure=$script:auto
            foreach($d in @($p.lastSuccessfulDispatch)+@($p.lastSuccessfulEyeDispatches)){$d.autoExposure=$script:auto}
            if($argsMap.action -ceq 'set'){$p|Add-Member accepted ($script:mode -cne 'bad-set');$p|Add-Member resultingRevision $script:revision}
            if($script:mode -ceq 'foreign-revision' -and $argsMap.action -ceq 'status'){$p.requested.revision=9}
            if($script:mode -ceq 'foreign-build'){$p.producer.buildId='f'*64}
            if($script:mode -ceq 'unsettled'){$p.runtimeContext.valid=$false}
            if($script:mode -ceq 'changed-context' -and -not $script:reset){$p.runtimeContext.generation=3}
        }else{
            switch($argsMap.action){
                'arm' {
                    $script:generation++;$script:id=$argsMap.captureId;$script:reset=$false
                    if($script:mode -ceq 'lost-arm'){throw 'fixture lost accepted arm'}
                    $p=[pscustomobject]@{action='arm';accepted=($script:mode -cne 'bad-arm');captureId=$script:id;generation=$script:generation;error=$null;producer=(CloneFixture $colour.producer)}
                }
                'status' {
                    $p=CloneFixture $probe;$p.generation=$script:generation
                    if(-not $script:reset){$p.captureId=$script:id;$p.state='complete';$p.cpuFrame=61039;$p.queuedStageEyeSlots=10;$p.mappedStageEyeSlots=10;$p.expectedColourContractRevision=$script:revision;$p.stagingPayloadBytes=1024;$p.armedQpc=1;$p.queryQueuedQpc=2;$p.completedQpc=3}
                    if($script:mode -ceq 'foreign-probe'){$p.captureId='foreign';$p.state='armed';$p.generation=3;$p.expectedColourContractRevision=1;$p.armedQpc=1}
                    if($script:mode -ceq 'native-failure' -and -not $script:reset){$p.state='failed';$p.error='native fixture failure'}
                }
                'read' {
                    $d=[pscustomobject]@{attribution='observed-successful-dispatch';colourContractRevision=$script:revision;contextGeneration=2;contextIndex=$argsMap.eye;path=3;frame=61039;requestedHighDynamicRangeInput=$true;effectiveHighDynamicRangeInput=$true;requestedAutoExposure=$script:auto;effectiveAutoExposure=$script:auto;dispatchSerial=(21879+$argsMap.eye)}
                    $slot=[pscustomobject]@{stage=$argsMap.stage;eye=@('left','right')[$argsMap.eye];eyeMask=(1 -shl $argsMap.eye);queued=$true;mapped=$true;frame=[pscustomobject]@{cpuFrame=61039};dispatch=(CloneFixture $d);readback=[pscustomobject]@{map=[pscustomobject]@{succeeded=$true;matchedMap=$true;readable=$true};sampling=[pscustomobject]@{transferConversion='none';gridSize=17;sampleCount=289;samples=@(for($i=0;$i -lt 289;$i++){[pscustomobject]@{grid=@(($i%17),([int][Math]::Floor($i/17)));rawLittleEndianHex='00000000';decodedRgba=$null}})}}}
                    $p=[pscustomobject]@{schema='csx-colour-pipeline-probe-v3';producer=(CloneFixture $colour.producer);metadata=[pscustomobject]@{calibratedScene='fixture-owner-calibration'};captureId=$script:id;generation=$script:generation;state='complete';error=$null;frame=[pscustomobject]@{cpuFrame=61039;eye='both';eyeMask=3;sceneEpoch=$null;submissionEpoch=$null};samplingContract=[pscustomobject]@{gridSize=17;rawBytesRetainedPerSample=$true;implicitTransferConversion=$false};immediateContext=[pscustomobject]@{pointer='0x1234';kind='immediate'};dispatch=$d;stages=@($slot)}
                    switch($script:mode){'wrong-page'{$slot.stage='foreign'};'wrong-generation'{$p.generation++};'partial-page'{$slot.mapped=$false};'wrong-frame'{$p.frame.cpuFrame++};'wrong-context'{$p.immediateContext.pointer='0x0000'};'wrong-eye-dispatch'{$p.dispatch.contextIndex=3}}
                }
                'reset' {
                    Check ($argsMap.captureId -ceq $script:id -and $argsMap.generation -eq $script:generation) 'reset owns exact arm tuple'
                    if($script:mode -ceq 'lost-reset'){throw 'fixture lost accepted reset'}
                    $script:generation++;$script:reset=$true;$p=[pscustomobject]@{action='reset';accepted=($script:mode -cne 'bad-reset');captureId=$script:id;generation=$script:generation;error=$null;producer=(CloneFixture $colour.producer)}
                }
            }
        }
        return [pscustomobject]@{content=@($p);rawResult=[pscustomobject]@{isError=$false}}
    }
    if($FixtureOnly){return [pscustomobject]@{Call=$call;Guard=$guard;Plan=$plan;Producer=$colour.producer}}
    $deadline=[datetime]::UtcNow.AddSeconds($(if($mode -ceq 'unsettled'){0.1}else{20}))
    $r=Invoke-DevBenchColourMeasurement -Call $call -CompilerGuard $guard -Plan $plan -DeadlineUtc $deadline -PollMilliseconds 10
    Check ($r.ok -eq ($mode -ceq 'healthy')) "$mode outcome: $($r.errors -join ';')"
    Check (@($script:calls|Where-Object {$_.mutation -and $_.name -cnotin @('communityshaders.fsr_color_contract','communityshaders.colour_pipeline_probe')}).Count -eq 0) 'no generic mutation'
    if($mode -ceq 'healthy'){
        Check ($r.conditions.Count -eq 3 -and $r.captures.Count -eq 6 -and @($r.captures|Where-Object {-not $_.complete -or -not $_.resetVerified}).Count -eq 0) 'all three conditions/two captures complete'
        Check (@($r.captures|ForEach-Object {$_.pages}).Count -eq 60) 'all sixty stage-eye pages retained'
        Check ($r.conditions[0].autoExposure -and -not $r.conditions[1].autoExposure -and $r.conditions[2].autoExposure -and $r.finalRevision -eq 3) 'on/off/on exactCAS sequence'
    }else{Check ($script:setCount -le 1) 'stop before successor condition after failure'}
    if($mode -cin @('lost-set','lost-arm','lost-reset')){Check $r.indeterminate 'lost mutation stays indeterminate';Check (@($script:calls|Where-Object {$_.arguments.action -ceq $mode.Substring(5)}).Count -eq 1) 'lost mutation never replayed'}
    if($mode -cin @('wrong-page','partial-page','native-failure')){Check ($r.captures.Count -eq 1 -and -not $r.captures[0].complete -and $null -ne $r.retainedProbe) 'partial owned evidence not erased by reset'}
}
foreach($name in @('expectedBuildId','expectedRevision','expectedCellFormId','highDynamicRangeInput','capturesPerCondition','metadata')){
    $bad=$plan.Clone();$bad.Remove($name);$rejected=$false;try{Assert-ColourMeasurementPlan $bad}catch{$rejected=$true};Check $rejected "missing plan$name refuses before mutation"
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$cases.Count;scope='offline finite typed engine; no runtime or scientific acceptance'}|ConvertTo-Json -Compress

