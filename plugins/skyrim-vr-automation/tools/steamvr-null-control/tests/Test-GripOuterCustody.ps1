# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$BoundedProcessPath,[Parameter(Mandatory)][string]$BoundedProcessSha256)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'GripLifecycle.Common.ps1')
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'Fresh isolated custody fixture root required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$root=Join-Path $EvidenceDirectory 'same-absent-root'
$gateName='Local\CodexGripRace-'+[guid]::NewGuid().ToString('N')
$gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$gateName)
$children=[Collections.Generic.List[object]]::new()
try{
    for($i=0;$i -lt 2;$i++){
        $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'GripLifecycle.Contender.ps1'),'-GateName',$gateName,'-EvidenceDirectory',$root,'-BoundedProcessPath',$BoundedProcessPath,'-BoundedProcessSha256',$BoundedProcessSha256)){$info.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        if(-not $process.Start()){throw 'Contender did not launch'}
        $children.Add(@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync();creationFileTime=$process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()})
    }
    [void]$gate.Set()
    foreach($child in $children){if(-not $child.process.WaitForExit(50000)){throw 'Contender exceeded fixed fifty-second test deadline'}}
    $winner=@($children | Where-Object {$_.process.ExitCode -eq 0})
    $loser=@($children | Where-Object {$_.process.ExitCode -ne 0})
    if($winner.Count -ne 1 -or $loser.Count -ne 1){throw 'Exactly one coordinator must acquire and complete the session'}
    $report=Read-GripJson (Join-Path $root 'session-result.json')
    $claim=Read-GripJson ($root+'.outer-session.json')
    if($claim.creatorPid -ne $winner[0].process.Id -or $claim.creatorFileTime -cne $winner[0].creationFileTime -or -not $report.cleanHandoffVerified -or $null -ne $report.firstFailure){throw 'Winner did not retain exact independent custody, normal assay and cleanup'}
    $loserOutput=$loser[0].stdout.GetAwaiter().GetResult()
    if(-not [string]::IsNullOrWhiteSpace($loserOutput)){throw 'Losing admission must not launch a stage or emit a lifecycle envelope'}
    foreach($file in Get-ChildItem -LiteralPath $root -File -Filter '*.json'){
        # Raw fixture launcher records are independently process-bound; every
        # lifecycle record created through Save carries the outer identity.
        if($file.Name -eq 'fixture-child.json'){continue}
        Assert-GripOuterRecord (Read-GripJson $file.FullName) $claim
    }
    $worker=Join-Path (Split-Path -Parent $PSScriptRoot) 'GripLifecycle.Worker.ps1'
    $deadline=(Get-GripTick)+[uint64]10000
    $foreignRejected=$false
    try{& $worker -Stage recovery -Root $root -OuterNonce ([guid]::NewGuid().ToString('N')) -OuterCreatorPid $PID -OuterCreatorFileTime (Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -DeadlineTickMs $deadline -PositiveDeadlineTickMs $deadline -CommonDeadlineTickMs $deadline}catch{$foreignRejected=$true}
    if(-not $foreignRejected){throw 'Foreign worker adopted winner ownership after completed claim'}
    $staleRejected=$false
    try{& $worker -Stage recovery -Root $root -OuterNonce $claim.nonce -OuterCreatorPid $claim.creatorPid -OuterCreatorFileTime $claim.creatorFileTime -DeadlineTickMs $deadline -PositiveDeadlineTickMs $deadline -CommonDeadlineTickMs $deadline}catch{$staleRejected=$true}
    if(-not $staleRejected){throw 'Dead coordinator identity implicitly admitted recovery'}
    $receipt=@{ok=$true;exactlyOneClaim=$true;winnerCreatorPid=$claim.creatorPid;loserCreatorPid=$loser[0].process.Id;loserHasNoLifecycleEnvelope=$true;allLifecycleRecordsWinnerBound=$true;winnerCleanupVerified=$true;foreignRecoveryRejected=$true;staleCreatorRecoveryRejected=$true;runtimeResponsesSimulated=$true;liveQualified=$false}
    Write-GripJson (Join-Path $EvidenceDirectory 'test-receipt.json') $receipt ((Get-GripTick)+[uint64]10000)
    $receipt | ConvertTo-Json -Compress
}finally{
    foreach($child in $children){if(-not $child.process.HasExited){$child.process.Kill($true);[void]$child.process.WaitForExit(5000)};$child.process.Dispose()}
    $gate.Dispose()
}
