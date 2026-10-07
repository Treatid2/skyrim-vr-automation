# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../MO2Control.psm1') -Force
$module=Get-Module MO2Control
$root=Join-Path $FixtureRoot ('launch-modal-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$result=& $module {
 param($root)
 $script:modalChecks=0
 function Check($ok,$label){if(-not $ok){throw $label};$script:modalChecks++}
 $names=@('Get-MO2OwnedSession','Invoke-MO2Validate','Get-MO2TaskWorkspaceIsolation','Get-MO2ProcessRecords','Get-MO2DispatchBoundChildEvidence','Get-MO2InspectionData','Get-MO2WindowSnapshot','Resolve-MO2OwnedProcessTarget','Get-MO2LaunchFailureEvidence','Invoke-MO2OwnedSessionMutation','Write-MO2OwnedSessionAtomic','Test-MO2InteractiveDesktop','Invoke-MO2RunButtonDispatch','Invoke-MO2OwnedProcessAction','Set-MO2OwnedSessionGameProcesses')
 $originals=@{};foreach($name in $names){$originals[$name]=(Get-Command $name).ScriptBlock}
 $cfg=[pscustomobject]@{mo2=[pscustomobject]@{root=$root;executable=(Join-Path $root 'FixtureMO2.exe');processNames=@('FixtureMO2');gameProcessNames=@('FixtureGame')};limits=[pscustomobject]@{}}
 $script:ModalOwner=[pscustomobject]@{id=111;name='FixtureMO2';path=$cfg.mo2.executable;startTime=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
 $script:ModalProcess=[pscustomobject]@{Id=111;StartTime=[datetime]::UtcNow.AddMinutes(-1);HasExited=$false;ExitCode=$null}
 $script:ModalProcess|Add-Member ScriptMethod Dispose {}
 try{
  Set-Item Function:script:Get-MO2OwnedSession {$script:ModalOwned}
  Set-Item Function:script:Invoke-MO2Validate {
   [pscustomobject]@{ok=$true;warnings=@();errors=@();data=[pscustomobject]@{executables=@([pscustomobject]@{title='Fixture SKSE';binary=(Join-Path $root 'sksevr_loader.exe');workingDirectory=$root});config=[pscustomobject]@{mo2Executable=$cfg.mo2.executable};processes=[pscustomobject]@{mo2=@(if($script:ModalRoute -ceq 'RunButton'){$script:ModalOwner});game=@()};sessionLock=[pscustomobject]@{ownerIdentityMatched=($script:ModalRoute -ceq 'RunButton')}}}
  }
  Set-Item Function:script:Get-MO2TaskWorkspaceIsolation {[pscustomobject]@{ok=$true}}
  Set-Item Function:script:Get-MO2ProcessRecords {param($Names)if($Names -contains 'FixtureMO2' -and ($script:ModalDispatched -or $script:ModalRoute -ceq 'RunButton')){@($script:ModalOwner)}else{@()}}
  Set-Item Function:script:Get-MO2DispatchBoundChildEvidence {@()}
  Set-Item Function:script:Get-MO2InspectionData {
   [pscustomobject]@{processes=[pscustomobject]@{mo2=@($script:ModalOwner);game=@()};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{exists=$true;status=$script:ModalOwned.data.status}}
  }
  Set-Item Function:script:Get-MO2WindowSnapshot {
   $script:ModalSnapshots++
   if($script:ModalMode -ceq 'changing' -and $script:ModalSnapshots -gt 1){$changed=$script:ModalWindows[0]|ConvertTo-Json|ConvertFrom-Json;$changed.dialogKind='failed-to-write-settings';@($changed)}else{@($script:ModalWindows)}
  }
  Set-Item Function:script:Resolve-MO2OwnedProcessTarget {[pscustomobject]@{ok=$true;adopted=$false;targets=@($script:ModalOwner);ownerPid=111}}
  Set-Item Function:script:Get-MO2LaunchFailureEvidence {$null}
  Set-Item Function:script:Invoke-MO2OwnedSessionMutation {param($Owned,$Action)$r=& $Action $Owned.data;$Owned.data=$r.sessionData;$Owned.data.generation++;$r.result}
  Set-Item Function:script:Write-MO2OwnedSessionAtomic {param($Owned,$Value)$Owned.data=$Value;$Owned.data.generation++}
  Set-Item Function:script:Test-MO2InteractiveDesktop {$true}
  Set-Item Function:script:Start-Process {$script:ModalDispatches++;$script:ModalDispatched=$true;$script:ModalProcess}
  Set-Item Function:script:Invoke-MO2RunButtonDispatch {
   param($Config,$Owned,$Validation,$LaunchStarted,$ReceiptPath,[switch]$PrepareOnly)
   if(-not $PrepareOnly){$script:ModalDispatches++;$script:ModalDispatched=$true}
   [pscustomobject]@{process=$script:ModalProcess;invocationError=$null}
  }
  Set-Item Function:script:Invoke-MO2OwnedProcessAction {param($Config,$Owned,$Process,$Action,$ArgumentList)& $Action @ArgumentList}
  Set-Item Function:script:Set-MO2OwnedSessionGameProcesses {$script:ModalGameCommits++;throw 'Unexpected game adoption'}
  foreach($route in @('CLI','RunButton')){
   foreach($mode in @('failed-to-run','failed-to-write-settings','hidden','foreign','unknown','multiple','changing','untyped-visible','missing-handle')){
    $script:ModalRoute=$route;$script:ModalMode=$mode;$script:ModalSnapshots=0;$script:ModalDispatches=0;$script:ModalDispatched=$false;$script:ModalGameCommits=0
    $session=Join-Path $root ($route+'-'+$mode);[IO.Directory]::CreateDirectory($session)|Out-Null
    $script:ModalOwned=[pscustomobject]@{path='fixture-lock';sessionId='fixture';accessId='fixture';data=[pscustomobject]@{status=$(if($route -ceq 'RunButton'){'mo2-open'}else{'prepared'});profile='Fixture Profile';executable='Fixture SKSE';sessionPath=$session;generation=0L;accessId='fixture';ownerPid=111;gameProcesses=@()}}
    $kind=if($mode -ceq 'failed-to-write-settings'){$mode}else{'failed-to-run'}
    $window=[pscustomobject]@{processId=111;handle=123L;visible=$true;dialogKind=$kind;automationId='ErrorDialog'}
    switch($mode){
     'hidden'{$window.visible=$false}
     'foreign'{$window.processId=222}
     'unknown'{$window.dialogKind='unknown'}
     'untyped-visible'{$window.visible='false'}
     'missing-handle'{$window.PSObject.Properties.Remove('handle')}
    }
    $script:ModalWindows=@($window);if($mode -ceq 'multiple'){$script:ModalWindows+=@($window)}
    $launch=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod $route -TimeoutSeconds 1
    $positive=$mode -cin @('failed-to-run','failed-to-write-settings')
    Check (-not $launch.ok -and $script:ModalDispatches -eq 1 -and $script:ModalGameCommits -eq 0) "$route $mode no success, replay or game adoption"
    $receiptPath=Join-Path $session 'mo2-launch-blocked-dialog.json'
    if($positive){
     Check ($launch.state -ceq 'launch-blocked-dialog' -and $launch.data.dialog.dialogKind -ceq $mode) "$route actual public dialog kind"
     $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json -Depth 30
     Check ($receipt.classification -ceq $mode -and $receipt.dialog.dialogKind -ceq $mode -and ($launch.errors -join ';') -cmatch [regex]::Escape($mode)) "$route consistent terminal receipt and error"
     $hash=(Get-FileHash $receiptPath).Hash
     $status=Invoke-MO2Status -Config $cfg -SessionId fixture
     Check (-not $status.ok -and $status.state -ceq 'launch-blocked-dialog' -and $status.data.controller.launchBlocker.windows[0].dialogKind -ceq $mode) "$route later status retains exact owned blocker"
     Check ((Get-FileHash $receiptPath).Hash -ceq $hash) "$route status does not rewrite original modal receipt"
     $again=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod $route -TimeoutSeconds 1
     Check (-not $again.ok -and $script:ModalDispatches -eq 1) "$route terminal blocker prevents second launch"
    }else{
     Check ($launch.state -ceq 'launch-failed' -and -not (Test-Path -LiteralPath $receiptPath)) "$route $mode refuses authoritative modal classification"
    }
   }
  }
  [pscustomobject]@{ok=$true;checks=$script:modalChecks;scope='actual synchronous CLI/RunButton launch and status with test-owned process/UI/lease mocks; no live dispatch/security changes'}
 }finally{
  foreach($name in $names){Set-Item ('Function:script:'+$name) $originals[$name]}
  Remove-Item Function:script:Start-Process -ErrorAction SilentlyContinue
 }
} $root
$result|ConvertTo-Json -Depth 8
