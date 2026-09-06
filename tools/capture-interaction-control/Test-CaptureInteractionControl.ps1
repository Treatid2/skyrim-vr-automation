# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('capture-interaction-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Import-Module (Join-Path $PSScriptRoot 'CaptureInteractionControl.psm1') -Force
    $pose = [pscustomobject]@{ available=$true; connected=$true; valid=$true; index=0; trackingResult=200; matrix=@(1,0,0,0,0,1,0,0,0,0,1,0); velocity=@(0,0,0); angularVelocity=@(0,0,0) }
    $controller = [pscustomobject]@{ available=$true; connected=$true; valid=$true; index=1; trackingResult=200; matrix=@(1,0,0,0,0,1,0,0,0,0,1,0); velocity=@(0,0,0); angularVelocity=@(0,0,0); controller=[pscustomobject]@{ packetNumber=4; pressed=99; touched=99; axes=@(@(0,0),@(0,0),@(0,0),@(0,0),@(0,0)) } }
    $frame = [pscustomobject]@{ tMs=0; seq=1; originCode=1; hmd=$pose; left=$controller; right=($controller | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
    $frame.right.index = 2
    $compiled = @(New-CaptureInteractionFrames -ObservedFrame $frame -ActionName 'accept')
    Assert-Test ($compiled.Count -eq 3) 'accept compiles into neutral, active, and released frames'
    Assert-Test ($compiled[0].right.controller.pressed -eq 0 -and $compiled[1].right.controller.pressed -eq 8589934592 -and $compiled[2].right.controller.pressed -eq 0) 'accept changes only the bounded active state'
    Assert-Test ($compiled[0].right.index -eq 2 -and $compiled[1].hmd.matrix[0] -eq 1) 'named actions preserve observed tracked poses'
    Assert-Test ($compiled[0].right.controller.packetNumber -lt $compiled[1].right.controller.packetNumber -and $compiled[1].right.controller.packetNumber -lt $compiled[2].right.controller.packetNumber) 'controller packets advance for every transition'

    $receipt = [pscustomobject]@{ requestId='req'; state='running'; children=@(
        [pscustomobject]@{ ordinal=1; scheduledEngineFrame=10; artifacts=@([pscustomobject]@{ view='left_eye';path='old.png';committed=$true }) },
        [pscustomobject]@{ ordinal=2; scheduledEngineFrame=20; artifacts=@([pscustomobject]@{ view='right_eye';path='right.png';committed=$true },[pscustomobject]@{ view='left_eye';path='latest.png';committed=$true }) }
    ) }
    $latest = Get-CaptureInteractionLatestFrame -Receipt $receipt -PreferredView left_eye
    Assert-Test ($latest.path -eq 'latest.png' -and $latest.ordinal -eq 2) 'latest-frame selection prefers the requested view at the newest ordinal'
    $partialReceipt = [pscustomobject]@{ requestId='partial'; state='running'; children=@(
        [pscustomobject]@{ ordinal=2; scheduledEngineFrame=20; artifacts=@([pscustomobject]@{ view='left_eye';path='stale-left.png';committed=$true }) },
        [pscustomobject]@{ ordinal=3; scheduledEngineFrame=30; artifacts=@([pscustomobject]@{ view='right_eye';path='current-right.png';committed=$true }) }
    ) }
    $partialLatest = Get-CaptureInteractionLatestFrame -Receipt $partialReceipt -PreferredView left_eye
    Assert-Test ($partialLatest.path -eq 'current-right.png') 'latest-frame selection never prefers an older eye over the newest committed frame'

    $saveRoot = Join-Path $root 'saves'
    New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null
    $utcBoundary = ConvertTo-CaptureInteractionUtcBoundary -Value '2026-08-26T09:30:58.715Z'
    $savePath = Join-Path $saveRoot 'Save3_Test_WhiterunWorld.ess'
    [IO.File]::WriteAllBytes($savePath, [byte[]](1,2,3,4))
    [IO.File]::SetLastWriteTimeUtc($savePath, [DateTime]::SpecifyKind([DateTime]'2026-08-26T09:33:10', [DateTimeKind]::Utc))
    $saveCandidates = @(Get-CaptureInteractionSaveCandidates -Directory $saveRoot -SinceUtc $utcBoundary -NamePattern 'Save3*')
    Assert-Test ($saveCandidates.Count -eq 1 -and $saveCandidates[0].name -eq 'Save3_Test_WhiterunWorld.ess') 'save boundary parsing and comparison remain UTC-safe in non-UTC local time'

    $fake = Join-Path $root 'fake-devbench.ps1'
    $fakeText = @'
param(
    [Parameter(Position=0)][string]$Command,
    [string]$Tool,
    [string]$ArgumentsJson,
    [string]$RuntimePath,
    [switch]$RequireSuccess,
    [switch]$Compact,
    [switch]$NoExit,
    [switch]$SkipRuntimeIdentityVerification
)
$argsObject = $ArgumentsJson | ConvertFrom-Json -Depth 80
$frame = [pscustomobject]@{
  tMs=0; seq=1; originCode=1
  hmd=[pscustomobject]@{available=$true;connected=$true;valid=$true;index=0;trackingResult=200;matrix=@(1,0,0,0,0,1,0,0,0,0,1,0);velocity=@(0,0,0);angularVelocity=@(0,0,0)}
  left=[pscustomobject]@{available=$true;connected=$true;valid=$true;index=1;trackingResult=200;matrix=@(1,0,0,-0.2,0,1,0,1,0,0,1,-0.3);velocity=@(0,0,0);angularVelocity=@(0,0,0);controller=[pscustomobject]@{packetNumber=1;pressed=0;touched=0;axes=@(@(0,0),@(0,0),@(0,0),@(0,0),@(0,0))}}
  right=[pscustomobject]@{available=$true;connected=$true;valid=$true;index=2;trackingResult=200;matrix=@(1,0,0,0.2,0,1,0,1,0,0,1,-0.3);velocity=@(0,0,0);angularVelocity=@(0,0,0);controller=[pscustomobject]@{packetNumber=1;pressed=0;touched=0;axes=@(@(0,0),@(0,0),@(0,0),@(0,0),@(0,0))}}
}
if ($Tool -eq 'communityshaders.screenshot') {
  if ($argsObject.action -in @('sequence_start','capture')) { $value=[pscustomobject]@{ok=$true;result=[pscustomobject]@{requestId='req-1';state='running';terminal=$false}} }
  elseif ($argsObject.action -eq 'request_get') {
    $image=Join-Path $env:CAPTURE_INTERACTION_FAKE_ROOT 'frame-left.png'
    if (-not (Test-Path $image)) { [IO.File]::WriteAllBytes($image,[byte[]](1,2,3)) }
    $value=[pscustomobject]@{ok=$true;result=[pscustomobject]@{requestId='req-1';state='completed';terminal=$true;children=@([pscustomobject]@{ordinal=4;scheduledEngineFrame=44;artifacts=@([pscustomobject]@{view='left_eye';path=$image;format='png';bytes=3;committed=$true})})}}
  }
  else { $value=[pscustomobject]@{ok=$true;result=[pscustomobject]@{requestId='req-1';state='stop_requested'}} }
} elseif ($Tool -eq 'record') {
  $correlationId = if ($argsObject.PSObject.Properties['correlationId']) { $argsObject.correlationId } else { $null }
  $value=[pscustomobject]@{action=$argsObject.action;recording=($argsObject.action -ne 'stop');correlationId=$correlationId;path=$(if($argsObject.action -eq 'stop'){'recording.json'}else{$null})}
} elseif ($Tool -eq 'input' -and $argsObject.action -eq 'observe') {
  $value=[pscustomobject]@{action='observe';source='physical_openvr';frame=$frame}
} elseif ($Tool -eq 'input' -and $argsObject.action -eq 'status' -and $argsObject.device -eq 'vrTrackedSet') {
  $value=[pscustomobject]@{device='vrTrackedSet';ready=$true;active=$false;generation=1;lastCompletion=[pscustomobject]@{generation=1;completed=$true}}
} elseif ($Tool -eq 'input') {
  $value=[pscustomobject]@{ok=$true;action=$argsObject.action;queued=($argsObject.action -eq 'sequence');generation=1}
} elseif ($Tool -eq 'menu') { $value=[pscustomobject]@{openMenus=@('HUD Menu');messageBoxOpen=$false} }
elseif ($Tool -eq 'inspect') { $value=[pscustomobject]@{playerLoaded=$true;frame=40} }
else { $value=[pscustomobject]@{ok=$true} }
[pscustomobject]@{ok=$true;data=[pscustomobject]@{content=@($value)};errors=@()} | ConvertTo-Json -Depth 100 -Compress
'@
    Set-Content -LiteralPath $fake -Value $fakeText -Encoding utf8
    $runtime = Join-Path $root 'runtime.json'
    '{}' | Set-Content -LiteralPath $runtime -Encoding utf8
    $env:CAPTURE_INTERACTION_FAKE_ROOT = $root
    $entry = Join-Path $PSScriptRoot 'Invoke-CaptureInteraction.ps1'
    $session = Join-Path $root 'session'
    $started = & $entry start -SessionDirectory $session -RuntimePath $runtime -VisualMode sequence -MaximumFrames 10 -FrameIntervalMs 500 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($started.ok -and $started.state -eq 'session-started' -and $started.data.screenshot.requestId -eq 'req-1') 'sequence session starts recording and screenshot capture under one session'
    $observed = & $entry observe -SessionDirectory $session -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($observed.ok -and $observed.data.observation.latestFrame.ordinal -eq 4) 'observe composites runtime state and the latest committed frame'
    Assert-Test (Test-Path -LiteralPath $observed.data.observationPath -PathType Leaf) 'observe persists a latest-observation receipt'
    $acted = & $entry act -SessionDirectory $session -ActionName accept -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($acted.ok -and $acted.state -eq 'action-submitted' -and $acted.data.action.receipt.compiledFrames.Count -eq 3 -and -not $acted.data.action.receipt.terminal.active) 'named action observes, submits, and awaits one atomic tracked-set sequence'
    $stopped = & $entry stop -SessionDirectory $session -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($stopped.ok -and $stopped.state -eq 'stopped' -and $stopped.data.recording.stopReceipt.path -eq 'recording.json') 'stop finalizes visual capture before state recording and persists receipts'

    [pscustomobject]@{ ok=$true; sessionPath=$started.data.statePath; actionCount=(Get-CaptureInteractionActionCatalog).actions.Count } | ConvertTo-Json -Compress
}
finally {
    Remove-Item Env:CAPTURE_INTERACTION_FAKE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
