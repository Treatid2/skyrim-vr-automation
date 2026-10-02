# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
function Qualify($Payload,$RequestArguments=@{action='newGame';phase='inspect'}) {
    Get-DevBenchCallSemanticStatus -ToolName game -Arguments $RequestArguments -Content @($Payload)
}
function Menu { [ordered]@{mainMenuOpen=$true;state='Main';moviePath='_root.MenuHolder.Menu_mc';pendingRequestId='';unresolvedRequestId='';newRequestsBlocked=$false;readyToRequest=$true;readyToConfirm=$false;selectedEntryId=0} }
function Receipt { [ordered]@{requestId='exact-id';phase='requested';newRow=1;state='MainConfirm';accepted=$false;completed=$false;unresolvedDispatch=$false} }
$request=@{action='newGame';phase='request';requestId='exact-id'}
$confirm=@{action='newGame';phase='confirm';requestId='exact-id';confirmNewGame=$true}
$lookup=@{action='newGame';phase='inspect';requestId='exact-id'}
$s=Qualify ([pscustomobject](Menu)); Check ($s.ok -and $s.known -and $s.readyToRequest -and $s.completionBasis -ceq 'current-menu-state') 'typed idle inspect qualifies readiness without generic ok'
$m=Menu; $m.state='MainAnimation';$m.readyToRequest=$false
$s=Qualify ([pscustomobject]$m); Check ($s.ok -and -not $s.readyToRequest -and -not $s.readyToConfirm) 'intermediate animation is valid observation, not readiness'
$m=Menu;$m.state='MainConfirm';$m.pendingRequestId='exact-id';$m.readyToRequest=$false;$m.readyToConfirm=$true;$m.selectedEntryId=1
$s=Qualify ([pscustomobject]$m); Check ($s.ok -and $s.readyToConfirm) 'exact pending New confirmation readiness qualifies'
$m=Menu;$m.mainMenuOpen=$false;$m.readyToRequest=$false;$m.Remove('state');$m.Remove('moviePath');$m.Remove('selectedEntryId')
Check ((Qualify ([pscustomobject]$m)).ok) 'native closed-menu inspect is valid observation'
foreach($closed in @($false,$true)) {
    $m=Menu;$m.mainMenuOpen=-not $closed;$m.readyToRequest=$false;$m.newRequestsBlocked=$true;$m.unresolvedRequestId='uncertain-id'
    $s=Qualify ([pscustomobject]$m);Check (-not $s.ok -and $s.newRequestsBlocked -and $s.unresolvedDispatch -and $s.unresolvedRequestId -ceq 'uncertain-id') "sticky general barrier survives closed=$closed"
}
$s=Qualify ([pscustomobject](Receipt)) $request
Check ($s.ok -and $s.completionBasis -ceq 'staged-request') 'accepted false/completed false is valid staged request'
Check ((Qualify ([pscustomobject](Receipt)) $lookup).ok) 'known-ID requested inspection is receipt-qualified'
Check (-not (Qualify ([pscustomobject](Menu)) $lookup).ok) 'unknown-ID general snapshot cannot impersonate a known receipt'
Check (-not (Qualify ([pscustomobject](Receipt)) $confirm).ok) 'confirm cannot qualify a merely staged receipt'
$r=Receipt;$r.phase='dispatched';$r.accepted=$true
foreach($args in @($request,$confirm,$lookup)) { $s=Qualify ([pscustomobject]$r) $args; Check ($s.ok -and $s.completionBasis -ceq 'dispatch-only') "dispatched same-ID receipt is dispatch-only for $($args.phase)" }
foreach($reason in @('expired','menuReplaced','menuInterrupted','')) {
    $r=Receipt;$r.phase='dispatchUncertain';$r.unresolvedDispatch=$true;if($reason){$r.invalidationReason=$reason}
    $s=Qualify ([pscustomobject]$r) $lookup
    Check (-not $s.ok -and $s.unresolvedDispatch -and $s.newRequestsBlocked -and $s.unresolvedRequestId -ceq 'exact-id' -and -not $s.transient) "uncertain receipt stays non-retryable after '$reason'"
}
foreach($phase in @('expired','menuReplaced','menuInterrupted','failed','success','completed')) {
    $r=Receipt;$r.phase=$phase;$r.ok=$true
    Check (-not (Qualify ([pscustomobject]$r) $lookup).ok) "generic positive does not promote failed/unsupported phase '$phase'"
}
foreach($field in @('mainMenuOpen','readyToRequest','readyToConfirm','newRequestsBlocked','pendingRequestId','unresolvedRequestId','state','moviePath','selectedEntryId')) {
    $m=Menu;$m.Remove($field);Check (-not (Qualify ([pscustomobject]$m)).ok) "missing $field refused"
}
foreach($field in @('mainMenuOpen','readyToRequest','readyToConfirm','newRequestsBlocked')) {
    foreach($value in @('false',0,1,$null)) { $m=Menu;$m[$field]=$value;Check (-not (Qualify ([pscustomobject]$m)).ok) "wrong typed menu $field='$value' refused" }
}
foreach($field in @('accepted','completed','unresolvedDispatch')) {
    foreach($value in @('false',0,1,$null)) { $r=Receipt;$r[$field]=$value;Check (-not (Qualify ([pscustomobject]$r) $request).ok) "wrong typed receipt $field='$value' refused" }
}
foreach($value in @('1',[datetime]::UtcNow,$true,[double]::NaN)) { $m=Menu;$m.selectedEntryId=$value;Check (-not (Qualify ([pscustomobject]$m)).ok) "malformed selected entry type $($value.GetType().Name) refused without throwing" }
foreach($extra in @(@{error='failure'},@{errors=@('failure')},@{ok='false'},@{isError=$true},@{failed=$true},@{retryable=$true},@{metadata=@{ok=$false}},@{metadata=@{status=@{name='failure';value=0}}},@{metadata=@{completed=$false}})) {
    $r=Receipt;foreach($key in $extra.Keys){$r[$key]=$extra[$key]}
    Check (-not (Qualify ($r|ConvertTo-Json -Depth 20|ConvertFrom-Json) $request).ok) 'explicit nested error/negative/malformed outcome defeats staged qualification'
}
$r=Receipt;$r.requestId='EXACT-ID';Check (-not (Qualify ([pscustomobject]$r) $request).ok) 'receipt ID comparison is ordinal'
$r=Receipt;$r.completed=$true;Check (-not (Qualify ([pscustomobject]$r) $request).ok) 'receipt cannot claim world completion'
$r=Receipt;$r.unresolvedDispatch=$true;Check (-not (Qualify ([pscustomobject]$r) $request).ok) 'requested uncertainty contradiction refused'
$r=Receipt;$r.phase='dispatched';$r.accepted=$false;Check (-not (Qualify ([pscustomobject]$r) $confirm).ok) 'dispatched acceptance contradiction refused'
$m=Menu;$m.readyToConfirm=$true;Check (-not (Qualify ([pscustomobject]$m)).ok) 'dual readiness refused'
$m=Menu;$m.newRequestsBlocked=$true;Check (-not (Qualify ([pscustomobject]$m)).ok) 'barrier ID/flag contradiction refused'
foreach($args in @(@{action='newGame';phase=1},@{action='newGame';phase='Request';requestId='exact-id'},@{action='newGame';phase='request';requestId=('x'*129)},@{action='newGame';phase='confirm';requestId='exact-id';confirmNewGame='true'})) {
    Check (-not (Qualify ([pscustomobject](Receipt)) $args).ok) 'malformed request cannot qualify a receipt'
}
Check (Test-DevBenchReadOnlyRequest -ToolName game -Arguments @{action='newGame'}) 'default inspect is read-only'
Check (Test-DevBenchReadOnlyRequest -ToolName game -Arguments $lookup) 'known-ID inspect is read-only'
Check (-not (Test-DevBenchReadOnlyRequest -ToolName game -Arguments $request)) 'request is mutation-capable'
Check (-not (Test-DevBenchReadOnlyRequest -ToolName game -Arguments $confirm)) 'confirm is mutation-capable'
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);nativeContract='4407a937734bcfe7c7f659a2bc159bc1795c6ac0';liveValidated=$false}|ConvertTo-Json -Depth 5
