# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[switch]$ExpectLegacyFailure,[string]$ControllerSource)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap { Write-Host $_.ScriptStackTrace; break }
$source=Split-Path -Parent $PSScriptRoot
if($ControllerSource){$source=[IO.Path]::GetFullPath($ControllerSource)}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('dialog-scope-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$checks=0
function Check([bool]$Condition,[string]$Label){if(-not $Condition){throw $Label};$script:checks++}
[object[]]$cases=if($ExpectLegacyFailure){@('healthy')}else{@('healthy','window-close','stale-generation','changed-path','changed-start','exited-binding','invalid-handle','unknown-modal','action-denied','remaining-dialog')}
foreach($case in $cases){
 $directory=Join-Path $root $case
 [IO.Directory]::CreateDirectory($directory)|Out-Null
 foreach($file in @(Get-ChildItem -LiteralPath $source -File|Where-Object Extension -In @('.ps1','.psm1'))){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $directory $file.Name)}
 [IO.File]::WriteAllText((Join-Path $directory 'fixture.json'),'{}')
 [IO.File]::WriteAllText((Join-Path $directory 'fixture-mode.txt'),$case)
 # Append only OS/UI/storage adapters to the private copied controller.
 # Keep the production entry, cleanup/default callbacks, OwnedProcessAction,
 # process identity resolver and exact-target checks unchanged. No injected
 # OwnedAction/BindingFactory/WindowFactory bypass of the reported scope bug.
 $adapters=@'
$script:dialogCase=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixture-mode.txt'))
$script:dialogInvokes=0;$script:dialogCleared=$false;$script:dialogChecks=0
$script:dialogOwner=[pscustomobject]@{id=700001;name='FixtureMO2';path=(Join-Path $PSScriptRoot 'ModOrganizer.exe');startTime='2026-10-01T00:00:00.0000000Z'}
$script:dialogOwned=[pscustomobject]@{path=(Join-Path $PSScriptRoot 'fixture-lock.json');sessionId='fixture-session';accessId='fixture-access';data=[pscustomobject]@{generation=1L;sessionPath=$PSScriptRoot;status='launch-blocked-dialog';profile='Fixture Profile';executable='Fixture SKSE';ownerPid=700001;processPath=$script:dialogOwner.path;processStartTime=$script:dialogOwner.startTime;gameProcesses=@()}}
$script:dialogProcess=[pscustomobject]@{Id=700001;ProcessName='FixtureMO2';Path=$script:dialogOwner.path;StartTime=[datetime]::Parse($script:dialogOwner.startTime).ToUniversalTime();HasExited=$false;SafeHandle=[pscustomobject]@{IsInvalid=$false;IsClosed=$false}}
$script:dialogProcess|Add-Member ScriptMethod Refresh {
 if($script:dialogCase -ceq 'changed-path'){$this.Path=Join-Path $PSScriptRoot 'ForeignMO2.exe'}
 if($script:dialogCase -ceq 'changed-start'){$this.StartTime=$this.StartTime.AddSeconds(1)}
 if($script:dialogCase -ceq 'exited-binding'){$this.HasExited=$true}
 if($script:dialogCase -ceq 'invalid-handle'){$this.SafeHandle.IsClosed=$true}
}
$script:dialogProcess|Add-Member ScriptMethod Dispose {}
$script:dialogWindow=[pscustomobject]@{Current=[pscustomobject]@{Name='Failed to run';AutomationId='TaskDialog';NativeWindowHandle=123L}}
if($script:dialogCase -ceq 'unknown-modal'){$script:dialogWindow.Current.Name='Unknown request'}
function Read-MO2ControlConfig {param($ConfigPath) [pscustomobject]@{mo2=[pscustomobject]@{root=$PSScriptRoot;executable=$script:dialogOwner.path;processNames=@('FixtureMO2');gameProcessNames=@('FixtureGame')}}}
function Get-MO2OwnedSession {param($Config,$SessionId)if($SessionId -cne 'fixture-session'){throw 'Foreign fixture session'};$script:dialogOwned}
function Test-MO2InteractiveDesktop {$true}
function Get-MO2InspectionData {param($Config,$RequestedProfile,$RequestedExecutable)[pscustomobject]@{processes=[pscustomobject]@{mo2=@($script:dialogOwner);game=@()};rootBuilder=[pscustomobject]@{active=@()}}}
function Invoke-MO2OwnedGameCloseRequest {param($Config,$Owned)[pscustomobject]@{ok=$true;targets=@();physicalAction=$false}}
function Get-Process {param($Id)if($Id -ne 700001){throw 'Unexpected live process lookup'};$script:dialogProcess}
function Start-Sleep {param($Milliseconds)}
function Wait-MO2RetainedProcessStability {param($Config,$Owned,$InitialInspection)[pscustomobject]@{stable=$true;finalInspection=$InitialInspection;physicalObservation=$false}}
function Get-MO2WindowSnapshot {
 param($Processes)
 if(-not $script:dialogCleared){[pscustomobject]@{processId=700001;handle=123L;visible=$true;automationId='TaskDialog';dialogKind=$(if($script:dialogCase -ceq 'unknown-modal'){'unknown'}else{'failed-to-run'})}}
}
function Get-MO2AutomationWindows {param($ProcessId)if($script:dialogCleared -or ($script:dialogCase -ceq 'remaining-dialog' -and $script:dialogInvokes -gt 0)){return};@($script:dialogWindow)}
function Get-MO2WindowTextElements {param($Window)if($script:dialogCase -ceq 'unknown-modal'){@('Unknown application request')}else{@('Failed to run sksevr_loader.exe')}}
function Get-MO2NamedButtons {param($Window,$Name)if($script:dialogCase -cne 'window-close' -and $Name -ceq 'OK'){[pscustomobject]@{Current=[pscustomobject]@{Name='OK';ProcessId=700001}}}}
function Invoke-WithMO2LeaseTransitionLock {param($LockPath,$Action,$ArgumentList)& $Action @ArgumentList}
function Assert-MO2OwnedSessionTransitionCurrent {
 param($Owned)
 $script:dialogChecks++
 if($script:dialogCase -ceq 'stale-generation'){throw 'The lease transition is stale.'}
 [pscustomobject]@{data=$Owned.data}
}
function Invoke-MO2AutomationButton {
 param($Button,$ExpectedName)
 if($script:dialogCase -ceq 'action-denied'){throw 'Injected UI access denied'}
 if($ExpectedName -cne 'OK'){throw 'Unexpected fixture control'}
 $script:dialogInvokes++;if($script:dialogCase -cne 'remaining-dialog'){$script:dialogCleared=$true}
 $true
}
function Request-MO2AutomationWindowClose {param($Window)$script:dialogInvokes++;$script:dialogCleared=$true;$true}
function Write-MO2OwnedSessionAtomic {
 param($Owned,$Value)
 [IO.File]::WriteAllText($Owned.path,($Value|ConvertTo-Json -Depth 30))
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'adapter-evidence.json'),(@{actions=$script:dialogInvokes;authorityChecks=$script:dialogChecks;cleared=$script:dialogCleared;physicalUI=$false}|ConvertTo-Json))
}
function Start-Process {throw 'Physical process launch forbidden'}
function Stop-Process {throw 'Physical process termination forbidden'}
'@
 [IO.File]::AppendAllText((Join-Path $directory 'MO2Control.psm1'),[char]10+$adapters,[Text.UTF8Encoding]::new($false))
 try{
  $result=& (Join-Path $directory 'Invoke-MO2Control.ps1') stop-game -SessionId fixture-session -ConfigPath (Join-Path $directory 'fixture.json') -TimeoutSeconds 1 -Compact -NoExit|ConvertFrom-Json -Depth 50
 }finally{foreach($m in @(Get-Module|Where-Object {$_.ModuleBase -ceq $directory})){Remove-Module -ModuleInfo $m -Force}}
 [IO.File]::WriteAllText((Join-Path $directory 'result.json'),($result|ConvertTo-Json -Depth 50))
 $evidence=Get-Content -LiteralPath (Join-Path $directory 'adapter-evidence.json') -Raw|ConvertFrom-Json
 Check (-not $evidence.physicalUI -and $result.data.mo2Retained -and -not $result.data.forceTermination) "$case retained owner, no physical mutation"
 $cleanup=$result.data.retainedDialogCleanup
 if($ExpectLegacyFailure){
  Check (-not $result.ok -and $evidence.actions -eq 0 -and $cleanup.blockedReason -match 'Invoke-MO2OwnedProcessAction.*not recognized') 'Original closure reproduces exact private function loss'
  continue
 }
 if($case -cin @('healthy','window-close')){
  Check ($result.ok -and $result.state -ceq 'game-stopped' -and $cleanup.cleared) "$case default callback succeeds through copied entry"
  Check ($evidence.actions -eq 1 -and $evidence.authorityChecks -eq 1) "$case exactly one revalidated simulated action"
  Check ($cleanup.actions.Count -eq 1 -and $cleanup.actions[0].accepted -and $cleanup.actions[0].processId -eq 700001) "$case exact action receipt"
 }else{
  Check (-not $result.ok -and $result.state -ceq 'game-stopped-needs-attention' -and ($case -ceq 'unknown-modal' -or -not $cleanup.cleared)) "$case preserves structured refusal"
  if($case -ceq 'unknown-modal'){Check ($cleanup.needsAttention.Count -eq 1) 'Unknown modal remains attended and untouched, even when no known failed-to-run dialog remains'}
  if($case -ceq 'remaining-dialog'){Check ($evidence.actions -gt 0 -and $cleanup.remainingKnown.Count -eq 1) 'Accepted action is not cleared-dialog proof'}else{Check ($evidence.actions -eq 0) "$case zero action before authority/identity/UI refusal"}
  if($case -ceq 'stale-generation'){Check ($cleanup.blockedReason -ceq 'stale-session-generation') 'Stale generation classification preserved'}
 }
 Check (Test-Path -LiteralPath (Join-Path $directory 'mo2-retained-dialog-cleanup.json')) "$case original cleanup evidence retained"
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$cases.Count;legacyCausalReproduction=[bool]$ExpectLegacyFailure;physicalProcessOrUIOperation=$false;scope='copied public stop-game entry, real default callbacks and OwnedProcessAction/identity resolver, synthetic OS/UI/storage boundaries';liveQualified=$false}|ConvertTo-Json -Depth 8 -Compress
