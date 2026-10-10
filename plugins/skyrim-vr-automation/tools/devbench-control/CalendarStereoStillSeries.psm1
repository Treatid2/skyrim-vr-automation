# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest

function Assert-CalendarStereoStillPlan([Collections.IDictionary]$Plan) {
    $fields=@('schemaVersion','expectedBuildId','expectedCellFormId','outputDirectory','sampleCount','minimumArmIntervalMilliseconds','requestTimeoutMilliseconds')
    if($null -eq $Plan -or $Plan.Count -ne $fields.Count -or @($fields|Where-Object {-not $Plan.Contains($_)}).Count){throw 'Still plan requires exactly its seven typed fields.'}
    foreach($name in @('schemaVersion','expectedCellFormId','sampleCount','minimumArmIntervalMilliseconds','requestTimeoutMilliseconds')){
        if($null -eq $Plan[$name] -or $Plan[$name].GetType() -notin @([int],[long],[uint32],[uint64])){throw "Still plan $name requires an integer."}
    }
    if($Plan.schemaVersion -ne 1 -or $Plan.expectedCellFormId -lt 1 -or $Plan.expectedCellFormId -gt [uint32]::MaxValue -or $Plan.sampleCount -lt 2 -or $Plan.sampleCount -gt 16 -or $Plan.minimumArmIntervalMilliseconds -lt 250 -or $Plan.minimumArmIntervalMilliseconds -gt 10000 -or $Plan.requestTimeoutMilliseconds -lt 1000 -or $Plan.requestTimeoutMilliseconds -gt 20000){throw 'Still plan is outside finite count/timing/cell limits.'}
    if($Plan.expectedBuildId -isnot [string] -or $Plan.expectedBuildId -cnotmatch '^[a-f0-9]{64}$' -or $Plan.outputDirectory -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Plan.outputDirectory)){throw 'Still plan requires exact build and absolute owned output directory.'}
    $directory=[IO.Path]::GetFullPath($Plan.outputDirectory)
    if(-not(Test-Path -LiteralPath $directory -PathType Container) -or (Get-Item -LiteralPath $directory).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)){throw 'Still output directory must already exist and not be a reparse point.'}
}

