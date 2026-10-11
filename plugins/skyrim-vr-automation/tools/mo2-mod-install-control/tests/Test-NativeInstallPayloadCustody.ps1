# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../NativeInstallPlan.psm1') -Force
$root=Join-Path $FixtureRoot ('native-custody-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$dll=Join-Path $root 'sample.dll'; $pdb=Join-Path $root 'sample.pdb'
$planPath=Join-Path $root 'plan.json'; $receiptPath=Join-Path $root 'receipt.json'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllBytes($dll,[byte[]](1,2,3,4)); [IO.File]::WriteAllBytes($pdb,[byte[]](5,6,7))
$commit='a'*40; $lease='lease-20261009T140000Z-1234abcd'
$passed=0; $failures=[Collections.Generic.List[string]]::new(); $cases=[Collections.Generic.List[object]]::new()
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12 -Compress),$utf8)}
function MakePlan {
 $files=@(@{sourcePath=$dll;relativePath='SKSE/Plugins/sample.dll';bytes=4;sha256=(Hash $dll)},
          @{sourcePath=$pdb;relativePath='SKSE/Plugins/sample.pdb';bytes=3;sha256=(Hash $pdb)})
 Json $receiptPath @{commit=$commit;artifacts=@($files|ForEach-Object{@{path=$_.sourcePath;bytes=$_.bytes;sha256=$_.sha256}})}
 return @{schema='mo2.native-install-plan.1';installId=('b'*32);sourceCommit=$commit;profile="Human's Profile";
   leaseId=$lease;modName='Synthetic TEST';buildReceipt=@{path=$receiptPath;sha256=(Hash $receiptPath)};files=$files}
}
function InvokeArgs {return @{PlanPath=$planPath;ExpectedPlanSha256=(Hash $planPath);ExpectedSourceCommit=$commit;
 ExpectedProfile="Human's Profile";ExpectedLeaseId=$lease;TimeoutSeconds=10}}
function OpenCustody {$invoke=InvokeArgs;Open-VerifiedNativeInstallPayloadCustody @invoke}
function CanWrite([string]$Path){$s=$null;try{$s=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);return $true}catch{return $false}finally{if($s){$s.Dispose()}}}
function Check([string]$Name,[bool]$Value){$cases.Add(@{name=$Name;passed=$Value});if($Value){$script:passed++}else{$failures.Add($Name)}}
$plan=MakePlan; Json $planPath $plan
$before=@{};foreach($path in @($dll,$pdb,$planPath,$receiptPath)){$before[$path]=Hash $path}
$invoke=InvokeArgs;$priorSnapshot=Get-VerifiedNativeInstallPlan @invoke
Check 'preloaded admission-only helper has no custody type yet' ($priorSnapshot.ok -and
 $null -ne ('SkyrimVRAutomation.NativePlanFileProofV1' -as [type]) -and
 $null -eq ('SkyrimVRAutomation.NativePlanPayloadCustodyV1' -as [type]))
