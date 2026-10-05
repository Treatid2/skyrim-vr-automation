# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ScreenshotSequenceEvidence.psm1') -Force
$script:checks=0
function Check([bool]$Good,[string]$Message) { $script:checks++; if (-not $Good) { throw $Message } }
function Obj($Value) { return $Value|ConvertTo-Json -Depth 80|ConvertFrom-Json -Depth 80 -DateKind String }
function Change($Value,[string]$Path,$Replacement) { $names=$Path.Split('.');$node=$Value;for($i=0;$i -lt $names.Count-1;$i++){$node=$node.($names[$i])};$node.($names[-1])=$Replacement }
$build='a'*64; $service='service-fixture'; $destination='C:\fixture\pr51'; $directory=$destination+'\CS_sequence_parent-owned'
$capture=Obj @{source=@{kind='hmd_submission';fallback='reject'};outputs=@(@{view='left_eye';encoding=@{format='png';colourContract='sdr_srgb'}},@{view='right_eye';encoding=@{format='png';colourContract='sdr_srgb'}});destination=@{policy='absolute';directory=$destination;baseName='frame';overwrite='never'};clipboard='none'}
$startArgs=@{action='sequence_start';clientId='pr51-owner';commandId='start-once';contractMajor=1;expectedBuildId=$build;sequence=@{frameCount=3;useSettings=$false;capture=$capture;schedule=@{basis='wall_clock';intervalMs=500;startDelayMs=0;pausePolicy='hold'};backpressure=@{policy='abort';maximumConsecutiveSkips=1};failurePolicy='abort';packaging=@{frameManifest=$true;previewVideo=@{requested=$false;required=$false}}}}
function Envelope($CommandArgs,$Receipt) { return Obj @{contract=@{name='csx.screenshot';major=1;minor=1;schemaRevision=2};command=@{action=$CommandArgs.action;clientId=$CommandArgs.clientId;commandId=$CommandArgs.commandId};server=@{component='CommunityShaders';buildId=$build;serviceSessionId=$service};timestampUtc='2026-10-05T20:00:05Z';ok=$true;result=$Receipt} }
$base=Obj @{requestId='parent-owned';kind='sequence';state='preparing';clientId='pr51-owner';commandId='start-once';acceptedUtc='2026-10-05T20:00:01Z';terminalUtc=$null;requested=$startArgs;effective=$startArgs.sequence;actual=@{};artifacts=@();warnings=@();errors=@();error=$null;acknowledged=$false;publication=@{state='settled';artifactCommitted=$null};artifactProgress=@{expected=1;terminal=0;successful=0};counts=@{requested=3;scheduled=0;acquired=0;written=0;dropped=0;failed=0;cancelled=0;inFlight=0};manifest=@{partialPath=$null;finalPath=$null};packaging=@{frameManifest=@{requested=$true;state='pending'};previewVideo=@{requested=$false;required=$false;state='not_requested'}};termination=@{stopRequested=$false;cancelRequested=$false;policyAbortRequested=$false;policyAbortCode=$null;preparationPending=$true;finalizationCommitted=$false;committedOutcome=$null}}
$start=Envelope $startArgs $base
function ParentRead($Payload,$CommandArgs,$Owner=$null) { return Get-DevBenchScreenshotSequenceEvidence -Payload $Payload -Arguments $CommandArgs -ExpectedBuildId $build -ExpectedServiceSessionId $service -DestinationDirectory $destination -AcceptedOwner $Owner }
$rawBefore=$start|ConvertTo-Json -Depth 80 -Compress
$accepted=ParentRead $start $startArgs
Check $accepted.ok ($accepted.errors -join '; ')
Check (-not $accepted.terminal -and -not $accepted.requestSucceeded) 'preparing is admission, not completion'
Check (($start|ConvertTo-Json -Depth 80 -Compress) -ceq $rawBefore) 'raw start unchanged'
$query=@{action='request_get';clientId='pr51-owner';commandId='read-once';contractMajor=1;requestId='parent-owned';expectedBuildId=$build}
$running=Obj $base; $running.state='running';$running.termination.preparationPending=$false;$running.manifest.partialPath=$directory+'\sequence.json.partial'
$runningRead=ParentRead (Envelope $query $running) $query $accepted
Check $runningRead.ok ($runningRead.errors -join '; ')
Check (-not $runningRead.requestSucceeded) 'running is read success, not capture success'
$frames=@();$children=@()
for ($ordinal=1;$ordinal -le 3;$ordinal++) {
    $effective=Obj $capture;$effective.destination.directory=$directory;$effective.destination|Add-Member resolvedDirectory $directory;$effective.destination.baseName="frame_$ordinal"
    $frame=Obj @{requestId="frame-id-$ordinal";kind='sequence_frame';state='completed';clientId='sequence:parent-owned';commandId="frame:$ordinal";parentRequestId='parent-owned';sequenceOrdinal=$ordinal;acceptedUtc='2026-10-05T20:00:02Z';terminalUtc='2026-10-05T20:00:03Z';requested=@{action='capture';clientId='sequence:parent-owned';commandId="frame:$ordinal";contractMajor=1};effective=$effective;actual=@{acquisition=@{engineFrame=100+$ordinal;compositorCycle=200+$ordinal;monotonicTimestampUs=1000+$ordinal;sourceKind='hmd_submission';utcTimestamp='2026-10-05T20:00:02.5Z';planes=@(@{eye='left'},@{eye='right'});schedule=@{basis='wall_clock';requestedEngineFrame=100+$ordinal;requestedMonotonicTimestampUs=1000+$ordinal;requestedUtc='2026-10-05T20:00:02Z';latenessFrames=0;latenessUs=0}}};artifacts=@(@{path="$directory\frame_${ordinal}_left.png";bytes=100;sha256=('b'*64);committed=$true;actual=@{view='left_eye';format='png';colourContract='sdr_srgb';width=64;height=64}},@{path="$directory\frame_${ordinal}_right.png";bytes=100;sha256=('c'*64);committed=$true;actual=@{view='right_eye';format='png';colourContract='sdr_srgb';width=64;height=64}});warnings=@();errors=@();error=$null;acknowledged=$false;publication=@{state='settled';artifactCommitted=$null};artifactProgress=@{expected=2;terminal=2;successful=2}}
    $frame.actual.acquisition.planes=@(foreach ($eye in @('left','right')) { Obj @{eye=$eye;boundsApplied=$true;colourSpace=1;deviceIdentity='0xfixture';dxgiFormat=28;orientation=@{flipHorizontal=$false;flipVertical=$false};publicationGeneration=4;sourceHeight=64;sourceWidth=128;stagedHeight=64;stagedWidth=64;submittedBounds=@{uMin=0;uMax=1;vMin=0;vMax=1};tonemapSceneHdr=$false} })
    $frameCommand=@{action='request_get';clientId='pr51-owner';commandId="read-frame-$ordinal";contractMajor=1;requestId=$frame.requestId;expectedBuildId=$build}
    $payload=Envelope $frameCommand $frame
    $qualified=Get-DevBenchScreenshotSequenceFrameEvidence -Payload $payload -Arguments $frameCommand -ParentEvidence $accepted
    Check $qualified.ok ($qualified.errors -join '; ')
    Check ($qualified.requestSucceeded -and $qualified.receipt.engineFrame -eq (100+$ordinal) -and $qualified.receipt.artifacts[0].view -ceq 'left_eye') 'typed frame/acquisition projection'
    $frames+=$qualified
    $children+=Obj @{ordinal=$ordinal;requestId=$frame.requestId;state=$frame.state;scheduledEngineFrame=100+$ordinal;scheduledTimestampUs=1000+$ordinal;requested=$frame.requested;effective=$frame.effective;actual=$frame.actual;artifacts=$frame.artifacts;warnings=$frame.warnings;errors=$frame.errors;error=$frame.error}
}
$done=Obj $running;$done.state='completed';$done.terminalUtc='2026-10-05T20:00:04Z';$done.counts.scheduled=3;$done.counts.acquired=3;$done.counts.written=3;$done.termination.finalizationCommitted=$true;$done.termination.committedOutcome='completed';$done.packaging.frameManifest.state='written';$done.packaging.frameManifest|Add-Member path ($directory+'\sequence.json');$done.manifest.finalPath=$directory+'\sequence.json';$done.artifactProgress.terminal=1;$done.artifactProgress.successful=1
$manifest=Obj @{contract=$start.contract;producer=@{component='CommunityShaders';buildId=$build};sessionId=$service;requestId='parent-owned';state='final';terminalOutcome='completed';client=@{clientId='pr51-owner';commandId='start-once'};acceptedUtc=$base.acceptedUtc;completedUtc='2026-10-05T20:00:03.5Z';requested=$startArgs.sequence;effective=$frames[0].raw.result.effective;actual=@{children=3;fallbacksPresent=$false};counts=$done.counts;warnings=@();errors=@();packaging=$done.packaging;updatedUtc='2026-10-05T20:00:03.5Z';children=$children}
function Bytes($Value) { return ,[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 80 -Compress)) }
$manifest.effective=Obj $capture
$manifest.effective.destination|Add-Member resolvedDirectory $destination
$bytes=Bytes $manifest
$done.artifacts=@(Obj @{path=$done.manifest.finalPath;bytes=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();committed=$true})
$donePayload=Envelope $query $done;$doneRead=ParentRead $donePayload $query $accepted
Check $doneRead.ok ($doneRead.errors -join '; ')
Check $doneRead.requestSucceeded 'all declared native parent frames complete'
$qualifiedManifest=Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes $bytes -ManifestPath $done.manifest.finalPath -ParentEvidence $doneRead -FrameEvidence $frames
Check $qualifiedManifest.ok ($qualifiedManifest.errors -join '; ')
Check ($qualifiedManifest.requestSucceeded -and $qualifiedManifest.frames.Count -eq 3 -and $qualifiedManifest.terminalProof) 'exact hashed final manifest and three independently owned frames'
foreach ($badField in @(@('ok','true'),@('ok',$false),@('contract.minor',0),@('contract.schemaRevision',1),@('command.commandId','foreign'),@('server.buildId',('d'*64)),@('server.serviceSessionId','foreign'),@('result.clientId','foreign'),@('result.commandId','foreign'),@('result.requestId','foreign'),@('result.counts.inFlight',1),@('result.counts.requested','3'),@('result.counts.written',2),@('result.publication.state','unresolved'),@('result.termination.finalizationCommitted',$false),@('result.manifest.finalPath','C:\outside\sequence.json'),@('result.packaging.frameManifest.state','pending'),@('result.terminalUtc',$null))) {
    $bad=Obj $donePayload;Change $bad $badField[0] $badField[1]
    Check (-not (ParentRead $bad $query $accepted).ok) "refuse parent $($badField[0])"
}
Check (-not (ParentRead $donePayload $query).ok) 'request read cannot adopt owner'
$cancelArgs=@{action='request_cancel';clientId='pr51-owner';commandId='cancel-once';contractMajor=1;requestId='parent-owned';expectedBuildId=$build}
$cancel=Obj $running;$cancel.state='cancel_requested';$cancel.termination.cancelRequested=$true;$cancel|Add-Member commandAccepted $true
$cancelRead=ParentRead (Envelope $cancelArgs $cancel) $cancelArgs $accepted
Check ($cancelRead.ok -and $cancelRead.commandAccepted -and -not $cancelRead.cancelCoverage) 'accepted cancellation is not terminal cancellation'
$late=Obj $done;$late|Add-Member commandAccepted $false
$lateRead=ParentRead (Envelope $cancelArgs $late) $cancelArgs $accepted
Check ($lateRead.ok -and -not $lateRead.commandAccepted -and -not $lateRead.cancelCoverage) 'late cancellation does not claim race coverage'
$already=Obj $done;foreach($name in @('counts','manifest','packaging','termination')){$already.PSObject.Properties.Remove($name)};$already|Add-Member alreadyTerminal $true
$alreadyRead=ParentRead (Envelope $cancelArgs $already) $cancelArgs $accepted
Check ($alreadyRead.ok -and $alreadyRead.terminal -and -not $alreadyRead.commandAccepted -and -not $alreadyRead.requestSucceeded -and -not $alreadyRead.cancelCoverage) 'base already-terminal receipt is command observation only'
$bypass=Obj $done;$bypass|Add-Member alreadyTerminal $true;$bypass.counts.inFlight=1
Check (-not (ParentRead (Envelope $cancelArgs $bypass) $cancelArgs $accepted).ok) 'alreadyTerminal cannot bypass malformed extended sequence state'
$terminalCancel=Obj $base;$terminalCancel.state='cancelled';$terminalCancel.terminalUtc='2026-10-05T20:00:04Z';$terminalCancel.termination.cancelRequested=$true;$terminalCancel.termination.preparationPending=$false;$terminalCancel.termination.finalizationCommitted=$true;$terminalCancel.packaging.frameManifest.state='cancelled';$terminalCancel.packaging.frameManifest|Add-Member path $null;$terminalCancel.packaging.frameManifest|Add-Member error '';$terminalCancel.error=Obj @{code='preparation_cancelled';message='queued destination preparation was cancelled';phase='preparation'};$terminalCancel.errors=@($terminalCancel.error);$terminalCancel.artifactProgress.terminal=1
$cancelledRead=ParentRead (Envelope $query $terminalCancel) $query $accepted
Check ($cancelledRead.ok -and $cancelledRead.terminal -and -not $cancelledRead.requestSucceeded) 'typed cancelled preparation retained as unsuccessful terminal read'
$storage=Obj $terminalCancel;$storage.state='failed';$storage.termination.cancelRequested=$false;$storage.packaging.frameManifest.state='failed';$storage.error.code='destination_preparation_failed';$storage.error.message='isolated worker fixture';$storage.error.phase='preparation';$storage.errors=@($storage.error)
$storageRead=ParentRead (Envelope $query $storage) $query $accepted
Check ($storageRead.ok -and $storageRead.terminal -and -not $storageRead.requestSucceeded -and $storageRead.raw.result.errors[0].code -ceq 'destination_preparation_failed') 'safe fixture shape is read-qualified, not runtime worker evidence'
$emptyStorage=Obj $storage;$emptyStorage.manifest.partialPath=''
$emptyRead=ParentRead (Envelope $query $emptyStorage) $query $accepted
Check ($emptyRead.ok -and $emptyRead.raw.result.manifest.partialPath -is [string] -and $emptyRead.raw.result.manifest.partialPath -ceq '' -and -not $emptyRead.requestSucceeded) 'native empty uncreated partial path retained in exact zero-output preparation failure'
foreach($defect in @('state','code','phase','packaging','scheduled','partialType','final')) {
    $bad=Obj $emptyStorage
    switch($defect){state{$bad.state='cancelled'};code{$bad.error.code='other'};phase{$bad.error.phase='packaging'};packaging{$bad.packaging.frameManifest.state='cancelled'};scheduled{$bad.counts.scheduled=1};partialType{$bad.manifest.partialPath=0};final{$bad.manifest.finalPath=$directory+'\sequence.json'}}
    Check (-not (ParentRead (Envelope $query $bad) $query $accepted).ok) "empty partial path cannot escape $defect guard"
}
$storage|Add-Member errorOutside 'query failed'
Check (-not (ParentRead (Envelope $query $storage) $query $accepted).ok) 'unknown extra failure field is not masked'
$frameArgs=@{action='request_get';clientId='pr51-owner';commandId='read-frame-1';contractMajor=1;requestId='frame-id-1';expectedBuildId=$build}
foreach($foreignDirectory in @($destination,($destination+'\CS_sequence_foreign'))){
    $bad=Obj $frames[0].raw;$bad.result.effective.destination.directory=$foreignDirectory
    Check (-not (Get-DevBenchScreenshotSequenceFrameEvidence -Payload $bad -Arguments $frameArgs -ParentEvidence $accepted).ok) 'only exact generated request leaf admits frame directory'
}
foreach ($defect in @(@('server.serviceSessionId','foreign'),@('result.parentRequestId','foreign'),@('result.clientId','pr51-owner'),@('result.commandId','frame:2'),@('result.sequenceOrdinal',4),@('result.actual.acquisition.engineFrame','101'),@('result.artifactProgress.expected',1),@('result.publication.state','unresolved'))) {
    $bad=Obj $frames[0].raw;Change $bad $defect[0] $defect[1]
    Check (-not (Get-DevBenchScreenshotSequenceFrameEvidence -Payload $bad -Arguments $frameArgs -ParentEvidence $accepted).ok) "refuse frame $($defect[0])"
}
foreach ($defect in @(@('sessionId','foreign'),@('requestId','foreign'),@('client.commandId','foreign'),@('terminalOutcome','cancelled'),@('actual.children',2))) {
    $bad=Obj $manifest;Change $bad $defect[0] $defect[1]
    Check (-not (Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes (Bytes $bad) -ManifestPath $done.manifest.finalPath -ParentEvidence $doneRead -FrameEvidence $frames).ok) "refuse manifest $($defect[0])"
}
$partial=Obj $manifest;$partial.state='partial';$partial.terminalOutcome=$null;$partial.completedUtc=$null;$partial.packaging.frameManifest.state='partial';$partial.packaging.frameManifest.path=$running.manifest.partialPath
$partialParent=Obj $done;$partialParent.state='running';$partialParent.terminalUtc=$null;$partialParent.termination.finalizationCommitted=$false;$partialParent.termination.committedOutcome=$null;$partialParent.manifest.finalPath=$null;$partialParent.packaging.frameManifest.state='partial';$partialParent.packaging.frameManifest.path=$running.manifest.partialPath;$partialParent.artifacts=@();$partialParent.artifactProgress.terminal=0;$partialParent.artifactProgress.successful=0
$partialRead=ParentRead (Envelope $query $partialParent) $query $accepted
Check $partialRead.ok ($partialRead.errors -join '; ')
$partialProof=Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes (Bytes $partial) -ManifestPath $running.manifest.partialPath -ParentEvidence $partialRead -FrameEvidence $frames
Check ($partialProof.ok -and -not $partialProof.terminalProof -and -not $partialProof.requestSucceeded -and $partialProof.frames.Count -eq 3) ($partialProof.errors -join '; ')
Check (($start|ConvertTo-Json -Depth 80 -Compress) -ceq $rawBefore) 'all operations leave original raw start unchanged'
foreach ($defect in @('outerError','unknownWarning','scalarError','nestedError','artifactHash','uncommitted','badPlaneEye','badPlaneBounds','planeType','missingOwner','foreignOwner','sourceFallback','frameRecipe','unknownState','ambiguousPublication')) {
    $bad=Obj $frames[0].raw;$parent=Obj $accepted
    switch ($defect) {
        outerError {$bad|Add-Member error 'failed query'}
        unknownWarning {$bad.result.warnings=@(Obj @{code='unknown';message='not source-bound'})}
        scalarError {$bad.result.error='failed'}
        nestedError {$bad.result.actual|Add-Member error 'failure'}
        artifactHash {$bad.result.artifacts[0].sha256='bad'}
        uncommitted {$bad.result.artifacts[0].committed=$false}
        badPlaneEye {$bad.result.actual.acquisition.planes[1].eye='left'}
        badPlaneBounds {$bad.result.actual.acquisition.planes[0].submittedBounds.uMax='1'}
        planeType {$bad.result.actual.acquisition.planes[0].publicationGeneration='4'}
        missingOwner {$parent.ok=$false}
        foreignOwner {$parent.owner.serviceSessionId='foreign'}
        sourceFallback {$bad.result.effective.source.fallback='desktop_mirror'}
        frameRecipe {$bad.result.effective.outputs[0].encoding.format='bmp'}
        unknownState {$bad.result.state='staging'}
        ambiguousPublication {$bad.result.publication.artifactCommitted=$true}
    }
    Check (-not (Get-DevBenchScreenshotSequenceFrameEvidence -Payload $bad -Arguments $frameArgs -ParentEvidence $parent).ok) "refuse frame $defect"
}
foreach ($defect in @('duplicateChild','wrongChildState','wrongImageHash','foreignDirectory','generatedInsteadOfRequested','foreignResolvedParent','missingChild','oversizedImages','unknownManifestField','badPartialOutcome')) {
    $bad=Obj $manifest;$parent=Obj $doneRead;$ownedFrames=Obj $frames
    switch ($defect) {
        duplicateChild {$bad.children[1]=$bad.children[0]}
        wrongChildState {$bad.children[0].state='cancelled'}
        wrongImageHash {$bad.children[0].artifacts[0].sha256=('d'*64)}
        foreignDirectory {$bad.effective.destination.directory='C:\outside'}
        generatedInsteadOfRequested {$bad.effective.destination.directory=$directory}
        foreignResolvedParent {$bad.effective.destination.resolvedDirectory=$directory}
        missingChild {$bad.children=@($bad.children[0]);$bad.actual.children=1;$ownedFrames=@($ownedFrames[0])}
        oversizedImages {$bad.children[0].artifacts[0].bytes=134217728;$ownedFrames[0].raw.result.artifacts[0].bytes=134217728}
        unknownManifestField {$bad|Add-Member error 'foreign failure'}
        badPartialOutcome {$bad.state='partial';$bad.completedUtc=$null}
    }
    # Rebind content hash to avoid letting every structural negative stop at hash alone.
    $badBytes=Bytes $bad;$parent.receipt.artifacts[0].bytes=$badBytes.Length;$parent.receipt.artifacts[0].sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($badBytes)).ToLowerInvariant()
    Check (-not (Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes $badBytes -ManifestPath $done.manifest.finalPath -ParentEvidence $parent -FrameEvidence $ownedFrames).ok) "refuse manifest $defect"
}
$duplicateFrames=@($frames[0],$frames[0],$frames[2])
Check (-not (Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes $bytes -ManifestPath $done.manifest.finalPath -ParentEvidence $doneRead -FrameEvidence $duplicateFrames).ok) 'native frame identity must be unique and complete'
$tooLarge=[byte[]]::new(1048577)
Check (-not (Get-DevBenchScreenshotSequenceManifestEvidence -ManifestBytes $tooLarge -ManifestPath $done.manifest.finalPath -ParentEvidence $doneRead -FrameEvidence $frames).ok) 'bounded manifest parser refuses oversized input'
[pscustomobject]@{ok=$true;checks=$script:checks;scope='synthetic source217 schema2 normal/cancel/storage-shape/identity/manifest fixtures; no live handler or filesystem claims'}|ConvertTo-Json -Compress
