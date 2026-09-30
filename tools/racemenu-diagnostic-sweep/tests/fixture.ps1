# SPDX-License-Identifier: GPL-3.0-or-later
# Offline fixture: never loads a runtime or sends network requests.
[CmdletBinding()]
param([Parameter(Position=0)][string]$Command,[string]$SessionPath,
 [string]$DevBenchScriptPath,[string]$DirectTool,[string]$DirectArgumentsJson,
 [string]$Tool,[string]$ArgumentsJson,[string]$RuntimePath,[string]$ExpectedRuntimeIdentityJson,
 [switch]$Compact,[switch]$NoExit,[switch]$RequireSuccess,
 [int]$MaxTransientRetries,[int]$TimeoutSeconds,[int]$RequestTimeoutSeconds)
$ErrorActionPreference='Stop'
if ($Command -eq 'call') {
 $state=Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
 if ($state.PSObject.Properties['hang'] -and $state.hang -eq $true) { Start-Sleep -Seconds 20 }
 $state | Add-Member -NotePropertyName retries -NotePropertyValue $MaxTransientRetries -Force
 $state | Add-Member -NotePropertyName timeout -NotePropertyValue $TimeoutSeconds -Force
 $argsValue=$ArgumentsJson | ConvertFrom-Json
 $returned=$null
 if ($argsValue.function -eq 'GetString') {
  if ($argsValue.args[1] -like '*.vrDiagnosticSnapshotJson') { $returned=$state | ConvertTo-Json -Depth 10 -Compress }
  else { $returned=@{ok=$true;code='dispatched';generation=$state.generation} | ConvertTo-Json -Compress }
 } elseif ($argsValue.args[1] -like '*.SelectVRDiagnosticRace') {
  $state.mutations++;$state.generation++
  foreach ($race in $state.races) { $race.active=$race.id -eq $argsValue.args[2][1] }
 }
 $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RuntimePath -Encoding utf8
 @{ok=$true;data=@{content=@(@{called=$true;returned=$returned})}} | ConvertTo-Json -Depth 12 -Compress
} else {
 $session=Get-Content -LiteralPath $SessionPath -Raw | ConvertFrom-Json
 if ($Command -eq 'observe') {
  $state=Get-Content -LiteralPath $session.modelPath -Raw | ConvertFrom-Json
  $state.frame++
  $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $session.modelPath -Encoding utf8
  @{ok=$true;data=@{observation=@{game=@{value=@{playerLoaded=$true;frame=$state.frame}};recording=@{value=@{recording=$true}}}}} | ConvertTo-Json -Depth 12 -Compress
 } else {
  $response=& $DevBenchScriptPath call -Tool $DirectTool -ArgumentsJson $DirectArgumentsJson -RuntimePath $session.modelPath -ExpectedRuntimeIdentityJson '{}' -Compact -NoExit -RequireSuccess | ConvertFrom-Json
  @{ok=$response.ok;data=@{action=@{receipt=@{result=$response.data.content[0]}}}} | ConvertTo-Json -Depth 15 -Compress
 }
}
