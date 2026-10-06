# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NativeReadContracts.ps1')
. (Join-Path $PSScriptRoot 'ColourCaptureReadBrackets.ps1')

function Assert-ColourMeasurementPlan([Collections.IDictionary]$Plan,[switch]$FixedAutoExposure) {
    $keys=@('expectedBuildId','expectedRevision','expectedCellFormId','highDynamicRangeInput','capturesPerCondition','metadata')
    $optional=@('burnIn','minimumElapsedMillisecondsBetweenCaptureArms')
    if($FixedAutoExposure){$keys+=@('autoExposure')+$optional;$optional=@('captureReadBrackets')}
    if ($null -eq $Plan -or @($keys | Where-Object {-not $Plan.Contains($_)}).Count -or @($Plan.Keys | Where-Object {$_ -cnotin ($keys+$optional)}).Count) { throw 'Colour plan requires six documented fields and only supported optional timing fields.' }
    if ($Plan.expectedBuildId -isnot [string] -or $Plan.expectedBuildId -cnotmatch '^[0-9a-f]{64}$' -or $Plan.highDynamicRangeInput -isnot [bool]) { throw 'Colour plan requires exact build and fixed Boolean HDR input.' }
    foreach($name in @('expectedRevision','expectedCellFormId','capturesPerCondition')) {
        if ($null -eq $Plan[$name] -or $Plan[$name].GetType() -notin @([int],[long],[uint32],[uint64]) -or $Plan[$name] -lt 1) { throw "Colour plan $name requires a positive integer." }
    }
    $maximumCaptures=if($FixedAutoExposure){16}else{4}
    if ($Plan.capturesPerCondition -gt $maximumCaptures -or $Plan.expectedCellFormId -gt [uint32]::MaxValue) { throw 'Colour plan exceeds finite capture/cell bounds.' }
    if($FixedAutoExposure -and $Plan.autoExposure -isnot [bool]){throw 'Fixed-AE baseline requires an explicit actual Boolean autoExposure.'}
    if($Plan.Contains('captureReadBrackets') -and $Plan.captureReadBrackets -isnot [bool]){throw 'captureReadBrackets requires an actual Boolean; baseline-only opt-in.'}
    if ($Plan.metadata -isnot [Collections.IDictionary] -or -not $Plan.metadata.Contains('calibratedScene') -or $Plan.metadata.calibratedScene -isnot [string] -or [string]::IsNullOrWhiteSpace($Plan.metadata.calibratedScene) -or [Text.Encoding]::UTF8.GetByteCount(($Plan.metadata|ConvertTo-Json -Depth 20 -Compress)) -gt 15000) { throw 'Explicit experiment-owner calibratedScene metadata (at most15000 UTF8 bytes) is required.' }
    if($Plan.Contains('burnIn')){
        $burn=$Plan.burnIn
        $fields=@('minimumElapsedMilliseconds','minimumObservedCpuFrameIdAdvancePerEye','minimumDistinctFreshSuccessfulBothEyeObservations','maximumElapsedMilliseconds')
        if($burn -isnot [Collections.IDictionary] -or $burn.Count -ne 4 -or @($fields|Where-Object {-not $burn.Contains($_)}).Count){throw 'burnIn requires exactly four documented coverage fields.'}
        foreach($name in $fields){if($null -eq $burn[$name] -or $burn[$name].GetType() -notin @([int],[long],[uint32],[uint64]) -or $burn[$name] -lt 1){throw "burnIn $name requires an actual positive integer."}}
        if($burn.maximumElapsedMilliseconds -gt 20000 -or $burn.minimumElapsedMilliseconds -ge $burn.maximumElapsedMilliseconds -or $burn.minimumObservedCpuFrameIdAdvancePerEye -gt [uint32]::MaxValue -or $burn.minimumDistinctFreshSuccessfulBothEyeObservations -gt 2000){throw 'burnIn exceeds bounded timing/frame/observation coverage.'}
    }
    if($Plan.Contains('minimumElapsedMillisecondsBetweenCaptureArms')){ $v=$Plan.minimumElapsedMillisecondsBetweenCaptureArms; if($null -eq $v -or $v.GetType() -notin @([int],[long],[uint32],[uint64]) -or $v -lt 1 -or $v -gt 10000){throw 'Inter-arm spacing requires an actual positive integer1..10000 milliseconds.'} }
}

