# SPDX-License-Identifier: GPL-3.0-or-later
# Offline, source-bound csx.screenshot 1.1/schema2 evidence qualification.
# No transport, filesystem writes, mutation, retry, scheduling or cleanup here.
Set-StrictMode -Version Latest
function Assert-SE($Condition,[string]$Message) { if ($Condition -isnot [bool] -or -not $Condition) { throw "Screenshot sequence evidence: $Message" } }
function Field-SE($Node,[string]$Name) { if ($Node -is [pscustomobject]) { $p=$Node.PSObject.Properties[$Name]; if ($p -and $p.Name -ceq $Name) { return ,$p.Value } }; return $null }
function UInt-SE($Value,[decimal]$Maximum=[uint64]::MaxValue,[decimal]$Minimum=0) { return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and [decimal]$Value -ge $Minimum -and [decimal]$Value -le $Maximum }
function Text-SE($Value) { return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) }
function Exact-SE($Value,[string]$Expected) { return $Value -is [string] -and $Value -ceq $Expected }
function Utc-SE($Value) {
    if ($Value -is [DateTime] -and $Value.Kind -eq [DateTimeKind]::Utc) { return [DateTimeOffset]$Value }
    Assert-SE ($Value -is [string] -and $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$') 'UTC timestamp must be explicit Z/UTC.'
    return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)
}
function Fields-SE($Value,[string[]]$Required,[string[]]$Optional=@()) {
    Assert-SE ($Value -is [pscustomobject]) 'structured object required.'
    foreach ($name in $Required) { Assert-SE ($null -ne $Value.PSObject.Properties[$name]) "missing $name." }
    foreach ($p in $Value.PSObject.Properties) { Assert-SE ($p.Name -cin @($Required+$Optional)) "unsupported field $($p.Name)." }
}
function Canonical-SE($Value,[int]$Depth=0) {
    Assert-SE ($Depth -le 40) 'comparison nesting bound exceeded.'
    if ($Value -is [pscustomobject]) { $out=[ordered]@{}; foreach ($p in @($Value.PSObject.Properties|Sort-Object Name)) { $out[$p.Name]=Canonical-SE $p.Value ($Depth+1) }; return [pscustomobject]$out }
    if ($Value -is [array]) { $out=@(foreach ($v in $Value) { Canonical-SE $v ($Depth+1) }); return ,$out }
    return ,$Value
}
function Equal-SE($Left,$Right) { return (Canonical-SE $Left|ConvertTo-Json -Depth 60 -Compress) -ceq (Canonical-SE $Right|ConvertTo-Json -Depth 60 -Compress) }
function Copy-SE($Value) { return $Value|ConvertTo-Json -Depth 80|ConvertFrom-Json -Depth 80 -DateKind String }
function Equal-FrameActual-SE($Left,$Right) {
    $a=Copy-SE $Left;$b=Copy-SE $Right
    # Retained PowerShell receipts may omit trailing zero fractional digits.
    # Only these native UTC fields compare by instant; all other fields stay exact.
    if($null -ne (Field-SE $a 'acquisition') -and $null -ne (Field-SE $b 'acquisition')){
        foreach($node in @($a,$b)){
            $node.acquisition.utcTimestamp=(Utc-SE $node.acquisition.utcTimestamp).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            $node.acquisition.schedule.requestedUtc=(Utc-SE $node.acquisition.schedule.requestedUtc).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        }
    }
    return Equal-SE $a $b
}
function Path-SE($Value,[string]$Root) {
    Assert-SE (Text-SE $Value) 'non-empty artifact path required.'
    Assert-SE ([IO.Path]::IsPathFullyQualified($Value) -and [IO.Path]::IsPathFullyQualified($Root)) 'absolute paths required.'
    $path=[IO.Path]::GetFullPath($Value); $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Assert-SE ($path.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) 'artifact outside explicitly owned destination.'
    return $path
}
function Contract-SE($Contract) {
    Fields-SE $Contract @('name','major','minor','schemaRevision')
    Assert-SE ((Exact-SE $Contract.name 'csx.screenshot') -and (UInt-SE $Contract.major 1 1) -and (UInt-SE $Contract.minor 1 1) -and (UInt-SE $Contract.schemaRevision 2 2)) 'only exact contract1.1/schema2 is supported.'
}
function SequenceDirectory-SE($Owner) {
    Assert-SE ($Owner.requestId -is [string] -and $Owner.requestId -cmatch '^[A-Za-z0-9-]+$') 'native safe request-directory suffix required.'
    Assert-SE ([IO.Path]::IsPathFullyQualified($Owner.destinationDirectory)) 'explicit absolute parent destination required.'
    return [IO.Path]::Combine([IO.Path]::GetFullPath($Owner.destinationDirectory),('CS_sequence_'+$Owner.requestId))
}
function Envelope-SE($Payload,[Collections.IDictionary]$Arguments,[string]$Build,[string]$Session) {
    Fields-SE $Payload @('contract','command','server','timestampUtc','ok','result')
    Contract-SE $Payload.contract
    Assert-SE ($Payload.ok -is [bool] -and $Payload.ok) 'outer query/action error is not historical request failure.'
    Fields-SE $Payload.command @('action','clientId','commandId')
    foreach ($name in @('action','clientId','commandId')) { Assert-SE ($Arguments.Contains($name) -and (Text-SE $Arguments[$name]) -and (Exact-SE $Payload.command.$name $Arguments[$name])) "exact query $name binding required." }
    Assert-SE ($Arguments.Contains('contractMajor') -and (UInt-SE $Arguments.contractMajor 1 1)) 'query contractMajor1 required.'
    Assert-SE ($Build -cmatch '^[a-f0-9]{64}$' -and (Text-SE $Session)) 'explicit admitted build/session required.'
    Assert-SE ((Exact-SE (Field-SE $Payload.server 'component') 'CommunityShaders') -and (Exact-SE (Field-SE $Payload.server 'buildId') $Build) -and (Exact-SE (Field-SE $Payload.server 'serviceSessionId') $Session)) 'foreign producer/build/service session.'
    if ($Arguments.Contains('expectedBuildId')) { Assert-SE (Exact-SE $Arguments.expectedBuildId $Build) 'native producer expectation must match admitted producer.' }
    return Utc-SE $Payload.timestampUtc
}
function Diagnostics-SE($Receipt,[string[]]$Phases,[bool]$AllowPolicyPending=$false) {
    Assert-SE ($Receipt.warnings -is [array] -and $Receipt.errors -is [array]) 'warning/error arrays required.'
    foreach ($warning in $Receipt.warnings) {
        if ((Field-SE $warning 'code') -ceq 'manifest_result_publication_retried') {
            Fields-SE $warning @('code','message','attempts'); Assert-SE (UInt-SE $warning.attempts ([uint32]::MaxValue) 1) 'publication retry attempts required.'
        } else { Fields-SE $warning @('code','message'); Assert-SE ($warning.code -cin @('source_fallback','artifact_hash_failed')) 'unknown warning code.' }
        Assert-SE (Text-SE $warning.message) 'typed warning message required.'
    }
    foreach ($errorItem in @($Receipt.errors)+@($Receipt.error)) { if ($null -ne $errorItem) {
        Fields-SE $errorItem @('code','message','phase') @('path')
        Assert-SE ((Text-SE $errorItem.code) -and (Text-SE $errorItem.message) -and $errorItem.phase -cin $Phases) 'unknown retained error shape/phase.'
        if ($errorItem.PSObject.Properties['path']) { Assert-SE ($null -eq $errorItem.path -or (Text-SE $errorItem.path)) 'error path/null required.' }
        Assert-SE ($Receipt.state -cnotin @('completed','completed_with_warnings') -and ($null -ne $Receipt.terminalUtc -or ($AllowPolicyPending -and $errorItem.phase -ceq 'sequence_policy'))) 'historical error contradicts request state.'
    } }
}
function BaseReceipt-SE($Receipt,$Observed) {
    foreach ($name in @('requestId','clientId','commandId')) { Assert-SE (Text-SE (Field-SE $Receipt $name)) "receipt $name required." }
    $terminalStates=@('completed','completed_with_warnings','failed','failed_partial','rejected','cancelled','cancelled_partial','stopped','dropped')
    $liveStates=@('accepted','preparing','waiting_source','queued','encoding','running','stop_requested','cancel_requested','finalizing')
    Assert-SE ($Receipt.state -is [string] -and $Receipt.state -cin @($terminalStates+$liveStates)) 'unsupported native state.'
    $terminal=$Receipt.state -cin $terminalStates; $accepted=Utc-SE $Receipt.acceptedUtc
    Assert-SE ($accepted -le $Observed) 'accepted time after observation.'
    if ($terminal) { $ended=Utc-SE $Receipt.terminalUtc; Assert-SE ($ended -ge $accepted -and $ended -le $Observed) 'terminal UTC chronology.' }
    else { Assert-SE ($null -eq $Receipt.terminalUtc) 'live request has terminal time.' }
    Fields-SE $Receipt.publication @('state','artifactCommitted')
    Assert-SE ((Exact-SE $Receipt.publication.state 'settled') -and $null -eq $Receipt.publication.artifactCommitted) 'unresolved publication cannot qualify.'
    Assert-SE ($Receipt.acknowledged -is [bool] -and $Receipt.artifacts -is [array]) 'acknowledgement/artifact types.'
    Fields-SE $Receipt.artifactProgress @('expected','terminal','successful')
    foreach ($p in $Receipt.artifactProgress.PSObject.Properties) { Assert-SE (UInt-SE $p.Value ([uint32]::MaxValue)) 'typed artifact progress required.' }
    Assert-SE ($Receipt.artifactProgress.successful -le $Receipt.artifactProgress.terminal -and $Receipt.artifactProgress.terminal -le $Receipt.artifactProgress.expected -and $Receipt.artifacts.Count -eq $Receipt.artifactProgress.successful) 'artifact progress contradiction.'
    return $terminal
}
function Capture-SE($Capture,[string]$Destination) {
    Fields-SE $Capture @('source','outputs','destination') @('clipboard','tags')
    Assert-SE ($Capture -is [pscustomobject] -and $Capture.outputs -is [array] -and $Capture.outputs.Count -eq 2) 'exact two-eye capture required.'
    Assert-SE ((Exact-SE (Field-SE $Capture.source 'kind') 'hmd_submission') -and (Exact-SE (Field-SE $Capture.source 'fallback') 'reject')) 'explicit HMD submission without fallback required.'
    Assert-SE ((Exact-SE (Field-SE $Capture.destination 'policy') 'absolute') -and (Exact-SE (Field-SE $Capture.destination 'overwrite') 'never') -and (Exact-SE (Field-SE $Capture.destination 'directory') $Destination)) 'exact explicit non-overwrite destination required.'
    $views=@(); foreach ($output in $Capture.outputs) {
        Fields-SE $output @('view','encoding') @('nameSuffix','dominantEye','width','height','crop')
        Fields-SE $output.encoding @('format','colourContract')
        Assert-SE ($output.view -is [string] -and $output.view -cin @('left_eye','right_eye') -and $output.view -cnotin $views) 'exact unique stereo views required.'
        $views+= $output.view
        Assert-SE ((Exact-SE (Field-SE $output.encoding 'format') 'png') -and (Exact-SE (Field-SE $output.encoding 'colourContract') 'sdr_srgb')) 'lossless PNG/sdr_srgb outputs required.'
    }
}
function Artifacts-SE($Artifacts,[string]$Root,[bool]$Images) {
    $paths=@(); $views=@(); foreach ($artifact in $Artifacts) {
        Fields-SE $artifact @('path','bytes','committed','sha256') $(if ($Images) { @('actual') } else { @() })
        Assert-SE ($artifact.committed -is [bool] -and $artifact.committed -and (UInt-SE $artifact.bytes ([uint64]::MaxValue) 1) -and $artifact.sha256 -is [string] -and $artifact.sha256 -cmatch '^[a-f0-9]{64}$') 'committed artifact bytes/hash required.'
        $path=Path-SE $artifact.path $Root; Assert-SE ($path -notin $paths) 'duplicate artifact path.'; $paths+= $path
        if ($Images) {
            $a=$artifact.actual
            Assert-SE ($a -is [pscustomobject] -and $a.view -is [string] -and $a.view -cin @('left_eye','right_eye') -and $a.view -cnotin $views -and (Exact-SE $a.format 'png') -and (Exact-SE $a.colourContract 'sdr_srgb') -and (UInt-SE $a.width ([uint32]::MaxValue) 1) -and (UInt-SE $a.height ([uint32]::MaxValue) 1)) 'image metadata/view/dimensions required.'
            $views+= $a.view
        }
    }
}
function Get-DevBenchScreenshotSequenceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Payload,[Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedBuildId,[Parameter(Mandatory)][string]$ExpectedServiceSessionId,
        [Parameter(Mandatory)][string]$DestinationDirectory,$AcceptedOwner)
    try {
        $observed=Envelope-SE $Payload $Arguments $ExpectedBuildId $ExpectedServiceSessionId
        Assert-SE ($Arguments.action -cin @('sequence_start','request_get','request_cancel','sequence_stop')) 'only exact sequence actions supported.'
        $r=$Payload.result
        Fields-SE $r @('requestId','kind','state','clientId','commandId','acceptedUtc','terminalUtc','requested','effective','actual','artifacts','warnings','errors','error','acknowledged','publication','artifactProgress') @('counts','manifest','packaging','termination','commandAccepted','alreadyTerminal','finalizationCommitted')
        Assert-SE ((Exact-SE $r.kind 'sequence') -and (Exact-SE $r.clientId $Arguments.clientId)) 'sequence parent/client ownership required.'
        Assert-SE ($r.state -cin @('preparing','running','stop_requested','cancel_requested','finalizing','completed','completed_with_warnings','failed','failed_partial','cancelled','cancelled_partial','stopped')) 'unsupported native parent lifecycle state.'
        $terminal=BaseReceipt-SE $r $observed
        Assert-SE ($r.requested -is [pscustomobject] -and (Exact-SE $r.requested.action 'sequence_start') -and (UInt-SE $r.requested.contractMajor 1 1) -and (Exact-SE $r.requested.clientId $r.clientId) -and (Exact-SE $r.requested.commandId $r.commandId)) 'original sequence-start identity required.'
        $seq=$r.requested.sequence
        Assert-SE ($seq -is [pscustomobject] -and (UInt-SE $seq.frameCount 3 1) -and (Equal-SE $r.effective $seq) -and $r.actual -is [pscustomobject]) 'finite1..3-frame requested/effective sequence required.'
        Fields-SE $seq @('frameCount','capture','schedule','backpressure','failurePolicy','packaging') @('useSettings')
        Fields-SE $seq.schedule @('basis','intervalMs','startDelayMs','pausePolicy')
        Assert-SE ((Exact-SE $seq.schedule.basis 'wall_clock') -and (UInt-SE $seq.schedule.intervalMs 10000 1) -and (UInt-SE $seq.schedule.startDelayMs 10000) -and (Exact-SE $seq.schedule.pausePolicy 'hold')) 'finite explicit wall-clock schedule required.'
        Fields-SE $seq.backpressure @('policy','maximumConsecutiveSkips')
        Assert-SE ($seq.backpressure.policy -cin @('skip','abort') -and (UInt-SE $seq.backpressure.maximumConsecutiveSkips 3) -and $seq.failurePolicy -cin @('continue','abort')) 'typed bounded failure/backpressure policy required.'
        Capture-SE $seq.capture $DestinationDirectory
        Assert-SE ($seq.packaging.frameManifest -is [bool] -and $seq.packaging.frameManifest -and $seq.packaging.previewVideo.requested -is [bool] -and -not $seq.packaging.previewVideo.requested -and $seq.packaging.previewVideo.required -is [bool] -and -not $seq.packaging.previewVideo.required) 'manifest required; no preview-video dependency.'
        if ($Arguments.action -ceq 'sequence_start') {
            $argObject=$Arguments|ConvertTo-Json -Depth 60|ConvertFrom-Json -Depth 60
            Assert-SE ((Exact-SE $r.commandId $Arguments.commandId) -and (Equal-SE $r.requested $argObject)) 'accepted start does not echo the exact submitted request.'
        } else {
            Assert-SE ($null -ne $AcceptedOwner -and $AcceptedOwner.ok -is [bool] -and $AcceptedOwner.ok -and $AcceptedOwner.owner -is [pscustomobject]) 'a qualified accepted owner is required; no adoption.'
            $owner=$AcceptedOwner.owner
            foreach ($name in @('requestId','clientId','commandId','acceptedUtc')) { Assert-SE (Equal-SE $r.$name $owner.$name) "original owner $name changed." }
            Assert-SE ((Exact-SE $owner.buildId $ExpectedBuildId) -and (Exact-SE $owner.serviceSessionId $ExpectedServiceSessionId) -and (Exact-SE $owner.destinationDirectory $DestinationDirectory) -and (Equal-SE $owner.requested $r.requested) -and (Exact-SE $Arguments.requestId $r.requestId)) 'owner/request/producer/session/destination drift.'
        }
        $alreadyTerminal=$r.PSObject.Properties['alreadyTerminal'] -and $r.alreadyTerminal -is [bool] -and $r.alreadyTerminal
        if ($r.PSObject.Properties['alreadyTerminal']) { Assert-SE ($r.alreadyTerminal -is [bool] -and $r.alreadyTerminal -and $terminal -and $Arguments.action -cin @('request_cancel','sequence_stop')) 'invalid alreadyTerminal command receipt.' }
        $commandAccepted=$null
        if ($Arguments.action -cin @('request_cancel','sequence_stop')) {
            if ($alreadyTerminal) {
                foreach ($name in @('counts','manifest','packaging','termination','commandAccepted','finalizationCommitted')) { Assert-SE (-not $r.PSObject.Properties[$name]) 'alreadyTerminal must be the source-bound base receipt, not an extended-state bypass.' }
                $commandAccepted=$false
            }
            else { Assert-SE ($r.commandAccepted -is [bool]) 'cancellation/stop acknowledgement required.'; $commandAccepted=$r.commandAccepted }
        } else { Assert-SE (-not $r.PSObject.Properties['commandAccepted'] -and -not $alreadyTerminal) 'unexpected command acknowledgement.' }
        if (-not $alreadyTerminal) {
            Fields-SE $r.counts @('requested','scheduled','acquired','written','dropped','failed','cancelled','inFlight')
            foreach ($p in $r.counts.PSObject.Properties) { Assert-SE (UInt-SE $p.Value 3) 'bounded typed sequence count required.' }
            Assert-SE ($r.counts.requested -eq $seq.frameCount -and $r.counts.scheduled -le $r.counts.requested -and $r.counts.acquired -le $r.counts.scheduled -and $r.counts.written -le $r.counts.acquired -and $r.counts.inFlight -le $r.counts.scheduled) 'sequence count ordering.'
            foreach ($n in @('dropped','failed','cancelled')) { Assert-SE ($r.counts.$n -le $r.counts.scheduled) 'child outcome count exceeds scheduled frames.' }
            if ($terminal) { Assert-SE ($r.counts.inFlight -eq 0) 'terminal parent has mutable children.' }
            Fields-SE $r.termination @('stopRequested','cancelRequested','policyAbortRequested','policyAbortCode','preparationPending','finalizationCommitted','committedOutcome')
            foreach ($n in @('stopRequested','cancelRequested','policyAbortRequested','preparationPending','finalizationCommitted')) { Assert-SE ($r.termination.$n -is [bool]) 'typed termination facts required.' }
            Assert-SE ($null -eq $r.termination.policyAbortCode -or (Text-SE $r.termination.policyAbortCode)) 'abort code/null required.'
            Assert-SE ($null -eq $r.termination.committedOutcome -or $r.termination.committedOutcome -cin @('completed','completed_with_warnings','failed','failed_partial','cancelled','cancelled_partial','stopped')) 'unsupported committed outcome.'
            if ($terminal) { Assert-SE (-not $r.termination.preparationPending -and $r.termination.finalizationCommitted) 'terminal preparation/finalization contradiction.' }
            if ($r.state -ceq 'preparing') { Assert-SE ($r.termination.preparationPending -and -not $r.termination.finalizationCommitted) 'preparing state requires pending preparation.' }
            Fields-SE $r.manifest @('partialPath','finalPath')
            Fields-SE $r.packaging @('frameManifest','previewVideo')
            $pack=$r.packaging.frameManifest; Fields-SE $pack @('requested','state') @('path','error')
            Assert-SE ($pack.requested -is [bool] -and $pack.requested -and $pack.state -cin @('pending','partial','written','failed','cancelled')) 'manifest packaging state.'
            Fields-SE $r.packaging.previewVideo @('requested','required','state')
            Assert-SE ($r.packaging.previewVideo.requested -is [bool] -and -not $r.packaging.previewVideo.requested -and $r.packaging.previewVideo.required -is [bool] -and -not $r.packaging.previewVideo.required -and (Exact-SE $r.packaging.previewVideo.state 'not_requested')) 'unexpected preview state.'
            $sequenceDirectory=SequenceDirectory-SE ([pscustomobject]@{requestId=$r.requestId;destinationDirectory=$DestinationDirectory})
            $emptyPartial=Exact-SE $r.manifest.partialPath ''
            if($emptyPartial) {
                Assert-SE ($terminal -and $r.state -ceq 'failed' -and $pack.state -ceq 'failed' -and $null -eq $r.manifest.finalPath -and $null -eq (Field-SE $pack 'path') -and $r.artifacts.Count -eq 0 -and $r.counts.scheduled -eq 0 -and (Exact-SE (Field-SE $r.error 'code') 'destination_preparation_failed') -and (Exact-SE (Field-SE $r.error 'phase') 'preparation')) 'empty uncreated partial path only qualifies exact zero-output preparation failure.'
            }
            foreach ($n in @('partialPath','finalPath')) { if ($null -ne $r.manifest.$n -and -not ($n -ceq 'partialPath' -and $emptyPartial)) {
                $path=Path-SE $r.manifest.$n $sequenceDirectory
                $file=if($n -ceq 'partialPath'){'sequence.json.partial'}else{'sequence.json'}
                Assert-SE ([string]::Equals($path,[IO.Path]::Combine($sequenceDirectory,$file),[StringComparison]::OrdinalIgnoreCase)) 'manifest path must be the exact owned generated sequence file.'
            } }
            if ($r.termination.preparationPending) { Assert-SE ($null -eq $r.manifest.partialPath -and $null -eq $r.manifest.finalPath -and $r.artifacts.Count -eq 0) 'preparation cannot invent manifest publication.' }
            if ($pack.state -ceq 'written') {
                Assert-SE ($terminal -and (Text-SE $r.manifest.finalPath) -and (Exact-SE $pack.path $r.manifest.finalPath) -and $r.artifacts.Count -eq 1 -and (Exact-SE $r.artifacts[0].path $r.manifest.finalPath)) 'final manifest publication inventory.'
            } else { Assert-SE ($null -eq $r.manifest.finalPath -and $r.artifacts.Count -eq 0) 'unwritten manifest cannot be a committed artifact.' }
            if ($pack.PSObject.Properties['error']) { Assert-SE ($pack.state -cin @('failed','cancelled') -and $pack.error -is [string]) 'only typed historical packaging error allowed.' }
            if ($terminal -and $r.state -cin @('completed','completed_with_warnings')) { Assert-SE ($pack.state -ceq 'written' -and $r.counts.written -eq $seq.frameCount -and $r.counts.scheduled -eq $seq.frameCount -and $r.counts.failed -eq 0 -and $r.counts.dropped -eq 0 -and $r.counts.cancelled -eq 0 -and (Exact-SE $r.termination.committedOutcome $r.state)) 'successful parent must have all declared frames and committed outcome.' }
            if ($commandAccepted -is [bool] -and -not $commandAccepted) { Assert-SE ($r.termination.finalizationCommitted) 'late refused command must retain committed finalization.' }
        }
        Diagnostics-SE $r @('preparation','packaging','sequence_policy') $true
        Artifacts-SE $r.artifacts $DestinationDirectory $false
        Assert-SE ($r.artifactProgress.expected -eq 1) 'parent progress describes one manifest, not stereo image count.'
        $owner=[pscustomobject]@{requestId=$r.requestId;clientId=$r.clientId;commandId=$r.commandId;acceptedUtc=$r.acceptedUtc;buildId=$ExpectedBuildId;serviceSessionId=$ExpectedServiceSessionId;destinationDirectory=$DestinationDirectory;requested=(Copy-SE $r.requested)}
        return [pscustomobject]@{ok=$true;raw=$Payload;owner=$owner;receipt=(Copy-SE $r);terminal=$terminal;requestSucceeded=($terminal -and -not $alreadyTerminal -and $r.state -cin @('completed','completed_with_warnings'));commandAccepted=$commandAccepted;cancelCoverage=($Arguments.action -ceq 'request_cancel' -and $commandAccepted -eq $true -and $r.state -cin @('cancelled','cancelled_partial'));basis='owned-schema2-sequence-observation; not image/science success';errors=@()}
    } catch { return [pscustomobject]@{ok=$false;raw=$Payload;owner=$null;receipt=$null;terminal=$false;requestSucceeded=$false;commandAccepted=$null;cancelCoverage=$false;errors=@($_.Exception.Message)} }
}
function Get-DevBenchScreenshotSequenceFrameEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Payload,[Parameter(Mandatory)][Collections.IDictionary]$Arguments,[Parameter(Mandatory)]$ParentEvidence)
    try {
        Assert-SE ($ParentEvidence.ok -is [bool] -and $ParentEvidence.ok -and $ParentEvidence.owner -is [pscustomobject]) 'qualified parent owner required.'
        $owner=$ParentEvidence.owner
        $observed=Envelope-SE $Payload $Arguments $owner.buildId $owner.serviceSessionId
        Assert-SE ((Exact-SE $Arguments.action 'request_get') -and (Exact-SE $Arguments.clientId $owner.clientId)) 'child read must retain parent query ownership.'
        $r=$Payload.result
        Fields-SE $r @('requestId','kind','state','clientId','commandId','acceptedUtc','terminalUtc','requested','effective','actual','artifacts','warnings','errors','error','acknowledged','publication','artifactProgress','parentRequestId','sequenceOrdinal')
        Assert-SE ((Exact-SE $r.kind 'sequence_frame') -and (Exact-SE $r.requestId $Arguments.requestId) -and (Exact-SE $r.parentRequestId $owner.requestId) -and (UInt-SE $r.sequenceOrdinal $owner.requested.sequence.frameCount 1) -and (Exact-SE $r.clientId ("sequence:"+$owner.requestId)) -and (Exact-SE $r.commandId ("frame:"+$r.sequenceOrdinal))) 'exact parent/frame/request/ordinal identity required.'
        Fields-SE $r.requested @('action','clientId','commandId','contractMajor')
        Assert-SE ((Exact-SE $r.requested.action 'capture') -and (Exact-SE $r.requested.clientId $r.clientId) -and (Exact-SE $r.requested.commandId $r.commandId) -and (UInt-SE $r.requested.contractMajor 1 1)) 'native generated frame command required; do not invent requested.capture.'
        $terminal=BaseReceipt-SE $r $observed
        Assert-SE ($r.state -cne 'preparing' -and (Utc-SE $r.acceptedUtc) -ge (Utc-SE $owner.acceptedUtc)) 'frame state/parent admission chronology.'
        $directory=Field-SE $r.effective.destination 'directory'; $generated=SequenceDirectory-SE $owner
        Assert-SE ((Text-SE $directory) -and [IO.Path]::IsPathFullyQualified($directory) -and [string]::Equals([IO.Path]::GetFullPath($directory),$generated,[StringComparison]::OrdinalIgnoreCase)) 'frame must use the exact native generated request directory.'
        Capture-SE $r.effective $directory
        Assert-SE ($r.artifactProgress.expected -eq 2) 'exact stereo output progress required.'
        for ($i=0;$i -lt 2;$i++) {
            Assert-SE ((Exact-SE $r.effective.outputs[$i].view $owner.requested.sequence.capture.outputs[$i].view) -and (Equal-SE $r.effective.outputs[$i].encoding $owner.requested.sequence.capture.outputs[$i].encoding)) 'frame outputs must match accepted parent recipe.'
        }
        Artifacts-SE $r.artifacts $directory $true
        Diagnostics-SE $r @('source','encoding')
        Fields-SE $r.actual @() @('acquisition','artifacts','source')
        $a=Field-SE $r.actual 'acquisition'
        if ($r.artifacts.Count -gt 0) {
            Fields-SE $a @('engineFrame','compositorCycle','monotonicTimestampUs','sourceKind','utcTimestamp','schedule','planes')
            Assert-SE ($a -is [pscustomobject] -and (UInt-SE $a.engineFrame ([uint32]::MaxValue) 1) -and (UInt-SE $a.compositorCycle ([uint64]::MaxValue) 1) -and (UInt-SE $a.monotonicTimestampUs ([uint64]::MaxValue) 1) -and (Exact-SE $a.sourceKind 'hmd_submission')) 'native source acquisition identity required.'
            $acquired=Utc-SE $a.utcTimestamp
            Assert-SE ($acquired -ge (Utc-SE $r.acceptedUtc) -and $acquired -le $observed) 'acquisition chronology.'
            Fields-SE $a.schedule @('basis','requestedEngineFrame','requestedMonotonicTimestampUs','requestedUtc','latenessFrames','latenessUs')
            Assert-SE ($a.schedule.basis -cin @('game_frames','wall_clock')) 'native schedule basis required.'
            foreach ($name in @('requestedEngineFrame','requestedMonotonicTimestampUs','latenessFrames','latenessUs')) { Assert-SE (UInt-SE $a.schedule.$name) 'schedule counters required.' }
            $null=Utc-SE $a.schedule.requestedUtc
            Assert-SE ($a.planes -is [array] -and $a.planes.Count -eq 2) 'native acquisition stereo planes required.'
        }
        if ($terminal -and $r.state -cin @('completed','completed_with_warnings')) { Assert-SE ($r.artifacts.Count -eq 2 -and $r.artifactProgress.terminal -eq 2) 'complete successful stereo frame required.' }
        if ($null -ne $a) {
            Assert-SE ($a -is [pscustomobject]) 'acquisition must be structured.'
            $planeEyes=@()
            foreach ($plane in $a.planes) {
                Fields-SE $plane @('eye','boundsApplied','colourSpace','deviceIdentity','dxgiFormat','orientation','publicationGeneration','sourceHeight','sourceWidth','stagedHeight','stagedWidth','submittedBounds','tonemapSceneHdr')
                Assert-SE ($plane.eye -is [string] -and $plane.eye -cin @('left','right') -and $plane.eye -cnotin $planeEyes -and (Text-SE $plane.deviceIdentity)) 'unique plane eye/device identity required.'
                $planeEyes+=$plane.eye
                foreach ($name in @('boundsApplied','tonemapSceneHdr')) { Assert-SE ($plane.$name -is [bool]) 'typed plane flags required.' }
                foreach ($name in @('publicationGeneration','sourceHeight','sourceWidth','stagedHeight','stagedWidth','dxgiFormat')) { Assert-SE (UInt-SE $plane.$name ([uint32]::MaxValue) 1) 'typed plane publication/dimensions/format required.' }
                Assert-SE (UInt-SE $plane.colourSpace 2) 'supported OpenVR colour space required.'
                Fields-SE $plane.orientation @('flipHorizontal','flipVertical')
                Assert-SE ($plane.orientation.flipHorizontal -is [bool] -and $plane.orientation.flipVertical -is [bool]) 'typed plane orientation required.'
                Fields-SE $plane.submittedBounds @('uMin','uMax','vMin','vMax')
                foreach ($p in $plane.submittedBounds.PSObject.Properties) { Assert-SE ($null -ne $p.Value -and $p.Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64],[single],[double],[decimal]) -and [double]::IsFinite([double]$p.Value) -and $p.Value -ge 0 -and $p.Value -le 1) 'finite normalized submitted bounds required.' }
            }
        }
        $projection=Copy-SE $r
        $projection|Add-Member terminal $terminal
        $projection|Add-Member ordinal $r.sequenceOrdinal
        if ($null -ne $a) { $projection|Add-Member engineFrame $a.engineFrame; $projection|Add-Member timestampUtc $a.utcTimestamp }
        foreach ($artifact in $projection.artifacts) { foreach ($name in @('view','format','width','height','colourContract')) { $artifact|Add-Member $name $artifact.actual.$name } }
        return [pscustomobject]@{ok=$true;raw=$Payload;parentRequestId=$owner.requestId;owner=$owner;receipt=$projection;terminal=$terminal;requestSucceeded=($terminal -and $r.state -cin @('completed','completed_with_warnings'));errors=@()}
    } catch { return [pscustomobject]@{ok=$false;raw=$Payload;receipt=$null;terminal=$false;requestSucceeded=$false;errors=@($_.Exception.Message)} }
}
function Get-DevBenchScreenshotSequenceManifestEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$ManifestBytes,[Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)]$ParentEvidence,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$FrameEvidence)
    $text=$null
    try {
        Assert-SE ($ParentEvidence.ok -is [bool] -and $ParentEvidence.ok -and $ParentEvidence.receipt.PSObject.Properties['counts']) 'fresh full parent receipt required.'
        $r=$ParentEvidence.receipt; $owner=$ParentEvidence.owner
        Assert-SE ($ManifestBytes.Length -gt 0 -and $ManifestBytes.Length -le 1048576) 'manifest content must be bounded to1MiB.'
        $null=Path-SE $ManifestPath $owner.destinationDirectory
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($ManifestBytes)
        $m=$text|ConvertFrom-Json -Depth 60 -DateKind String
        Fields-SE $m @('contract','producer','sessionId','requestId','state','terminalOutcome','client','acceptedUtc','completedUtc','requested','effective','actual','counts','warnings','errors','packaging','updatedUtc','children')
        Contract-SE $m.contract
        Assert-SE ((Exact-SE (Field-SE $m.producer 'component') 'CommunityShaders') -and (Exact-SE (Field-SE $m.producer 'buildId') $owner.buildId) -and (Exact-SE $m.sessionId $owner.serviceSessionId) -and (Exact-SE $m.requestId $owner.requestId)) 'manifest producer/session/request ownership.'
        Fields-SE $m.client @('clientId','commandId')
        Assert-SE ((Exact-SE $m.client.clientId $owner.clientId) -and (Exact-SE $m.client.commandId $owner.commandId) -and (Equal-SE $m.acceptedUtc $owner.acceptedUtc) -and (Equal-SE $m.requested $owner.requested.sequence)) 'manifest original start identity/recipe.'
        Assert-SE ($m.state -is [string] -and $m.state -cin @('partial','final')) 'manifest state required.'
        Assert-SE ($m.warnings -is [array] -and $m.errors -is [array]) 'manifest diagnostic arrays required.'
        Assert-SE (Equal-SE $m.packaging $r.packaging) 'manifest packaging disagrees with fresh owned receipt.'
        $final=$m.state -ceq 'final'; $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ManifestBytes)).ToLowerInvariant()
        $updated=Utc-SE $m.updatedUtc
        Assert-SE ($updated -ge (Utc-SE $owner.acceptedUtc) -and $updated -le (Utc-SE $ParentEvidence.raw.timestampUtc)) 'manifest checkpoint must precede fresh parent observation.'
        if ($final) {
            Assert-SE ($ParentEvidence.terminal -and (Exact-SE $ManifestPath $r.manifest.finalPath) -and $r.artifacts.Count -eq 1 -and (Exact-SE $hash $r.artifacts[0].sha256) -and $ManifestBytes.Length -eq $r.artifacts[0].bytes -and (Exact-SE $m.terminalOutcome $r.state) -and (Equal-SE $m.counts $r.counts)) 'final manifest hash/bytes/path/outcome/counts must match terminal native receipt.'
            Assert-SE ((Utc-SE $m.completedUtc) -eq $updated -and $updated -le (Utc-SE $r.terminalUtc)) 'final manifest completion chronology.'
        } else {
            Assert-SE ((Exact-SE $ManifestPath $r.manifest.partialPath) -and $null -eq $m.terminalOutcome -and $null -eq $m.completedUtc) 'partial checkpoint cannot claim terminal publication.'
            Fields-SE $m.counts @('requested','scheduled','acquired','written','dropped','failed','cancelled','inFlight')
            foreach ($p in $m.counts.PSObject.Properties) { Assert-SE ((UInt-SE $p.Value 3) -and $p.Value -le $r.counts.($p.Name)) 'partial checkpoint cannot exceed fresh parent counters.' }
        }
        # Native manifest effective is sequence.capture with requested parent
        # directory; the lease-generated child directory belongs to artifacts.
        Capture-SE $m.effective $owner.destinationDirectory
        if($m.effective.destination.PSObject.Properties['resolvedDirectory']) {
            Assert-SE ((Text-SE $m.effective.destination.resolvedDirectory) -and [string]::Equals([IO.Path]::GetFullPath($m.effective.destination.resolvedDirectory),[IO.Path]::GetFullPath($owner.destinationDirectory),[StringComparison]::OrdinalIgnoreCase)) 'manifest resolved parent destination changed.'
        }
        $directory=SequenceDirectory-SE $owner
        Assert-SE ([string]::Equals([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath)),$directory,[StringComparison]::OrdinalIgnoreCase)) 'manifest must be in its exact generated request directory.'
        Assert-SE ($m.children -is [array] -and $m.children.Count -le 3 -and $FrameEvidence.Count -eq $m.children.Count -and $m.actual.children -eq $m.children.Count -and $m.actual.fallbacksPresent -is [bool] -and -not $m.actual.fallbacksPresent) 'exact bounded non-fallback child inventory required.'
        $ids=@(); $ordinals=@(); $projected=@()
        $artifactPaths=@(); [uint64]$artifactBytes=$ManifestBytes.Length
        foreach ($child in $m.children) {
            Fields-SE $child @('ordinal','requestId','state','scheduledEngineFrame','scheduledTimestampUs','requested','effective','actual','artifacts','warnings','errors','error')
            Assert-SE ((UInt-SE $child.ordinal $owner.requested.sequence.frameCount 1) -and (Text-SE $child.requestId) -and $child.requestId -cnotin $ids -and $child.ordinal -notin $ordinals -and (UInt-SE $child.scheduledEngineFrame) -and (UInt-SE $child.scheduledTimestampUs)) 'duplicate/invalid manifest child identity.'
            $ids+=$child.requestId; $ordinals+=$child.ordinal
            $matches=@($FrameEvidence|Where-Object { $_.ok -is [bool] -and $_.ok -and $_.terminal -and $_.receipt.requestId -ceq $child.requestId })
            Assert-SE ($matches.Count -eq 1 -and (Exact-SE $matches[0].parentRequestId $owner.requestId) -and (Exact-SE $matches[0].owner.serviceSessionId $owner.serviceSessionId) -and (Exact-SE $matches[0].owner.buildId $owner.buildId)) 'every manifest child needs an independently qualified terminal native read.'
            $f=$matches[0].raw.result
            Assert-SE ($f.sequenceOrdinal -eq $child.ordinal) 'manifest/frame ordinal mismatch.'
            Assert-SE (Exact-SE $f.effective.destination.directory $directory) 'child belongs to a different sequence directory.'
            foreach ($name in @('state','requested','effective','artifacts','warnings','errors','error')) { Assert-SE (Equal-SE $child.$name $f.$name) "manifest child $name differs from owned native frame." }
            Assert-SE (Equal-FrameActual-SE $child.actual $f.actual) 'manifest child actual differs from owned native frame.'
            $acquisition=Field-SE $f.actual 'acquisition'
            if ($null -ne $acquisition) { Assert-SE ($child.scheduledEngineFrame -eq $acquisition.schedule.requestedEngineFrame -and $child.scheduledTimestampUs -eq $acquisition.schedule.requestedMonotonicTimestampUs) 'manifest/native schedule identity mismatch.' }
            foreach ($artifact in $f.artifacts) {
                Assert-SE ($artifact.path -notin $artifactPaths) 'duplicate artifact across sequence frames.'
                $artifactPaths+=$artifact.path; $artifactBytes+=$artifact.bytes
                Assert-SE ($artifactBytes -le 134217728) '128MiB finite output budget exceeded.'
            }
            $projected+= $matches[0].receipt
        }
        if ($final) { Assert-SE ($m.children.Count -eq $r.counts.scheduled -and $m.counts.inFlight -eq 0) 'terminal manifest cannot omit scheduled children.' }
        return [pscustomobject]@{ok=$true;rawManifest=$m;manifestSha256=$hash;manifestBytes=$ManifestBytes.Length;declaredArtifactBytes=$artifactBytes;final=$final;terminalProof=$final;frames=$projected;requestSucceeded=($final -and $ParentEvidence.requestSucceeded -and @($FrameEvidence|Where-Object { -not $_.requestSucceeded }).Count -eq 0);errors=@()}
    } catch { return [pscustomobject]@{ok=$false;rawManifestText=$text;final=$false;terminalProof=$false;requestSucceeded=$false;frames=@();errors=@($_.Exception.Message)} }
}
Export-ModuleMember -Function Get-DevBenchScreenshotSequenceEvidence, Get-DevBenchScreenshotSequenceFrameEvidence, Get-DevBenchScreenshotSequenceManifestEvidence
