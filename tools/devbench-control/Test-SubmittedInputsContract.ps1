# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NativeReadContracts.ps1')
$checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Clone($Value){$Value|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20}
$valid=[pscustomobject]@{schemaVersion=1;available=$true;reset=$false;jitterOffsetPixels=@(-0.25,0.125);frameTimeDeltaMilliseconds=0}
$unavailable=[pscustomobject]@{schemaVersion=1;available=$false;reset=$null;jitterOffsetPixels=$null;frameTimeDeltaMilliseconds=$null}
Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{}) -Successful $true).Count -eq 0) 'Absent legacy telemetry remains compatible, not available evidence'
foreach($input in @($valid,$unavailable)){
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$input}) -Successful $true).Count -eq 0) 'Exact optional telemetry supported'
}
Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$valid}) -Successful $false).Count -gt 0) 'Failed dispatch cannot claim available inputs'
Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$unavailable}) -Successful $false).Count -eq 0) 'Failed/nonfinite native capture may report unavailable/null'
foreach($value in @($null,'1',1.0,2,$true)){
    $bad=Clone $valid;$bad.schemaVersion=$value
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Version cannot be null/coerced/fractional/unknown/Boolean'
}
foreach($value in @($null,'true',1)){
    $bad=Clone $valid;$bad.available=$value
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Availability must be Boolean'
    $bad=Clone $valid;$bad.reset=$value
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Reset must be Boolean when available'
}
foreach($value in @($null,'13.5',$true,-1,[double]::NaN,[double]::PositiveInfinity)){
    $bad=Clone $valid;$bad.frameTimeDeltaMilliseconds=$value
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Delta requires finite nonnegative actual number'
}
foreach($value in @($null,'0,0',@(),@(0),@(0,0,0),@('0',0),@($true,0),@([double]::NaN,0),@(0,[double]::NegativeInfinity))){
    $bad=Clone $valid;$bad.jitterOffsetPixels=$value
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Jitter requires exactly two finite actual numbers'
}
foreach($name in @('schemaVersion','available','reset','jitterOffsetPixels','frameTimeDeltaMilliseconds')){
    $bad=Clone $valid;$bad.PSObject.Properties.Remove($name)
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Missing field is not unavailable evidence'
}
foreach($name in @('reset','jitterOffsetPixels','frameTimeDeltaMilliseconds')){
    $bad=Clone $unavailable;$bad.$name=$valid.$name
    Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Unavailable fields must remain null'
}
$bad=Clone $valid;$bad|Add-Member extra 1
Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$bad}) -Successful $true).Count -gt 0) 'Unknown schema1 field refuses'
Check (@(Get-DevBenchSubmittedInputReasons -Dispatch ([pscustomobject]@{submittedInputs=$null}) -Successful $true).Count -gt 0) 'Present null is malformed, not legacy absence'
$fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-fsr-colour-status.json') -Raw|ConvertFrom-Json
foreach($index in 0,1,2){
    $p=Clone $fixture;$d=@($p.lastSuccessfulDispatch)+@($p.lastSuccessfulEyeDispatches)
    $d[$index]|Add-Member submittedInputs (Clone $valid)
    Check (@(Get-DevBenchNativeReadReasons -Kind fsr-colour-status -Payload $p -Arguments @{action='status';expectedBuildId=$p.producer.buildId}).Count -eq 0) 'Each status dispatch independently accepts schema1'
    $d[$index].submittedInputs.reset='false'
    Check (@(Get-DevBenchNativeReadReasons -Kind fsr-colour-status -Payload $p -Arguments @{action='status';expectedBuildId=$p.producer.buildId}).Count -gt 0) 'Each status dispatch independently rejects malformed telemetry'
}
[pscustomobject]@{ok=$true;checks=$checks;nativeSource='cb1e44e9aecc6ba0309bb44bdb5d57daa1811e69';scope='strict optional schema1 typing; availability does not establish freshness; no live calls'}|ConvertTo-Json -Compress
