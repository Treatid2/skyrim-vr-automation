# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CalendarObservationWindow.psm1') -Force
$checks=0
function Require([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
function Clone($Object){return $Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30}
foreach($mode in @('healthy','failed-observation','expired','generation','globals','cell','foreign-owner','wrong-session','lost-hold','late-hold','late-response','release-failed','restore-proof','no-prior-rate','uncertain-no-lease','stale-initial','deadline')) {
    $script:mode=$mode; $script:calls=[Collections.Generic.List[object]]::new(); $script:held=$false; $script:released=$false; $script:statusCount=0; $script:holdId=$null; $script:owner=$null
    $script:binding=[pscustomobject]@{processSession='123:456';pid=123;loadGeneration=1;cellFormId=7;globalFormIds=@(1,2,3,4,5,6)}
    $script:values=[pscustomobject]@{year=201;month=1;day=1;gameHour=12;daysPassed=1;calendarRate=20;engineMultiplier=1}
    $call={
        param($name,$arguments,$mutation,$bound)
        $script:calls.Add([pscustomobject]@{name=$name;arguments=$arguments;mutation=$mutation})
        if($name -ne 'calendar') {
            if($script:mode -eq 'failed-observation'){return [pscustomobject]@{content=@([pscustomobject]@{ok=$false;error='fixture negative'})}}
            return [pscustomobject]@{content=@([pscustomobject]@{ok=$true;playerLoaded=$true})}
        }
        if($arguments.action -eq 'hold') {
            $script:held=$true; $script:holdId=$arguments.commandId; $script:owner=$arguments.owner
            if($script:mode -in @('lost-hold','uncertain-no-lease')){throw 'fixture lost hold response'}
            if($script:mode -eq 'late-response'){Start-Sleep -Milliseconds 350}
        }
        if($arguments.action -eq 'release') {
            Require ($arguments.leaseId -ceq 'fixture-lease') 'Exact lease was not released'
            Require ($arguments.owner -ceq $script:owner) 'Exact owner was not released'
            if($script:mode -eq 'release-failed'){throw 'fixture release failure'}
            $script:released=$true
        }
        if($arguments.action -eq 'status'){$script:statusCount++}
        $b=Clone $script:binding; $v=Clone $script:values
        $outstanding=$script:held -and -not $script:released
        $payload=[pscustomobject]@{ok=$true;action=$arguments.action;status=$(if($arguments.action -eq 'hold'){'held'}elseif($arguments.action -eq 'release'){'released'}else{'observed'});schemaVersion=1;plugin='devbench';binding=$b;frame=1;readbackFresh=$true;available=$true;worldLoaded=$true;values=$v;outstanding=$outstanding;leaseActive=$outstanding;expiryDue=$false;cleanupPending=$false;holdValid=$outstanding;serviceStopping=$false;restored=$script:released;lastTransition=[pscustomobject]@{ok=$true;status='released';restored=$script:released}}
        if($script:held -and $script:mode -ne 'uncertain-no-lease') {
            $payload | Add-Member lease ([pscustomobject]@{id='fixture-lease';owner=$script:owner;commandId=$script:holdId;binding=(Clone $script:binding);applied=$true;captured=(Clone $script:values);cleanupAttempted=$script:released})
        }
        if($outstanding){$payload.values.calendarRate=0}
        if($script:mode -eq 'no-prior-rate' -and $script:held){$payload.lease.captured.calendarRate='20'}
        if($script:mode -eq 'stale-initial' -and -not $script:held){$payload.readbackFresh=$false}
        if($script:mode -eq 'late-hold' -and $arguments.action -eq 'hold'){$payload.ok=$false;$payload | Add-Member mayCompleteLater $true}
        if($script:held -and -not $script:released -and $script:statusCount -gt 1) {
            switch($script:mode) {
                'expired' {$payload.expiryDue=$true;$payload.leaseActive=$false;$payload.holdValid=$false}
                'generation' {$payload.binding.loadGeneration=2}
                'globals' {$payload.binding.globalFormIds[0]=9}
                'cell' {$payload.binding.cellFormId=8}
                'foreign-owner' {$payload.lease.owner='foreign'}
            }
        }
        if($script:mode -eq 'restore-proof' -and $script:released){$payload.lastTransition.restored=$false}
        return [pscustomobject]@{content=@($payload)}
    }
    $assertSession={if($script:mode -eq 'wrong-session' -and $script:held){throw 'fixture session mismatch'}}
    $deadline=$(if($mode -eq 'deadline'){[datetime]::UtcNow.AddSeconds(1)}elseif($mode -eq 'late-response'){[datetime]::UtcNow.AddSeconds(5.2)}else{[datetime]::UtcNow.AddSeconds(60)})
    $result=Invoke-DevBenchCalendarWindow -Call $call -AssertSession $assertSession -Owner 'fixture-owner' -Observations @(@{tool='inspect';arguments=@{kind='state'}}) -DeadlineUtc $deadline -CleanupSeconds 5
    Require ($result.ok -eq ($mode -eq 'healthy')) "$mode had incorrect success"
    Require (@($script:calls | Where-Object {$_.arguments.Contains('action') -and $_.arguments.action -eq 'hold'}).Count -le 1) "$mode replayed hold"
    Require (@($script:calls | Where-Object {$_.arguments.Contains('action') -and $_.arguments.action -eq 'release'}).Count -le 1) "$mode replayed release"
    Require (-not $result.disconnectRestorationClaimed) "$mode invented disconnect restoration"
    if($mode -eq 'healthy'){Require $result.restorationVerified 'Healthy restoration missing';Require $result.continuityVerified 'Healthy continuity missing'}
    if($mode -in @('failed-observation','expired','generation','globals','cell','foreign-owner','lost-hold','late-hold','late-response')){Require $script:released "$mode skipped same-session original exact cleanup"}
    if($mode -in @('wrong-session','uncertain-no-lease','no-prior-rate')){Require (-not $script:released) "$mode adopted unknown cleanup authority"}
    if($mode -in @('stale-initial','deadline')){Require (-not $script:held) "$mode dispatched despite rejected admission"}
}
# Exercise refusal through the actual public production entry point before it
# opens any network session. Native operation tests above substitute only RPC.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('calendar-admission-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $runtime=Join-Path $temp 'runtime.json'; [IO.File]::WriteAllText($runtime,'{"port":1}')
    foreach($observations in @('[{"tool":"game","arguments":{"action":"save"}}]','[{"tool":"calendar","arguments":{"action":"hold"}}]','[{"tool":"camera","arguments":{"action":"drive"}}]')) {
        $raw=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') calendar-window -CalendarOwner fixture -CalendarObservationsJson $observations -RuntimePath $runtime -EvidenceDirectory $temp -MaxTransientRetries 0 -NoExit -Compact
        $actual=$raw | ConvertFrom-Json
        Require (-not $actual.ok -and -not $actual.dispatchReached -and $actual.sessionCleanup.state -eq 'not_opened') 'Production entry accepted an intrusive observation'
    }
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
[pscustomobject]@{ok=$true;checks=$checks;cases=17;liveQualification=$false} | ConvertTo-Json -Compress
