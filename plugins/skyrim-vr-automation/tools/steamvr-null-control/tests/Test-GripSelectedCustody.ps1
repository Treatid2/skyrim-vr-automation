# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New disposable fixture root required'}
$source=Split-Path -Parent $PSScriptRoot
$toolkit=Join-Path $EvidenceDirectory 'toolkit'
$lifecycle=Join-Path $toolkit 'tools/steamvr-null-control'
[void][IO.Directory]::CreateDirectory($lifecycle)
foreach($name in @('GripLifecycle.Common.ps1','GripLifecycle.Worker.ps1','Invoke-NullHmdGripDiagnostic.ps1','Invoke-NullHmdGripSelectedRun.ps1')){Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $lifecycle $name)}
function Pin([string]$Path){return @{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}}
function Dummy([string]$Relative){
    $path=Join-Path $toolkit $Relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path,'disposable selection fixture - never executable')
    return Pin $path
}
$plan=@{schemaVersion='null-grip-session.1';diagnostic='fixed-grip-neutral-A-B';standalone=$true;toolkitRoot=$toolkit}
foreach($pair in @(@('nullControl','tools/steamvr-null-control/Invoke-SteamVRNullControl.ps1'),@('headControl','tools/steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1'),@('controllerControl','tools/steamvr-controller-control/Invoke-SteamVRControllerControl.ps1'),@('nullProfile','profiles/steamvr-null.profile.json'),@('fixture','fixture/grip_neutral_ab.py'),@('atomics','fixture/atomics.dll'),@('python','fixture/python.cmd'),@('provider','driver/bin/win64/driver_codex_head_pose.dll'),@('openvr','fixture/openvr.dll'),@('poseProbe','fixture/probe.exe'))){$plan[$pair[0]]=Dummy $pair[1]}
$owner=Join-Path $toolkit 'tools/process-control/Invoke-BoundedProcess.ps1'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $owner))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GripLifecycle.SelectionOwner.ps1') -Destination $owner
$plan.boundedProcess=Pin $owner
$plan.fixtureDependencies=@('Invoke-NullHmdGripDiagnostic.ps1','GripLifecycle.Worker.ps1','GripLifecycle.Common.ps1' | ForEach-Object {Pin (Join-Path $lifecycle $_)})
foreach($key in @('settingsPath','openVRPathsPath','steamVRRoot','serverLogPath')){$plan[$key]=Join-Path $EvidenceDirectory $key}
$plan.driverRoot=Join-Path $toolkit 'driver'
$proposal=Join-Path $EvidenceDirectory 'proposal.json'
[IO.File]::WriteAllText($proposal,($plan | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$proposalPin=Pin $proposal
$alternatePlan=$plan.Clone();$alternatePlan.settingsPath=Join-Path $EvidenceDirectory 'alternate-settings';$alternatePlan.openVRPathsPath=Join-Path $EvidenceDirectory 'alternate-registration'
$alternate=Join-Path $EvidenceDirectory 'alternate-plan.json'
[IO.File]::WriteAllText($alternate,($alternatePlan | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$runtimeEvidence=Join-Path $toolkit 'fixture/evidence'
[void][IO.Directory]::CreateDirectory($runtimeEvidence)
$run=Join-Path $runtimeEvidence 'one-attempt'
$marker=Join-Path $EvidenceDirectory 'controller-was-invoked'
$entry=Join-Path $lifecycle 'Invoke-NullHmdGripDiagnostic.ps1'
$config=@{proposal=$proposal;alternatePlan=$alternate;controlMarker=$marker;coordinator=$entry}
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $owner) 'selection-fixture.json'),($config | ConvertTo-Json))
$pwsh=(Get-Process -Id $PID).Path
$argsBase=@('-Live','-PlanPath',$proposal,'-EvidenceDirectory',$run,'-BoundedProcessPath',$owner,'-BoundedProcessSha256',$plan.boundedProcess.sha256,'-SessionBudgetSeconds','20','-CleanupReserveSeconds','10')
$checks=[Collections.Generic.List[string]]::new()
$prior=[Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process')
try{
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$plan.python.path,'Process')
    $missing=& $pwsh -NoProfile -File $entry @argsBase 2>&1 | Out-String
    if($LASTEXITCODE -eq 0 -or $missing -notlike '*Live requires ExpectedPlanSha256*' -or (Test-Path -LiteralPath $run)){throw 'Unhashed direct Live invocation did not fail before root creation'}
    $checks.Add('direct Live without selected hash refuses before admission')
    $changed=& $pwsh -NoProfile -File $entry @argsBase -ExpectedPlanSha256 ('0'*64) 2>&1 | Out-String
    if($LASTEXITCODE -eq 0 -or $changed -notlike '*Selected plan hash changed*' -or (Test-Path -LiteralPath $run)){throw 'Changed proposal admitted before coordinator'}
    $checks.Add('changed proposal refuses before coordinator admission')
    # Real public wrapper ValidateOnly, all fixture pins, no runtime call.
    $wrapper=Join-Path $lifecycle 'Invoke-NullHmdGripSelectedRun.ps1'
    $valid=& $wrapper -PlanPath $proposal -PlanSha256 $proposalPin.sha256 -ConfiguredPythonPath $plan.python.path -ConfiguredPythonSha256 $plan.python.sha256 -EvidenceDirectory $run -ValidateOnly | ConvertFrom-Json -AsHashtable
    if(-not $valid.ok -or -not $valid.selectedInputsProtected -or $valid.runtimeInvoked -or (Test-Path -LiteralPath $run)){throw 'Selected validation did not protect exact fixture inputs'}
    $checks.Add('public selected envelope validates without evidence/runtime mutation')
    $common=Join-Path $lifecycle 'GripLifecycle.Common.ps1'
    $commonBytes=[IO.File]::ReadAllBytes($common)
    [IO.File]::WriteAllText($common,'throw "untrusted Common executed"')
    $badCommon=& $pwsh -NoProfile -File $entry @argsBase -ExpectedPlanSha256 $proposalPin.sha256 2>&1 | Out-String
    [IO.File]::WriteAllBytes($common,$commonBytes)
    if($LASTEXITCODE -eq 0 -or $badCommon -notlike '*Selected Common hash changed before execution*' -or $badCommon -like '*untrusted Common executed*' -or (Test-Path -LiteralPath $run)){throw 'Changed Common executed before pin verification'}
    $checks.Add('changed Common rejected before execution')
    $worker=Join-Path $lifecycle 'GripLifecycle.Worker.ps1';$workerBytes=[IO.File]::ReadAllBytes($worker)
    [IO.File]::WriteAllText($worker,'throw "untrusted Worker executed"')
    $badWorker=& $pwsh -NoProfile -File $entry @argsBase -ExpectedPlanSha256 $proposalPin.sha256 2>&1 | Out-String
    [IO.File]::WriteAllBytes($worker,$workerBytes)
    if($LASTEXITCODE -eq 0 -or $badWorker -notlike '*Pinned artifact hash changed*' -or $badWorker -like '*untrusted Worker executed*' -or (Test-Path -LiteralPath $run)){throw 'Changed Worker admitted before pin verification'}
    $checks.Add('changed Worker rejected before launch')
    # Coordinator runs all three real launch boundaries; process responses are
    # injected and deliberately unsuccessful. No real runtime/controller is used.
    $raw=& $pwsh -NoProfile -File $entry @argsBase -ExpectedPlanSha256 $proposalPin.sha256
    $exit=$LASTEXITCODE;$result=$raw | ConvertFrom-Json -AsHashtable
    if($exit -ne 2 -or $result.cleanHandoffVerified -or $result.published -or $result.stages.Count -ne 3){throw 'Fixture failure became a clean/published handoff'}
    foreach($stage in @('session','recovery','publication')){
        $receipt=Get-Content -LiteralPath (Join-Path $run ('selection-boundary-'+$stage+'.json')) -Raw | ConvertFrom-Json -AsHashtable
        if($receipt.checks.Count -ne 7 -or -not $receipt.workerRefusedChangedPlan -or -not $receipt.nativeWorkerRefusedChangedPlan -or -not $receipt.workerHashArgumentsPropagated){throw 'Boundary custody evidence is incomplete'}
        $checks.Add("$stage boundary: seven selected inputs resist writes/replacement; real worker refuses changed plan")
    }
    $snapshot=Pin (Join-Path $run 'selected-plan.json')
    if($snapshot.sha256 -cne $proposalPin.sha256 -or $result.selectedPlan.sha256 -cne $proposalPin.sha256){throw 'Selected snapshot changed exact bytes'}
    if(Test-Path -LiteralPath $marker){throw 'Selection tests invoked a runtime controller'}
    $checks.Add('exact-byte staged plan and no false clean handoff or controller dispatch')
    # All owner handles must be released after a terminal coordinator result.
    [IO.File]::WriteAllBytes($proposal,[IO.File]::ReadAllBytes($proposal))
    [IO.File]::WriteAllBytes($common,$commonBytes)
    [IO.File]::WriteAllBytes($worker,$workerBytes)
    $checks.Add('selected handles released after terminal result')
    $receipt=@{ok=$true;checks=$checks.ToArray();count=$checks.Count;runtimeInvoked=$false;processResponsesInjected=$true;scope='Production selected-envelope/coordinator/worker admission with disposable pinned toolkit; not runtime or process-custody qualification';selectedPlanSha256=$proposalPin.sha256;sourceRoot=$source}
    [IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'test-receipt.json'),($receipt | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $receipt | ConvertTo-Json -Depth 8 -Compress
}finally{[Environment]::SetEnvironmentVariable('CODEX_PYTHON',$prior,'Process')}