$custody=OpenCustody
try {
 Check 'exact disposable custody, two payloads, not disposed' ($custody -is [IDisposable] -and $custody.PayloadCount -eq 2 -and -not $custody.IsDisposed)
 $validation=$custody.ValidationJson|ConvertFrom-Json
 Check 'immutable snapshot is not deployment or authority' ($validation.ok -and -not $validation.mutationAuthorized -and -not $validation.deploymentPerformed -and $validation.requiresFreshDeploymentValidation)
 Check 'DLL write denied while custody retained' (-not (CanWrite $dll))
 Check 'PDB write denied while custody retained' (-not (CanWrite $pdb))
 foreach($path in @($dll,$pdb)) {
  $denied=$false;try{[IO.File]::Move($path,$path+'.moved')}catch{$denied=$true}
  Check ('rename denied '+[IO.Path]::GetFileName($path)) $denied
 }
 $changed=$false;try{$custody.ValidationJson='{}';$changed=$true}catch{}
 Check 'captured validation has no mutable setter' (-not $changed)
 $validation.files[0].sha256='0'*64
 Check 'caller projection cannot change captured immutable validation' (($custody.ValidationJson|ConvertFrom-Json).files[0].sha256 -ceq $plan.files[0].sha256)
 Check 'no payload streams/copy/callback exposed' (@($custody.PSObject.Properties|Where-Object Name -match 'stream|handle').Count -eq 0 -and $null -eq $custody.PSObject.Methods['CopyTo'])
}finally{$custody.Dispose()}
$custody.Dispose()
Check 'explicit disposal is idempotent and releases both files' ($custody.IsDisposed -and (CanWrite $dll) -and (CanWrite $pdb))
foreach($path in $before.Keys){Check ('read only unchanged '+[IO.Path]::GetFileName($path)) ((Hash $path) -ceq $before[$path])}
$invoke=InvokeArgs;$snapshot=Get-VerifiedNativeInstallPlan @invoke
Check 'ordinary snapshot leaves payloads writable' ($snapshot.ok -and (CanWrite $dll) -and (CanWrite $pdb))
$plan=MakePlan;$plan.files=@($plan.files[0]);Json $planPath $plan
$single=OpenCustody
try{Check 'single DLL custody retains one exact file' ($single.PayloadCount -eq 1 -and -not (CanWrite $dll) -and (CanWrite $pdb))}finally{$single.Dispose()}
foreach($case in @('bad-plan-hash','second-payload-bad-hash','orphan-pdb','extra-field','foreign-profile')){
 $plan=MakePlan
 switch($case){
  second-payload-bad-hash {$plan.files[1].sha256='0'*64; $r=Get-Content $receiptPath -Raw|ConvertFrom-Json -AsHashtable;$r.artifacts[1].sha256='0'*64;Json $receiptPath $r;$plan.buildReceipt.sha256=Hash $receiptPath}
  orphan-pdb {$plan.files=@($plan.files[1])}
  extra-field {$plan.privateCapability='rejected'}
  foreign-profile {$plan.profile='Foreign'}
 }
 Json $planPath $plan;$invoke=InvokeArgs;if($case -eq 'bad-plan-hash'){$invoke.ExpectedPlanSha256='0'*64}
 $refused=$false; $unexpected=$null
 try{$unexpected=Open-VerifiedNativeInstallPayloadCustody @invoke}catch{$refused=$true}finally{if($unexpected){$unexpected.Dispose()}}
 Check ('refusal and all handles released '+$case) ($refused -and (CanWrite $dll) -and (CanWrite $pdb))
}
$module=Get-Module NativeInstallPlan
& $module { $script:originalNamespace=${function:Get-NativePlanNamespaceData};$script:originalOpened=${function:Get-NativePlanOpenedFileData};$script:originalDeadline=${function:Assert-NativePlanDeadline} }
try {
 $plan=MakePlan;Json $planPath $plan
 & $module {param($first,$second)
  $script:first=$first;$script:second=$second;$script:firstWasHeld=$false
  function script:Get-NativePlanOpenedFileData([IO.FileStream]$Stream){
   if($Stream.Name -ieq $script:second){$s=$null;try{$s=[IO.File]::Open($script:first,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{$script:firstWasHeld=$true}finally{if($s){$s.Dispose()}}}
   return & $script:originalOpened $Stream
  }
 } $dll $pdb
 $custody=OpenCustody
 try{Check 'first source remains pinned while second is verified' (& $module {$script:firstWasHeld})}finally{$custody.Dispose()}
 & $module {Set-Item Function:script:Get-NativePlanOpenedFileData $script:originalOpened}
 & $module {param($path)
  $script:driftPath=$path;$script:driftCalls=0
  function script:Get-NativePlanNamespaceData([string]$Path){
   if($Path -ieq $script:driftPath){$script:driftCalls++;if($script:driftCalls -ge 5){return @{driveType=3;device='\Device\HarddiskVolume999999'}}}
   return & $script:originalNamespace $Path
  }
 } $dll
 $refused=$false;$unexpected=$null
 try{$unexpected=OpenCustody}catch{$refused=$_.Exception.Message -match 'namespace'}finally{if($unexpected){$unexpected.Dispose()}}
 Check 'whole-set final namespace drift refused, every handle closed' ($refused -and (CanWrite $dll) -and (CanWrite $pdb))
 & $module {Set-Item Function:script:Get-NativePlanNamespaceData $script:originalNamespace}
 & $module {param($path)
  $script:identityPath=$path;$script:identityReads=0
  function script:Get-NativePlanOpenedFileData([IO.FileStream]$Stream){
   $data=& $script:originalOpened $Stream
   if($Stream.Name -ieq $script:identityPath){$script:identityReads++;if($script:identityReads -ge 3){$data.identity='0000000000000000:00000000000000000000000000000000'}}
   return $data
  }
 } $dll
 $refused=$false;$unexpected=$null
 try{$unexpected=OpenCustody}catch{$refused=$_.Exception.Message -match 'custody identity'}finally{if($unexpected){$unexpected.Dispose()}}
 Check 'whole-set final opened identity drift refused, every handle closed' ($refused -and (CanWrite $dll) -and (CanWrite $pdb))
 & $module {Set-Item Function:script:Get-NativePlanOpenedFileData $script:originalOpened}
 $writer=[IO.File]::Open($pdb,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
 try{
  $refused=$false;$unexpected=$null
  try{$unexpected=OpenCustody}catch{$refused=$true}finally{if($unexpected){$unexpected.Dispose()}}
  Check 'existing second-file writer prevents custody and closes first source' ($refused -and (CanWrite $dll))
 }finally{$writer.Dispose()}
 Check 'writer refusal leaves no second-file read custody' (CanWrite $pdb)
 & $module {param($path)
  $script:lastPath=$path;$script:lastReads=0;$script:expired=$false
  function script:Get-NativePlanOpenedFileData([IO.FileStream]$Stream){
   $data=& $script:originalOpened $Stream
   if($Stream.Name -ieq $script:lastPath){$script:lastReads++;if($script:lastReads -ge 2){$script:expired=$true}}
   return $data
  }
  function script:Assert-NativePlanDeadline([datetime]$DeadlineUtc){if($script:expired){throw 'Native plan validation deadline exceeded (synthetic final-boundary).'};& $script:originalDeadline $DeadlineUtc}
 } $pdb
 $refused=$false;$unexpected=$null
 try{$unexpected=OpenCustody}catch{$refused=$_.Exception.Message -match 'deadline'}finally{if($unexpected){$unexpected.Dispose()}}
 Check 'final-boundary deadline refuses and closes entire set' ($refused -and (CanWrite $dll) -and (CanWrite $pdb))
}finally{
 & $module {Set-Item Function:script:Get-NativePlanNamespaceData $script:originalNamespace;Set-Item Function:script:Get-NativePlanOpenedFileData $script:originalOpened;Set-Item Function:script:Assert-NativePlanDeadline $script:originalDeadline}
}
@{ok=$failures.Count -eq 0;passed=$passed;failed=$failures.Count;failures=$failures.ToArray();cases=$cases.ToArray();fixtureRoot=$root;
 syntheticPayloads=$true;liveRuntimeUsed=$false;realLeaseUsed=$false;publicationImplemented=$false}|ConvertTo-Json -Depth 12
if($failures.Count){exit 1}
