# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[switch]$ExpectLegacyFailure)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$source=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('unlock-scope-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$cases=if($ExpectLegacyFailure){@('healthy')}else{@('healthy','post-inspection-failed','unlock-inspection-failed','receipt-write-failed','status-write-failed','owner-changed','remaining-game','rootbuilder-incomplete','primitive-refused','reconciliation-write-failed','final-resolution-write-failed','projection-write-failed')}
foreach($case in $cases){
 $directory=Join-Path $root $case
 [IO.Directory]::CreateDirectory($directory)|Out-Null
 # Execute the unchanged production entry and real termination/Unlock functions.
 # Append test-only OS/ownership adapters in the copied module. No live process
 # lookup, handle, UI action, lease, or termination function can be reached.
 foreach($file in @(Get-ChildItem -LiteralPath $source -File|Where-Object Extension -In @('.ps1','.psm1'))){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $directory $file.Name)}
 [IO.File]::WriteAllText((Join-Path $directory 'fixture.json'),'{}')
 [IO.File]::WriteAllText((Join-Path $directory 'fixture-mode.txt'),$case)
 $adapters=@'
# Test-only adapters. This block is never part of a shipped controller module.
$script:scopeCase=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixture-mode.txt'))
$script:scopeRequested=0;$script:scopeInspections=0;$script:scopeOwnerResolutions=0
$script:scopeMO2=[pscustomobject]@{id=700001;name='FixtureMO2';path=(Join-Path $PSScriptRoot 'ModOrganizer.exe');startTime='2026-10-01T00:00:00Z'}
$script:scopeGame=[pscustomobject]@{id=700002;name='FixtureGame';path=(Join-Path $PSScriptRoot 'SkyrimVR.exe');startTime='2026-10-01T00:01:00Z'}
$script:scopeOwned=[pscustomobject]@{path=(Join-Path $PSScriptRoot 'fixture-lock.json');sessionId='fixture-session';accessId='fixture-access';data=[pscustomobject]@{sessionId='fixture-session';sessionPath=$PSScriptRoot;status='game-running';profile='Fixture Profile';executable='Fixture SKSE';gameProcesses=@($script:scopeGame)}}
if(Test-Path -LiteralPath $script:scopeOwned.path){$script:scopeOwned.data=ConvertFrom-MO2JsonText ([IO.File]::ReadAllText($script:scopeOwned.path))}
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'request-evidence.json')){$script:scopeRequested=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'request-evidence.json') -Raw|ConvertFrom-Json).requests}
function Read-MO2ControlConfig {param($ConfigPath) [pscustomobject]@{mo2=[pscustomobject]@{root=$PSScriptRoot;executable=$script:scopeMO2.path;processNames=@('FixtureMO2');gameProcessNames=@('FixtureGame')}}}
function Get-MO2OwnedSession {param($Config,$SessionId) if($SessionId -cne 'fixture-session'){throw 'Foreign fixture session'};$script:scopeOwned}
function Get-MO2InspectionData {
 param($Config,$RequestedProfile,$RequestedExecutable)
 $script:scopeInspections++
 if($script:scopeRequested -gt 0 -and (($script:scopeCase -ceq 'post-inspection-failed' -and $script:scopeInspections -ge 3) -or ($script:scopeCase -ceq 'unlock-inspection-failed' -and $script:scopeInspections -ge 4))){throw 'Injected exact post-mutation inspection failure'}
 [pscustomobject]@{sessionLock=[pscustomobject]@{exists=$true;sessionId=$script:scopeOwned.sessionId;data=$script:scopeOwned.data};processes=[pscustomobject]@{mo2=@($script:scopeMO2);game=@(if($script:scopeRequested -eq 0 -or $script:scopeCase -ceq 'remaining-game'){$script:scopeGame})};rootBuilder=[pscustomobject]@{active=@(if($script:scopeRequested -gt 0 -and $script:scopeCase -ceq 'rootbuilder-incomplete'){[pscustomobject]@{path=(Join-Path $PSScriptRoot 'BuildData.json')}})}}
}
function Resolve-MO2OwnedProcessTarget {
 param($Config,$Owned,$Processes)
 $script:scopeOwnerResolutions++
 [pscustomobject]@{ok=(-not (($script:scopeCase -ceq 'owner-changed' -and $script:scopeOwnerResolutions -gt 1) -or ($script:scopeCase -ceq 'rootbuilder-incomplete' -and $script:scopeRequested -gt 0)));targets=@($script:scopeMO2);ownerPid=700001;reason='fixture-owner-changed'}
}
function Resolve-MO2RecordedGameProcessTargets {param($Recorded,$Current) [pscustomobject]@{ok=$true;targets=@($Current);reason='fixture-exact-recorded'}}
function Test-MO2InteractiveDesktop {$true}
function Invoke-MO2OwnedSessionMutation {
 param($Owned,$Action)
 if($script:scopeCase -ceq 'reconciliation-write-failed' -and $script:scopeRequested -gt 0){throw 'Injected reconciliation publication failure'}
 $copy=ConvertFrom-MO2JsonText ($Owned.data|ConvertTo-Json -Depth 50)
 $r=& $Action $copy
 if($script:scopeCase -ceq 'final-resolution-write-failed' -and $r.sessionData.gameTerminationReconciliation.resolved){throw 'Injected final resolution commit failure'}
 if($r.commit){$Owned.data=$r.sessionData;[IO.File]::WriteAllText($Owned.path,($Owned.data|ConvertTo-Json -Depth 50))}
 $r.result
}
function Invoke-MO2VerifiedGameTerminationSet {
 param($Config,$Owned,$Targets,[switch]$WhatIf)
 if($WhatIf){throw 'No fixture preview expected'}
 if($script:scopeCase -ceq 'primitive-refused'){return [pscustomobject]@{ok=$false;state='blocked';targets=@($Targets)}}
 $script:scopeRequested++
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'request-evidence.json'),(@{requests=$script:scopeRequested;targets=$Targets;physicalTermination=$false}|ConvertTo-Json -Depth 8))
 [pscustomobject]@{ok=$true;state='fixture-exact-request';targets=@($Targets);physicalTermination=$false}
}
function Set-MO2OwnedSessionStatus {param($Owned,$Status,$TimestampProperty) if($script:scopeCase -ceq 'status-write-failed'){throw 'Injected status publication failure'};$Owned.data.status=$Status}
function Write-MO2JsonAtomic {param($Path,$Value) if($script:scopeCase -ceq 'receipt-write-failed' -or ($script:scopeCase -ceq 'projection-write-failed' -and [IO.Path]::GetFileName($Path) -ceq 'mo2-terminate-game.json')){throw 'Injected terminal receipt publication failure'};[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40))}
function Invoke-WithMO2LeaseTransitionLock {param($LockPath,$Action,$ArgumentList) & $Action @ArgumentList}
function Assert-MO2OwnedSessionTransitionCurrent {param($Owned) $Owned}
function Stop-Process {throw 'Physical termination forbidden in fixture'}
function Get-Process {throw 'Live process query forbidden in fixture'}
function Get-MO2AutomationWindows {throw 'Live UI query forbidden in fixture'}
'@
 $modulePath=Join-Path $directory 'MO2Control.psm1'
 [IO.File]::AppendAllText($modulePath,[char]10+$adapters,[Text.UTF8Encoding]::new($false))
 try {
  $result=& (Join-Path $directory 'Invoke-MO2Control.ps1') terminate-game -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -TimeoutSeconds 1 -Compact -NoExit|ConvertFrom-Json -Depth 50
 }finally{
  # Each copied production entry imports its own named modules. Unload only
  # that exact fixture directory so a later broad suite gets one real module.
  foreach($m in @(Get-Module|Where-Object {$_.ModuleBase -ceq $directory})){Remove-Module -ModuleInfo $m -Force}
 }
 $requestPath=Join-Path $directory 'request-evidence.json'
 [IO.File]::WriteAllText((Join-Path $directory 'result.json'),($result|ConvertTo-Json -Depth 50))
 if($case -cin @('owner-changed','primitive-refused')){
  Check (-not $result.ok -and $result.state -ceq 'blocked') 'Changed owner must refuse before dispatch'
  Check (-not (Test-Path -LiteralPath $requestPath)) 'Changed owner must not terminate'
  continue
 }
 $request=Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json -Depth 10
 Check ($request.requests -eq 1 -and -not $request.physicalTermination) "$case must retain exactly one simulated request, never a physical termination"
 Check ($request.targets.Count -eq 1 -and $request.targets[0].id -eq 700002) "$case must preserve exact requested identity"
 if($ExpectLegacyFailure){
  Check (-not $result.ok -and $result.state -ceq 'tool-error' -and $result.errors[0] -match 'Get-MO2InspectionData') 'Old default closure must reproduce private-module inspection loss after dispatch'
  continue
 }
 if($case -ceq 'healthy'){
  Check ($result.ok -and $result.state -ceq 'game-terminated-rootbuilder-restored') "Real default callback must resolve private inspection after termination: $($result.errors -join ';')"
  Check ($result.data.rootBuilder.restored -and $result.data.rootBuilder.gameProcesses.Count -eq 0) 'Actual default Unlock read must preserve independent cleanup proof'
  Check ($result.data.terminatedProcesses[0].id -eq 700002 -and $result.data.mo2Retained) 'Successful exact request and retained MO2 proof must survive'
  Check (Test-Path -LiteralPath $result.data.receiptPath) 'Healthy terminal receipt must publish'
 }elseif($case -cin @('remaining-game','rootbuilder-incomplete')){
  $expectedState=if($case -ceq 'remaining-game'){'game-terminate-incomplete'}else{'rootbuilder-recovery-pending'}
  Check (-not $result.ok -and $result.state -ceq $expectedState) "$case must retain precise structured failure"
  Check ($result.data.mutationDispatched -and $result.data.recoveryRequired -and $result.data.noAutomaticRetry) "$case must expose accepted action/recovery/no-retry"
  Check ($result.data.gameTermination.ok -and $result.data.terminatedProcesses[0].id -eq 700002) "$case retains exact accepted result and targets"
  Check (-not $result.data.cleanupVerified -and $result.data.gameStopVerified -eq ($case -ceq 'rootbuilder-incomplete')) "$case keeps game stop and cleanup independently verified"
  Check ($result.data.receiptPublished -and $result.data.reconciliationPersisted) "$case publishes truthful pending outcome and receipt"
 }else{
  Check (-not $result.ok -and $result.state -ceq 'game-termination-reporting-failed') "$case must retain post-mutation reporting failure, not generic tool-error"
  Check ($result.data.mutationDispatched -and $result.data.recoveryRequired -eq ($case -cne 'projection-write-failed') -and $result.data.noAutomaticRetry) "$case must distinguish unresolved authority from postcommit projection failure"
  Check ($result.data.gameTermination.ok -and $result.data.terminatedProcesses[0].id -eq 700002) "$case must retain exact accepted simulated request evidence"
  $cleanup=$case -cin @('receipt-write-failed','status-write-failed','reconciliation-write-failed','final-resolution-write-failed','projection-write-failed')
  Check ($result.data.cleanupVerified -eq $cleanup) "$case must separate retained cleanup proof from failed publication"
  Check ($result.data.gameStopVerified -eq ($case -cne 'post-inspection-failed')) "$case must not infer game closure from request acceptance"
  Check ($result.data.receiptPublished -eq ($case -cin @('final-resolution-write-failed','projection-write-failed')) -and $result.errors[0] -like 'Injected*') "$case must retain primary reporting error and exact candidate publication"
 }
 if(-not $ExpectLegacyFailure){
  $retained=Get-Content -LiteralPath (Join-Path $directory 'fixture-lock.json') -Raw|ConvertFrom-Json -Depth 50
  Check ($retained.gameTerminationResult.ok -and $retained.gameTerminationTargets[0].id -eq 700002) "$case durably retains original acceptance and targets"
  Check ($retained.gameTerminationReconciliation.resolved -eq ($case -cin @('healthy','projection-write-failed'))) "$case unresolved request cannot become resolved by request acceptance"
  if($case -notin @('healthy','projection-write-failed')){
   $beforeHash=(Get-FileHash -LiteralPath (Join-Path $directory 'fixture-lock.json')).Hash
   try{
    $again=& (Join-Path $directory 'Invoke-MO2Control.ps1') terminate-game -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -TimeoutSeconds 1 -Compact -NoExit|ConvertFrom-Json -Depth 50
   }finally{foreach($m in @(Get-Module|Where-Object {$_.ModuleBase -ceq $directory})){Remove-Module -ModuleInfo $m -Force}}
   Check (-not $again.ok -and $again.state -ceq 'game-termination-recovery-required' -and -not $again.data.newTerminationDispatched) "$case fresh entry refuses replay and false already-stopped success"
   Check ($again.data.gameTermination.ok -and $again.data.terminatedProcesses[0].id -eq 700002 -and $again.data.priorReconciliation.resolved -eq $false) "$case fresh entry returns original durable evidence"
   Check ((Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json).requests -eq 1) "$case fresh entry never issues a second request"
   Check ((Get-FileHash -LiteralPath (Join-Path $directory 'fixture-lock.json')).Hash -ceq $beforeHash) "$case refusal preserves original journal bytes"
  }
  if($case -ceq 'projection-write-failed'){
   Check ($result.data.projectionFailed -and -not $result.data.publicReceiptPublished -and (Test-Path -LiteralPath $result.data.receiptPath)) 'Projection failure identifies existing proof and missing public receipt separately'
   $again=& (Join-Path $directory 'Invoke-MO2Control.ps1') terminate-game -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -TimeoutSeconds 1 -Compact -NoExit|ConvertFrom-Json -Depth 50
   Check ($again.ok -and -not $again.data.newTerminationDispatched) 'Projection failure must not reopen authoritative termination'
   Check ((Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json).requests -eq 1) 'Projection repair never terminates twice'
  }
  if($case -ceq 'final-resolution-write-failed'){
   $candidate=Get-Content -LiteralPath $result.data.receiptPath -Raw|ConvertFrom-Json
   Check ($result.data.receiptPublished -and -not $candidate.resolved -and $candidate.data.recoveryRequired) 'Published receipt path must name the actual explicitly unresolved proof candidate'
   Check (-not (Test-Path -LiteralPath (Join-Path $directory 'mo2-terminate-game.json'))) 'Final commit refusal never publishes success receipt'
   Check ($retained.status -cne 'game-terminated-rootbuilder-restored') 'Durable status cannot advertise premature success'
   foreach($command in @('status','release')){
    $blocked=& (Join-Path $directory 'Invoke-MO2Control.ps1') $command -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -Compact -NoExit|ConvertFrom-Json -Depth 50
    Check (-not $blocked.ok -and $blocked.state -ceq 'game-termination-recovery-required') "$command must retain unresolved session"
   }
   $ordinary=& (Join-Path $directory 'Invoke-MO2Control.ps1') status -ConfigPath (Join-Path $directory 'fixture.json') -Compact -NoExit|ConvertFrom-Json -Depth 50
   Check (-not $ordinary.ok -and $ordinary.state -ceq 'game-termination-recovery-required') 'Untargeted ordinary status also respects retained pending authority'
   $module=Get-Module|Where-Object {$_.Path -ceq $modulePath}
   $serialized=& $module {Invoke-MO2ReleaseTransition -Config (Read-MO2ControlConfig) -Owned $script:scopeOwned -SessionId fixture-session -SessionPath $PSScriptRoot}
   Check (-not $serialized.ok -and $serialized.state -ceq 'game-termination-recovery-required') 'Release guard rechecks under actual serialized transition'
   $resetRefused=& $module {try{Reset-MO2GameProcessStateForLaunch -Data $script:scopeOwned.data -LaunchAttemptId next -LaunchDispatchedUtc '2026-10-02T00:00:00Z' -PreLaunchGameProcesses @();$false}catch{$_.Exception.Message -like '*reconciliation*'}}
   Check $resetRefused 'Pending next-launch reset cannot clear accepted evidence'
   # Owner reporting reconciliation: same retained acceptance and independently
   # retained cleanup facts; never calls termination or unlock a second time.
   $repair=& $module {
    $script:scopeCase='healthy';$d=@{}
    foreach($p in $args[0].PSObject.Properties){if($p.Name -cnotin @('approval','configuration')){$d[$p.Name]=$p.Value}}
    Complete-MO2GameTerminationReporting -Config (Read-MO2ControlConfig) -Owned $script:scopeOwned -SessionId fixture-session -State game-terminated-rootbuilder-restored -Success $true -Data $d -Errors @()
   } $result.data
   Check ($repair.ok) "Exact owner reconciliation must complete original request: $($repair.errors -join ';')"
   Check ((Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json).requests -eq 1) 'Later reporting reconciliation never repeats mutation'
   $beforeHash=(Get-FileHash -LiteralPath (Join-Path $directory 'fixture-lock.json')).Hash
   $repeat=& $module {Complete-MO2GameTerminationReporting -Config (Read-MO2ControlConfig) -Owned $script:scopeOwned -SessionId fixture-session -State game-termination-reporting-failed -Success $false -Data @{} -Errors @('stale writer')}
   Check ($repeat.ok -and (Get-FileHash -LiteralPath (Join-Path $directory 'fixture-lock.json')).Hash -ceq $beforeHash) 'Stale reporter cannot unresolve or overwrite committed authority'
  }
  if($case -ceq 'healthy'){
   $original=[IO.File]::ReadAllText((Join-Path $directory 'fixture-lock.json'))
   $mutations=@('minimal','version','foreign-session','foreign-request','state','errors','unknown','missing-proof','missing-receipt','foreign-target','foreign-result','proof-digest','proof-length','proof-path','proof-file','unknown-data','bad-resolved','bad-rootbuilder','missing-accepted-id','partial-accepted')
   $mutations+=@($retained.gameTerminationReconciliation.PSObject.Properties.Name|ForEach-Object {'missing-record-'+$_})
   $dataKeys=@($retained.gameTerminationReconciliation.data.PSObject.Properties.Name)
   $mutations+=@($dataKeys|ForEach-Object {'missing-data-'+$_})
   $mutations+=@('mutationDispatched','gameStopVerified','cleanupVerified','mo2Retained','receiptPublished','noAutomaticRetry','reconciliationPersisted','recoveryRequired','remaining','reportingErrors')|ForEach-Object {'bad-data-'+$_}
   foreach($fault in $mutations){
    $lock=ConvertFrom-Json -InputObject $original -Depth 50 -DateKind String
    $r=$lock.gameTerminationReconciliation;$proofBytes=[IO.File]::ReadAllBytes($r.proof.path)
    switch -CaseSensitive ($fault){
     minimal {$lock.gameTerminationReconciliation=[pscustomobject]@{resolved=$true}}
     version {$r.schemaVersion='999'}
     foreign-session {$r.sessionId='foreign'}
     foreign-request {$r.requestId='00000000000000000000000000000000'}
     state {$r.state='game-termination-reporting-failed'}
     errors {$r.errors=@('failed')}
     unknown {$r|Add-Member extra $true}
     missing-proof {$r.PSObject.Properties.Remove('proof')}
     missing-receipt {$r.proof.path=(Join-Path $directory ('mo2-termination-proof-'+$r.requestId+'-'+('a'*64)+'.json'))}
     foreign-target {$r.data.terminatedProcesses[0].id=700003}
     foreign-result {$r.data.gameTermination.state='foreign'}
     proof-digest {$r.proof.sha256='a'*64}
     proof-length {$r.proof.bytes++}
     proof-path {$r.proof.path=$requestPath}
     proof-file {[IO.File]::WriteAllText($r.proof.path,'{}')}
     unknown-data {$r.data|Add-Member extra $true}
     bad-resolved {$r.resolved='true'}
     bad-rootbuilder {$r.data.rootBuilder.restored=$false}
     missing-accepted-id {$lock.PSObject.Properties.Remove('gameTerminationRequestId')}
     partial-accepted {$lock.PSObject.Properties.Remove('gameTerminationReconciliation');$lock.PSObject.Properties.Remove('gameTerminationTargets')}
     default {
      if($fault.StartsWith('missing-record-')){$r.PSObject.Properties.Remove($fault.Substring(15))}
      elseif($fault.StartsWith('missing-data-')){$r.data.PSObject.Properties.Remove($fault.Substring(13))}
      elseif($fault.StartsWith('bad-data-')){
       $key=$fault.Substring(9)
       $r.data.$key=if($key -cin @('remaining','reportingErrors')){@('unexpected')}elseif($key -ceq 'recoveryRequired'){$true}else{'true'}
      }
     }
    }
    [IO.File]::WriteAllText((Join-Path $directory 'fixture-lock.json'),($lock|ConvertTo-Json -Depth 50))
    try{
     foreach($command in @('terminate-game','status','release')){
      $refused=& (Join-Path $directory 'Invoke-MO2Control.ps1') $command -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -Compact -NoExit|ConvertFrom-Json -Depth 50
      Check (-not $refused.ok -and $refused.state -ceq 'game-termination-recovery-required') "$fault $command must fail closed, not generic tool error"
     }
     Check ((Get-Content -LiteralPath $requestPath -Raw|ConvertFrom-Json).requests -eq 1) "$fault never repeats termination"
    }finally{[IO.File]::WriteAllBytes($retained.gameTerminationReconciliation.proof.path,$proofBytes)}
   }
   [IO.File]::WriteAllText((Join-Path $directory 'fixture-lock.json'),$original)
   Import-Module $modulePath -Force
   $module=Get-Module|Where-Object {$_.Path -ceq $modulePath}
   $reset=& $module {Reset-MO2GameProcessStateForLaunch -Data $script:scopeOwned.data -LaunchAttemptId next -LaunchDispatchedUtc '2026-10-02T00:00:00Z' -PreLaunchGameProcesses @();$script:scopeOwned.data}
   Check ($reset.gameTerminationHistory.Count -eq 1 -and $reset.gameTerminationHistory[0].resolved) 'A genuinely new launch archives prior validated terminal authority'
   Check (-not $reset.PSObject.Properties['gameTerminationRequestId'] -and -not $reset.PSObject.Properties['gameTerminationReconciliation']) 'Only validated new-launch reset clears prior acceptance'
  }
  foreach($m in @(Get-Module|Where-Object {$_.ModuleBase -ceq $directory})){Remove-Module -ModuleInfo $m -Force}
 }
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$cases.Count;root=$root;legacyCausalReproduction=[bool]$ExpectLegacyFailure;physicalProcessOrUIOperation=$false;ownershipOSAdapters='mocked';productionEntryAndDefaultUnlock='unchanged copied source';liveQualified=$false}|ConvertTo-Json -Depth 6 -Compress
