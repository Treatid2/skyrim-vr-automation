# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes=0; $failures=[Collections.Generic.List[string]]::new()
function Check([bool]$Good,[string]$Label) { if ($Good) { $script:passes++ } else { $failures.Add($Label) } }
function Copy-NativeFixture($Value) { return $Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50 }
function Read-Input($Content) { return Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{action='capabilities'} -Content $Content }
function Read-Colour($Content) { return Get-DevBenchCallSemanticStatus -ToolName communityshaders.fsr_color_contract -Arguments @{action='status';expectedBuildId=$colour.producer.buildId} -Content $Content }
function Change($Node,[string]$Path,$Value,[switch]$Remove) {
    $parts=$Path.Split('.'); $owner=$Node
    for($i=0;$i -lt $parts.Count-1;$i++) { $owner=$owner.($parts[$i]) }
    $name=$parts[-1]
    if ($Remove) { $owner.PSObject.Properties.Remove($name) } else { $owner.$name=$Value }
}
$input=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-input-capabilities.v2.json') -Raw | ConvertFrom-Json -Depth 40
$colour=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-fsr-colour-status.json') -Raw | ConvertFrom-Json -Depth 40
$hashBefore=($input | ConvertTo-Json -Depth 40 -Compress)
$status=Read-Input @($input)
Check ($status.known -and $status.ok -and $status.completionBasis -eq 'read-schema-only' -and $null -ne $status.qualifiedInputCapabilities) 'observed native input v2 qualifies without generic ok'
Check (($input|ConvertTo-Json -Depth 40 -Compress) -ceq $hashBefore) 'input source payload is unchanged'
Check ($status.qualifiedInputCapabilities.capabilities.keyboard.keys.Count -eq 102) 'all canonical keyboard bindings retained'
Check ($status.qualifiedInputCapabilities.capabilities.vrTrackedSet.atomicDevices.Count -eq 3) 'all atomic devices retained'
foreach($path in @('contract','contract.name','contract.version','contract.version.major','contract.version.minor','capabilities','capabilities.keyboard','capabilities.vrTrackedSet')) {
    $bad=Copy-NativeFixture $input; Change $bad $path $null -Remove
    $s=Read-Input @($bad); Check (-not $s.ok -and $null -eq $s.qualifiedInputCapabilities) "input missing $path refuses projection"
}
foreach($node in @('keyboard','vrTrackedSet')) {
    foreach($property in @($input.capabilities.$node.PSObject.Properties)) {
        $bad=Copy-NativeFixture $input; $bad.capabilities.$node.PSObject.Properties.Remove($property.Name)
        $s=Read-Input @($bad); Check (-not $s.ok -and $null -eq $s.qualifiedInputCapabilities) "input $node missing $($property.Name)"
    }
    foreach($flag in @('available','ready')) { foreach($value in @($false,'true',1,$null)) {
        $bad=Copy-NativeFixture $input; $bad.capabilities.$node.$flag=$value
        Check (-not (Read-Input @($bad)).ok) "input $node.$flag rejects false or coercible type"
    } }
}
foreach($path in @('capabilities.keyboard.defaultMaxHoldMs','capabilities.keyboard.maximumSequenceMs','capabilities.keyboard.maximumHeldKeys','capabilities.vrTrackedSet.maximumDurationMs','capabilities.vrTrackedSet.maximumFrames')) {
    foreach($value in @(-1,0,1.5,$true,'100',$null,[uint64]4294967296)) { $bad=Copy-NativeFixture $input; Change $bad $path $value; Check (-not (Read-Input @($bad)).ok) "input $path rejects malformed limit" }
}
foreach($defect in @('foreign','major','minor','keyboardVersion','trackedVersion','duplicateAction','missingAction','duplicateDevice','encoding','ownership','partialKeyMap','extraKey','duplicateKey','wrongScancode','stringScancode','negativeScancode','wrongKeyCase','defaultBounds','nestedError','okFalse')) {
    $bad=Copy-NativeFixture $input
    switch($defect) {
        foreign {$bad.contract.name='foreign'}; major {$bad.contract.version.major='2'}; minor {$bad.contract.version.minor=1}
        keyboardVersion {$bad.capabilities.keyboard.version=2}; trackedVersion {$bad.capabilities.vrTrackedSet.version.major=2}
        duplicateAction {$bad.capabilities.keyboard.actions[0]='tap'}; missingAction {$bad.capabilities.vrTrackedSet.actions=@('status')}
        duplicateDevice {$bad.capabilities.vrTrackedSet.atomicDevices=@('hmd','hmd','right')}
        encoding {$bad.capabilities.keyboard.encoding='VirtualKey'}; ownership {$bad.capabilities.vrTrackedSet.ownership='any owner'}
        partialKeyMap {$bad.capabilities.keyboard.keys=@($bad.capabilities.keyboard.keys|Select-Object -Skip 1)}
        extraKey {$bad.capabilities.keyboard.keys+=@([pscustomobject]@{key='alias';scancode=15})}
        duplicateKey {$bad.capabilities.keyboard.keys[1]=$bad.capabilities.keyboard.keys[0]}
        wrongScancode {$bad.capabilities.keyboard.keys[0].scancode=9}; stringScancode {$bad.capabilities.keyboard.keys[0].scancode='1'}
        negativeScancode {$bad.capabilities.keyboard.keys[0].scancode=-1}; wrongKeyCase {$bad.capabilities.keyboard.keys[0].key='Escape'}
        defaultBounds {$bad.capabilities.keyboard.defaultTapMs=60001}; nestedError {$bad.capabilities.keyboard|Add-Member error 'unavailable'}; okFalse {$bad|Add-Member ok $false}
    }
    $s=Read-Input @($bad); Check (-not $s.ok -and $null -eq $s.qualifiedInputCapabilities) "input $defect refuses projection"
}
foreach($content in @(@($input,$input),@([pscustomobject]@{ok=$true}),@('scalar'),@(,@($input)))) { Check (-not (Read-Input $content).ok) 'input refuses foreign/multiple/scalar/nested payloads' }
Check (Test-DevBenchReadOnlyRequest -ToolName input -Arguments @{action='capabilities'}) 'explicit input capabilities is read-only'
foreach($action in @('sequence','CAPABILITIES','releaseAll','')) { Check (-not (Test-DevBenchReadOnlyRequest -ToolName input -Arguments @{action=$action})) 'input mutations/case drift are not read-only capabilities' }
$status=Read-Colour @($colour)
Check ($status.known -and $status.ok -and $status.completionBasis -eq 'read-schema-only') 'observed native colour status qualifies without generic ok'
Check (Test-DevBenchReadOnlyRequest -ToolName communityshaders.fsr_color_contract -Arguments @{action='status'}) 'explicit colour status is read-only'
foreach($path in @('producer','producer.component','producer.buildId','producer.shaderCacheAbiId','producer.sourceCommit','producer.sourceDirty','requested','requested.revision','requested.highDynamicRangeInput','requested.autoExposure','hostContext','runtimeContext','lastSuccessfulDispatch','lastSuccessfulEyeDispatches','sourceColorContractChanged')) {
    $bad=Copy-NativeFixture $colour; Change $bad $path $null -Remove; Check (-not (Read-Colour @($bad)).ok) "colour missing $path"
}
foreach($node in @('hostContext','runtimeContext','lastSuccessfulDispatch')) {
    foreach($property in @($colour.$node.PSObject.Properties)) {
        $bad=Copy-NativeFixture $colour; $bad.$node.PSObject.Properties.Remove($property.Name)
        Check (-not (Read-Colour @($bad)).ok) "colour $node missing $($property.Name)"
    }
}
foreach($value in @(-1,1.5,$true,'1',$null)) {
    foreach($path in @('requested.revision','runtimeContext.generation','lastSuccessfulDispatch.serial','lastSuccessfulDispatch.dispatchQpc','lastSuccessfulDispatch.renderWidth','lastSuccessfulDispatch.contextIndex')) {
        $bad=Copy-NativeFixture $colour; Change $bad $path $value; Check (-not (Read-Colour @($bad)).ok) "colour $path rejects malformed unsigned value"
    }
}
foreach($defect in @('foreignProducer','foreignBuild','booleanString','nan','infinity','scalarEyes','oneEye','threeEyes','eyeMalformed','inactivePath','unknownPath','index2','validZeroDimension','validZeroGeneration','setReceipt','nestedError','okFalse')) {
    $bad=Copy-NativeFixture $colour
    switch($defect) {
        foreignProducer {$bad.producer.component='foreign'}; foreignBuild {$bad.producer.buildId='f'*64}; booleanString {$bad.requested.autoExposure='true'}
        nan {$bad.lastSuccessfulDispatch.effectiveSharpness=[double]::NaN}; infinity {$bad.lastSuccessfulDispatch.preExposure=[double]::PositiveInfinity}
        scalarEyes {$bad.lastSuccessfulEyeDispatches='scalar'}; oneEye {$bad.lastSuccessfulEyeDispatches=@($bad.lastSuccessfulEyeDispatches[0])}
        threeEyes {$bad.lastSuccessfulEyeDispatches+=@($bad.lastSuccessfulDispatch)}; eyeMalformed {$bad.lastSuccessfulEyeDispatches[1].dispatchQpc='1'}
        inactivePath {$bad.lastSuccessfulDispatch.path=0}; unknownPath {$bad.lastSuccessfulDispatch.path=5}; index2 {$bad.lastSuccessfulDispatch.contextIndex=2}
        validZeroDimension {$bad.lastSuccessfulDispatch.renderWidth=0}; validZeroGeneration {$bad.runtimeContext.generation=0}
        setReceipt {$bad|Add-Member accepted $true}; nestedError {$bad.runtimeContext|Add-Member error 'unavailable'}; okFalse {$bad|Add-Member ok $false}
    }
    Check (-not (Read-Colour @($bad)).ok) "colour $defect is refused"
}
foreach($content in @(@($colour,$colour),@([pscustomobject]@{ok=$true}),@('scalar'),@(,@($colour)))) { Check (-not (Read-Colour $content).ok) 'colour refuses foreign/multiple/scalar/nested payloads' }
$inactive=Copy-NativeFixture $colour
foreach($d in @($inactive.lastSuccessfulDispatch)+@($inactive.lastSuccessfulEyeDispatches)) {
    $d.valid=$false
    foreach($name in @('configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled','dispatchQpc')) { $d.$name=$null }
}
$inactive.runtimeContext.valid=$false; $inactive.runtimeContext.generation=0
Check ((Read-Colour @($inactive)).ok) 'inactive contexts/explicit null invalid-dispatch evidence remain valid reads, not vendor admission'
$unmatched=Copy-NativeFixture $colour; $unmatched.lastSuccessfulEyeDispatches[0].frame--
Check ((Read-Colour @($unmatched)).ok) 'typed unmatched eye frames are preserved, not promoted to scientific synchronization'
foreach($name in @('expectedRevision','highDynamicRangeInput','autoExposure')) {
    $args=@{action='status'}; $args[$name]=1
    Check (-not (Get-DevBenchCallSemanticStatus -ToolName communityshaders.fsr_color_contract -Arguments $args -Content @($colour)).ok) 'status rejects mutation arguments'
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.fsr_color_contract -Arguments $args)) 'mutation parameters cannot enter read-only admission'
}
foreach($action in @('set','probe','STATUS','')) {
    $s=Get-DevBenchCallSemanticStatus -ToolName communityshaders.fsr_color_contract -Arguments @{action=$action} -Content @($colour)
    Check (-not $s.known) 'colour typed status does not qualify set/probe/case drift'
}
Check (-not (Get-DevBenchCallSemanticStatus -ToolName input -Arguments @{action=@('capabilities')} -Content @($input)).known) 'array action cannot select the native input read adapter'
Check (-not (Get-DevBenchCallSemanticStatus -ToolName communityshaders.fsr_color_contract -Arguments @{action=@('status')} -Content @($colour)).known) 'array action cannot select the native colour read adapter'
if($failures.Count) { [pscustomobject]@{ok=$false;passed=$passes;failed=$failures.Count;failures=@($failures)}|ConvertTo-Json -Depth 5; exit 1 }
[pscustomobject]@{ok=$true;passed=$passes;failed=0;scope='offline exact-native schemas; no runtime calls or scientific admission'}|ConvertTo-Json
