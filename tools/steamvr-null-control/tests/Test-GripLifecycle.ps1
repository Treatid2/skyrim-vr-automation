# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$BoundedProcessPath,[Parameter(Mandatory)][string]$BoundedProcessSha256,[string[]]$Case=@(),[ValidateRange(12,300)][int]$SessionBudgetSeconds=20,[ValidateRange(5,90)][int]$CleanupReserveSeconds=10)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'A new test evidence root is required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$entry=Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-NullHmdGripDiagnostic.ps1'
$pwsh=(Get-Process -Id $PID).Path
$cases=@('normal','semantic-mismatch','baseline-failure','startup-stall','assay-stall','cleanup-unknown','baseline-cleanup-unknown','publication-stall','binding-mismatch','close-unknown','abnormal-assay-exit','restore-drift','result-injected','result-instance','result-ceiling','close-errors','close-state','exit-unknown','owner-busy','deadline-active','pair-active','health-unknown','runtime-changed','close-clock-unknown','result-partial','restore-preview-rejected')
if($Case.Count -gt 0){foreach($selected in $Case){if($selected -notin $cases){throw 'Unknown fixed case selection'}};$cases=@($cases | Where-Object {$_ -in $Case})}
$checks=[Collections.Generic.List[object]]::new()
foreach($case in $cases){
    $root=Join-Path $EvidenceDirectory $case
    $raw=& $pwsh -NoProfile -File $entry -OfflineCase $case -EvidenceDirectory $root -BoundedProcessPath $BoundedProcessPath -BoundedProcessSha256 $BoundedProcessSha256 -SessionBudgetSeconds $SessionBudgetSeconds -CleanupReserveSeconds $CleanupReserveSeconds
    $exit=$LASTEXITCODE
    $coordinator=$raw | ConvertFrom-Json -AsHashtable -DateKind String
    $reportPath=Join-Path $root 'session-result.json'
    $report=if(Test-Path -LiteralPath $reportPath){Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String}else{$null}
    if(-not $coordinator.deadlineSatisfied){throw "Common deadline failed: $case"}
    foreach($stage in $coordinator.stages){if([uint64]$stage.ceilingTickMs -gt [uint64]$coordinator.commonDeadlineTickMs){throw 'A stage renewed the common deadline'}}
    $child=Get-Content -LiteralPath (Join-Path $root 'fixture-child.json') -Raw | ConvertFrom-Json -AsHashtable
    $live=Get-Process -Id ([int]$child.id) -ErrorAction SilentlyContinue
    if($null -ne $live -and $live.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -ceq $child.creationFileTime){throw "Owned child survived: $case"}
    $startup=Get-Content -LiteralPath (Join-Path $root 'startup-child-custody.json') -Raw | ConvertFrom-Json -AsHashtable
    if(-not $startup.launcherExited -or -not $startup.childAliveAfterLauncherExit){throw 'Persistent child custody was not exercised'}
    switch($case){
        normal {
            if($exit -ne 0 -or $null -ne $report.firstFailure -or -not $report.cleanHandoffVerified){throw 'Normal path did not verify clean injected handoff'}
            $boundary=$report.session.probeBoundary
            if($boundary.scope -cne 'after-shutdown-return-and-worker-exit' -or $boundary.externalUnregistrationVerified -or $boundary.launchAndInitInterval.exactTicksKnown -or [uint64]$boundary.workerExitObservation.upperTickMs -gt [uint64]$boundary.probeInvocation.lowerTickMs -or [uint64]$boundary.shutdownEnd.tickMs -gt [uint64]$boundary.workerExitObservation.upperTickMs){throw 'Observation boundary is missing, reordered, or stronger than recorded evidence'}
            $aProcess=Get-Content -LiteralPath (Join-Path $root 'assay-A-process.json') -Raw | ConvertFrom-Json -AsHashtable
            if(-not $aProcess.attempts[0].jobQuiescent -or -not $aProcess.attempts[0].exitVerified -or $aProcess.attempts[0].terminationRequested){throw 'Real nested A worker exit was not exercised'}
            $restores=@(Get-ChildItem -LiteralPath $root -Filter 'nullControl-restore-*.json' -File | ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable})
            if(@($restores | Where-Object state -eq 'fixture-restore-preview').Count -ne 1 -or @($restores | Where-Object state -eq 'restored').Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $root 'fixture-restore-count.txt')) -cne '1'){throw 'Normal recovery did not exercise nonmutating preview then exactly one restore'}
        }
        'semantic-mismatch' {if($null -ne $report.firstFailure -or $report.session.semanticMismatches.Count -ne 1 -or $report.productAcceptancePassed){throw 'Semantic mismatch was lost or promoted to product PASS'}}
        'baseline-failure' {if($report.firstFailure.phase -cne 'assay-A' -or -not $report.cleanHandoffVerified -or (Test-Path -LiteralPath (Join-Path $root 'injected-assay-B.json'))){throw 'Baseline failure did not stop later dispatch'}}
        {$_ -in @('startup-stall','assay-stall')} {
            $active=@($coordinator.stages | Where-Object stage -eq 'session')[0]
            if(-not $active.receipt.attempts[-1].terminationRequested -or -not $active.receipt.attempts[-1].jobQuiescent -or -not $report.cleanHandoffVerified -or $null -eq $report.firstFailure){throw 'Actual session cancellation/recovery was not verified'}
        }
        'cleanup-unknown' {if($exit -ne 2 -or $report.cleanHandoffVerified -or $null -eq $report.recoveryErrors){throw 'Unknown cleanup became verified'}}
        'baseline-cleanup-unknown' {if($report.firstFailure.phase -cne 'assay-A' -or $report.cleanHandoffVerified -or $null -eq $report.recoveryErrors){throw 'Cleanup replaced the primary baseline failure'}}
        'publication-stall' {
            $publication=@($coordinator.stages | Where-Object stage -eq 'publication')[0]
            if($exit -ne 2 -or $coordinator.published -or $null -ne $report -or -not $publication.receipt.attempts[-1].terminationRequested -or -not $publication.receipt.attempts[-1].jobQuiescent){throw 'Stalled publication escaped cancellation or published a result'}
        }
        'binding-mismatch' {if($report.firstFailure.phase -cne 'controllerControl-inspect' -or (Test-Path -LiteralPath (Join-Path $root 'injected-assay-A.json'))){throw 'Wrong PID binding admitted positive dispatch'}}
        'close-unknown' {if($report.firstFailure.phase -cne 'assay-A' -or (Test-Path -LiteralPath (Join-Path $root 'injected-assay-B.json')) -or [IO.File]::ReadAllText((Join-Path $root 'fixture-neutral-count.txt')) -cne '1'){throw 'Unknown A close admitted the after-close probe'}}
        'abnormal-assay-exit' {
            if($null -eq $report.firstFailure -or -not $report.cleanHandoffVerified -or (Test-Path -LiteralPath (Join-Path $root 'injected-assay-B.json'))){throw 'Abnormal assay exit lost failure or recovery'}
            $aProcess=Get-Content -LiteralPath (Join-Path $root 'assay-A-process.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            if($aProcess.attempts[0].exitCode -ne 17 -or -not $aProcess.attempts[0].jobQuiescent -or -not $aProcess.attempts[0].exitVerified -or $report.firstFailure.reason -notlike 'Native A diagnostic exited with code 17; owned exit/quiescence verified;*'){throw 'Native diagnostic failure was mislabeled as custody failure'}
        }
        'restore-drift' {if($exit -ne 2 -or $report.cleanHandoffVerified -or $null -eq $report.recoveryErrors){throw 'A restoration acknowledgement hid hash drift'}}
        'restore-preview-rejected' {
            if($exit -ne 2 -or $report.cleanHandoffVerified -or $null -eq $report.recoveryErrors -or [IO.File]::ReadAllText((Join-Path $root 'fixture-settings.txt')) -cne 'applied-fixture-settings' -or (Test-Path -LiteralPath (Join-Path $root 'fixture-restore-count.txt'))){throw 'Rejected preview mutated applied fixture state or dispatched restore'}
        }
        {$_ -in @('result-injected','result-instance','result-ceiling','close-errors','close-state','exit-unknown','owner-busy','deadline-active','pair-active','health-unknown','runtime-changed','close-clock-unknown','result-partial')} {
            if($null -eq $report.firstFailure -or -not $report.cleanHandoffVerified -or (Test-Path -LiteralPath (Join-Path $root 'injected-assay-B.json')) -or (Test-Path -LiteralPath (Join-Path $root 'after-close-probe-boundary.json')) -or [IO.File]::ReadAllText((Join-Path $root 'fixture-neutral-count.txt')) -cne '1'){throw "Invalid boundary admitted the after-close probe: $case"}
        }
    }
    if($null -ne $report -and $report.cleanHandoffVerified -and [IO.File]::ReadAllText((Join-Path $root 'fixture-settings.txt')) -cne 'original-fixture-settings'){throw 'Fixture baseline payload is not restored'}
    if($null -ne $report -and -not $report.cleanHandoffVerified -and $exit -ne 2){throw 'Unknown handoff did not return a blocked exit'}
    $checks.Add(@{case=$case;ok=$true;exitCode=$exit;childPid=$child.id;childClosed=$true;deadlineSatisfied=$coordinator.deadlineSatisfied;resultPath=if($null -ne $report){$reportPath}else{$null};runtimeResponsesSimulated=$true})
}
$receipt=@{ok=$true;cases=$checks.ToArray();count=$checks.Count;sessionBudgetSeconds=$SessionBudgetSeconds;cleanupReserveSeconds=$CleanupReserveSeconds;scope='Actual task-specific entry point and owned cancellation; injected runtime responses';liveQualified=$false}
$path=Join-Path $EvidenceDirectory 'test-receipt.json'
[IO.File]::WriteAllText($path,($receipt | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
@{ok=$true;count=$checks.Count;receipt=$path;liveQualified=$false} | ConvertTo-Json -Compress
