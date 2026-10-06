# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\MO2Control.psm1') -Force
$module=Get-Module MO2Control
$fixture=Join-Path $FixtureRoot ('deployed-loader-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$result=& $module {
 param($root)
 $checks=0
 function Check([bool]$Value,[string]$Name){if(-not $Value){throw ('FAIL: '+$Name)};$script:deployedChecks++}
 $script:deployedChecks=0
 $mods=Join-Path $root 'mods';$sourceRoot=Join-Path $mods 'Fixture Loader\root';$game=Join-Path $root 'game'
 $profileRoot=Join-Path $root 'profiles';$profile=Join-Path $profileRoot 'Fixture Profile'
 foreach($dir in @($sourceRoot,$game,$profile)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
 $binary=Join-Path $sourceRoot 'sksevr_loader.exe';$deployed=Join-Path $game 'sksevr_loader.exe'
 [IO.File]::WriteAllBytes($binary,[byte[]](1,2,3,4));[IO.File]::WriteAllBytes($deployed,[byte[]](1,2,3,4))
 [IO.File]::WriteAllText((Join-Path $profile 'modlist.txt'),'+Fixture Loader')
 $cfg=[pscustomobject]@{mo2=[pscustomobject]@{root=$root;modsDirectory=$mods;profilesDirectory=$profileRoot;executable=(Join-Path $root 'ModOrganizer.exe');processNames=@('FixtureMO2');gameProcessNames=@('FixtureGame')};limits=[pscustomobject]@{}}
 $entry=[pscustomobject]@{title='Fixture SKSE';binary=$binary;workingDirectory=$game}
 $validation=[pscustomobject]@{data=[pscustomobject]@{executables=@($entry)}}
 $attempt=[guid]::NewGuid().ToString('D')
 $boundary=New-MO2LaunchLogBoundary -Config $cfg -Validation $validation -AttemptId $attempt -Profile 'Fixture Profile' -Executable 'Fixture SKSE' -ArgumentLine 'fixture' -RetainedOwner $true
 Check ($boundary.available -and $null -ne $boundary.rootBinaryMapping) 'capture enabled exact mod/root mapping before dispatch'
 $proof=Get-MO2LaunchBinaryBinding -Boundary $boundary -ObservedBinary $deployed
 Check ($null -ne $proof -and $proof.basis -ceq 'root-relative-path-and-equal-deployed-bytes') 'prove actual deployed path and byte identity'
 Check ($proof.registeredBinary -ceq $binary -and $proof.actualBinary -ceq $deployed -and $proof.deployedBytes -eq 4) 'retain distinct registered and actual paths'
 $direct=Get-MO2LaunchBinaryBinding -Boundary $boundary -ObservedBinary $binary
 Check ($direct.basis -ceq 'exact-registered-binary') 'legacy exact registered identity unchanged'
 $legacy=[pscustomobject]@{binary=$binary}
 Check ($null -eq (Get-MO2LaunchBinaryBinding -Boundary $legacy -ObservedBinary $deployed)) 'historical boundary without mapping cannot acquire retrospective deployment proof'
 $foreignDir=Join-Path $root 'other-game';[IO.Directory]::CreateDirectory($foreignDir)|Out-Null
 $foreign=Join-Path $foreignDir 'sksevr_loader.exe';[IO.File]::WriteAllBytes($foreign,[byte[]](1,2,3,4))
 Check ($null -eq (Get-MO2LaunchBinaryBinding -Boundary $boundary -ObservedBinary $foreign)) 'same basename and bytes in different directory refused'
 [IO.File]::WriteAllBytes($deployed,[byte[]](4,3,2,1))
 Check ($null -eq (Get-MO2LaunchBinaryBinding -Boundary $boundary -ObservedBinary $deployed)) 'same target path different bytes refused'
 [IO.File]::WriteAllBytes($deployed,[byte[]](1,2,3,4,5))
 Check ($null -eq (Get-MO2LaunchBinaryBinding -Boundary $boundary -ObservedBinary $deployed)) 'different length refused'
 [IO.File]::WriteAllBytes($deployed,[byte[]](1,2,3,4))
 [IO.File]::WriteAllText((Join-Path $profile 'modlist.txt'),'-Fixture Loader')
 Check ($null -eq (Get-MO2LaunchRootBinaryMapping -Config $cfg -Entry $entry -Profile 'Fixture Profile')) 'disabled provider refused'
 [IO.File]::WriteAllText((Join-Path $profile 'modlist.txt'),'+Fixture Loader'+"`n"+'+Fixture Loader')
 Check ($null -eq (Get-MO2LaunchRootBinaryMapping -Config $cfg -Entry $entry -Profile 'Fixture Profile')) 'ambiguous provider refused'
 [IO.File]::WriteAllText((Join-Path $profile 'modlist.txt'),'+Fixture Loader')
 $entry.workingDirectory='relative'
 Check ($null -eq (Get-MO2LaunchRootBinaryMapping -Config $cfg -Entry $entry -Profile 'Fixture Profile')) 'relative destination refused'
 $entry.workingDirectory=$sourceRoot
 Check ($null -eq (Get-MO2LaunchRootBinaryMapping -Config $cfg -Entry $entry -Profile 'Fixture Profile')) 'mod source directory is not a deployed destination'
 $entry.workingDirectory=$game
 $originalSource=$entry.binary;$entry.binary=$deployed
 Check ($null -eq (Get-MO2LaunchRootBinaryMapping -Config $cfg -Entry $entry -Profile 'Fixture Profile')) 'unmanaged binary not upgraded to root mapping'
 $entry.binary=$originalSource
 $bad=[pscustomobject]@{binary=$binary;rootBinaryMapping=($boundary.rootBinaryMapping|ConvertTo-Json|ConvertFrom-Json)}
 $bad.rootBinaryMapping.registeredBinary=$foreign
 Check ($null -eq (Get-MO2LaunchBinaryBinding -Boundary $bad -ObservedBinary $deployed)) 'contradictory captured source refused'
 $oversized=Join-Path $game 'large.exe';$stream=[IO.File]::Create($oversized);$stream.SetLength(16777217);$stream.Dispose()
 $refused=$false;try {Get-MO2LaunchBinaryDigest $oversized|Out-Null}catch{$refused=$true}
 Check $refused 'bounded digest refuses over16MiB without hashing whole file'
 # Real classifier, synthetic retained-owner append and current attempt.
 [IO.Directory]::CreateDirectory((Join-Path $root 'logs'))|Out-Null
 $log=Join-Path $root 'logs\mo_interface.log';[IO.File]::WriteAllText($log,'baseline')
 $boundary=New-MO2LaunchLogBoundary -Config $cfg -Validation $validation -AttemptId $attempt -Profile 'Fixture Profile' -Executable 'Fixture SKSE' -ArgumentLine 'fixture' -RetainedOwner $true
 $dispatch=[datetime]::UtcNow.AddSeconds(-2);$stamp=$dispatch.AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss.fff')
 [IO.File]::AppendAllText($log,"`r`n[$stamp E] Error 5 ERROR_ACCESS_DENIED: denied (0x5)`r`n[$stamp E]  . binary: '$deployed'`r`n")
 $owner=[pscustomobject]@{id=111;name='FixtureMO2';path=$cfg.mo2.executable;startTime=$dispatch.AddSeconds(-10).ToString('o')}
 $owned=[pscustomobject]@{path='fixture-lock';sessionId='fixture';accessId='fixture';data=[pscustomobject]@{status='launching';profile='Fixture Profile';executable='Fixture SKSE';launchLogBoundary=$boundary;launchAttemptId=$attempt;launchDispatchedUtc=$dispatch.ToString('o');launchedUtc=$dispatch.AddSeconds(-100).ToString('o');sessionPath=$root}}
 $names=@('Resolve-MO2OwnedProcessTarget','Get-MO2OwnedSession','Get-MO2InspectionData','Get-MO2WindowSnapshot')
 $saved=@{};foreach($name in $names){$saved[$name]=(Get-Command $name).ScriptBlock}
 try{
  $script:deployedOwner=$owner;$script:deployedOwned=$owned;$script:deployedOwnerOK=$true;$script:deployedOwners=@($owner)
  $script:deployedWindows=@([pscustomobject]@{processId=111;visible=$true;dialogKind='failed-to-run';title='Cannot launch program';texts=@('Cannot start sksevr_loader.exe')})
  Set-Item Function:script:Resolve-MO2OwnedProcessTarget {[pscustomobject]@{ok=$script:deployedOwnerOK;targets=@($script:deployedOwner);adopted=$false;ownerPid=111}}
  $failure=Get-MO2LaunchFailureEvidence -Config $cfg -Owned $owned -MO2Processes @($owner) -GameProcesses @()
  Check ($null -ne $failure -and $failure.win32ErrorCode -eq 5 -and $failure.cause -ceq 'unassigned') 'classify current-attempt deployed denial without assigning mechanism'
  Check ($failure.binary -ceq $deployed -and $failure.registeredBinary -ceq $binary -and $failure.windowStableAtVerification) 'failure retains source/deployed binding and stable log proof'
  [IO.File]::WriteAllBytes($deployed,[byte[]](4,3,2,1))
  Check ($null -eq (Get-MO2LaunchFailureEvidence -Config $cfg -Owned $owned -MO2Processes @($owner) -GameProcesses @())) 'real classifier refuses wrong deployed content'
  Set-Item Function:script:Get-MO2OwnedSession {$script:deployedOwned}
  Set-Item Function:script:Get-MO2InspectionData {[pscustomobject]@{processes=[pscustomobject]@{mo2=$script:deployedOwners;game=@()};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{exists=$true;status='launching'}}}
  Set-Item Function:script:Get-MO2WindowSnapshot {$script:deployedWindows}
  # Wrong/missing detailed mapping must still report the current owned modal.
  $blocked=Invoke-MO2Status -Config $cfg -SessionId fixture
  Check (-not $blocked.ok -and $blocked.state -ceq 'launch-blocked-dialog' -and $null -eq $blocked.data.controller.launchFailure) 'unproven log cannot hide owned modal behind healthy status'
  Check ($null -ne $blocked.data.controller.launchBlocker -and -not $blocked.data.controller.launchPending -and $blocked.data.controller.launchBlocker.cause -ceq 'unassigned') 'explicit independent modal blocker, no Win32 or deployment inference'
  $owned.data.launchedUtc=[datetime]::UtcNow.ToString('o')
  $early=Invoke-MO2Status -Config $cfg -SessionId fixture
  Check (-not $early.ok -and $early.state -ceq 'launch-blocked-dialog' -and -not $early.data.controller.launchPending) 'known blocker outranks startup grace'
  $script:deployedWindows[0].processId=222
  $foreignStatus=Invoke-MO2Status -Config $cfg -SessionId fixture
  Check ($null -eq $foreignStatus.data.controller.launchBlocker) 'foreign process modal not attributed'
  $script:deployedWindows[0].processId=111;$script:deployedWindows[0].visible=$false
  Check ($null -eq (Invoke-MO2Status -Config $cfg -SessionId fixture).data.controller.launchBlocker) 'hidden modal not a current blocker'
  $script:deployedWindows[0].visible=$true;$script:deployedWindows[0].dialogKind='unknown'
  Check ($null -eq (Invoke-MO2Status -Config $cfg -SessionId fixture).data.controller.launchBlocker) 'unknown modal not relabelled as launch-error proof'
  $script:deployedWindows[0].dialogKind='failed-to-run';$script:deployedOwnerOK=$false
  Check ($null -eq (Invoke-MO2Status -Config $cfg -SessionId fixture).data.controller.launchBlocker) 'unproven owner not attributed'
  $script:deployedOwnerOK=$true;$script:deployedOwners=@($owner,$owner)
  Check ($null -eq (Invoke-MO2Status -Config $cfg -SessionId fixture).data.controller.launchBlocker) 'multiple MO2 owners not attributed'
 }finally{foreach($name in $names){Set-Item ("Function:script:"+$name) $saved[$name]}}
 [pscustomobject]@{ok=$true;tests=$script:deployedChecks;scope='offline source/deployed digest and actual public status; no live dispatch/security/ACL/elevation'}
} $fixture
$result|ConvertTo-Json -Depth 6 -Compress