function Invoke-CalendarStereoStillSeries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Plan,
          [Parameter(Mandatory)][scriptblock]$Call,
          [Parameter(Mandatory)][scriptblock]$CalendarGuard,
          [Parameter(Mandatory)][scriptblock]$CompilerGuard,
          [Parameter(Mandatory)][scriptblock]$PerformanceGuard,
          [Parameter(Mandatory)][datetime]$DeadlineUtc,
          [Parameter(Mandatory)][datetime]$CleanupDeadlineUtc)
    $samples=[Collections.Generic.List[object]]::new();$errors=[Collections.Generic.List[string]]::new()
    $client='calendar-stills/'+[guid]::NewGuid().ToString('N');$uncertain=$false;$previous=$null;$lastFrame=0;$lastCycle=0;$lastAcquired=$null;$producerSession=$null
    function Command([string]$Action){return @{contractMajor=1;contractMinor=0;clientId=$client;commandId=[guid]::NewGuid().ToString('N');action=$Action}}
    function Guard([datetime]$Bound){& $CalendarGuard $Bound|Out-Null;if([datetime]::UtcNow -ge $Bound){throw 'Still workflow deadline expired.'}}
    function QualifyRequest($Reply,$Query,$Sample){
        if(@($Reply.content).Count -ne 1){throw 'Still request requires one native reply.'}
        $qualifiedQuery=@{};foreach($key in $Query.Keys){$qualifiedQuery[$key]=$Query[$key]};$qualifiedQuery.expectedBuildId=$Plan.expectedBuildId
        $status=Get-DevBenchCallSemanticStatus -ToolName communityshaders.screenshot -Arguments $qualifiedQuery -Content @($Reply.content)
        if(-not $status.known -or -not $status.ok -or -not $status.PSObject.Properties['qualifiedScreenshotRequest']){throw ('Still request_get unqualified: '+($status.reasons -join '; '))}
        $r=$status.qualifiedScreenshotRequest
        if($r.commandId -cne $Sample.command.commandId -or $r.clientId -cne $client -or $r.requestId -cne $Sample.requestId){throw 'Still original capture ownership changed.'}
        $session=[string]$Reply.content[0].server.serviceSessionId
        if($null -ne $producerSession -and $session -cne $producerSession){throw 'Still producer service session changed.'}
        return $r
    }
    function ReadRequest($Sample,[datetime]$Bound){
        Guard $Bound
        $query=Command request_get;$query.requestId=$Sample.requestId
        $reply=& $Call communityshaders.screenshot $query $false $Bound
        $Sample.reads.Add([ordered]@{query=$query;receivedUtc=[datetime]::UtcNow.ToString('o');reply=$reply})
        $r=QualifyRequest $reply $query $Sample
        $Sample.finalReceipt=$r
        Guard $Bound
        return $r
    }
    function VerifyArtifact($Artifact,[string]$ExpectedPath,[datetime]$Bound){
        if(-not [string]::Equals([IO.Path]::GetFullPath($Artifact.path),$ExpectedPath,[StringComparison]::OrdinalIgnoreCase)){throw 'Still artifact escaped exact owned path.'}
        $info=Get-Item -LiteralPath $ExpectedPath -ErrorAction Stop
        if($info.PSIsContainer -or $info.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint) -or $info.Length -ne $Artifact.bytes -or $info.Length -lt 8 -or $info.Length -gt 67108864){throw 'Still artifact size/type exceeds bounded publication contract.'}
        $stream=[IO.File]::Open($ExpectedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try{
            $buffer=[byte[]]::new(65536);$total=0
            while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
                if([datetime]::UtcNow -ge $Bound){throw 'Still artifact verification deadline expired.'}
                if($total -eq 0 -and [Convert]::ToHexString($buffer[0..7]) -cne '89504E470D0A1A0A'){throw 'Still artifact is not PNG encoded.'}
                $total+=$n;if($total -gt 67108864){throw 'Still artifact grew beyond bound.'};$hash.AppendData($buffer,0,$n)
            }
            $digest=[Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
            $after=Get-Item -LiteralPath $ExpectedPath
            if($total -ne $Artifact.bytes -or $after.Length -ne $info.Length -or $after.LastWriteTimeUtc -ne $info.LastWriteTimeUtc -or $digest -cne $Artifact.sha256){throw 'Still artifact hash/stability mismatch.'}
            return [pscustomobject]@{path=$ExpectedPath;bytes=$total;sha256=$digest;verified=$true}
        }finally{$hash.Dispose();$stream.Dispose()}
    }
    try{
        Assert-CalendarStereoStillPlan $Plan
        if(([decimal]$Plan.sampleCount-1)*$Plan.minimumArmIntervalMilliseconds+1000 -ge ($DeadlineUtc-[datetime]::UtcNow).TotalMilliseconds){throw 'Still minimum arm span does not fit original work budget.'}
        for($i=0;$i -lt $Plan.sampleCount;$i++){
            if($previous){
                $next=([datetimeoffset]$previous.intendedUtc).UtcDateTime.AddMilliseconds($Plan.minimumArmIntervalMilliseconds)
                while([datetime]::UtcNow -lt $next){if([datetime]::UtcNow -ge $DeadlineUtc){throw 'Still arm-spacing deadline expired.'};Start-Sleep -Milliseconds ([int][math]::Min(100,[math]::Max(1,($next-[datetime]::UtcNow).TotalMilliseconds)))}
            }
            Guard $DeadlineUtc
            $beforeCompiler=& $CompilerGuard $DeadlineUtc
            if(-not $beforeCompiler.admissible){throw 'Still compiler first boundary unqualified.'}
            $beforePerformance=& $PerformanceGuard $DeadlineUtc
            if(-not $beforePerformance.neutral -or -not $beforePerformance.physicalStateKnown){throw 'Still performance neutrality unqualified.'}
            $cmd=Command capture;$base='still-'+$client.Split('/')[-1]+'-'+$i.ToString('D2')
            $cmd.useSettings=$false
            $cmd.capture=@{source=@{kind='hmd_submission';fallback='reject'};outputs=@(@{view='left_eye';nameSuffix='left';encoding=@{format='png';colourContract='sdr_srgb'}},@{view='right_eye';nameSuffix='right';encoding=@{format='png';colourContract='sdr_srgb'}});destination=@{policy='absolute';directory=[IO.Path]::GetFullPath($Plan.outputDirectory);baseName=$base;overwrite='never'};clipboard='none';tags=@{calendarStillSeries=$client}}
            $sample=[ordered]@{ordinal=$i;command=$cmd;intendedUtc=[datetime]::UtcNow.ToString('o');dispatchAttempted=$false;acceptedReply=$null;requestId=$null;reads=[Collections.Generic.List[object]]::new();finalReceipt=$null;publication=@();compilerBefore=$beforeCompiler;compilerAfter=$null;performanceBefore=$beforePerformance;performanceAfter=$null;cancelReply=$null;error=$null}
            $samples.Add($sample);$previous=$sample
            foreach($suffix in @('left','right')){if(Test-Path -LiteralPath (Join-Path $Plan.outputDirectory ($base+'_'+$suffix+'.png'))){throw 'Still output already exists; no overwrite.'}}
            Guard $DeadlineUtc
            $sample.dispatchAttempted=$true
            $reply=& $Call communityshaders.screenshot $cmd $true $DeadlineUtc
            $sample.acceptedReply=$reply
            if(@($reply.content).Count -ne 1){throw 'Still acceptance requires one native reply.'}
            $p=$reply.content[0];$r=$p.result
            if($p.ok -isnot [bool] -or -not $p.ok -or $p.command.action -cne 'capture' -or $p.command.clientId -cne $client -or $p.command.commandId -cne $cmd.commandId -or $p.server.buildId -cne $Plan.expectedBuildId -or [string]::IsNullOrWhiteSpace($p.server.serviceSessionId) -or $p.contract.name -cne 'csx.screenshot' -or $p.contract.major -ne 1 -or $r.kind -cne 'still' -or $r.clientId -cne $client -or $r.commandId -cne $cmd.commandId -or $r.requestId -isnot [string] -or [string]::IsNullOrWhiteSpace($r.requestId)){throw 'Still acceptance did not establish exact original request custody.'}
            $sample.requestId=$r.requestId
            if($producerSession -and $producerSession -cne $p.server.serviceSessionId){throw 'Still acceptance producer changed.'};$producerSession=$p.server.serviceSessionId
            $requestDeadline=[datetime]::UtcNow.AddMilliseconds($Plan.requestTimeoutMilliseconds)
            if($requestDeadline -gt $DeadlineUtc){$requestDeadline=$DeadlineUtc}
            do{
                $r=ReadRequest $sample $requestDeadline
                if($r.terminal){break}
                Start-Sleep -Milliseconds 100
            }while([datetime]::UtcNow -lt $requestDeadline)
            if(-not $r.terminal -or -not $r.requestSucceeded){throw 'Still original request did not complete successfully.'}
            $acquired=([datetimeoffset]$r.timestampUtc).UtcDateTime
            $dispatchUtc=([datetimeoffset]$sample.intendedUtc).UtcDateTime
            # Native JSON UTCs have millisecond precision; compare against the
            # same precision, not a fabricated sub-millisecond native ordering.
            $dispatchFloor=$dispatchUtc.AddTicks(-($dispatchUtc.Ticks % [TimeSpan]::TicksPerMillisecond))
            if(([datetimeoffset]$r.acceptedUtc).UtcDateTime -lt $dispatchFloor){throw 'Still native acceptance predates this exact dispatch.'}
            if($r.engineFrame -le $lastFrame -or $r.actual.acquisition.compositorCycle -le $lastCycle -or ($lastAcquired -and $acquired -le $lastAcquired)){throw 'Still acquisition did not advance frame/cycle/time.'}
            if($r.artifacts.Count -ne 2 -or @($r.effective.outputs).Count -ne 2 -or $r.effective.source.kind -cne 'hmd_submission' -or $r.effective.source.fallback -cne 'reject' -or $r.effective.clipboard -cne 'none' -or $r.effective.destination.overwrite -cne 'never'){throw 'Still source/stereo/destination semantics changed.'}
            foreach($pair in @(@('left_eye','left'),@('right_eye','right'))){
                $artifact=@($r.artifacts|Where-Object view -CEQ $pair[0])
                if($artifact.Count -ne 1 -or $artifact[0].format -cne 'png'){throw 'Still missing exact stereo PNG view.'}
                $sample.publication+=VerifyArtifact $artifact[0] (Join-Path $Plan.outputDirectory ($base+'_'+$pair[1]+'.png')) $DeadlineUtc
            }
            $lastFrame=$r.engineFrame;$lastCycle=$r.actual.acquisition.compositorCycle;$lastAcquired=$acquired
            $sample.compilerAfter=& $CompilerGuard $DeadlineUtc
            if(-not $sample.compilerAfter.admissible){throw 'Still compiler AFTER boundary unqualified; original capture retained.'}
            $sample.performanceAfter=& $PerformanceGuard $DeadlineUtc
            $neutral=Test-DevBenchPerformanceWindow $beforePerformance $sample.performanceAfter
            if(-not $sample.performanceAfter.physicalStateKnown -or -not $neutral.valid){throw 'Still performance epoch/neutrality changed.'}
            Guard $DeadlineUtc
        }
        $coverage=([datetimeoffset]$samples[-1].finalReceipt.timestampUtc).UtcDateTime-([datetimeoffset]$samples[0].finalReceipt.timestampUtc).UtcDateTime
        if($coverage.TotalMilliseconds -lt ($Plan.sampleCount-1)*$Plan.minimumArmIntervalMilliseconds){throw 'Actual acquisition coverage is shorter than the declared minimum arm span.'}
    }catch{$errors.Add($_.Exception.Message);if($previous){$previous.error=$_.Exception.Message}}
    finally{
        if($previous -and $previous.dispatchAttempted){
            if(-not $previous.requestId){$uncertain=$true;$errors.Add('Capture dispatched without qualified request ID; no replay or guessed cancellation.')}
            elseif(-not $previous.finalReceipt -or -not $previous.finalReceipt.terminal){
                try{
                    # Cancel only the known original request, then observe its
                    # settled final publication BEFORE calendar/session release.
                    $cancel=Command request_cancel;$cancel.requestId=$previous.requestId
                    $previous.cancelReply=& $Call communityshaders.screenshot $cancel $true $CleanupDeadlineUtc
                    do{
                        $query=Command request_get;$query.requestId=$previous.requestId
                        $reply=& $Call communityshaders.screenshot $query $false $CleanupDeadlineUtc
                        $previous.reads.Add([ordered]@{query=$query;receivedUtc=[datetime]::UtcNow.ToString('o');reply=$reply})
                        $previous.finalReceipt=QualifyRequest $reply $query $previous
                        if($previous.finalReceipt.terminal){break};Start-Sleep -Milliseconds 100
                    }while([datetime]::UtcNow -lt $CleanupDeadlineUtc)
                    if(-not $previous.finalReceipt.terminal){throw 'Owned still final publication remains nonterminal.'}
                }catch{$uncertain=$true;$errors.Add('Still cleanup: '+$_.Exception.Message)}
            }
        }
    }
    $acquisitions=@($samples|Where-Object {$_.finalReceipt -and $_.finalReceipt.requestSucceeded}|ForEach-Object {$_.finalReceipt.timestampUtc})
    $span=if($acquisitions.Count -gt 1){(([datetimeoffset]$acquisitions[-1]).UtcDateTime-([datetimeoffset]$acquisitions[0]).UtcDateTime).TotalMilliseconds}else{$null}
    return [pscustomobject]@{ok=($errors.Count -eq 0 -and $samples.Count -eq $Plan.sampleCount);indeterminate=$uncertain;clientId=$client;samples=@($samples);errors=@($errors);actualAcquisitionSpanMilliseconds=$span;requestedMinimumArmSpanMilliseconds=($Plan.sampleCount-1)*$Plan.minimumArmIntervalMilliseconds;uniformCadenceClaimed=$false;continuousSequenceClaimed=$false;quietnessClaimed=$false}
}
Export-ModuleMember -Function Assert-CalendarStereoStillPlan,Invoke-CalendarStereoStillSeries
