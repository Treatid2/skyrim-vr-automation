# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $FixtureRoot ('start-selection-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$entry=Join-Path $PSScriptRoot 'New-CSXRenderMapCapturePlan.ps1'
$checks=[Collections.Generic.List[string]]::new()
function Assert-Selection([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Write-Fixture($Value) { $p=Join-Path $root ([guid]::NewGuid().ToString('N')+'.json'); [IO.File]::WriteAllText($p,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false)); return $p }
$descriptor=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-render-map-start.ad8.json') -Raw|ConvertFrom-Json -Depth 30
$schemaPath=Write-Fixture $descriptor
$defaults=[ordered]@{fixedCatalogueBytes=1000;eventStorageUnitBytes=100}
$limits=[ordered]@{maximumBytes=100000;maximumDurationMs=10000;maximumEvents=10000;maximumFrames=100;maximumScopeDepth=32}
$observations=[ordered]@{}
foreach($family in @('Geometry','MaterialState','Resource','SceneObject','Shader','StageShader','TargetBinding','TargetView')) {
    $defaults['max'+$family+'Observations']=20; $limits['maximum'+$family+'Observations']=1000
    $observations[$family.Substring(0,1).ToLowerInvariant()+$family.Substring(1)]=10
}
$registry=[pscustomobject]@{ok=$true;result=[pscustomobject]@{service='communityshaders.render-map';major=1;producerBuildId='fixture-ad8';defaults=[pscustomobject]$defaults;limits=[pscustomobject]$limits;eventSelection=@{optional=$true};eventKinds=@('draw','eye-submitted');activationModes=@('immediate','main_post_processing');geometrySelection=@{executionWithinSelectedGeometry='optional native Boolean'};lateWindow=@{runtime='SkyrimVR';maximumActivationWaitMs=10000}}}
$registryPath=Write-Fixture $registry
$workloadPath=Write-Fixture @{expectedDurationMs=1000;expectedFrames=1;expectedEvents=100;expectedEventBytes=10000;expectedScopeDepth=4;expectedObservations=$observations}
$base=@{RegistryPath=$registryPath;WorkloadPath=$workloadPath;ClientId='fixture-client';CommandId='fixture-command';InputSchemaPath=$schemaPath;ExpectedInputSchemaSha256=(Get-FileHash -LiteralPath $schemaPath).Hash;Activation='main_post_processing';MaxActivationWaitMs=2000;ExecutionWithinSelectedGeometry=$false;EventKinds=@('eye-submitted');NoExit=$true;Compact=$true}
function Invoke-Plan([hashtable]$Changes=@{},[string[]]$Omit=@()) {
    $a=@{};foreach($key in $base.Keys){$a[$key]=$base[$key]};foreach($key in $Changes.Keys){$a[$key]=$Changes[$key]};foreach($key in $Omit){$a.Remove($key)}
    $a.OutputPath=Join-Path $root ([guid]::NewGuid().ToString('N')+'.plan.json')
    return (& $entry @a|ConvertFrom-Json -Depth 30)
}
function Reject([hashtable]$Changes,[string]$Name,[string[]]$Omit=@()) {
    $r=Invoke-Plan $Changes $Omit
    Assert-Selection (-not $r.ok -and $null -eq $r.arguments -and -not $r.receiptPublished) $Name
}
$r=Invoke-Plan
Assert-Selection $r.ok 'production planner admits ad8 late selection offline'
$receipt=Get-Content -LiteralPath $r.receiptPath -Raw|ConvertFrom-Json -Depth 30
Assert-Selection (($r.arguments|ConvertTo-Json -Depth 20 -Compress) -ceq ($receipt.arguments|ConvertTo-Json -Depth 20 -Compress)) 'returned request equals immutable receipt exactly'
Assert-Selection ($r.arguments.executionWithinSelectedGeometry -is [bool] -and -not $r.arguments.executionWithinSelectedGeometry) 'explicit Boolean false retained'
Assert-Selection ($r.arguments.activation -ceq 'main_post_processing' -and $r.arguments.maxActivationWaitMs -eq 2000 -and ($r.arguments.eventKinds -join ',') -ceq 'eye-submitted') 'exact activation wait and event selection retained'
Assert-Selection ($receipt.startSelection.inputSchemaSha256 -ceq (Get-FileHash -LiteralPath $schemaPath).Hash -and $receipt.registrySha256 -ceq (Get-FileHash -LiteralPath $registryPath).Hash) 'schema and registry immutable snapshot hashes retained'
foreach($value in @('unknown','MAIN_POST_PROCESSING',$true,2000)) { Reject @{Activation=$value} 'unknown or malformed activation refused' }
foreach($value in @(-1,0,10001,1.5,'2000',$true,$null,[long]::MaxValue)) { Reject @{MaxActivationWaitMs=$value} 'invalid activation wait refused' }
foreach($value in @('false',0,$null,$true)) { Reject @{ExecutionWithinSelectedGeometry=$value} 'non-Boolean or restricted late geometry refused' }
foreach($omit in @('InputSchemaPath','ExpectedInputSchemaSha256','MaxActivationWaitMs','ExecutionWithinSelectedGeometry','EventKinds','Activation')) { Reject @{} "missing required selection evidence $omit refused" @($omit) }
Reject @{ExpectedInputSchemaSha256=('0'*64)} 'wrong schema hash refused'
Reject @{EventKinds=@('draw')} 'late window without requested eye-submitted refused'
Reject @{Activation='immediate'} 'activation wait with immediate selection refused'
foreach($case in @('major','modes','runtime','wait-limit','missing-window','geometry')) {
    $bad=$registry|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30
    switch($case){'major'{$bad.result.major=2};'modes'{$bad.result.activationModes=@('immediate')};'runtime'{$bad.result.lateWindow.runtime='SkyrimSE'};'wait-limit'{$bad.result.lateWindow.maximumActivationWaitMs=1999};'missing-window'{$bad.result.PSObject.Properties.Remove('lateWindow')};'geometry'{$bad.result.PSObject.Properties.Remove('geometrySelection')}}
    Reject @{RegistryPath=(Write-Fixture $bad)} "unsupported registry $case refused"
}
foreach($case in @('tool','type','major','action','activation','wait','boolean','minimum','maximum')) {
    $bad=$descriptor|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30
    switch($case){'tool'{$bad.name='foreign'};'type'{$bad.inputSchema.type='string'};'major'{$bad.inputSchema.properties.contractMajor.const=2};'action'{$bad.inputSchema.properties.action.enum=@('registry')};'activation'{$bad.inputSchema.properties.activation.enum=@('immediate')};'wait'{$bad.inputSchema.properties.maxActivationWaitMs.type='string'};'boolean'{$bad.inputSchema.properties.executionWithinSelectedGeometry.type='string'};'minimum'{$bad.inputSchema.properties.maxActivationWaitMs.minimum=2001};'maximum'{$bad.inputSchema.properties.maxActivationWaitMs.maximum=1999}}
    $path=Write-Fixture $bad
    Reject @{InputSchemaPath=$path;ExpectedInputSchemaSha256=(Get-FileHash -LiteralPath $path).Hash} "unsupported schema $case refused"
}
$legacy=Invoke-Plan @{} @('Activation','MaxActivationWaitMs','ExecutionWithinSelectedGeometry','InputSchemaPath','ExpectedInputSchemaSha256')
Assert-Selection ($legacy.ok -and -not $legacy.arguments.PSObject.Properties['activation']) 'omitted selectors preserve existing planner behavior'
$immediate=Invoke-Plan @{Activation='immediate';ExecutionWithinSelectedGeometry=$true} @('MaxActivationWaitMs')
Assert-Selection ($immediate.ok -and $immediate.arguments.executionWithinSelectedGeometry) 'supported immediate selection preserves true Boolean'
$r=Invoke-Plan @{InternalTestFailurePoint='receipt-hash'}
Assert-Selection (-not $r.ok -and $r.receiptPublished -and $null -eq $r.arguments) 'finalization failure withholds selected start arguments'
[pscustomobject]@{ok=$true;checks=$checks.Count;scope='Production planner entry point with source-derived ad8 schema and synthetic registry; no live schema currency or runtime qualification';runtimeChanged=$false;liveQualified=$false}|ConvertTo-Json -Compress
