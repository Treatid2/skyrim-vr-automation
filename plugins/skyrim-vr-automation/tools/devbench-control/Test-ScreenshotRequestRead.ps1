# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'capture-interaction-control/CaptureInteractionControl.psm1') -Force
$script:assertions=0
function Check([bool]$Good,[string]$Message){$script:assertions++; if(-not $Good){throw $Message}}
function Copy-Fixture($Value){return $Value|ConvertTo-Json -Depth 80|ConvertFrom-Json -Depth 80}
function Change($Value,[string]$Path,$Replacement){$names=$Path.Split('.');$node=$Value;for($i=0;$i -lt $names.Count-1;$i++){$node=$node.($names[$i])};$node.($names[-1])=$Replacement}
$encoding=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-screenshot-encoding.json') -Raw|ConvertFrom-Json -Depth 80
$completed=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-screenshot-completed.json') -Raw|ConvertFrom-Json -Depth 80
function Query-Args($Payload){return @{action='request_get';contractMajor=1;clientId=$Payload.command.clientId;commandId=$Payload.command.commandId;requestId=$Payload.result.requestId;expectedBuildId=$Payload.server.buildId}}
function Read-Receipt($Payload,$Query=(Query-Args $completed)) {return Get-DevBenchCallSemanticStatus -ToolName communityshaders.screenshot -Arguments $Query -Content @($Payload)}
foreach($fixture in @($encoding,$completed)){
    $before=$fixture|ConvertTo-Json -Depth 80 -Compress
    $read=Read-Receipt $fixture (Query-Args $fixture)
    Check $read.ok 'exact retained native receipt must qualify'
    Check ($read.completionBasis -ceq 'owned-request-observation-only') 'read is not capture or experiment success'
    Check (-not $fixture.result.PSObject.Properties['terminal'] -and ($fixture|ConvertTo-Json -Depth 80 -Compress) -ceq $before) 'raw receipt is unchanged and has no synthetic terminal flag'
    Check ($read.qualifiedScreenshotRequest.terminal -eq ($fixture.result.state -ceq 'completed')) 'source states/UTC/progress derive terminal Boolean'
    Check ($read.qualifiedScreenshotRequest.requestSucceeded -eq ($fixture.result.state -ceq 'completed')) 'encoding is a valid read but not successful capture'
    $latest=Get-CaptureInteractionLatestFrame -Receipt $read.qualifiedScreenshotRequest -PreferredView left_eye
    Check ($latest.view -ceq 'left_eye' -and $latest.engineFrame -eq 159016 -and $latest.sha256 -ceq '80df3332b3ca5eee83fe22df00f109455865b3e8f96ce132cc9f8fc3df81dcc4') 'nested native actual metadata supports exact latest-frame ranking'
}
$right=Get-CaptureInteractionLatestFrame -Receipt (Read-Receipt $completed).qualifiedScreenshotRequest -PreferredView right_eye
Check ($right.view -ceq 'right_eye' -and $right.sha256 -ceq '051bb3fd47ebb8b672b8dbbc9041c27c6c792fa338a3050273523452f9ca99a3') 'completed stereo preserves exact right-eye hash'
$defects=@(
    @('ok','true'),@('ok',$false),@('contract.name','foreign'),@('contract.major','1'),@('contract.minor',1),@('contract.schemaRevision',2),
    @('command.action','capture'),@('command.clientId','foreign'),@('command.commandId','foreign'),@('server.component','foreign'),@('server.buildId',('e'*64)),@('server.serviceSessionId',''),
    @('result.requestId','foreign'),@('result.clientId','foreign'),@('result.commandId','foreign'),@('result.kind','sequence'),@('result.kind','sequence_frame'),
    @('result.requested.action','request_get'),@('result.requested.contractMajor','1'),@('result.requested.commandId','foreign'),
    @('result.state','staging'),@('result.state','COMPLETED'),@('result.state','foreign'),@('result.terminalUtc',$null),@('result.acceptedUtc','invalid'),
    @('timestampUtc','2026-10-04T02:49:00Z'),@('result.terminalUtc','2026-10-04T02:48:00Z'),@('result.publication.state','unresolved'),@('result.publication.artifactCommitted',$true),
    @('result.acknowledged','false'),@('result.artifactProgress.expected','2'),@('result.artifactProgress.expected',-1),@('result.artifactProgress.successful',1),@('result.artifactProgress.terminal',3),
    @('result.artifacts','scalar'),@('result.actual.acquisition.engineFrame',0),@('result.actual.acquisition.engineFrame','159016'),@('result.actual.acquisition.compositorCycle',-1),
    @('result.actual.acquisition.utcTimestamp','2026-10-04T02:48:00Z'),@('result.errors','scalar'),@('result.warnings','scalar'),
    @('result.error',[pscustomobject]@{code='capture_failed';message='failure'})
    @('contract.name',@('csx.screenshot')),@('command.action',@('request_get')),@('server.component',@('CommunityShaders')),@('result.kind',@('still')),
    @('result.requested.action',@('capture')),@('result.publication.state',@('settled'))
)
foreach($defect in $defects){$bad=Copy-Fixture $completed;Change $bad $defect[0] $defect[1];$read=Read-Receipt $bad;Check (-not $read.ok -and $null -eq $read.qualifiedScreenshotRequest) "refuse malformed $($defect[0])"}
foreach($value in @($null,'2',2.5,-1,[uint64]::MaxValue)){
    foreach($name in @('expected','successful','terminal')){$bad=Copy-Fixture $completed;$bad.result.artifactProgress.$name=$value;Check (-not (Read-Receipt $bad).ok) "refuse malformed progress $name"}
}
foreach($defect in @('stringCommit','badHash','noHash','zeroBytes','duplicateView','duplicatePath','badDimension','scalarActual','wrongColour','wrongFormat','nestedError','outerError','terminalMismatch','missingTerminalUtc','scalarOutput','duplicateOutput','typedWarningExtra')){
    $bad=Copy-Fixture $completed
    switch($defect){
        stringCommit {$bad.result.artifacts[0].committed='true'}
        badHash {$bad.result.artifacts[0].sha256='bad'}
        noHash {$bad.result.artifacts[0].PSObject.Properties.Remove('sha256')}
        zeroBytes {$bad.result.artifacts[0].bytes=0}
        duplicateView {$bad.result.artifacts[1].actual.view='left_eye'}
        duplicatePath {$bad.result.artifacts[1].path=$bad.result.artifacts[0].path}
        badDimension {$bad.result.artifacts[0].actual.width='1512'}
        scalarActual {$bad.result.artifacts[0].actual='scalar'}
        wrongColour {$bad.result.artifacts[0].actual.colourContract='hdr'}
        wrongFormat {$bad.result.artifacts[0].actual.format='zip'}
        nestedError {$bad.result.actual|Add-Member error 'failed'}
        outerError {$bad|Add-Member error 'failed'}
        terminalMismatch {$bad.result|Add-Member terminal $false}
        missingTerminalUtc {$bad.result.PSObject.Properties.Remove('terminalUtc')}
        scalarOutput {$bad.result.effective.outputs='scalar'}
        duplicateOutput {$bad.result.effective.outputs[1].view='left_eye'}
        typedWarningExtra {$bad.result.warnings=@([pscustomobject]@{code='source_fallback';message='fallback';ok=$false})}
    }
    Check (-not (Read-Receipt $bad).ok) "refuse $defect"
}
foreach($name in @('requestId','clientId','commandId','expectedBuildId')){$query=Query-Args $completed;$query[$name]='foreign';Check (-not (Read-Receipt $completed $query).ok) "exact query $name binding"}
$badBuild=Query-Args $completed;$badBuild.expectedBuildId=@($completed.server.buildId)
Check (-not (Read-Receipt $completed $badBuild).ok) 'producer expectation must be a string, not truthy singleton array'
$nonterminal=Copy-Fixture $encoding;$nonterminal.result.terminalUtc='2026-10-04T02:49:28.223Z'
Check (-not (Read-Receipt $nonterminal (Query-Args $encoding)).ok) 'nonterminal must explicitly retain null terminalUtc'
$failed=Copy-Fixture $completed;$failed.result.state='failed_partial';$failed.result.artifacts=@($failed.result.artifacts[0]);$failed.result.artifactProgress.successful=1
$failed.result.error=[pscustomobject]@{code='artifact_failed';message='retained failure';phase='encoding';path=$null};$failed.result.errors=@($failed.result.error)
$read=Read-Receipt $failed
Check ($read.ok -and $read.qualifiedScreenshotRequest.terminal -and -not $read.qualifiedScreenshotRequest.requestSucceeded -and $read.qualifiedScreenshotRequest.errors[0].code -ceq 'artifact_failed') 'owned failed capture is a successful terminal read, never successful capture; errors retained'
$failed|Add-Member error 'query failed'
Check (-not (Read-Receipt $failed).ok) 'historical request error exception never masks outer query error'
$errorExtension=Copy-Fixture $failed;$errorExtension.PSObject.Properties.Remove('error');$errorExtension.result.error|Add-Member ok $false
Check (-not (Read-Receipt $errorExtension).ok) 'unknown negative extension inside historical error is never masked'
$formatMismatch=Copy-Fixture $completed;$formatMismatch.result.artifacts[0].actual.format='bmp'
Check (-not (Read-Receipt $formatMismatch).ok) 'supported but wrong artifact format refuses effective output mismatch'
$requestedMismatch=Copy-Fixture $completed;$requestedMismatch.result.requested.capture.outputs[0].view='right_eye'
Check (-not (Read-Receipt $requestedMismatch).ok) 'requested and effective output inventories must agree'
$warn=Copy-Fixture $completed;$warn.result.state='completed_with_warnings';$warn.result.warnings=@([pscustomobject]@{code='source_fallback';message='native source fallback retained'})
Check ((Read-Receipt $warn).ok -and (Read-Receipt $warn).qualifiedScreenshotRequest.warnings.Count -eq 1) 'typed native warning remains visible and does not become a query failure'
foreach($action in @('capture','request_cancel','REQUEST_GET')){
    $query=Query-Args $completed;$query.action=$action
    $read=Read-Receipt $completed $query
    Check (-not $read.PSObject.Properties['qualifiedScreenshotRequest']) 'native request read adapter does not qualify foreign actions'
}
$multiple=Get-DevBenchCallSemanticStatus -ToolName communityshaders.screenshot -Arguments (Query-Args $completed) -Content @($completed,$completed)
Check (-not $multiple.ok) 'multiple native receipts refuse qualification'
[pscustomobject]@{ok=$true;assertions=$script:assertions;scope='offline retained native still request_get and adversarial schema/correlation fixtures; no runtime dispatch'}|ConvertTo-Json -Compress
