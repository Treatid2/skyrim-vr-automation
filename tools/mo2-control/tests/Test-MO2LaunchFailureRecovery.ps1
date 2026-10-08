[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot,[string]$ModulePath=(Join-Path $PSScriptRoot '../MO2Control.psm1'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$module=Get-Module MO2Control
$root=Join-Path $FixtureRoot ('launch-receipt-recovery-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'logs'))|Out-Null
$passes=[Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$passes.Add($Name)}
$results=& $module {
 param($root)
 $names=@('Get-MO2ProcessRecords','Resolve-MO2OwnedProcessTarget','Get-MO2InspectionData','Get-MO2WindowSnapshot','Write-MO2JsonAtomic')
 $originals=@{};foreach($n in $names){$originals[$n]=(Get-Command $n).ScriptBlock}
 $script:RecoveryWrite=$originals['Write-MO2JsonAtomic']
 $cfg=[pscustomobject]@{mo2=[pscustomobject]@{root=$root;executable=(Join-Path $root 'ModOrganizer.exe');processNames=@('ReceiptMO2');gameProcessNames=@('ReceiptGame')};limits=[pscustomobject]@{};session=[pscustomobject]@{lockFile=(Join-Path $root 'lock.json')}}
 $binary=Join-Path $root 'sksevr_loader.exe'
 $dispatch=[DateTime]::UtcNow.AddSeconds(-5)
 $script:RecoveryOwner=[pscustomobject]@{id=101;name='ReceiptMO2';path=$cfg.mo2.executable;startTime=$dispatch.AddMilliseconds(100).ToString('o')}
 $script:RecoveryGame=$false;$script:RecoveryFailPath=$null
 $log=Join-Path $root 'logs/mo_interface.log'
 $validation=[pscustomobject]@{data=[pscustomobject]@{executables=@([pscustomobject]@{title='Fixture SKSE';binary=$binary})}}
 $argumentLine='--profile "Fixture Profile" run --executable "Fixture SKSE"'
 $command='"'+$cfg.mo2.executable+'" '+$argumentLine
 $text="[$($dispatch.AddMilliseconds(200).ToString('yyyy-MM-dd HH:mm:ss.fff')) D] command line: '$command'`r`n[$($dispatch.AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss.fff')) E] Error 5 ERROR_ACCESS_DENIED: Access denied`r`n[$($dispatch.AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss.fff')) E]  . binary: '$binary'`r`n"
 function New-Fixture([string]$Case){
  $sessionPath=Join-Path $root $Case;[IO.Directory]::CreateDirectory($sessionPath)|Out-Null
  [IO.File]::WriteAllText($log,'baseline',[Text.UTF8Encoding]::new($false))
  $id=[guid]::NewGuid().ToString('D')
  $boundary=New-MO2LaunchLogBoundary -Config $cfg -Validation $validation -AttemptId $id -Profile 'Fixture Profile' -Executable 'Fixture SKSE' -ArgumentLine $argumentLine -RetainedOwner $false
  [IO.File]::WriteAllText($log,$text,[Text.UTF8Encoding]::new($false))
  $data=[pscustomobject]@{sessionId=$Case;accessId='fixture';leaseId='fixture';generation=3L;status='launching';profile='Fixture Profile';executable='Fixture SKSE';sessionPath=$sessionPath;launchAttemptId=$id;launchDispatchedUtc=$dispatch.ToString('o');launchLogBoundary=$boundary;gameProcesses=@()}
  & $script:RecoveryWrite -Path $cfg.session.lockFile -Value $data
  & $script:RecoveryWrite -Path (Join-Path $sessionPath 'session.json') -Value $data
  Get-MO2OwnedSession -Config $cfg -SessionId $Case
 }
 function Capture($Owned){Get-MO2LaunchFailureEvidence -Config $cfg -Owned $Owned -MO2Processes @($script:RecoveryOwner) -GameProcesses @()}
 function Status([string]$Session){Invoke-MO2Status -Config $cfg -SessionId $Session}
 $out=[ordered]@{}
 try{
  Set-Item Function:script:Get-MO2ProcessRecords {param($Names) if($Names -contains 'ReceiptMO2'){@($script:RecoveryOwner)}elseif($script:RecoveryGame){@([pscustomobject]@{id=222})}else{@()}}
  Set-Item Function:script:Resolve-MO2OwnedProcessTarget {[pscustomobject]@{ok=$true;adopted=$false;targets=@($script:RecoveryOwner);ownerPid=$script:RecoveryOwner.id}}
  Set-Item Function:script:Get-MO2InspectionData {[pscustomobject]@{processes=[pscustomobject]@{mo2=@($script:RecoveryOwner);game=@()};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{exists=$true;status='launching'}}}
  Set-Item Function:script:Get-MO2WindowSnapshot {@()}
  # Real transition lock, authoritative generation writer, manifest projection,
  # and public status. Inject only the deterministic atomic writer fault.
  Set-Item Function:script:Write-MO2JsonAtomic {
   param($Path,$Value,[switch]$CreateNew)
   if($Path -ceq $script:RecoveryFailPath){$script:RecoveryFailPath=$null;throw 'injected persistence failure'}
   & $script:RecoveryWrite -Path $Path -Value $Value -CreateNew:$CreateNew
  }
  $owned=New-Fixture 'interrupted'
  $script:RecoveryFailPath=$cfg.session.lockFile
  $out.interrupted=$false
  try{$null=Status 'interrupted'}catch{if($_.Exception.Message -notlike '*injected persistence failure*'){throw};$out.interrupted=$true}
  $durable=Get-MO2OwnedSession -Config $cfg -SessionId 'interrupted'
  $receiptPath=Join-Path $durable.data.sessionPath ('mo2-launch-failure.'+$durable.data.launchAttemptId+'.json')
  $receiptHash=(Get-FileHash -LiteralPath $receiptPath).Hash
  $first=Read-MO2LaunchFailureReceipt $receiptPath
  $out.receiptBeforeLock=$durable.data.status -ceq 'launching' -and $durable.data.generation -eq 3 -and $first.attemptId -ceq $durable.data.launchAttemptId
  Start-Sleep -Milliseconds 30
  $status=Status 'interrupted'
  $durable=Get-MO2OwnedSession -Config $cfg -SessionId 'interrupted'
  $manifest=ConvertFrom-MO2JsonText (Get-Content -LiteralPath (Join-Path $durable.data.sessionPath 'session.json') -Raw)
  $out.recovered=-not $status.ok -and $status.state -ceq 'launch-failed' -and $durable.data.generation -eq 4 -and $manifest.generation -eq 4
  $out.immutableReuse=(Get-FileHash -LiteralPath $receiptPath).Hash -ceq $receiptHash -and $durable.data.launchFailure.observedUtc -ceq $first.observedUtc
  $canonicalReceipt=ConvertTo-MO2LaunchEvidenceCanonicalValue $first | ConvertTo-Json -Depth 20 -Compress
  $canonicalPublic=ConvertTo-MO2LaunchEvidenceCanonicalValue $status.data.controller.launchFailure | ConvertTo-Json -Depth 20 -Compress
  $canonicalDurable=ConvertTo-MO2LaunchEvidenceCanonicalValue $durable.data.launchFailure | ConvertTo-Json -Depth 20 -Compress
  $out.firstPublicEvidenceIdentity=$canonicalPublic -ceq $canonicalReceipt -and $canonicalPublic -ceq $canonicalDurable
  $out.firstPublicOriginalTime=$status.data.controller.launchFailure.observedUtc -ceq $first.observedUtc
  $out.firstPublicReceiptIdentity=$status.data.controller.launchFailureReceiptPath -ceq $receiptPath -and (Get-FileHash -LiteralPath $receiptPath).Hash -ceq $receiptHash
  $repeat=Status 'interrupted'
  $out.repeatNoCommit=(Get-MO2OwnedSession -Config $cfg -SessionId 'interrupted').data.generation -eq 4
  $out.repeatPublicEvidenceIdentity=(ConvertTo-MO2LaunchEvidenceCanonicalValue $repeat.data.controller.launchFailure | ConvertTo-Json -Depth 20 -Compress) -ceq $canonicalPublic -and (Get-FileHash -LiteralPath $receiptPath).Hash -ceq $receiptHash
  foreach($field in @('sessionId','attemptId','binary','win32ErrorCode','message','windowSha256','byteOffset','byteLength','logFileIdentity','commandHeaderText','observedUtc','owner','logBoundary','extra')){
   $owned=New-Fixture ('conflict-'+$field);$failure=Capture $owned
   $path=Join-Path $owned.data.sessionPath ('mo2-launch-failure.'+$owned.data.launchAttemptId+'.json')
   $tampered=ConvertFrom-MO2JsonText ($failure|ConvertTo-Json -Depth 16)
   switch($field){win32ErrorCode{$tampered.$field=193}byteOffset{$tampered.$field=17}byteLength{$tampered.$field=19}observedUtc{$tampered.$field=[DateTime]::UtcNow.AddMinutes(1).ToString('o')}owner{$tampered.owner.startTime=[DateTime]::UtcNow.AddMinutes(1).ToString('o')}logBoundary{$tampered.logBoundary.profile='foreign'}extra{$tampered|Add-Member extra 'foreign'}default{$tampered.$field='foreign'}}
   & $script:RecoveryWrite -Path $path -Value $tampered -CreateNew
   $hash=(Get-FileHash -LiteralPath $path).Hash;$refused=$false
   try{$null=Status $owned.sessionId}catch{$refused=$_.Exception.Message -like '*custody conflict*'}
   $current=Get-MO2OwnedSession -Config $cfg -SessionId $owned.sessionId
   $out['conflict-'+$field]=$refused -and $current.data.generation -eq 3 -and $current.data.status -ceq 'launching' -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash
  }
  foreach($kind in @('malformed','overBudget')){
   $owned=New-Fixture ('invalid-'+$kind)
   $path=Join-Path $owned.data.sessionPath ('mo2-launch-failure.'+$owned.data.launchAttemptId+'.json')
   $payload=if($kind -ceq 'malformed'){'{unfinished'}else{'x'*1048577}
   [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
   $hash=(Get-FileHash -LiteralPath $path).Hash;$refused=$false
   try{$null=Status $owned.sessionId}catch{$refused=$_.Exception.Message -like '*custody conflict*'}
   $out['invalid-'+$kind]=$refused -and (Get-MO2OwnedSession -Config $cfg -SessionId $owned.sessionId).data.generation -eq 3 -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash
  }
  $owned=New-Fixture 'reordered';$proof=Capture $owned
  $reordered=[ordered]@{};foreach($p in @($proof.PSObject.Properties|Sort-Object Name -Descending)){$reordered[$p.Name]=$p.Value}
  $path=Join-Path $owned.data.sessionPath ('mo2-launch-failure.'+$owned.data.launchAttemptId+'.json')
  & $script:RecoveryWrite -Path $path -Value $reordered -CreateNew
  $hash=(Get-FileHash -LiteralPath $path).Hash;$r=Status 'reordered'
  $out.reorderedReuse=-not $r.ok -and $r.state -ceq 'launch-failed' -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash
  foreach($change in @('owner','game','attempt','window')){
   $owned=New-Fixture ('race-'+$change);$proof=Capture $owned
   $path=Join-Path $owned.data.sessionPath ('mo2-launch-failure.'+$owned.data.launchAttemptId+'.json')
   & $script:RecoveryWrite -Path $path -Value $proof -CreateNew
   $hash=(Get-FileHash -LiteralPath $path).Hash;$oldOwner=$script:RecoveryOwner
   switch($change){
    owner{$script:RecoveryOwner=ConvertFrom-MO2JsonText ($oldOwner|ConvertTo-Json);$script:RecoveryOwner.startTime=[DateTime]::UtcNow.AddMinutes(1).ToString('o')}
    game{$script:RecoveryGame=$true}
    attempt{$data=ConvertFrom-MO2JsonText ($owned.data|ConvertTo-Json -Depth 16);$data.launchAttemptId=[guid]::NewGuid().ToString('D');& $script:RecoveryWrite -Path $cfg.session.lockFile -Value $data}
    window{[IO.File]::AppendAllText($log,'changed',[Text.UTF8Encoding]::new($false))}
   }
   $refused=$false;try{$null=Set-MO2LaunchFailureEvidence -Config $cfg -Owned $owned -Failure $proof}catch{$refused=$true}
   $current=Get-MO2OwnedSession -Config $cfg -SessionId $owned.sessionId
   $out['race-'+$change]=$refused -and $current.data.generation -eq 3 -and $current.data.status -ceq 'launching' -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash
   $script:RecoveryOwner=$oldOwner;$script:RecoveryGame=$false
  }
  $owned=New-Fixture 'projection'
  $script:RecoveryFailPath=Join-Path $owned.data.sessionPath 'session.json'
  $out.projectionReported=$false
  try{$null=Status 'projection'}catch{$out.projectionReported=$_.Exception.Message -like '*authoritative MO2 ownership lock committed generation 4*projection failed*'}
  $current=Get-MO2OwnedSession -Config $cfg -SessionId 'projection'
  $out.projectionCommitted=$current.data.status -ceq 'launch-failed' -and $current.data.generation -eq 4 -and (Test-Path -LiteralPath $current.data.launchFailureReceiptPath)
  $r=Status 'projection';$out.projectionNoDuplicate=-not $r.ok -and $r.state -ceq 'launch-failed' -and (Get-MO2OwnedSession -Config $cfg -SessionId 'projection').data.generation -eq 4
 }finally{
  foreach($n in $names){Set-Item "Function:script:$n" $originals[$n]}
  Remove-Variable -Scope Script -Name RecoveryWrite,RecoveryOwner,RecoveryGame,RecoveryFailPath -ErrorAction SilentlyContinue
 }
 [pscustomobject]$out
} $root
foreach($p in $results.PSObject.Properties){Assert-Test ([bool]$p.Value) $p.Name}
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);fixturePath=$root;realGenerationTransition=$true;liveCalls=0}|ConvertTo-Json -Depth 6
