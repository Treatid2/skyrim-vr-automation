# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([string]$RetainedExecPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
function Clone($p){$p|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30}
$execArgs=@{action='exec';command='getini fVRScale:VR';capture=$true}
$exec=[pscustomobject]@{command=$execArgs.command;completed=$true;queued=$false;capturing=$true;windowId=1}
$readArgs=@{action='read';windowId=1;maxLines=200}
$diag=[pscustomobject]@{
    consoleLogNull=$false;bufferEmpty=$true;bufferLen=0;bufferHasBegin=$false
    lastMessage='Script command "DVBCAPEND" not found.';lastMessageHasBegin=$false
    consoleMenuExists=$true;consoleMenuOpen=$false;consoleMode=$false
    printHooked=$true;printLines=3;printDropped=0;printPayloadLines=1;printPayloadBytes=34
    printLoss=[pscustomobject]@{lineLimit=0;byteLimit=0;format=0;allocation=0;oversize=0}
    ringLines=0;samples=0;ticks=1;engineFrames=1;timedOut=$false
}
$read=[pscustomobject]@{windowId=1;markersFound=$true;sawBegin=$true;sawEnd=$true
    count=1;lines=@('INISetting fVRScale:VR >> 79.06');source='print';lossPossible=$false;diag=$diag}
