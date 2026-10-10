# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProcessLaunchInterop.ps1')
$passed=0
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw "FAIL: $Name" }; $script:passed++ }
function Context { param([int]$Integrity=8192,[bool]$Elevated=$false)
    $c=[SkyrimVRAutomation.Native.InteractiveContext]::new();$c.Pid=1;$c.SessionId=1;$c.UserSid='S-1-5-21-1';$c.CreatedUtc=[DateTime]::UtcNow.ToString('o');$c.Path=Join-Path $env:windir 'explorer.exe';$c.IntegrityRid=$Integrity;$c.Elevated=$Elevated;return $c
}
$desktop=Context;$caller=Context -Integrity 12288 -Elevated $true
[SkyrimVRAutomation.Native.NormalInteractiveProcess]::ValidateContext($caller,$desktop);Check $true 'same-user high caller and medium desktop admitted'
foreach($badCaller in @((Context -Integrity 8192 -Elevated $true),(Context -Integrity 12288 -Elevated $false),(Context -Integrity 16384 -Elevated $true))){
    $refused=$false;try{[SkyrimVRAutomation.Native.NormalInteractiveProcess]::ValidateContext($badCaller,$desktop)}catch{$refused=$true}
    Check $refused 'inconsistent/unsupported caller integrity and elevation refused'
}
foreach($case in @('UserSid','SessionId','Elevated','AppContainer','IntegrityRid','Path','CreatedUtc','Pid')) {
    $bad=Context
    switch($case) { UserSid {$bad.UserSid='S-1-5-21-2'} SessionId {$bad.SessionId=2} Elevated {$bad.Elevated=$true} AppContainer {$bad.AppContainer=$true} IntegrityRid {$bad.IntegrityRid=12288} Path {$bad.Path='C:\wrong.exe'} CreatedUtc {$bad.CreatedUtc=''} Pid {$bad.Pid=0} }
    $refused=$false;try {[SkyrimVRAutomation.Native.NormalInteractiveProcess]::ValidateContext($caller,$bad)}catch{$refused=$true}
    Check $refused "desktop $case drift/unknown refused"
}
foreach($case in @('UserSid','SessionId','Elevated','AppContainer','IntegrityRid','Path','CreatedUtc','Pid')) {
    $bad=Context
    switch($case) { UserSid {$bad.UserSid='S-1-5-21-2'} SessionId {$bad.SessionId=2} Elevated {$bad.Elevated=$true} AppContainer {$bad.AppContainer=$true} IntegrityRid {$bad.IntegrityRid=12288} Path {$bad.Path='C:\wrong.exe'} CreatedUtc {$bad.CreatedUtc=''} Pid {$bad.Pid=0} }
    $refused=$false;try {[SkyrimVRAutomation.Native.NormalInteractiveProcess]::ValidateChild($desktop,$bad,$desktop.Path)}catch{$refused=$true}
    Check $refused "suspended child $case drift/unknown refused"
}
$refused=$false;try {[SkyrimVRAutomation.Native.NormalInteractiveProcess]::Create($env:ComSpec,'never runs',(Get-Location).Path,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[DateTime]::UtcNow.AddSeconds(-1))}catch{$refused=$true}
Check $refused 'expired admission deadline refuses before process creation'
$absentTarget=Join-Path ([IO.Path]::GetTempPath()) ('absent-normal-launch-'+[guid]::NewGuid().ToString('N')+'.exe')
$refused=$false;try {[SkyrimVRAutomation.Native.NormalInteractiveProcess]::Create($absentTarget,'never runs',(Get-Location).Path,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[DateTime]::UtcNow.AddSeconds(10))}catch{$refused=$true}
Check $refused 'unavailable exact target fails before execution without elevated fallback'
$tool=Join-Path $PSScriptRoot 'Invoke-BoundedProcess.ps1'
$normal=& $tool -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo normal-out & echo normal-err 1>&2') -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds 10 -Compact -NoExit | ConvertFrom-Json -Depth 20
$attempt=$normal.attempts[0]
Check ($normal.ok -and $normal.attemptsRun -eq 1 -and -not $normal.retried) 'benign normal-user fixture succeeds once'
Check ($attempt.stdout -match 'normal-out' -and $attempt.stderr -match 'normal-err' -and $attempt.streamDrainComplete) 'exact stdout/stderr handles inherited and drained'
Check ($attempt.interactiveLaunch.child.IntegrityRid -eq 8192 -and -not $attempt.interactiveLaunch.child.Elevated -and $attempt.interactiveLaunch.normalUserAccessVerified) 'child medium effective token and normal-token broad access independently checked before resume'
Check ($attempt.processTreeOwned -and $attempt.jobQuiescent -and $attempt.jobClosed -and $attempt.exitVerified) 'original pre-resume job ownership and cleanup preserved'
Check ($attempt.interactiveLaunch.PSObject.Properties.Name -notcontains 'ProcessHandle' -and $attempt.interactiveLaunch.PSObject.Properties.Name -notcontains 'ThreadHandle') 'public evidence contains identity not private handles'
$failure=& $tool -FilePath $env:ComSpec -ArgumentList @('/d','/c','exit 7') -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds 10 -Compact -NoExit | ConvertFrom-Json -Depth 20
Check (-not $failure.ok -and $failure.attemptsRun -eq 1 -and $failure.attempts[0].exitCode -eq 7 -and $failure.attempts[0].exitVerified) 'original nonzero result remains failure without retry'
$pwsh=(Get-Command pwsh).Source
$innerCode=@'
& '__TOOL__' -FilePath $env:ComSpec -ArgumentList @('/d','/c','echo nested-normal') -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds 5 -Compact -NoExit
'@
$innerCode=$innerCode.Replace('__TOOL__',$tool.Replace("'","''"))
$nested=& $tool -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command',$innerCode) -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds 10 -Compact -NoExit | ConvertFrom-Json -Depth 30
Check ($nested.ok -and $nested.attemptsRun -eq 1 -and $nested.attempts[0].jobQuiescent) 'normal-context caller fixture returns through original owned process tree'
$inner=$nested.attempts[0].stdout|ConvertFrom-Json -Depth 30
Check ($inner.ok -and $inner.attempts[0].interactiveLaunch.method -ceq 'same-normal-context-CreateProcessW' -and $inner.attempts[0].interactiveLaunch.normalUserAccessVerified -and $inner.attempts[0].jobQuiescent) 'already-normal caller uses ordinary suspended creation with verified token access and cleanup'
$timed=& $tool -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command',"[Console]::Out.WriteLine('partial-before-timeout'); [Console]::Error.WriteLine('error-before-timeout'); Start-Sleep -Seconds 30") -NormalInteractiveUser -MaxAttempts 1 -TimeoutSeconds 2 -TerminationGraceMilliseconds 500 -StreamDrainGraceMilliseconds 500 -Compact -NoExit | ConvertFrom-Json -Depth 20
Check (-not $timed.ok -and $timed.attemptsRun -eq 1 -and $timed.attempts[0].timedOut -and $timed.attempts[0].terminationConfirmed -and -not $timed.attempts[0].unresolvedProcess) 'normal-user timeout terminates exact owned job once'
Check ($timed.attempts[0].stdout -match 'partial-before-timeout' -and $timed.attempts[0].stderr -match 'error-before-timeout' -and $timed.attempts[0].streamDrainComplete) 'timeout retains partial streams after verified drain'
Check (-not (Get-Process -Id $timed.attempts[0].pid -ErrorAction SilentlyContinue)) 'owned timed-out fixture is gone'
$text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NormalInteractiveProcess.cs'))
Check ($text -notmatch 'AdjustTokenPrivileges|SetTokenInformation|SetSecurityInfo|SetNamedSecurityInfo|CreateProcessWithLogon|runas') 'no privilege/token/existing-ACL repair or escalation API'
[ordered]@{ok=$true;passed=$passed;scope='synthetic context refusal plus benign Windows processes, no SteamVR/OpenVR/game execution';normalSuccess=$normal;normalTimeout=$timed}|ConvertTo-Json -Depth 30 -Compress
