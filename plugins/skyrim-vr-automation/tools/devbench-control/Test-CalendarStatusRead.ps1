# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$script:checks=0
function Require([bool]$Good,[string]$Label) { if (-not $Good) { throw $Label }; $script:checks++ }
function Clone($Value) { $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30 }
function Read($Value, $Query=@{action='status'}) { Get-DevBenchCallSemanticStatus -ToolName calendar -Arguments $Query -Content @($Value) }
function Change($Value,[string]$Path,$NewValue,[switch]$Remove) {
    $parts=$Path.Split('.');$node=$Value
    for($i=0;$i -lt $parts.Count-1;$i++){$node=$node.($parts[$i])}
    if($Remove){$node.PSObject.Properties.Remove($parts[-1])}else{$node.($parts[-1])=$NewValue}
}
function Reject($Value,[string]$Label,$Query=@{action='status'}) {
    $s=Read $Value $Query
    Require (-not $s.ok -and $null -eq $s.qualifiedCalendarStatus -and $s.reasons.Count -gt 0) $Label
}
$fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-calendar-status.schema1.json') -Raw | ConvertFrom-Json -Depth 30
$before=$fixture|ConvertTo-Json -Depth 30 -Compress
$s=Read $fixture
Require ($s.ok -and $s.known -and $s.completionBasis -ceq 'read-schema-only' -and $s.qualifiedCalendarStatus.binding.pid -eq 82384) 'Exact retained status observation failed'
Require (-not $s.qualifiedCalendarStatus.restored -and -not $s.qualifiedCalendarStatus.holdValid) 'Read inferred restoration or valid hold'
Require (($fixture|ConvertTo-Json -Depth 30 -Compress) -ceq $before) 'Adapter mutated input'
Require (-not (Test-DevBenchReadOnlyRequest -ToolName calendar -Arguments @{action='status'})) 'Calendar identity admission was relaxed'
Require (-not (Get-DevBenchSemanticStatus -Content @($fixture)).ok) 'Generic observed was widened'
foreach($nodePath in @('', 'binding','values','lastTransition')) {
    $node=if($nodePath){$fixture.$nodePath}else{$fixture}
    foreach($property in $node.PSObject.Properties) {
        $path=if($nodePath){"$nodePath.$($property.Name)"}else{$property.Name}
        $bad=Clone $fixture;Change $bad $path $null -Remove;Reject $bad "Missing $path accepted"
    }
}
foreach($field in @('ok','readbackFresh','available')) {
    foreach($value in @($false,'true',1,$null,@($true))) { $bad=Clone $fixture;Change $bad $field $value;Reject $bad "$field coercion/staleness accepted" }
}
foreach($field in @('worldLoaded','serviceStopping','outstanding','leaseActive','expiryDue','cleanupPending','holdValid','restored','lastTransition.ok','lastTransition.restored')) {
    foreach($value in @('false',0,$null,@($false))) { $bad=Clone $fixture;Change $bad $field $value;Reject $bad "$field malformed Boolean accepted" }
}
foreach($field in @('schemaVersion','binding.pid','binding.loadGeneration','binding.cellFormId','frame','observedMonotonicMs')) {
    foreach($value in @(-1,1.5,'1',$true,$null)) { $bad=Clone $fixture;Change $bad $field $value;Reject $bad "$field malformed integer accepted" }
}
foreach($field in @('year','month','day','gameHour','daysPassed','calendarRate','engineMultiplier')) {
    foreach($value in @('1',$true,$null,[double]::NaN,[double]::PositiveInfinity,@(1))) { $bad=Clone $fixture;Change $bad "values.$field" $value;Reject $bad "values.$field nonfinite/non-numeric accepted" }
}
foreach($mode in @('foreign-action','foreign-plugin','schema2','string-schema','false-restored','nonempty-command','wrong-session','session-case','zero-pid','zero-generation','bad-global','few-global','many-global','global-string','swapped-order','scalar-order','version','nested-error','explicit-error','explicit-errors','mutation-extra','singleton-action','extra-args','argument-case')) {
    $bad=Clone $fixture;$query=@{action='status'}
    switch($mode) {
        foreign-action {$bad.action='hold'}; foreign-plugin {$bad.plugin='foreign'}; schema2 {$bad.schemaVersion=2}; string-schema {$bad.schemaVersion='1'}
        false-restored {$bad.restored=$true}; nonempty-command {$bad.commandId='old'}; wrong-session {$bad.binding.processSession='1:01DD586E0A0FCA50'}
        session-case {$bad.binding.processSession='82384:01dd586e0a0fca50'}; zero-pid {$bad.binding.pid=0}; zero-generation {$bad.binding.loadGeneration=0}
        bad-global {$bad.binding.globalFormIds[0]=0}; few-global {$bad.binding.globalFormIds=@(1)}; many-global {$bad.binding.globalFormIds+=1}; global-string {$bad.binding.globalFormIds[0]='53'}
        swapped-order {$bad.globalOrder[0]='day'}; scalar-order {$bad.globalOrder='year'}; version {$bad.version=''}
        nested-error {$bad.binding|Add-Member error 'failed'}; explicit-error {$bad|Add-Member error 'failure'}; explicit-errors {$bad|Add-Member errors @('failure')}
        mutation-extra {$bad|Add-Member accepted $true}; singleton-action {$bad.action=@('status')}; extra-args {$query.owner='someone'}; argument-case {$query=@{Action='status'}}
    }
    Reject $bad $mode $query
}
foreach($field in @('serviceStopping','outstanding','leaseActive','expiryDue','cleanupPending','holdValid')) {
    $good=Clone $fixture;$good.$field=$true
    Require ((Read $good).ok) "$field observation was mistaken for readiness qualification"
}
$good=Clone $fixture;$good.worldLoaded=$false;$good.binding.cellFormId=0
Require ((Read $good).ok) 'Valid fresh calendar read without world mistaken for world readiness'
$good=Clone $fixture;$good.lastTransition.ok=$false;$good.lastTransition.status='restore_failed';$good.lastTransition.restored=$false
Require ((Read $good).ok) 'Historical mutation failure vetoed current read'
$good|Add-Member lease ([pscustomobject]@{id='old';owner='owner';commandId='old-command';binding=(Clone $fixture.binding);deadlineMonotonicMs=1L;applied=$false;captured=(Clone $fixture.values);cleanupAttempted=$true})
Require ((Read $good).ok) 'Valid historical lease did not qualify as read'
foreach($field in @('id','owner','commandId','binding','deadlineMonotonicMs','applied','captured','cleanupAttempted')) {
    $bad=Clone $good;$bad.lease.PSObject.Properties.Remove($field);Reject $bad "Missing lease.$field accepted"
}
$bad=Clone $good;$bad.lease.binding.pid=1;Reject $bad 'Malformed historical binding accepted'
$bad=Clone $good;$bad.lease.captured.engineMultiplier='1';Reject $bad 'Malformed historical values accepted'
foreach($content in @(@($fixture,$fixture),@(,@($fixture)),@('scalar'),@(),@([pscustomobject]@{ok=$true;status='observed'}))) {
    $s=Get-DevBenchCallSemanticStatus -ToolName calendar -Arguments @{action='status'} -Content $content
    Require (-not $s.ok -and $null -eq $s.qualifiedCalendarStatus) 'Multiple/nested/scalar/foreign receipt accepted'
}
foreach($action in @('hold','release','STATUS',@('status'),$null)) {
    $s=Read $fixture @{action=$action}
    Require (-not $s.PSObject.Properties['qualifiedCalendarStatus']) 'Mutation or malformed action acquired calendar read adapter'
    Require (-not $s.ok) 'Observed response qualified wrong action'
}
$s=Get-DevBenchCallSemanticStatus -ToolName foreign -Arguments @{action='status'} -Content @($fixture)
Require (-not $s.ok -and -not $s.PSObject.Properties['qualifiedCalendarStatus']) 'Foreign tool acquired calendar qualifier'
[pscustomobject]@{ok=$true;checks=$checks;liveCalls=0;fixtureOriginalSha256='e793b29be50693f138af1e2cd14c9d324f780d41dedc1728535fe525de5e2865';nativeContractCommit='16dac4fc0653e1cc3c7f1275242949083b4697c2'}|ConvertTo-Json -Compress
