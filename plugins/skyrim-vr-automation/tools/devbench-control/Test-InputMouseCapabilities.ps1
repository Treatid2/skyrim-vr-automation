# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([switch]$UseSemanticAdapter)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($UseSemanticAdapter){Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force}
else{. (Join-Path $PSScriptRoot 'NativeReadContracts.ps1')}
$checks=0;$failures=[Collections.Generic.List[string]]::new()
function Check([bool]$Good,[string]$Label){$script:checks++;if(-not $Good){$failures.Add($Label)}}
function Clone($Value){return $Value|ConvertTo-Json -Depth 60|ConvertFrom-Json -Depth 60}
function Read($Payload){
 if($UseSemanticAdapter){return Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{action='capabilities'} -Content @($Payload)}
 $r=@(Get-DevBenchNativeReadReasons -Kind input-capabilities -Payload $Payload -Arguments @{action='capabilities'})
 return [pscustomobject]@{ok=($r.Count -eq 0);reasons=$r}
}
$current=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-input-capabilities.v2.mouse.json') -Raw|ConvertFrom-Json -Depth 60
$legacy=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-input-capabilities.v2.json') -Raw|ConvertFrom-Json -Depth 60
$before=$current|ConvertTo-Json -Depth 60 -Compress
Check ($current.capabilities.keyboard.keys.Count -eq 105) 'retained native current fixture has exactly105'
Check ($legacy.capabilities.keyboard.keys.Count -eq 102 -and -not $legacy.capabilities.keyboard.PSObject.Properties['mouseButtons']) 'independently retained legacy102 has no descriptor'
Check ((Read $current).ok) 'native exact105 accepted'
Check ((Read $legacy).ok) 'source-qualified exact legacy102 accepted'
$reordered=Clone $current;$reordered.capabilities.keyboard.keys=[array]($reordered.capabilities.keyboard.keys|Sort-Object scancode -Descending)
Check ((Read $reordered).ok) 'inventory order is not semantic'
foreach($defect in @('noDescriptor','nullDescriptor','scalarDescriptor','wrongDescriptorCase','wrongBase','stringBase','booleanBase','fractionBase','nullBase','missingBase','missingNames','scalarNames','foreignNames','duplicateNames','nameCase','only102','only103','only104','extra106','mouseCode','mouseNameCase','duplicateNamesInInventory','duplicateCodes','nullKeyRecord','scalarKeyRecord','missingKey','missingCode','keyboardNameCase','keyboardCode','unknownContract','contractMajor','contractMinor','keyboardVersion','trackedVersion','defaultBounds')){
 $bad=Clone $current;$kb=$bad.capabilities.keyboard
 switch($defect){
  noDescriptor {$kb.PSObject.Properties.Remove('mouseButtons')}
  nullDescriptor {$kb.mouseButtons=$null}
  scalarDescriptor {$kb.mouseButtons='scalar'}
  wrongDescriptorCase {$m=$kb.mouseButtons;$kb.PSObject.Properties.Remove('mouseButtons');$kb|Add-Member MouseButtons $m}
  wrongBase {$kb.mouseButtons.codeBase=255}
  stringBase {$kb.mouseButtons.codeBase='256'}
  booleanBase {$kb.mouseButtons.codeBase=$true}
  fractionBase {$kb.mouseButtons.codeBase=256.5}
  nullBase {$kb.mouseButtons.codeBase=$null}
  missingBase {$kb.mouseButtons.PSObject.Properties.Remove('codeBase')}
  missingNames {$kb.mouseButtons.PSObject.Properties.Remove('keys')}
  scalarNames {$kb.mouseButtons.keys='mouseLeft'}
  foreignNames {$kb.mouseButtons.keys=@('mouseLeft','mouseRight','foreign')}
  duplicateNames {$kb.mouseButtons.keys=@('mouseLeft','mouseLeft','mouseMiddle')}
  nameCase {$kb.mouseButtons.keys=@('MouseLeft','mouseRight','mouseMiddle')}
  only102 {$kb.keys=@($kb.keys|Select-Object -First 102)}
  only103 {$kb.keys=@($kb.keys|Select-Object -First 103)}
  only104 {$kb.keys=@($kb.keys|Select-Object -First 104)}
  extra106 {$kb.keys+=@([pscustomobject]@{key='foreign';scancode=259})}
  mouseCode {$kb.keys[102].scancode=259}
  mouseNameCase {$kb.keys[102].key='MouseLeft'}
  duplicateNamesInInventory {$kb.keys[103]=$kb.keys[102]}
  duplicateCodes {$kb.keys[103].scancode=256}
  nullKeyRecord {$kb.keys[102]=$null}
  scalarKeyRecord {$kb.keys[102]='mouseLeft'}
  missingKey {$kb.keys[102].PSObject.Properties.Remove('key')}
  missingCode {$kb.keys[102].PSObject.Properties.Remove('scancode')}
  keyboardNameCase {$kb.keys[0].key='Escape'}
  keyboardCode {$kb.keys[0].scancode=2}
  unknownContract {$bad.contract.name='foreign'}
  contractMajor {$bad.contract.version.major=3}
  contractMinor {$bad.contract.version.minor=1}
  keyboardVersion {$kb.version=2}
  trackedVersion {$bad.capabilities.vrTrackedSet.version.minor=2}
  defaultBounds {$kb.defaultTapMs=$kb.maximumMaxHoldMs+1}
 }
 Check (-not (Read $bad).ok) "refuse $defect"
}
foreach($value in @('256',$true,256.5,-1,$null)){
 $bad=Clone $current;$bad.capabilities.keyboard.keys[102].scancode=$value
 Check (-not (Read $bad).ok) 'mouse code requires exact native integral type/value'
}
foreach($node in @('keyboard','vrTrackedSet')){foreach($flag in @('available','ready')){foreach($value in @($false,'true',1,$null)){
 $bad=Clone $current;$bad.capabilities.$node.$flag=$value
 Check (-not (Read $bad).ok) "readiness $node.$flag rejects false/coercion"
}}}
$bad=Clone $legacy;$bad.capabilities.keyboard|Add-Member mouseButtons (Clone $current.capabilities.keyboard.mouseButtons)
Check (-not (Read $bad).ok) 'legacy102 cannot masquerade as descriptor-bearing105'
if($UseSemanticAdapter){
 $s=Read $current
 Check ($s.known -and $s.completionBasis -eq 'read-schema-only' -and $s.qualifiedInputCapabilities.capabilities.keyboard.keys.Count -eq 105) 'real production semantic adapter returns full qualified105 projection'
 Check (($s.qualifiedInputCapabilities|ConvertTo-Json -Depth 60 -Compress) -ceq $before) 'production qualified projection preserves exact native payload'
 foreach($defect in @('outerFalse','nestedError')){
  $bad=Clone $current
  if($defect -eq 'outerFalse'){$bad|Add-Member ok $false}else{$bad.capabilities.keyboard|Add-Member error 'unavailable'}
  $s=Read $bad;Check (-not $s.ok -and $null -eq $s.qualifiedInputCapabilities) "negative envelope veto $defect"
 }
 foreach($content in @(@($current,$current),@('scalar'),@([pscustomobject]@{ok=$true}))){
  $s=Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{action='capabilities'} -Content $content
  Check (-not $s.ok -and $null -eq $s.qualifiedInputCapabilities) 'foreign/multiple/scalar response refused'
 }
 foreach($action in @('sequence','releaseAll','CAPABILITIES','')){
  Check (-not (Test-DevBenchReadOnlyRequest -ToolName input -Arguments @{action=$action})) 'mutation/case drift stays outside read-only admission'
 }
}
Check (($current|ConvertTo-Json -Depth 60 -Compress) -ceq $before) 'original native fixture unchanged'
[pscustomobject]@{ok=($failures.Count -eq 0);checks=$checks;failed=$failures.Count;failures=@($failures);semanticAdapter=[bool]$UseSemanticAdapter;runtimeChanged=$false}|ConvertTo-Json -Depth 6
if($failures.Count){exit 1}
