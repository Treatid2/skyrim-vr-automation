# SPDX-License-Identifier: GPL-3.0-or-later
# Offline fixture: never loads a runtime or sends network requests.
[CmdletBinding()]
param([Parameter(Position=0)][string]$Command,[string]$SessionPath,
 [string]$DevBenchScriptPath,[string]$DirectTool,[string]$DirectArgumentsJson,
 [string]$Tool,[string]$ArgumentsJson,[string]$RuntimePath,[string]$ExpectedRuntimeIdentityJson,
 [string]$ArtifactPath,[string]$ExpectedBuildId,[string]$ExpectedArtifactSha256,
 [switch]$Compact,[switch]$NoExit,[switch]$RequireSuccess,
 [int]$MaxTransientRetries,[int]$TimeoutSeconds,[int]$RequestTimeoutSeconds)
$ErrorActionPreference='Stop'
if ($Command -eq 'call') {
 # Current real CaptureInteraction inherits these exact bootstrap expectations.
 # Older scoped capture context supplies only ExpectedRuntimeIdentityJson.
 if ($ArtifactPath -and ($ArtifactPath -cne 'fixture.dll' -or $ExpectedBuildId -cne 'fixture' -or $ExpectedArtifactSha256 -cne ('a'*64))) { throw 'Fixture capture artifact expectations drifted.' }
 $state=Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
 if ($state.PSObject.Properties['hang'] -and $state.hang -eq $true) { Start-Sleep -Seconds 20 }
 $state | Add-Member -NotePropertyName retries -NotePropertyValue $MaxTransientRetries -Force
 $state | Add-Member -NotePropertyName timeout -NotePropertyValue $TimeoutSeconds -Force
 $argsValue=$ArgumentsJson | ConvertFrom-Json
 if ($state.PSObject.Properties['calls']) {
  $state.calls=@($state.calls)+@(@{tool=$Tool;arguments=$argsValue;identity=$ExpectedRuntimeIdentityJson;retries=$MaxTransientRetries;timeout=$TimeoutSeconds})
 }
 if ($state.PSObject.Properties['adapterResponse']) {
  $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $RuntimePath -Encoding utf8
  $state.adapterResponse | ConvertTo-Json -Depth 30 -Compress
  return
 }
 if ($Tool -cne 'papyrus') {
  $value=switch ($Tool) {
   'record' { @{recording=$true} }
   'inspect' { $state.frame++; @{playerLoaded=$true;frame=$state.frame} }
   'menu' { @{menus=@('RaceSex Menu')} }
   'input' { @{active=$false;frame=@{}} }
   'communityshaders.screenshot' { @{requestId='fixture-shot';state='completed';terminal=$true} }
   default { throw "Unexpected fixture observation tool: $Tool" }
  }
  $denied=$state.PSObject.Properties['denyObservation'] -and $state.denyObservation -ceq $Tool
  $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $RuntimePath -Encoding utf8
  @{ok=(-not $denied);transportOk=$true;indeterminate=$false;semantic=@{known=$true;ok=(-not $denied)};errors=$(if ($denied) {@('fixture observation rejection')} else {@()});data=@{content=@($value)}} | ConvertTo-Json -Depth 30 -Compress
  return
 }
 $returned=$null
 if ($argsValue.function -eq 'GetString') {
  if ($argsValue.args[1] -like '*.vrDiagnosticSnapshotJson') { $returned=$state | ConvertTo-Json -Depth 10 -Compress }
  else { $returned=@{ok=$true;code='dispatched';generation=$state.generation} | ConvertTo-Json -Compress }
 } elseif ($argsValue.args[1] -like '*.SelectVRDiagnosticRace') {
  $state.mutations++;$state.generation++
  foreach ($race in $state.races) { $race.active=$race.id -eq $argsValue.args[2][1] }
 }
 $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RuntimePath -Encoding utf8
 $known=$state.PSObject.Properties['denyKnown'] -and $state.denyKnown -eq $true
 $called=-not ($state.PSObject.Properties['denyCalled'] -and $state.denyCalled -eq $true)
 @{ok=$false;transportOk=$true;indeterminate=$false;semantic=@{known=[bool]$known};errors=@('Unrecognized or rejected Papyrus return');data=@{content=@(@{called=[bool]$called;returned=$returned;returnedType='String'})}} | ConvertTo-Json -Depth 12 -Compress
} else {
 $session=Get-Content -LiteralPath $SessionPath -Raw | ConvertFrom-Json
 if ($Command -eq 'observe') {
  $state=Get-Content -LiteralPath $session.modelPath -Raw | ConvertFrom-Json
  $state.frame++
  $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $session.modelPath -Encoding utf8
  @{ok=$true;data=@{observation=@{game=@{ok=$true;value=@{playerLoaded=$true;frame=$state.frame}};recording=@{ok=$true;value=@{recording=$true}}}}} | ConvertTo-Json -Depth 12 -Compress
 } else {
  $response=& $DevBenchScriptPath call -Tool $DirectTool -ArgumentsJson $DirectArgumentsJson -RuntimePath $session.modelPath -ExpectedRuntimeIdentityJson '{}' -Compact -NoExit -RequireSuccess | ConvertFrom-Json
  @{ok=$response.ok;data=@{action=@{receipt=@{result=$response.data.content[0]}}}} | ConvertTo-Json -Depth 15 -Compress
 }
}
