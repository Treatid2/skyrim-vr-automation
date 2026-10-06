# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([switch]$FixtureOnly,[string]$FixtureMode='healthy')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$requestedReadBracketFixtureOnly=[bool]$FixtureOnly
$requestedReadBracketMode=$FixtureMode
$fixture=. (Join-Path $PSScriptRoot 'Test-FixedAEColourBaseline.ps1') -FixtureOnly -FixtureMode 'healthy'
$bracketBaseCall=$fixture.Call
$script:bracketFixtureMode=$requestedReadBracketMode;$script:bracketReadCount=0
$fixture.Plan.captureReadBrackets=$true;$fixture.Plan.capturesPerCondition=1
$bracketCall={
    param($name,$argsMap,$mutation,$bound)
    if($name -cnotin @('camera','inspect')){return & $bracketBaseCall $name $argsMap $mutation $bound}
    $script:bracketReadCount++
    $script:calls.Add([pscustomobject]@{name=$name;arguments=$argsMap;mutation=$mutation})
    if($mutation){throw 'Bracket fixture rejects mutations'}
    if($script:bracketFixtureMode -ceq 'lost-before' -and $script:bracketReadCount -eq 1){throw 'fixture lost before read'}
    if($script:bracketFixtureMode -ceq 'lost-after' -and $script:bracketReadCount -eq 4){throw 'fixture lost after read'}
    if(($script:bracketFixtureMode -ceq 'late-before' -and $script:bracketReadCount -eq 1) -or ($script:bracketFixtureMode -ceq 'late-after' -and $script:bracketReadCount -eq 4)){Start-Sleep -Milliseconds ([int][Math]::Max(1,($bound-[datetime]::UtcNow).TotalMilliseconds+10))}
    if($name -ceq 'camera'){
        $p=[pscustomobject]@{camX=1.5;camY=2.5;camZ=3.5;camPitch=0.1;camYaw=-0.2;pov='first';stateId=0;freeCam=$false;freeCamOwned=$false;freeCamBackend='vr-state'}
        if($script:bracketFixtureMode -ceq 'camera-malformed'){$p.camX='1.5'}
        if($script:bracketFixtureMode -ceq 'camera-unavailable'){$p=[pscustomobject]@{pov=$null}}
    }elseif($argsMap.kind -ceq 'scene'){
        $p=[pscustomobject]@{playerLoaded=$true;cell=[pscustomobject]@{formId='0x00000007';formType='CELL';editorId='fixture'};position=@(1.0,2.0,3.0);gameHour=12.0;daysPassed=1.0;weather=$null}
        if($script:bracketFixtureMode -ceq 'scene-foreign'){$p.cell.formId='0x00000008'}
        if($script:bracketFixtureMode -ceq 'scene-unloaded'){$p.playerLoaded=$false}
        if($script:bracketFixtureMode -ceq 'time-malformed'){$p.gameHour='12'}
        if($script:bracketFixtureMode -ceq 'time-unavailable'){$p.PSObject.Properties.Remove('gameHour');$p.PSObject.Properties.Remove('daysPassed')}
    }else{
        if($argsMap.scope -cne 'scene' -or $argsMap.limit -ne 64 -or $argsMap.Count -ne 3){throw 'fixture requires exact bounded scene light args'}
        $source=[pscustomobject]@{source='BSShaderManager.shadowSceneNode[0]';index=0;lists=@('activeShadowLights','activeLights');available=$true;complete=$true;observedUniqueLights=1;visibleIlluminationProven=$false}
        $light=[pscustomobject]@{position=@(1.0,2.0,3.0);diffuse=@(0.5,0.4,0.3);radius=10.0;fade=1.0;fadeAmount=0.7;appCulled=$false;inScene='shadow';name='fixture';lineageCoverage=[pscustomobject]@{complete=$true}}
        $p=[pscustomobject]@{scope='scene';count=1;returned=1;truncated=$false;countScope='filtered-observed-subset-before-limit';playerPositionAvailable=$true;lightObservation=[pscustomobject]@{source=$source;budget=[pscustomobject]@{reasons=@()}};lights=@($light)}
        if($script:bracketFixtureMode -ceq 'lights-unavailable'){$source.available=$false;$source.complete=$false;$p.count=0;$p.returned=0;$p.lights=@();$p.truncated=$true}
        if($script:bracketFixtureMode -ceq 'lights-truncated'){$source.complete=$false;$p.truncated=$true;$p.count=100}
        if($script:bracketFixtureMode -ceq 'lights-malformed'){$light.diffuse=@('0.5',0.4,0.3)}
        if($script:bracketFixtureMode -ceq 'lights-over-limit'){$p.returned=65}
        if($script:bracketFixtureMode -ceq 'lights-contradictory'){$source.available=$false}
    }
    $reply=[pscustomobject]@{content=@($p)}
    if($script:bracketFixtureMode -ceq 'mcp-error'){$reply|Add-Member rawResult ([pscustomobject]@{isError=$true})}
    return $reply
}
$bracketCleanup={param($name,$argsMap,$mutation,$bound)$script:cleanupPhase=$true;& $bracketCall $name $argsMap $mutation $bound}
if($requestedReadBracketFixtureOnly){return [pscustomobject]@{Call=$bracketCall;Guard=$fixture.Guard;Cleanup=$bracketCleanup;Plan=$fixture.Plan;Producer=$fixture.Producer}}
$readBracketChecks=0
function BC([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:readBracketChecks++}
$readBracketCases=@('healthy','camera-malformed','camera-unavailable','scene-foreign','scene-unloaded','time-malformed','time-unavailable','lights-unavailable','lights-truncated','lights-malformed','lights-over-limit','lights-contradictory','mcp-error','lost-before','lost-after','late-before','late-after')
foreach($testCase in $readBracketCases){
    $f=. $PSCommandPath -FixtureOnly -FixtureMode $testCase
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    if($testCase -cin @('late-before','late-after')){$deadline=[datetime]::UtcNow.AddSeconds(2)}
    $r=Invoke-DevBenchColourMeasurement -FixedAutoExposure -Call $f.Call -CompilerGuard $f.Guard -CleanupCall $f.Cleanup -Plan $f.Plan -DeadlineUtc $deadline -CleanupDeadlineUtc $deadline.AddSeconds(2) -PollMilliseconds 10
    $success=$testCase -cin @('healthy','time-unavailable','lights-unavailable','lights-truncated')
    BC ($r.ok -eq $success) "$testCase bracket outcome: $($r.errors -join ';')"
    BC ($script:setCount -eq 0) "$testCase no colour writes"
    BC ($r.captures.Count -eq 1) "$testCase no successor capture"
    $record=$r.captures[0]
    BC (-not $record.readBrackets[0].atomicRenderFrameEquivalent) "$testCase no atomic equivalence"
    BC ($record.readBrackets[0].reads[0].mutation -eq $false) "$testCase read-only observations"
    BC (@($script:calls|Where-Object {$_.name -ceq 'camera' -and $_.arguments.action -cne 'get'}).Count -eq 0) "$testCase camera get only"
    if($success){
        BC ($record.complete -and $record.resetVerified -and $record.readBrackets.Count -eq 2 -and $record.readBrackets[0].complete -and $record.readBrackets[1].complete) "$testCase bracket/capture completion"
        BC ($record.readBrackets[0].generation -eq $record.generation -and -not $record.readBrackets[0].generationKnownAtRead -and $record.readBrackets[1].generationKnownAtRead) "$testCase retroactive exact arm binding not invented pre-read generation"
        BC ($record.readBrackets[0].capturedCpuFrame -eq $record.status.cpuFrame -and -not $record.readBrackets[0].cpuFrameKnownAtRead -and $record.readBrackets[1].cpuFrameKnownAtRead) "$testCase native frame association not observation frame"
        BC ($script:bracketReadCount -eq 6 -and @($record.readBrackets|ForEach-Object {$_.reads}).Count -eq 6) "$testCase exact six sequential reads"
        if($testCase -ceq 'time-unavailable'){BC (-not $record.readBrackets[0].reads[1].availability.sceneTime) 'missing time retained unavailable'}
        if($testCase -ceq 'lights-unavailable'){BC (-not $record.readBrackets[0].reads[2].availability.rendererLists) 'unavailable renderer retained'}
        if($testCase -ceq 'lights-truncated'){BC (-not $record.readBrackets[0].reads[2].availability.boundedCoverageComplete) 'truncation not full coverage'}
        $events=@($script:calls);$armIndex=0;$resetIndex=0
        for($i=0;$i -lt $events.Count;$i++){if($events[$i].name -ceq 'communityshaders.colour_pipeline_probe' -and $events[$i].arguments.action -ceq 'arm'){$armIndex=$i};if($events[$i].name -ceq 'communityshaders.colour_pipeline_probe' -and $events[$i].arguments.action -ceq 'reset'){$resetIndex=$i}}
        BC ($events[$armIndex-3].name -ceq 'camera' -and $events[$armIndex-2].arguments.kind -ceq 'scene' -and $events[$armIndex-1].arguments.kind -ceq 'lights') "$testCase before arm ordering"
        BC (@($events[($armIndex+1)..($resetIndex-1)]|Where-Object name -CEQ 'camera').Count -eq 1) "$testCase exactly one after completion bracket"
    }else{
        BC (-not $record.complete -and $record.readBrackets[-1].error) "$testCase diagnostic partial evidence"
        if($testCase -cin @('lost-after','late-after')){BC ($r.probeCleanup.verified -and $record.resetVerified -and $record.pages.Count -eq 0 -and $record.readBrackets[1].reads.Count -eq 1) 'failed after-read still owned cleanup, no read replay/pages'}
        else{BC (@($script:calls|Where-Object {$_.name -ceq 'communityshaders.colour_pipeline_probe' -and $_.arguments.action -ceq 'arm'}).Count -eq 0) "$testCase refused before arm"}
    }
}
foreach($value in @('true',1,$null,@{})){
    $f=. $PSCommandPath -FixtureOnly;$f.Plan.captureReadBrackets=$value;$rejected=$false
    try{Assert-ColourMeasurementPlan $f.Plan -FixedAutoExposure}catch{$rejected=$true};BC $rejected 'strict Boolean opt-in'
}
$f=. $PSCommandPath -FixtureOnly
$rejected=$false;try{Assert-ColourMeasurementPlan $f.Plan}catch{$rejected=$true};BC $rejected 'legacy lane rejects bracket key'
foreach($selection in @('absent','false')){
    $f=. $PSCommandPath -FixtureOnly
    if($selection -ceq 'absent'){$f.Plan.Remove('captureReadBrackets')}else{$f.Plan.captureReadBrackets=$false}
    $r=Invoke-DevBenchColourMeasurement -FixedAutoExposure -Call $f.Call -CompilerGuard $f.Guard -CleanupCall $f.Cleanup -Plan $f.Plan -DeadlineUtc ([datetime]::UtcNow.AddSeconds(20)) -PollMilliseconds 10
    BC ($r.ok -and $script:bracketReadCount -eq 0 -and -not $r.captures[0].Contains('readBrackets')) "$selection preserves old strict plan and zero new reads"
}
[pscustomobject]@{ok=$true;checks=$readBracketChecks;cases=$readBracketCases.Count;scope='offline source-shaped read brackets, not atomic frame or live qualification'}|ConvertTo-Json -Compress