function ExecStatus($p){Get-DevBenchCallSemanticStatus -ToolName console -Arguments $execArgs -Content @($p)}
function ReadStatus($p,$argsMap=$readArgs){Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($p)}
foreach($id in @(1,[long]::MaxValue,[uint64]::MaxValue)){
    $e=Clone $exec;$e.windowId=$id;$s=ExecStatus $e
    Check ($s.ok -and $s.qualifiedExecution.windowId -eq $id -and -not $s.outputQualified -and -not $s.desiredEffectVerified) 'exact modern exec ID and execution-only'
    $p=Clone $read;$p.windowId=$id;$a=$readArgs.Clone();$a.windowId=$id;$s=ReadStatus $p $a
    Check ($s.ok -and $s.windowMatched -and $s.qualifiedConsoleOutput.windowId -eq $id -and -not $s.desiredEffectVerified) 'exact guarded read ID'
}
foreach($id in @($null,0,-1,$true,'1',1.0,1.5,[decimal]1,[bigint]1)){
    $e=Clone $exec;$e.windowId=$id;Check (-not (ExecStatus $e).ok) 'malformed exec window ID'
    $p=Clone $read;$p.windowId=$id;Check (-not (ReadStatus $p).ok) 'malformed read window ID'
    $a=$readArgs.Clone();$a.windowId=$id;Check (-not (ReadStatus $read $a).ok) 'malformed request window ID'
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName console -Arguments $a)) 'malformed request not admitted as read-only'
}
foreach($field in @($read.PSObject.Properties.Name)){
    $p=Clone $read;$p.PSObject.Properties.Remove($field)
    Check (-not (ReadStatus $p).ok) "missing read $field"
}
foreach($field in @($diag.PSObject.Properties.Name)){
    $p=Clone $read;$p.diag.PSObject.Properties.Remove($field)
    Check (-not (ReadStatus $p).ok) "missing modern diag $field"
}
foreach($field in @('markersFound','sawBegin','sawEnd','lossPossible')){
    foreach($v in @('false',0,$null,-not $read.$field)){
        $p=Clone $read;$p.$field=$v;Check (-not (ReadStatus $p).ok) "bad $field"
    }
}
foreach($field in @('consoleLogNull','bufferEmpty','bufferHasBegin','lastMessageHasBegin','consoleMenuExists','consoleMenuOpen','consoleMode','printHooked','timedOut')){
    $p=Clone $read;$p.diag.$field='false';Check (-not (ReadStatus $p).ok) "bad diagnostic Boolean $field"
}
foreach($field in @('bufferLen','printLines','printDropped','printPayloadLines','printPayloadBytes','ringLines','samples','ticks','engineFrames')){
    foreach($v in @('0',-1,0.0,$true,$null)){
        $p=Clone $read;$p.diag.$field=$v;Check (-not (ReadStatus $p).ok) "bad counter $field"
    }
}
foreach($field in @('lineLimit','byteLimit','format','allocation','oversize')){
    foreach($v in @(1,'0',$null)){
        $p=Clone $read;$p.diag.printLoss.$field=$v;Check (-not (ReadStatus $p).ok) "print loss $field"
    }
}
foreach($field in @('ok','error','redirected','isError','WindowID','extension')){
    foreach($level in @('exec','read','diag','loss','arguments')){
        $p=Clone $read;$e=Clone $exec;$a=$readArgs.Clone()
        switch($level){
            exec {$e|Add-Member $field $true -Force;Check (-not (ExecStatus $e).ok) "exec extension $field"}
            read {$p|Add-Member $field $true -Force;Check (-not (ReadStatus $p).ok) "read extension $field"}
            diag {$p.diag|Add-Member $field $true -Force;Check (-not (ReadStatus $p).ok) "diag extension $field"}
            loss {$p.diag.printLoss|Add-Member $field $true -Force;Check (-not (ReadStatus $p).ok) "loss extension $field"}
            arguments {$a[$field]=$true;Check (-not (ReadStatus $p $a).ok) "request extension $field"}
        }
    }
}
$p=Clone $read;$p.windowId=2;Check (-not (ReadStatus $p).ok) 'replaced capture generation refuses'
$p=Clone $read;$p.diag.printDropped=1;Check (-not (ReadStatus $p).ok) 'drop refuses'
$p=Clone $read;$p.diag.timedOut=$true;Check (-not (ReadStatus $p).ok) 'timeout refuses'
$p=Clone $read;$p.diag.printHooked=$false;Check (-not (ReadStatus $p).ok) 'print hook absent refuses'
$p=Clone $read;$p.diag.printPayloadLines=2;Check (-not (ReadStatus $p).ok) 'native tail truncation refuses'
$p=Clone $read;$p.count=2;Check (-not (ReadStatus $p).ok) 'count mismatch refuses'
$p=Clone $read;$p.lines=@(1);Check (-not (ReadStatus $p).ok) 'nonstring line refuses'
$p=Clone $read;$p.source='sampler';Check (-not (ReadStatus $p).ok) 'lossy sampler refuses'
$p=Clone $read;$p.source='buffer'
Check (-not (ReadStatus $p).ok) 'bounded buffer cannot prove untruncated'
$a=$readArgs.Clone();$a.maxLines=20000
Check (ReadStatus $p $a).ok 'full native buffer limit admitted'
foreach($limit in @($null,0,-1,20001,'200',200.0,$true)){
    $a=$readArgs.Clone();$a.maxLines=$limit;Check (-not (ReadStatus $read $a).ok) 'invalid maxLines'
}
Check (-not (Get-DevBenchConsoleReadStatus -Arguments $readArgs -Content @($read,$read)).ok) 'multiple read payloads'
$p=Clone $read;$p.PSObject.Properties.Remove('windowId');$p.diag=[pscustomobject]@{timedOut=$false;printHooked=$true;printDropped=0;lastMessage='retained marker diagnostic'}
Check (-not (ReadStatus $p).ok) 'legacy reply cannot satisfy modern guard'
$s=ReadStatus $p @{action='read'}
Check ($s.ok -and -not $s.windowMatched) 'legacy uncorrelated read preserved'
$s=ReadStatus $read @{action='read'}
Check ($s.ok -and -not $s.windowMatched) 'modern unguarded read makes no generation match claim'
Check (Test-DevBenchReadOnlyRequest -ToolName console -Arguments $readArgs) 'exact read admitted as read-only'
Check (-not (Test-DevBenchReadOnlyRequest -ToolName console -Arguments $execArgs)) 'capture exec remains mutation-capable'
$before=$read|ConvertTo-Json -Depth 30 -Compress
$null=ReadStatus $read
Check (($read|ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'raw read unchanged'
if($RetainedExecPath){
    $receipt=Get-Content -LiteralPath $RetainedExecPath -Raw|ConvertFrom-Json -Depth 100
    $s=Get-DevBenchCallSemanticStatus -ToolName console -Arguments $execArgs -Content @($receipt.data.content)
    Check ($s.ok -and $s.qualifiedExecution.windowId -eq 1 -and -not $s.desiredEffectVerified) 'retained actual native window1 accepted offline; no RPC replay'
}
[pscustomobject]@{ok=$true;checks=$checks;scope='offline console window evidence; no native execution, transport/session authentication or desired effect proof'}|ConvertTo-Json -Compress
