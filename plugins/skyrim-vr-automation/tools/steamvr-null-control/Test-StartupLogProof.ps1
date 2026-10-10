# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$checks=0
function Require([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$script:checks++}
$fixture=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('startup-proof-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$tokens=$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'),[ref]$tokens,[ref]$errors)
Require (@($errors).Count -eq 0) 'controller parses'
foreach($name in @('Get-StreamRangeSha256','Get-ByteArraySha256','Get-Utf8TrailingIncompleteByteCount','Get-SharedTextTail','Get-LogTimestampUtc','Get-NullRuntimeEvidence')){
 $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
 Invoke-Expression $node.Extent.Text
}
. (Join-Path $PSScriptRoot 'StartupLogProof.ps1')
$SteamVRRoot=Join-Path $fixture 'SteamVR';$ServerLogPath=Join-Path $fixture 'vrserver.txt';$LogTailMaxBytes=4096
$InternalTestFailurePoint='';$script:SharedTextTailState=@{};$utf8=[Text.UTF8Encoding]::new($false)
$server=[pscustomobject]@{name='vrserver';id=123;path=(Join-Path $SteamVRRoot 'bin/win64/vrserver.exe');startTimeUtc=''}
$profile=@{driver_null=@{serialNumber='fixture-null'};headPoseProviderContract=@{};dashboard=@{enableDashboard=$false}}
$script:probes=0
function Get-NullProviderAuthority{param($DeadlineUtc) [pscustomobject]@{verified=$true}}
function Get-HeadPoseSharedState{param($Contract) [pscustomobject]@{qualified=$true;driverCreatorPid=$server.id;creatorAuthority=[pscustomobject]@{pid=$server.id;executablePath=$server.path;processStartFileTimeUtc=([DateTimeOffset]$server.startTimeUtc).UtcDateTime.ToFileTimeUtc()}}}
function Get-ApplicationHeadPose{param($Contract,$PreProbePose,$PreProbePackageAuthority,$DeadlineUtc) $script:probes++;[pscustomobject]@{qualified=$true;controllersQualified=$true;poseAfterProbe=$PreProbePose;packageAuthority=$PreProbePackageAuthority;providerContinuity=@{verified=$true}}}
function Reset-Log([string]$History=''){
 $script:SharedTextTailState.Clear();[IO.File]::WriteAllText($ServerLogPath,$History,$utf8)
 $null=New-NullStartupLogAnchor -Path $ServerLogPath -AttemptId ([guid]::NewGuid().ToString('N')) -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
 $server.startTimeUtc=[DateTime]::UtcNow.ToString('o')
}
function Proof-Lines([string]$Serial='fixture-null',[int]$PidValue=$server.id,[string]$RuntimeRoot=$SteamVRRoot,[DateTime]$At=([DateTimeOffset]$server.startTimeUtc).UtcDateTime){
 $stamp=$At.ToLocalTime().ToString('ddd MMM d yyyy HH:mm:ss.fff',[cultureinfo]::InvariantCulture)
 @("$stamp [Info] - vrserver 2.17.10 startup with PID=$PidValue, config=fixture, runtime=$RuntimeRoot, arch=win64",
 "$stamp [Info] Loaded server driver null fixture driver_null.dll","$stamp [Info] Active HMD set to null.$Serial",
 "$stamp [Info] Loaded server driver codex_head_pose fixture driver_codex_head_pose.dll",
 "$stamp [Info] codex_head_pose: registered synthetic head-pose device at configured standing pose") -join "`n"
}
function Append-Proof{[IO.File]::AppendAllText($ServerLogPath,(Proof-Lines)+"`n",$utf8)}
function Read-Proof{Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))}
$history="historical framed line`n"*15000;$noise="diagnostic noise`n"*3000
Reset-Log $history;Append-Proof
$offset=$utf8.GetByteCount($history);$length=$utf8.GetByteCount((Proof-Lines)+"`n")
[IO.File]::AppendAllText($ServerLogPath,$noise,$utf8)
$runtime=Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Require ($runtime.active -and $runtime.headPoseReady -and $runtime.controllersReady -and $script:probes -eq 1) 'delayed observation beyond history and tail still reaches unchanged fixture probe gate'
Require ($runtime.startupLogProof.offset -eq $offset -and $runtime.startupLogProof.length -eq $length -and $runtime.startupLogProof.serverStartup.byteStartInclusive -eq $offset) 'physical offsets and current PID bind attempt, not byte zero'
Require ($runtime.startupLogProof.bytesRead -le 4096 -and $runtime.startupLogProof.hashBytesRead -le 12288) 'bounded acquisition does not scan history'
[IO.File]::AppendAllText($ServerLogPath,$noise,$utf8);$again=Read-Proof
Require ($again.complete -and $again.retained -and $again.sha256 -ceq $runtime.startupLogProof.sha256 -and $again.bytesRead -eq 0) 'append/noise rollover preserves exact immutable range'
Require ($again.hashBytesRead -eq 2*($again.length+$again.anchor.guardLength)) 'retained proof checks exactly two ranges plus two guards'
$edit=[IO.File]::Open($ServerLogPath,'Open','Write',[IO.FileShare]::ReadWrite)
try{$edit.Position=$offset+30;$edit.WriteByte([byte][char]'X')}finally{$edit.Dispose()}
$bad=Read-Proof
Require ($bad.terminalFailure -and -not $bad.complete -and $bad.error -match 'in place') 'retained-range mutation terminal'
[IO.File]::WriteAllText($ServerLogPath,$history+(Proof-Lines)+"`n"+$noise,$utf8)
Require ((Read-Proof).terminalFailure) 'restored bytes cannot silently reanchor rejected attempt'
Reset-Log $history;Append-Proof;$null=Read-Proof
$rotated=Join-Path $fixture 'rotated.txt';[IO.File]::Move($ServerLogPath,$rotated)
[IO.File]::WriteAllText($ServerLogPath,$history+(Proof-Lines)+"`n",$utf8)
[IO.File]::SetCreationTimeUtc($ServerLogPath,[IO.File]::GetCreationTimeUtc($rotated))
Require ((Read-Proof).terminalFailure) 'same-name identical-content replacement with copied creation time refused by physical ID'
Reset-Log $history;Append-Proof;$null=Read-Proof;[IO.File]::WriteAllText($ServerLogPath,'truncated',$utf8)
Require ((Read-Proof).error -match 'truncated') 'prelaunch truncation refused'
Reset-Log $history;Append-Proof;[IO.File]::AppendAllText($ServerLogPath,$noise,$utf8);$null=Read-Proof
$cut=[IO.File]::Open($ServerLogPath,'Open','Write',[IO.FileShare]::ReadWrite)
try{$cut.SetLength($offset+$utf8.GetByteCount((Proof-Lines)+"`n"))}finally{$cut.Dispose()}
Require ((Read-Proof).error -match 'truncated') 'post-proof truncation refused even with retained bytes intact'
Reset-Log $history
$edit=[IO.File]::Open($ServerLogPath,'Open','Write',[IO.FileShare]::ReadWrite)
try{$edit.Position=$offset-1;$edit.WriteByte([byte][char]'X')}finally{$edit.Dispose()}
Append-Proof;Require ((Read-Proof).error -match 'guard changed') 'framing guard in-place mutation refused'
Reset-Log 'historical partial';Append-Proof
Require (-not (Read-Proof).complete) 'partial historical first line cannot synthesize startup proof'
Reset-Log 'historical partial';[IO.File]::AppendAllText($ServerLogPath," continuation`n"+(Proof-Lines)+"`n",$utf8)
Require ((Read-Proof).complete) 'partial first line skipped to LF before current proof'
Reset-Log $history;$text=(Proof-Lines)+"`n";[IO.File]::AppendAllText($ServerLogPath,$text.TrimEnd([char]10),$utf8)
Require (-not (Read-Proof).complete) 'partial last line not proof'
[IO.File]::AppendAllText($ServerLogPath,"`n",$utf8);Require ((Read-Proof).complete) 'LF completion extends unchanged incomplete range'
foreach($serial in @('fixture-null-extra','FIXTURE-NULL')){
 Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,(Proof-Lines -Serial $serial)+"`n",$utf8)
 Require (-not (Read-Proof).complete) 'exact serial suffix/case matching'
}
Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,(Proof-Lines -PidValue 999)+"`n",$utf8)
Require ((Read-Proof).terminalFailure) 'wrong startup PID refused'
Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,(Proof-Lines -RuntimeRoot (Join-Path $fixture 'foreign'))+"`n",$utf8)
Require ((Read-Proof).terminalFailure) 'foreign startup runtime refused'
Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,(Proof-Lines -At ([DateTime]::UtcNow.AddSeconds(-10)))+"`n",$utf8)
Require (-not (Read-Proof).complete) 'historical timestamp refused'
Reset-Log $history;Append-Proof;$null=Read-Proof;$server.id++
Require ((Read-Proof).terminalFailure) 'server binding drift cannot transfer authority'
Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,$noise,$utf8)
Require ((Read-Proof).error -match 'byte budget') 'new payload cap terminal without scanning history'
Reset-Log $history;[IO.File]::AppendAllText($ServerLogPath,("n`n"*10001),$utf8)
$cap=Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes 65536
Require ($cap.terminalFailure -and $cap.error -match 'line budget') 'line budget preserved'
Reset-Log $history;Append-Proof
$drift=Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -InternalMutationHook {param($path) [IO.File]::WriteAllText($path,'rewritten')}
Require ($drift.terminalFailure -and -not $drift.stable) 'selected-path revalidation rejects between-read mutation'
Reset-Log $history;Append-Proof;$expired=$false
try{Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1))|Out-Null}catch [TimeoutException]{$expired=$true}
Require ($expired -and @($script:NullStartupLogProofState.Values)[0].terminalFailure) 'deadline invalidates proof before publication'
Reset-Log $history;$anchorFailed=$false
try{New-NullStartupLogAnchor -Path $ServerLogPath -AttemptId 'mutation' -InternalMutationHook {param($path) [IO.File]::AppendAllText($path,"advance`n")}|Out-Null}catch{$anchorFailed=$true}
Require ($anchorFailed -and $null -eq $script:NullStartupLogAnchor) 'concurrent writer during anchor refuses launch boundary'
Reset-Log $history;Append-Proof;$good=Read-Proof
$receipt=[pscustomobject]@{schemaVersion=2;attemptId=$good.attemptId;runtimeAccepted=$true;admissionState='accepted';startupLogAnchor=$good.anchor;runtime=[pscustomobject]@{startupLogProof=$good}}
$receipt=$receipt|ConvertTo-Json -Depth 15|ConvertFrom-Json -Depth 15
$script:NullStartupLogAnchor=$null;$script:NullStartupLogProofState.Clear()
Import-NullStartupLogAnchor -Receipt $receipt -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes
Require ((Read-Proof).complete -and (Read-Proof).retained) 'read-only accepted-receipt continuity verifies original ranges rather than live reanchoring'
$importFailed=$false
try{Import-NullStartupLogAnchor -Receipt $receipt -Path $ServerLogPath -Server $server -SerialNumber 'foreign' -MaxBytes $LogTailMaxBytes}catch{$importFailed=$true}
Require ($importFailed) 'accepted receipt cannot lend proof to different configured serial'
$edit=[IO.File]::Open($ServerLogPath,'Open','Write',[IO.FileShare]::ReadWrite)
try{$edit.Position=$offset+30;$edit.WriteByte([byte][char]'X')}finally{$edit.Dispose()}
Import-NullStartupLogAnchor -Receipt $receipt -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes
Require ((Read-Proof).terminalFailure) 'accepted receipt hash revalidation rejects changed live proof on later invocation'
$script:NullStartupLogAnchor=$null;$script:NullStartupLogProofState.Clear()
Require ((Read-Proof).terminalFailure) 'missing prelaunch provenance cannot be reconstructed from running log'
$ServerLogPath=Join-Path $fixture 'initially-absent.txt'
$null=New-NullStartupLogAnchor -Path $ServerLogPath -AttemptId 'absent';$server.startTimeUtc=[DateTime]::UtcNow.ToString('o')
Require (-not (Read-Proof).terminalFailure -and $script:NullStartupLogProofState.Count -eq 0) 'initial absence waits without poisoning cache or creating log'
[IO.File]::WriteAllText($ServerLogPath,(Proof-Lines)+"`n",$utf8);Require ((Read-Proof).complete) 'single new file admitted with exact startup identity'
[IO.File]::Move($ServerLogPath,(Join-Path $fixture 'created-old.txt'))
Require ((Read-Proof).terminalFailure) 'created path disappearance is terminal'
Reset-Log ''
$empty=Read-Proof
Require ($empty.stable -and -not $empty.complete -and -not $empty.terminalFailure -and $empty.length -eq 0) 'empty existing log is pending, not proof failure'
Append-Proof;$good=Read-Proof
Require ($good.complete -and $good.anchor.existed -and $good.anchor.guardLength -eq 0) 'empty prelaunch file can append current proof'
$receipt=[pscustomobject]@{schemaVersion=2;attemptId=$good.attemptId;runtimeAccepted=$true;admissionState='accepted';startupLogAnchor=$good.anchor;runtime=[pscustomobject]@{startupLogProof=$good}}
Import-NullStartupLogAnchor -Receipt $receipt -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes
Require ((Read-Proof).complete) 'empty-boundary guard preserves accepted-receipt continuity'
[pscustomobject]@{ok=$true;checks=$checks;liveRuntimeChanged=$false;applicationProbe='fixture only';fixtureRoot=$fixture;historicalBytes=$offset;maxPayloadBytes=$LogTailMaxBytes}|ConvertTo-Json -Depth 8 -Compress