function Invoke-DevBenchColourMeasurement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Call,
          [Parameter(Mandatory)][scriptblock]$CompilerGuard,
          [Parameter(Mandatory)][Collections.IDictionary]$Plan,
          [Parameter(Mandatory)][datetime]$DeadlineUtc,
          [scriptblock]$CleanupCall,
          [datetime]$CleanupDeadlineUtc=$DeadlineUtc,
          [switch]$FixedAutoExposure,
          [ValidateRange(10,1000)][int]$PollMilliseconds=100)
    Assert-ColourMeasurementPlan $Plan -FixedAutoExposure:$FixedAutoExposure
    $colour='communityshaders.fsr_color_contract'; $probe='communityshaders.colour_pipeline_probe'
    $stages=@('fsr_input','fsr_output','combined_main','imagespace_input','imagespace_output')
    $captures=[Collections.Generic.List[object]]::new(); $conditions=[Collections.Generic.List[object]]::new()
    $errors=[Collections.Generic.List[string]]::new(); $guards=[Collections.Generic.List[object]]::new()
    $revision=$Plan.expectedRevision; $owned=$null; $uncertain=$false; $resetVerified=$true; $mutationPending=$false
    $probeCleanup=[ordered]@{attempted=$false;verified=$true;errors=[Collections.Generic.List[string]]::new()}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $readBrackets=$FixedAutoExposure -and $Plan.Contains('captureReadBrackets') -and $Plan.captureReadBrackets
    $timed=$Plan.Contains('burnIn') -or $Plan.Contains('minimumElapsedMillisecondsBetweenCaptureArms')
    $burnPolicy=if($Plan.Contains('burnIn')){$Plan.burnIn}else{$null}
    $spacing=if($Plan.Contains('minimumElapsedMillisecondsBetweenCaptureArms')){$Plan.minimumElapsedMillisecondsBetweenCaptureArms}else{0}
    $lastArmAcknowledged=$null; $originalAuto=$null; $knownColour=$false; $knownAuto=$null
    $colourCleanup=[ordered]@{requested=$timed;required=$false;attempted=$false;verified=$true;reply=$null;readback=$null;errors=[Collections.Generic.List[string]]::new()}
    function UInt($Value,[decimal]$Minimum=0){return $null -ne $Value -and $Value.GetType() -in @([byte],[int16],[uint16],[int],[uint32],[long],[uint64]) -and [decimal]$Value -ge $Minimum -and [decimal]$Value -le [uint64]::MaxValue}
    function One($Reply,[bool]$AllowNativeFailure=$false) {
        if ($null -eq $Reply -or @($Reply.content).Count -ne 1 -or $Reply.content[0] -isnot [pscustomobject]) { throw 'Colour action requires exactly one native payload.' }
        if ($Reply.PSObject.Properties['rawResult'] -and $Reply.rawResult.PSObject.Properties['isError'] -and ($Reply.rawResult.isError -isnot [bool] -or $Reply.rawResult.isError)) { throw 'Native MCP error cannot qualify colour action.' }
        $p=$Reply.content[0]
        if (-not $p.PSObject.Properties['producer'] -or $p.producer -isnot [pscustomobject] -or $p.producer.component -isnot [string] -or $p.producer.component -cne 'CommunityShaders' -or $p.producer.buildId -isnot [string] -or $p.producer.buildId -cne $Plan.expectedBuildId) { throw 'Colour action carries foreign or malformed producer; raw reply retained.' }
        if (-not $AllowNativeFailure -and $p.PSObject.Properties['error'] -and $null -ne $p.error) {
            if($p.error -isnot [string] -or [string]::IsNullOrWhiteSpace($p.error)){throw 'Matching producer returned malformed native error; raw reply retained.'}
            throw "Matching producer returned native colour action error: $($p.error); raw reply retained."
        }
        return $p
    }
    function Guard([datetime]$Bound) {
        if ([datetime]::UtcNow -ge $Bound) { throw 'Colour work deadline expired.' }
        $g=& $CompilerGuard $Bound; $guards.Add($g)
        if ($g.admissible -isnot [bool] -or -not $g.admissible) {
            # Preserve the transport's exact pre-request budget refusal, without
            # relabelling other unavailable reads or compiler failures as timeout.
            if ($g.admissible -is [bool] -and -not $g.admissible -and
                $g.PSObject.Properties['state'] -and $g.state -ceq 'READ_UNAVAILABLE' -and
                $g.PSObject.Properties['health'] -and $null -eq $g.health -and
                $g.PSObject.Properties['reasons'] -and @($g.reasons).Count -eq 1 -and
                $g.reasons[0] -is [string] -and
                $g.reasons[0] -ceq 'The DevBench operation deadline expired before another request could start.') {
                throw 'Colour work deadline exhausted before another qualified compiler read could start.'
            }
            throw 'Compiler boundary refused colour measurement.'
        }
        return $g
    }
    function ReadBracket($Record,[string]$Phase,[datetime]$Bound) {
        $bracket=[ordered]@{schema='auto-tools.colour-capture-read-bracket.1';phase=$Phase;captureId=$Record.captureId;generation=$Record.generation;generationKnownAtRead=($null -ne $Record.generation);generationBindingBasis=if($null -ne $Record.generation){'native-arm-acceptance'}else{'pending-native-arm-acceptance'};capturedCpuFrame=if($null -ne $Record.status){$Record.status.cpuFrame}else{$null};cpuFrameKnownAtRead=($null -ne $Record.status);startedUtc=[datetime]::UtcNow.ToString('o');finishedUtc=$null;startedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds;finishedElapsedMilliseconds=$null;reads=[Collections.Generic.List[object]]::new();complete=$false;atomicRenderFrameEquivalent=$false;error=$null}
        $Record.readBrackets.Add($bracket)
        try {
            foreach($item in @(@{tool='camera';arguments=@{action='get'}},@{tool='inspect';arguments=@{kind='scene'}},@{tool='inspect';arguments=@{kind='lights';scope='scene';limit=64}})) {
                $read=[ordered]@{tool=$item.tool;arguments=$item.arguments;mutation=$false;intendedUtc=[datetime]::UtcNow.ToString('o');receivedUtc=$null;intendedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds;receivedElapsedMilliseconds=$null;reply=$null;availability=$null;qualified=$false;error=$null}
                $bracket.reads.Add($read)
                try {
                    if([datetime]::UtcNow -ge $Bound){throw 'Read bracket original work/capture deadline expired before dispatch.'}
                    $read.reply=& $Call $item.tool $item.arguments $false $Bound
                    $read.receivedUtc=[datetime]::UtcNow.ToString('o');$read.receivedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds
                    if([datetime]::UtcNow -ge $Bound){throw 'Read bracket response arrived at or after original deadline.'}
                    $projection=Get-ColourReadBracketPayload -Reply $read.reply -Tool $item.tool -Arguments $item.arguments -Cell $Plan.expectedCellFormId
                    $read.availability=$projection.availability;$read.qualified=$true
                } catch {$read.error=$_.Exception.Message;throw}
            }
            $bracket.complete=$true
        } catch {$bracket.error=$_.Exception.Message;throw}
        finally {$bracket.finishedUtc=[datetime]::UtcNow.ToString('o');$bracket.finishedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds}
    }
    function Status([string]$Name,[datetime]$Bound,$Observations=$null) {
        $argsMap=@{action='status';expectedBuildId=$Plan.expectedBuildId}
        $entry=$null
        if($null -ne $Observations){$entry=[ordered]@{intendedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds;receivedElapsedMilliseconds=$null;reply=$null;error=$null;classification='unqualified'};$Observations.Add($entry)}
        try{$reply=& $Call $Name $argsMap $false $Bound; if($null -ne $entry){$entry.reply=$reply;$entry.receivedElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds}}
        catch{if($null -ne $entry){$entry.error=$_.Exception.Message};throw}
        # Native probe failed is a typed observation, not foreign identity or
        # measurement success. Preserve it for owner binding and diagnostics.
        $p=One $reply ($Name -ceq $probe)
        $kind=if($Name -ceq $colour){'fsr-colour-status'}else{'colour-probe-status'}
        if (@(Get-DevBenchNativeReadReasons -Kind $kind -Payload $p -Arguments $argsMap).Count) { throw "Native status schema failed: $Name." }
        return $p
    }
    function StableSignature($Status,$Baseline){
        if($Status.runtimeContext.generation -ne $Baseline.runtimeContext.generation){throw 'Timing coverage context generation changed.'}
        foreach($eye in 0,1){foreach($field in @('contextIndex','contextGeneration','path','renderWidth','renderHeight','displayWidth','displayHeight','configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled','highDynamicRangeInput','autoExposure')){
            if($Status.lastSuccessfulEyeDispatches[$eye].$field -cne $Baseline.lastSuccessfulEyeDispatches[$eye].$field){throw "Timing coverage eye$eye signature changed: $field."}
        }}
    }
    function DelayBounded([double]$Milliseconds,[datetime]$Bound){
        $remaining=($Bound-[datetime]::UtcNow).TotalMilliseconds
        if($remaining -le 0){throw 'Timing coverage original work deadline expired.'}
        Start-Sleep -Milliseconds ([int][Math]::Ceiling([Math]::Max(0,[Math]::Min($Milliseconds,$remaining))))
    }
    function Assert-Revision($Status,[uint64]$Revision,[bool]$AutoExposure) {
        if ($Status.requested.revision -ne $Revision -or $Status.requested.highDynamicRangeInput -cne $Plan.highDynamicRangeInput -or $Status.requested.autoExposure -cne $AutoExposure) { throw 'Colour request revision/flags changed.' }
    }
    function Settled($Status,[uint64]$Revision,[bool]$AutoExposure) {
        Assert-Revision $Status $Revision $AutoExposure
        $c=$Status.runtimeContext
        if (-not $c.valid -or $c.highDynamicRangeInput -cne $Plan.highDynamicRangeInput -or $c.autoExposure -cne $AutoExposure) { return $false }
        $a=$Status.lastSuccessfulEyeDispatches[0]; $b=$Status.lastSuccessfulEyeDispatches[1]
        foreach($eye in 0,1) {
            $d=$Status.lastSuccessfulEyeDispatches[$eye]
            if (-not $d.valid) { return $false }
            if ($d.path -ne 3 -or $d.contextIndex -ne $eye -or $d.contextGeneration -ne $c.generation -or $d.highDynamicRangeInput -cne $Plan.highDynamicRangeInput -or $d.autoExposure -cne $AutoExposure) { throw 'Successful eye dispatch mismatches FSR4 context/flags/eye.' }
            if($FixedAutoExposure -and (-not $d.PSObject.Properties['submittedInputs'] -or $d.submittedInputs.available -isnot [bool] -or -not $d.submittedInputs.available)){throw 'Fixed-AE baseline requires available native submitted reset/jitter/delta telemetry; never synthesize it.'}
        }
        foreach($field in @('frame','contextGeneration','path','renderWidth','renderHeight','displayWidth','displayHeight','configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled')) { if($a.$field -cne $b.$field) { throw "Successful eyes disagree: $field." } }
        if ($a.serial -ge $b.serial -or $a.dispatchQpc -gt $b.dispatchQpc -or $Status.lastSuccessfulDispatch.serial -ne $b.serial) { throw 'Successful stereo dispatch ordering mismatch.' }
        return $true
    }
    function Assert-ProbeOwner($Status,$Owned) {
        if ($Status.captureId -isnot [string] -or -not (UInt $Status.generation 1) -or -not (UInt $Status.expectedColourContractRevision 1) -or $Status.captureId -cne $Owned.captureId -or $Status.generation -ne $Owned.generation -or $Status.expectedColourContractRevision -ne $revision) { throw 'Probe capture/generation/revision changed or malformed; no foreign adoption.' }
    }
    try {
        $null=Guard $DeadlineUtc
        $initial=Status $colour $DeadlineUtc
        if ($initial.requested.revision -ne $revision -or $initial.requested.highDynamicRangeInput -cne $Plan.highDynamicRangeInput) { throw 'Initial colour revision/fixed HDR mismatch.' }
        $originalAuto=$initial.requested.autoExposure;$knownAuto=$originalAuto;$knownColour=$true
        if($FixedAutoExposure){
            if($originalAuto -cne $Plan.autoExposure){throw 'Fixed-AE baseline current autoExposure differs from explicit admission; no colour set.'}
            $colourCleanup.required=$true
        }
        if($timed){$colourCleanup.verified=$true}
        $idle=Status $probe $DeadlineUtc
        if ($idle.state -cne 'idle') { throw 'Existing probe custody is not ours; refusing arm/reset.' }
        $sequence=if($FixedAutoExposure){@($Plan.autoExposure)}else{@($true,$false,$true)}
        foreach($auto in $sequence) {
            $condition=[ordered]@{autoExposure=$auto;setAttempted=$false;setAccepted=$false;setReply=$null;settled=$null;nativeDispatchMatched=$false;startupObservations=[Collections.Generic.List[object]]::new();burnIn=$null;complete=$false}
            $conditions.Add($condition)
            $pre=Guard $DeadlineUtc
            if(-not $FixedAutoExposure){
            $condition.setAttempted=$true
            $colourCleanup.required=$timed;$colourCleanup.verified=(-not $timed)
            $knownColour=$false
            $mutationPending=$true
            $condition.setReply=& $Call $colour @{action='set';expectedBuildId=$Plan.expectedBuildId;expectedRevision=$revision;highDynamicRangeInput=$Plan.highDynamicRangeInput;autoExposure=$auto} $true $DeadlineUtc
            $set=One $condition.setReply
            if ($set.accepted -isnot [bool] -or -not $set.accepted) { throw 'Colour set did not carry positive native CAS acceptance.' }
            $condition.setAccepted=$true
            $mutationPending=$false
            $setProjection=$set|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
            $setProjection.PSObject.Properties.Remove('accepted');$setProjection.PSObject.Properties.Remove('resultingRevision')
            if(-not (UInt $set.resultingRevision 1) -or @(Get-DevBenchNativeReadReasons -Kind 'fsr-colour-status' -Payload $setProjection -Arguments @{action='status';expectedBuildId=$Plan.expectedBuildId}).Count){throw 'Accepted set has malformed native status/revision; raw accepted action retained.'}
            $next=$revision+$(if($initial.requested.autoExposure -cne $auto){1}else{0})
            if ($set.resultingRevision -ne $next -or $set.requested.revision -ne $next) { throw 'Colour set resulting revision violates exact CAS transition.' }
            $revision=$next
            Assert-Revision $set $revision $auto
            $knownAuto=$auto;$knownColour=$true
            }
            $settleDeadline=$DeadlineUtc
            if($null -ne $burnPolicy){
                $burnStarted=$clock.Elapsed.TotalMilliseconds
                $settleDeadline=[datetime]::UtcNow.AddMilliseconds($burnPolicy.maximumElapsedMilliseconds)
                if($settleDeadline -gt $DeadlineUtc){$settleDeadline=$DeadlineUtc}
                $condition.burnIn=[ordered]@{status='running';complete=$false;thresholdBasis='engineering-coverage-not-vendor-convergence';policy=$burnPolicy;budgetStartedElapsedMilliseconds=$burnStarted;baselineObservedElapsedMilliseconds=$null;elapsedMilliseconds=0;observations=[Collections.Generic.List[object]]::new();distinctFreshSuccessfulBothEyeObservations=0;observedCpuFrameIdAdvancePerEye=@(0,0);successfulEyeFrameCount=$null;reason=$null}
            }
            $post=Guard $DeadlineUtc
            if (-not (Test-DevBenchShaderCompilerWindow -Before $pre.health -After $post.health).valid) { throw 'Compiler changed across accepted colour set; no replay.' }
            do {
                $s=Status $colour $settleDeadline $condition.startupObservations
                $settled=Settled $s $revision $auto
                $condition.startupObservations[-1].classification=if($settled){'matching-successful-dispatch'}else{'transient-unmatched-dispatch'}
                if(-not $settled){DelayBounded $PollMilliseconds $settleDeadline}
            } while(-not $settled -and [datetime]::UtcNow -lt $settleDeadline)
            if(-not $settled -or [datetime]::UtcNow -ge $settleDeadline){throw 'Stereo dispatch settlement deadline expired.'}
            $condition.settled=$s
            $condition.nativeDispatchMatched=$true
            if($null -ne $burnPolicy){
                $burn=$condition.burnIn; $baselineTick=$clock.Elapsed.TotalMilliseconds
                $burn.baselineObservedElapsedMilliseconds=$baselineTick
                $burn.distinctFreshSuccessfulBothEyeObservations=1
                $burn.observations.Add([ordered]@{classification='baseline';status=$s;receivedElapsedMilliseconds=$baselineTick;reply=$condition.startupObservations[-1].reply})
                $lastFresh=$s;$latest=$s
                do{
                    $burn.elapsedMilliseconds=$clock.Elapsed.TotalMilliseconds-$baselineTick
                    $within=[datetime]::UtcNow -lt $settleDeadline -and ($clock.Elapsed.TotalMilliseconds-$burnStarted) -lt $burnPolicy.maximumElapsedMilliseconds
                    if(-not $within){break}
                    if($burn.elapsedMilliseconds -ge $burnPolicy.minimumElapsedMilliseconds -and $burn.distinctFreshSuccessfulBothEyeObservations -ge $burnPolicy.minimumDistinctFreshSuccessfulBothEyeObservations -and @($burn.observedCpuFrameIdAdvancePerEye|Where-Object {$_ -lt $burnPolicy.minimumObservedCpuFrameIdAdvancePerEye}).Count -eq 0){$burn.complete=$true;break}
                    DelayBounded $PollMilliseconds $settleDeadline
                    $g=Guard $settleDeadline
                    if(-not (Test-DevBenchShaderCompilerWindow -Before $post.health -After $g.health).valid){throw 'Compiler changed during burn-in coverage.'}
                    $latest=Status $colour $settleDeadline $burn.observations
                    $entry=$burn.observations[-1]
                    if([datetime]::UtcNow -ge $settleDeadline){break}
                    $entry.classification='transient-unmatched-dispatch'
                    if($latest.runtimeContext.generation -ne $s.runtimeContext.generation){throw 'Burn-in context generation changed.'}
                    if(-not (Settled $latest $revision $auto)){continue}
                    StableSignature $latest $s
                    $fresh=$true
                    foreach($eye in 0,1){
                        $d=$latest.lastSuccessfulEyeDispatches[$eye];$prior=$lastFresh.lastSuccessfulEyeDispatches[$eye]
                        if($d.frame -lt $prior.frame -or $d.serial -lt $prior.serial -or $d.dispatchQpc -lt $prior.dispatchQpc){throw 'Burn-in frame/serial/QPC regressed; no wrap or successful-frame-count inference.'}
                        if($d.frame -le $prior.frame -or $d.serial -le $prior.serial -or $d.dispatchQpc -le $prior.dispatchQpc){$fresh=$false}
                    }
                    if($fresh){$lastFresh=$latest;$burn.distinctFreshSuccessfulBothEyeObservations++;$entry.classification='distinct-fresh-successful-both-eye'}
                    else{$entry.classification='matching-but-not-distinct-fresh-both-eye'}
                    $burn.observedCpuFrameIdAdvancePerEye=@(foreach($eye in 0,1){[long]$lastFresh.lastSuccessfulEyeDispatches[$eye].frame-[long]$s.lastSuccessfulEyeDispatches[$eye].frame})
                }while($true)
                if(-not $burn.complete){$burn.status='incomplete';$burn.reason='coverage-or-original-work-deadline';throw 'burn-in-incomplete: declared elapsed/frame/observation coverage not met within bounded deadline.'}
                $burn.status='complete'
                $condition.burnInComplete=$true
            }
            for($iteration=0;$iteration -lt $Plan.capturesPerCondition;$iteration++) {
                $record=[ordered]@{autoExposure=$auto;iteration=$iteration;revision=$revision;captureId=[guid]::NewGuid().ToString('N');generation=$null;armReply=$null;status=$null;pages=[Collections.Generic.List[object]]::new();complete=$false;resetVerified=$false;resetAttempted=$false;spacing=[ordered]@{minimumMilliseconds=$spacing;priorArmAcknowledgedElapsedMilliseconds=$lastArmAcknowledged;observations=[Collections.Generic.List[object]]::new();armIntentElapsedMilliseconds=$null;verified=$false}}
                $captures.Add($record)
                if($readBrackets){$record.readBrackets=[Collections.Generic.List[object]]::new()}
                while($null -ne $lastArmAcknowledged -and ($clock.Elapsed.TotalMilliseconds-$lastArmAcknowledged) -lt $spacing){
                    $g=Guard $DeadlineUtc
                    if(-not (Test-DevBenchShaderCompilerWindow -Before $post.health -After $g.health).valid){throw 'Compiler changed during inter-arm spacing.'}
                    $current=Status $colour $DeadlineUtc $record.spacing.observations
                    if(-not (Settled $current $revision $auto)){throw 'Dispatch ceased matching during inter-arm spacing.'}
                    if($null -ne $burnPolicy){StableSignature $current $s}
                    DelayBounded ([Math]::Min($PollMilliseconds,$spacing-($clock.Elapsed.TotalMilliseconds-$lastArmAcknowledged))) $DeadlineUtc
                }
                $before=Guard $DeadlineUtc
                $current=Status $colour $DeadlineUtc
                if(-not (Settled $current $revision $auto) -or $current.runtimeContext.generation -ne $s.runtimeContext.generation){throw 'Settled context changed before arm.'}
                if($null -ne $burnPolicy){StableSignature $current $s}
                if($readBrackets){ReadBracket $record 'before-arm' $DeadlineUtc}
                $captureBound=[datetime]::UtcNow.AddSeconds(15)
                if($captureBound -gt $DeadlineUtc){$captureBound=$DeadlineUtc}
                $mutationPending=$true
                $record.spacing.armIntentElapsedMilliseconds=$clock.Elapsed.TotalMilliseconds
                $record.spacing.verified=$null -eq $lastArmAcknowledged -or ($record.spacing.armIntentElapsedMilliseconds-$lastArmAcknowledged) -ge $spacing
                if(-not $record.spacing.verified){throw 'Inter-arm spacing incomplete; no arm dispatched.'}
                $record.armReply=& $Call $probe @{action='arm';expectedBuildId=$Plan.expectedBuildId;expectedRevision=$revision;captureId=$record.captureId;metadata=$Plan.metadata} $true $captureBound
                $arm=One $record.armReply
                if($arm.action -isnot [string] -or $arm.action -cne 'arm' -or $arm.accepted -isnot [bool] -or -not $arm.accepted -or $arm.captureId -isnot [string] -or $arm.captureId -cne $record.captureId -or -not (UInt $arm.generation 1)){throw 'Probe arm acceptance/identity unproven; no replay or foreign reset.'}
                $record.generation=$arm.generation; $owned=$record; $resetVerified=$false
                if($readBrackets){$record.readBrackets[0].generation=$arm.generation;$record.readBrackets[0].generationBindingBasis='native-arm-acceptance-after-read'}
                $lastArmAcknowledged=$clock.Elapsed.TotalMilliseconds
                $mutationPending=$false
                do {
                    $p=Status $probe $captureBound; Assert-ProbeOwner $p $owned; $record.status=$p
                    if($p.state -ceq 'failed'){throw "Native colour probe capture failed: $($p.error) [captureId=$($p.captureId); generation=$($p.generation); cpuFrame=$($p.cpuFrame); queuedStageEyeSlots=$($p.queuedStageEyeSlots)/$($p.expectedStageEyeSlots); mappedStageEyeSlots=$($p.mappedStageEyeSlots); stagingPayloadBytes=$($p.stagingPayloadBytes)]. Raw reply retained; no capture replay."}
                    if($p.state -cnotin @('armed','capturing','readback_pending','complete')){throw 'Probe failed or lost custody.'}
                    $current=Status $colour $captureBound
                    if(-not (Settled $current $revision $auto) -or $current.runtimeContext.generation -ne $s.runtimeContext.generation){throw 'Colour context/eyes changed during capture.'}
                    if($null -ne $burnPolicy){StableSignature $current $s}
                    if($p.state -cne 'complete'){Start-Sleep -Milliseconds ([Math]::Min($PollMilliseconds,[Math]::Max(0,($captureBound-[datetime]::UtcNow).TotalMilliseconds)))}
                } while($p.state -cne 'complete' -and [datetime]::UtcNow -lt $captureBound)
                if($p.state -cne 'complete' -or [datetime]::UtcNow -ge $captureBound){throw 'Native fifteen-second capture/readback deadline expired; partial capture retained.'}
                if($null -ne $burnPolicy -and $p.cpuFrame -le $lastFresh.lastSuccessfulEyeDispatches[0].frame){throw 'Capture CPU frame did not advance beyond final burn-in observation.'}
                if($readBrackets){
                    $record.readBrackets[0].capturedCpuFrame=$p.cpuFrame
                    ReadBracket $record 'after-native-completion' $captureBound
                }
                $context=$null; $eyeDispatch=@{}
                foreach($stage in $stages){foreach($eye in 0,1){
                    $page=One (& $Call $probe @{action='read';expectedBuildId=$Plan.expectedBuildId;captureId=$owned.captureId;generation=$owned.generation;stage=$stage;eye=$eye} $false $captureBound)
                    $record.pages.Add($page)
                    if($page.schema -cne 'csx-colour-pipeline-probe-v3' -or $page.captureId -cne $owned.captureId -or $page.generation -ne $owned.generation -or $page.state -cne 'complete' -or $page.frame.cpuFrame -ne $p.cpuFrame -or $page.frame.eye -cne 'both' -or $page.frame.eyeMask -ne 3 -or $null -ne $page.frame.sceneEpoch -or $null -ne $page.frame.submissionEpoch -or @($page.stages).Count -ne 1){throw 'Capture page schema/identity/frame/epochs mismatch.'}
                    $slot=$page.stages[0]; $d=$page.dispatch
                    foreach($value in @($page.generation,$page.frame.cpuFrame,$page.frame.eyeMask,$slot.eyeMask,$slot.frame.cpuFrame,$d.colourContractRevision,$d.contextGeneration,$d.frame,$d.dispatchSerial)){if(-not (UInt $value 1)){throw 'Page ownership/frame/dispatch IDs require typed positive unsigned integers.'}}
                    foreach($value in @($d.contextIndex,$slot.readback.sampling.gridSize,$slot.readback.sampling.sampleCount,$page.samplingContract.gridSize)){if(-not (UInt $value)){throw 'Page numeric fields cannot be strings/Booleans/fractions.'}}
                    # Probe schema3 DispatchMetadata.path is a native string label;
                    # colour status path3 is a different, numeric contract. Never coerce.
                    if($d.path -isnot [string] -or $d.path -cne 'Runtime FSR4 (amd_fidelityfx_upscaler_dx12.dll)'){throw 'Page dispatch path is not the exact native FSR4 string label.'}
                    foreach($value in @($d.requestedHighDynamicRangeInput,$d.effectiveHighDynamicRangeInput,$d.requestedAutoExposure,$d.effectiveAutoExposure)){if($value -isnot [bool]){throw 'Page dynamic flags require actual Booleans.'}}
                    if($page.metadata -isnot [pscustomobject] -or $page.metadata.calibratedScene -isnot [string] -or $page.metadata.calibratedScene -cne $Plan.metadata.calibratedScene){throw 'Owner calibration metadata differs from the arm request.'}
                    if($slot.stage -cne $stage -or $slot.eye -cne @('left','right')[$eye] -or $slot.eyeMask -ne (1 -shl $eye) -or $slot.queued -isnot [bool] -or -not $slot.queued -or $slot.mapped -isnot [bool] -or -not $slot.mapped -or $slot.frame.cpuFrame -ne $p.cpuFrame){throw 'Capture page is incomplete or wrong stage/eye.'}
                    if($page.immediateContext.kind -cne 'immediate' -or $page.immediateContext.pointer -isnot [string] -or $page.immediateContext.pointer -notmatch '^0x[0-9a-fA-F]+$' -or $page.immediateContext.pointer -match '^0x0+$'){throw 'Capture immediate context is unproven.'}
                    if($null -eq $context){$context=$page.immediateContext.pointer}else{if($context -cne $page.immediateContext.pointer){throw 'Capture pages changed immediate context.'}}
                    if($d.attribution -cne 'observed-successful-dispatch' -or $d.colourContractRevision -ne $revision -or $d.contextGeneration -ne $s.runtimeContext.generation -or $d.contextIndex -ne $eye -or $d.frame -ne $p.cpuFrame -or $d.requestedHighDynamicRangeInput -cne $Plan.highDynamicRangeInput -or $d.effectiveHighDynamicRangeInput -cne $Plan.highDynamicRangeInput -or $d.requestedAutoExposure -cne $auto -or $d.effectiveAutoExposure -cne $auto -or $d.dispatchSerial -le 0){throw 'Page lacks matching actual successful eye dispatch.'}
                    if(@(Get-DevBenchSubmittedInputReasons -Dispatch $d -Successful $true).Count){throw 'Page submittedInputs is malformed or unsupported; raw page retained.'}
                    if($FixedAutoExposure -and (-not $d.PSObject.Properties['submittedInputs'] -or $d.submittedInputs.available -isnot [bool] -or -not $d.submittedInputs.available)){throw 'Fixed-AE baseline page requires actual submitted reset/jitter/delta telemetry; raw page retained.'}
                    if($null -ne $burnPolicy){
                        foreach($field in @('renderWidth','renderHeight','displayWidth','displayHeight','configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled')){if(-not $d.PSObject.Properties[$field] -or $d.$field -cne $s.lastSuccessfulEyeDispatches[$eye].$field){throw "Burn-in qualified page signature changed: $field."}}
                        if(-not $d.PSObject.Properties['dispatchQpc'] -or -not (UInt $d.dispatchQpc 1) -or $d.dispatchSerial -le $lastFresh.lastSuccessfulEyeDispatches[$eye].serial -or $d.dispatchQpc -le $lastFresh.lastSuccessfulEyeDispatches[$eye].dispatchQpc){throw 'Capture eye dispatch did not advance beyond final burn-in observation.'}
                    }
                    $dispatchKey=$d|ConvertTo-Json -Depth 8 -Compress
                    if($eyeDispatch.ContainsKey($eye)){if($eyeDispatch[$eye] -cne $dispatchKey){throw 'Stage pages disagree on eye dispatch.'}}else{$eyeDispatch[$eye]=$dispatchKey}
                    if(($slot.dispatch|ConvertTo-Json -Depth 8 -Compress) -cne $dispatchKey -or $slot.readback.map.succeeded -isnot [bool] -or -not $slot.readback.map.succeeded -or $slot.readback.map.matchedMap -isnot [bool] -or -not $slot.readback.map.matchedMap -or $slot.readback.map.readable -isnot [bool] -or -not $slot.readback.map.readable -or $slot.readback.sampling.transferConversion -cne 'none' -or @($slot.readback.sampling.samples).Count -ne $slot.readback.sampling.sampleCount){throw 'Raw sample readback/dispatch completeness unproven.'}
                    $sampling=$slot.readback.sampling
                    if($sampling.gridSize -ne 17 -or $sampling.sampleCount -ne 289 -or $page.samplingContract.gridSize -ne 17 -or $page.samplingContract.rawBytesRetainedPerSample -isnot [bool] -or -not $page.samplingContract.rawBytesRetainedPerSample -or $page.samplingContract.implicitTransferConversion -isnot [bool] -or $page.samplingContract.implicitTransferConversion){throw 'Native17x17 lossless sampling contract unproven.'}
                    for($sampleIndex=0;$sampleIndex -lt 289;$sampleIndex++){
                        $sample=$sampling.samples[$sampleIndex]
                        if(@($sample.sourcePixel).Count -ne 2 -or -not (UInt $sample.sourcePixel[0]) -or -not (UInt $sample.sourcePixel[1])){throw 'Raw sample source pixel coordinates are malformed.'}
                        if(@($sample.grid).Count -ne 2 -or -not (UInt $sample.grid[0]) -or -not (UInt $sample.grid[1]) -or $sample.grid[0] -ne ($sampleIndex%17) -or $sample.grid[1] -ne [int][Math]::Floor($sampleIndex/17) -or $sample.rawLittleEndianHex -isnot [string] -or $sample.rawLittleEndianHex -notmatch '^[0-9a-fA-F]{2,32}$' -or ($sample.rawLittleEndianHex.Length%2) -ne 0 -or -not $sample.PSObject.Properties['decodedRgba']){throw 'Raw sample inventory/bytes incomplete.'}
                        if($null -ne $sample.decodedRgba){if(@($sample.decodedRgba).Count -ne 4 -or @($sample.decodedRgba|Where-Object {$null -eq $_ -or $_.GetType() -notin @([int],[long],[double],[single],[decimal],[uint32],[uint64]) -or -not [double]::IsFinite([double]$_)}).Count){throw 'Decoded sample is malformed; no implicit transfer conversion.'}}
                    }
                }}
                $after=Guard $captureBound
                if(-not (Test-DevBenchShaderCompilerWindow -Before $before.health -After $after.health).valid){throw 'Compiler boundary changed across capture; pages remain diagnostic.'}
                $current=Status $colour $captureBound
                if(-not (Settled $current $revision $auto) -or $current.runtimeContext.generation -ne $s.runtimeContext.generation){throw 'Colour context changed after pages.'}
                if($null -ne $burnPolicy){StableSignature $current $s}
                $record.complete=$true
                $mutationPending=$true
                $record.resetAttempted=$true
                $reset=One (& $Call $probe @{action='reset';expectedBuildId=$Plan.expectedBuildId;captureId=$owned.captureId;generation=$owned.generation} $true $DeadlineUtc)
                if($reset.action -isnot [string] -or $reset.action -cne 'reset' -or $reset.accepted -isnot [bool] -or -not $reset.accepted -or $reset.captureId -isnot [string] -or $reset.captureId -cne $owned.captureId -or -not (UInt $reset.generation 1) -or $reset.generation -ne ($owned.generation+1)){throw 'Exact owned probe reset unverified; no retry.'}
                $idle=Status $probe $DeadlineUtc
                if($idle.state -cne 'idle' -or $idle.generation -ne $reset.generation){throw 'Fresh probe reset readback failed.'}
                $resetVerified=$true; $record.resetVerified=$true; $owned=$null
                $mutationPending=$false
            }
            $condition.complete=$true; $initial=$s
        }
    } catch {
        $failure=$_.Exception.Message
        foreach($c in $conditions){if($null -ne $c.burnIn -and -not $c.burnIn.complete){$c.burnIn.status='incomplete';$c.burnIn.reason=$failure;$c.burnIn.failureCode=if($failure -match 'deadline|expired|burn-in-incomplete'){'burn-in-incomplete'}else{'burn-in-invalidated'};if($failure -notmatch '^burn-in-'){$failure=$c.burnIn.failureCode+': '+$failure}}}
        $errors.Add($failure); $uncertain=$mutationPending -or @($conditions | Where-Object {$_.setAttempted -and -not $_.setAccepted}).Count -gt 0
    }
    finally {
        # Evidence is already retained before cleanup. Never repeat reset after
        # an attempted/lost reset and never adopt a foreign or unproven arm.
        if($null -ne $owned -and $null -ne $CleanupCall){
            $probeCleanup.attempted=$true;$probeCleanup.verified=$false
            try{
                if(-not $owned.resetAttempted){
                    do{
                        $status=One (& $CleanupCall $probe @{action='status';expectedBuildId=$Plan.expectedBuildId} $false $CleanupDeadlineUtc) $true
                        if(@(Get-DevBenchNativeReadReasons -Kind 'colour-probe-status' -Payload $status -Arguments @{action='status';expectedBuildId=$Plan.expectedBuildId}).Count){throw 'Owned failure cleanup status schema unverified.'}
                        Assert-ProbeOwner $status $owned
                        if($status.state -cin @('armed','capturing','readback_pending')){Start-Sleep -Milliseconds ([Math]::Min(100,[Math]::Max(0,($CleanupDeadlineUtc-[datetime]::UtcNow).TotalMilliseconds)))}
                    }while($status.state -cin @('armed','capturing','readback_pending') -and [datetime]::UtcNow -lt $CleanupDeadlineUtc)
                    if($status.state -cnotin @('complete','failed') -or [datetime]::UtcNow -ge $CleanupDeadlineUtc){throw 'Native probe remains active; no forbidden reset, bounded cleanup unverified.'}
                    $owned.resetAttempted=$true
                    $reset=One (& $CleanupCall $probe @{action='reset';expectedBuildId=$Plan.expectedBuildId;captureId=$owned.captureId;generation=$owned.generation} $true $CleanupDeadlineUtc)
                    if($reset.action -isnot [string] -or $reset.action -cne 'reset' -or $reset.accepted -isnot [bool] -or -not $reset.accepted -or $reset.captureId -isnot [string] -or $reset.captureId -cne $owned.captureId -or -not (UInt $reset.generation 1) -or $reset.generation -ne ($owned.generation+1)){throw 'Owned failure cleanup reset unverified.'}
                }
                $status=One (& $CleanupCall $probe @{action='status';expectedBuildId=$Plan.expectedBuildId} $false $CleanupDeadlineUtc)
                if(@(Get-DevBenchNativeReadReasons -Kind 'colour-probe-status' -Payload $status -Arguments @{action='status';expectedBuildId=$Plan.expectedBuildId}).Count){throw 'Owned cleanup fresh idle status schema unverified.'}
                if($status.state -cne 'idle' -or $status.generation -ne ($owned.generation+1) -or $status.captureId -cne ''){throw 'Owned probe cleanup fresh idle readback unverified.'}
                $probeCleanup.verified=$true;$resetVerified=$true;$owned.resetVerified=$true
            }catch{$probeCleanup.errors.Add($_.Exception.Message)}
        }elseif($null -ne $owned -or $mutationPending){$probeCleanup.verified=$false}
        if($timed -and $colourCleanup.required -and $null -ne $originalAuto){
            $colourCleanup.verified=$false
            try{
                if(-not $knownColour -or $mutationPending -or -not $probeCleanup.verified){throw 'Original AE restoration has unresolved mutation/probe custody; no speculative set.'}
                if($null -eq $CleanupCall){
                    if($knownAuto -cne $originalAuto){throw 'Original AE restoration requires same-session cleanup call.'}
                    $colourCleanup.verified=$true
                }else{
                    $restoreArgs=@{action='status';expectedBuildId=$Plan.expectedBuildId}
                    $read=One (& $CleanupCall $colour $restoreArgs $false $CleanupDeadlineUtc)
                    if(@(Get-DevBenchNativeReadReasons -Kind 'fsr-colour-status' -Payload $read -Arguments $restoreArgs).Count){throw 'AE restoration read schema unqualified.'}
                    Assert-Revision $read $revision $knownAuto
                    if($knownAuto -cne $originalAuto){
                        if($FixedAutoExposure){throw 'Fixed-AE baseline never writes the colour contract, including cleanup.'}
                        $colourCleanup.attempted=$true
                        $colourCleanup.reply=& $CleanupCall $colour @{action='set';expectedBuildId=$Plan.expectedBuildId;expectedRevision=$revision;highDynamicRangeInput=$Plan.highDynamicRangeInput;autoExposure=$originalAuto} $true $CleanupDeadlineUtc
                        $restored=One $colourCleanup.reply
                        $projection=$restored|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20
                        $projection.PSObject.Properties.Remove('accepted');$projection.PSObject.Properties.Remove('resultingRevision')
                        if($restored.accepted -isnot [bool] -or -not $restored.accepted -or -not (UInt $restored.resultingRevision 1) -or $restored.resultingRevision -ne ($revision+1) -or @(Get-DevBenchNativeReadReasons -Kind 'fsr-colour-status' -Payload $projection -Arguments $restoreArgs).Count){throw 'Original AE restore CAS unverified; never replay.'}
                        $revision=$restored.resultingRevision;Assert-Revision $restored $revision $originalAuto
                    }
                    $read=One (& $CleanupCall $colour $restoreArgs $false $CleanupDeadlineUtc)
                    if(@(Get-DevBenchNativeReadReasons -Kind 'fsr-colour-status' -Payload $read -Arguments $restoreArgs).Count){throw 'AE restoration fresh read schema unqualified.'}
                    Assert-Revision $read $revision $originalAuto
                    $colourCleanup.readback=$read;$colourCleanup.verified=$true
                }
            }catch{$colourCleanup.errors.Add($_.Exception.Message);$errors.Add('AE restoration: '+$_.Exception.Message)}
        }
    }
    return [pscustomobject]@{ok=($errors.Count -eq 0 -and $colourCleanup.verified);conditions=@($conditions);captures=@($captures);compilerBoundaries=@($guards);errors=@($errors);indeterminate=($uncertain -or -not $probeCleanup.verified -or -not $colourCleanup.verified);probeResetVerified=$resetVerified;probeCleanup=$probeCleanup;colourCleanup=$colourCleanup;retainedProbe=$owned;finalRevision=$revision;completionBasis='native-stereo-dispatch-and-ten-owned-pages-not-scientific-colour';burnInRequested=($null -ne $burnPolicy);vendorExposureConvergenceKnown=$false;nativeCaptureDeadlineSeconds=15;nativeReadbackFrameLimit=120;calibrationOwnedByCaller=$true;qualityAndRenderScaleAdmissionOwnedByCaller=$true;fixedAutoExposureBaseline=[bool]$FixedAutoExposure}
}
Export-ModuleMember -Function Assert-ColourMeasurementPlan,Invoke-DevBenchColourMeasurement,Assert-ColourReadBracketCatalog
