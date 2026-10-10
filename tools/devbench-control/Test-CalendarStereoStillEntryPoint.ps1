# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[string]$PythonEntry=$env:CODEX_PYTHON,[string[]]$Modes=@('healthy','prehold-advance','held-drift-hour','held-drift-days','held-drift-date','held-drift-engine','captured-drift','held-lease-id','held-expiry','captured-missing','captured-type','schema-missing','compiler','nonneutral','epoch-drift','after-compiler','bad-hash','wrong-command','wrong-path','missing-eye','stale-frame','timeout','cancel-failed','lost-acceptance','cell-drift','release-failed','plan-extra','plan-string-count','plan-foreign-build','plan-foreign-cell','plan-budget'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$checks=0;$caseResults=@()
function Check([bool]$Good,[string]$Message){if(-not $Good){throw $Message};$script:checks++}
$root=Join-Path $FixtureRoot ('stills-entry-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root|Out-Null
$python=(& $PythonEntry -c 'import sys;print(sys.executable)').Trim()
foreach($mode in $Modes){
    $dir=Join-Path $root $mode;New-Item -ItemType Directory -Path $dir|Out-Null
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$python;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($arg in @('-B',(Join-Path $PSScriptRoot 'fixtures/calendar_stills_mcp_server.py'),$dir,(Join-Path $PSScriptRoot 'fixtures'),$mode)){$start.ArgumentList.Add($arg)}
    $worker=[Diagnostics.Process]::Start($start)
    try{
        $runtime=Join-Path $dir 'runtime.json';$ready=[datetime]::UtcNow.AddSeconds(5)
        while(-not(Test-Path $runtime) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $ready){Start-Sleep -Milliseconds 50}
        Check (Test-Path $runtime) "$mode fixture failed to start"
        $plan=@{schemaVersion=1;expectedBuildId=('a'*64);expectedCellFormId=7;outputDirectory=$dir;sampleCount=2;minimumArmIntervalMilliseconds=250;requestTimeoutMilliseconds=1000}
        if($mode -ceq 'plan-extra'){$plan.genericCallback='not-admitted'}
        if($mode -ceq 'plan-string-count'){$plan.sampleCount='2'}
        if($mode -ceq 'plan-foreign-build'){$plan.expectedBuildId='c'*64}
        if($mode -ceq 'plan-foreign-cell'){$plan.expectedCellFormId=8}
        if($mode -ceq 'plan-budget'){$plan.sampleCount=16;$plan.minimumArmIntervalMilliseconds=10000}
        $response=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') calendar-still-window -StillSeriesPlanJson ($plan|ConvertTo-Json -Compress) -CalendarOwner fixture-stills -CalendarHoldMilliseconds 30000 -RuntimePath $runtime -ArtifactPath (Join-Path $PSScriptRoot 'fixtures/calendar_stills_mcp_server.py') -ExpectedBuildId ('a'*64) -MaxTransientRetries 0 -TimeoutSeconds 30 -EvidenceDirectory $dir -Compact -NoExit|ConvertFrom-Json -Depth 100
        [IO.File]::WriteAllText((Join-Path $dir 'response.json'),($response|ConvertTo-Json -Depth 100))
        Check ($response.ok -eq ($mode -cin @('healthy','prehold-advance'))) "$mode wrong outcome: $($response.errors -join '; ')"
        $eventPath=Join-Path $dir 'events.json';$events=if(Test-Path $eventPath){@(Get-Content $eventPath -Raw|ConvertFrom-Json -Depth 50)}else{@()}
        $preDispatch=$mode -cin @('plan-extra','plan-string-count')
        Check (@($events|Where-Object method -CEQ initialize).Count -eq $(if($preDispatch){0}else{1})) "$mode reinitialized session"
        if(-not $preDispatch){Check ($events[-1].method -ceq 'DELETE' -and $response.sessionCleanup.ok) "$mode closure order/unverified session cleanup"}
        Check (@($events|Where-Object {$_.method -ceq 'tools/call' -and $_.session -cne 'stills-fixture'}).Count -eq 0) "$mode changed session"
        $holds=@($events|Where-Object {$_.method -ceq 'tools/call' -and $_.arguments.name -ceq 'calendar' -and $_.arguments.arguments.action -ceq 'hold'})
        $releases=@($events|Where-Object {$_.method -ceq 'tools/call' -and $_.arguments.name -ceq 'calendar' -and $_.arguments.arguments.action -ceq 'release'})
        $noHold=$mode -cin @('schema-missing','plan-extra','plan-string-count','plan-foreign-build','plan-foreign-cell','plan-budget')
        Check ($holds.Count -eq $(if($noHold){0}else{1}) -and $releases.Count -eq $holds.Count) "$mode missing/replayed exact hold/release"
        $captures=@($events|Where-Object {$_.method -ceq 'tools/call' -and $_.arguments.name -ceq 'communityshaders.screenshot' -and $_.arguments.arguments.action -ceq 'capture'})
        $cancels=@($events|Where-Object {$_.method -ceq 'tools/call' -and $_.arguments.name -ceq 'communityshaders.screenshot' -and $_.arguments.arguments.action -ceq 'request_cancel'})
        Check ($captures.Count -le 2 -and $cancels.Count -le 1) "$mode replayed capture/cancel"
        if($mode -cin @('schema-missing','compiler','nonneutral') -or $mode.StartsWith('plan-')){Check ($captures.Count -eq 0) "$mode dispatched without admission"}
        if($mode.StartsWith('held-') -or $mode.StartsWith('captured-')){Check ($captures.Count -eq 0 -and $cancels.Count -eq 0) "$mode dispatched despite held-baseline refusal"}
        if(-not $noHold){
            Check ($response.data.restorationVerified -eq ($mode -cne 'release-failed')) "$mode incorrect calendar restoration"
            Check ($response.data.indeterminate -eq ($mode -cin @('lost-acceptance','cancel-failed','release-failed','wrong-command'))) "$mode incorrect uncertainty"
            Check ($releases[0].arguments.arguments.leaseId -ceq 'stills-lease' -and $releases[0].arguments.arguments.owner -ceq $holds[0].arguments.arguments.owner) "$mode foreign calendar release"
        }
        if($mode -cin @('timeout','cancel-failed','cell-drift')){Check ($cancels.Count -eq 1 -and $captures.Count -eq 1 -and $cancels[0].arguments.arguments.requestId -ceq 'owned-1') "$mode did not finalize original known request"}
        if($mode -ceq 'lost-acceptance'){Check ($captures.Count -eq 1 -and $cancels.Count -eq 0) 'lost acceptance replayed/guessed cancellation'}
        if($mode -cin @('healthy','prehold-advance')){
            Check ($response.data.measurement.samples.Count -eq 2 -and $response.data.measurement.actualAcquisitionSpanMilliseconds -gt 0) 'no actual finite coverage'
            foreach($sample in $response.data.measurement.samples){Check ($sample.publication.Count -eq 2 -and @($sample.publication|Where-Object {-not $_.verified}).Count -eq 0 -and $sample.finalReceipt.requestSucceeded) 'unverified stereo publication'}
            Check (-not $response.data.measurement.continuousSequenceClaimed -and -not $response.data.measurement.quietnessClaimed) 'invented sequence/scientific claim'
        }
        if($mode -ceq 'prehold-advance'){
            $calendarCalls=@($response.data.calls|Where-Object tool -ceq 'calendar')
            $before=$calendarCalls[0].data.content[0];$acquired=$calendarCalls[1].data.content[0]
            Check ($before.values.gameHour -ne $acquired.lease.captured.gameHour -and $before.values.daysPassed -ne $acquired.lease.captured.daysPassed) 'positive fixture did not advance before acquisition'
            Check ($response.data.heldBaseline.basis -ceq 'original-admitted-lease-captured' -and $response.data.heldBaseline.leaseId -ceq 'stills-lease' -and $response.data.heldBaseline.values.gameHour -eq $acquired.lease.captured.gameHour -and $response.data.heldBaseline.values.daysPassed -eq $acquired.lease.captured.daysPassed) 'held baseline did not pin original acquisition'
            Check ($captures.Count -eq 2 -and $response.data.restorationVerified -and -not $response.data.indeterminate) 'advancing prehold case did not complete original captures/restoration'
        }
        $caseResults+=@{mode=$mode;ok=$response.ok;captures=$captures.Count;cancels=$cancels.Count;holds=$holds.Count;releases=$releases.Count;restorationVerified=$(if($null -ne $response.data -and $response.data.PSObject.Properties['restorationVerified']){$response.data.restorationVerified}else{$null});sessionClosed=$(if($response.PSObject.Properties['sessionCleanup'] -and $null -ne $response.sessionCleanup){$response.sessionCleanup.ok}else{$null});errors=@($response.errors)}
    }finally{if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit(5000)|Out-Null};$worker.Dispose()}
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$Modes.Count;caseResults=$caseResults;root=$root;nativeLiveQualification=$false}|ConvertTo-Json -Depth 12 -Compress
