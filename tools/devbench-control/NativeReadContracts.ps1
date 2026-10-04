# SPDX-License-Identifier: GPL-3.0-or-later
# Exact native read schemas. No mutation outcome or runtime admission is inferred.
function Get-DevBenchNativeReadReasons {
    param([string]$Kind, $Payload, [Collections.IDictionary]$Arguments)
    $reasons = [Collections.Generic.List[string]]::new()
    function Member($Node, [string]$Name) {
        if ($Node -isnot [pscustomobject]) { return $null }
        $p = $Node.PSObject.Properties[$Name]
        if ($p -and $p.Name -ceq $Name) { return $p.Value }
        return $null
    }
    function Require([bool]$Good, [string]$Path) { if (-not $Good) { $reasons.Add("Native $Kind read: $Path is missing, malformed or unsupported.") } }
    function UInt($Value, [decimal]$Max = [uint64]::MaxValue, [decimal]$Min = 0) {
        return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and [decimal]$Value -ge $Min -and [decimal]$Value -le $Max
    }
    function Number($Value) {
        return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64],[single],[double],[decimal]) -and -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value)
    }
    function Boolean($Node, [string]$Name, [string]$Path) { Require ((Member $Node $Name) -is [bool]) "$Path.$Name" }
    function Literal($Node, [string]$Name, [string]$Expected, [string]$Path) {
        $v = Member $Node $Name; Require ($v -is [string] -and $v -ceq $Expected) "$Path.$Name"
    }
    function Strings($Value, [string[]]$Expected, [string]$Path) {
        $good = $Value -is [array] -and $Value.Count -eq $Expected.Count
        if ($good) {
            foreach ($s in $Expected) { if (@($Value | Where-Object { $_ -is [string] -and $_ -ceq $s }).Count -ne 1) { $good = $false } }
        }
        Require $good $Path
    }
    Require ($Payload -is [pscustomobject]) 'payload (exactly one structured object required)'
    if ($Payload -isnot [pscustomobject]) { return @($reasons) }
    if ($Kind -ceq 'input-capabilities') {
        $contract = Member $Payload 'contract'; $version = Member $contract 'version'
        Literal $contract 'name' 'devbench.input' 'contract'
        Require ((UInt (Member $version 'major') 2 2) -and (UInt (Member $version 'minor') 0)) 'contract.version (2.0)'
        $caps = Member $Payload 'capabilities'
        $keyboard = Member $caps 'keyboard'; $tracked = Member $caps 'vrTrackedSet'
        foreach ($pair in @(@('keyboard',$keyboard),@('vrTrackedSet',$tracked))) {
            foreach ($name in @('available','ready')) { $v=Member $pair[1] $name; Require ($v -is [bool] -and $v) "capabilities.$($pair[0]).$name" }
        }
        Require (UInt (Member $keyboard 'version') 1 1) 'keyboard.version (1)'
        Strings (Member $keyboard 'actions') @('status','down','up','tap','sequence','releaseAll') 'keyboard.actions'
        Literal $keyboard 'encoding' 'DirectInputScanCode' 'keyboard'
        Literal $keyboard 'injection' 'Skyrim.BSInputEventQueue' 'keyboard'
        foreach ($name in @('defaultMaxHoldMs','defaultTapMs','maximumHeldKeys','maximumMaxHoldMs','maximumSequenceEvents','maximumSequenceMs')) { Require (UInt (Member $keyboard $name) ([uint32]::MaxValue) 1) "keyboard.$name" }
        $hold=Member $keyboard 'defaultMaxHoldMs'; $tap=Member $keyboard 'defaultTapMs'; $max=Member $keyboard 'maximumMaxHoldMs'; $sequence=Member $keyboard 'maximumSequenceMs'
        if ((UInt $hold) -and (UInt $tap) -and (UInt $max) -and (UInt $sequence)) { Require ($tap -le $hold -and $hold -le $max -and $tap -le $sequence) 'keyboard default/maximum hold and sequence bounds' }
        # Canonical v1 binding inventory, not an alias or a caller-supplied map.
        $bindings = 'escape:1 1:2 2:3 3:4 4:5 5:6 6:7 7:8 8:9 9:10 0:11 minus:12 equals:13 backspace:14 tab:15 q:16 w:17 e:18 r:19 t:20 y:21 u:22 i:23 o:24 p:25 leftBracket:26 rightBracket:27 enter:28 leftControl:29 a:30 s:31 d:32 f:33 g:34 h:35 j:36 k:37 l:38 semicolon:39 apostrophe:40 grave:41 leftShift:42 backslash:43 z:44 x:45 c:46 v:47 b:48 n:49 m:50 comma:51 period:52 slash:53 rightShift:54 numpadMultiply:55 leftAlt:56 space:57 capsLock:58 f1:59 f2:60 f3:61 f4:62 f5:63 f6:64 f7:65 f8:66 f9:67 f10:68 numLock:69 scrollLock:70 numpad7:71 numpad8:72 numpad9:73 numpadSubtract:74 numpad4:75 numpad5:76 numpad6:77 numpadAdd:78 numpad1:79 numpad2:80 numpad3:81 numpad0:82 numpadDecimal:83 f11:87 f12:88 numpadEnter:156 rightControl:157 numpadDivide:181 rightAlt:184 home:199 up:200 pageUp:201 left:203 right:205 end:207 down:208 pageDown:209 insert:210 delete:211 leftWindows:219 rightWindows:220 menu:221' -split ' '
        $keys = Member $keyboard 'keys'
        Require ($keys -is [array] -and $keys.Count -eq $bindings.Count) 'keyboard.keys complete canonical inventory'
        if ($keys -is [array]) {
            foreach ($binding in $bindings) {
                $parts=$binding.Split(':'); $matches=@($keys | Where-Object { (Member $_ 'key') -is [string] -and (Member $_ 'key') -ceq $parts[0] })
                Require ($matches.Count -eq 1 -and (UInt (Member $matches[0] 'scancode') ([int]$parts[1]) ([int]$parts[1]))) "keyboard.keys.$($parts[0])"
            }
        }
        $v=Member $tracked 'version'
        Require ((UInt (Member $v 'major') 1 1) -and (UInt (Member $v 'minor') 1 1)) 'vrTrackedSet.version (1.1)'
        Strings (Member $tracked 'actions') @('status','observe','sequence','stop','releaseAll') 'vrTrackedSet.actions'
        Strings (Member $tracked 'atomicDevices') @('hmd','left','right') 'vrTrackedSet.atomicDevices'
        foreach ($entry in @(
            @('device','vrTrackedSet'), @('controllerEncoding','OpenVR packetNumber/pressed/touched/five x-y axes'),
            @('injection','OpenVR IVRCompositor poses + IVRSystem controller state'), @('ordering','tMs then seq'),
            @('ownership','one bounded sequence owner; start returns a required external cleanup token'),
            @('poseEncoding','OpenVR device-to-absolute 3x4 row-major'), @('timing','steadyMillisecondsFromSequenceStart'),
            @('validation','complete sequence before activation'), @('lifecyclePolicy','default stop; recording replay may explicitly survive recorded load/new-game boundaries'))) { Literal $tracked $entry[0] $entry[1] 'vrTrackedSet' }
        $pass=Member $tracked 'passThroughWhenInactive'; Require ($pass -is [bool] -and $pass) 'vrTrackedSet.passThroughWhenInactive'
        foreach ($name in @('maximumDurationMs','maximumFrames')) { Require (UInt (Member $tracked $name) ([uint32]::MaxValue) 1) "vrTrackedSet.$name" }
    }
    elseif ($Kind -ceq 'fsr-colour-status') {
        foreach ($name in @('expectedRevision','highDynamicRangeInput','autoExposure')) { Require (-not $Arguments.Contains($name)) "status cannot accept mutation parameter $name" }
        foreach ($name in @('accepted','resultingRevision')) { Require (-not $Payload.PSObject.Properties[$name]) "status cannot qualify set receipt $name" }
        $producer=Member $Payload 'producer'
        Literal $producer 'component' 'CommunityShaders' 'producer'
        foreach ($pair in @(@('buildId',64),@('shaderCacheAbiId',64),@('sourceCommit',40))) {
            $value=Member $producer $pair[0]; Require ($value -is [string] -and $value -cmatch ('^[0-9a-f]{'+$pair[1]+'}$')) "producer.$($pair[0])"
        }
        Boolean $producer 'sourceDirty' 'producer'
        if ($Arguments.Contains('expectedBuildId')) { Require ($Arguments['expectedBuildId'] -is [string] -and $Arguments['expectedBuildId'] -ceq (Member $producer 'buildId')) 'producer expectedBuildId binding' }
        $request=Member $Payload 'requested'
        Require (UInt (Member $request 'revision')) 'requested.revision'
        foreach ($name in @('highDynamicRangeInput','autoExposure')) { Boolean $request $name 'requested' }
        foreach ($name in @('hostContext','runtimeContext')) {
            $context=Member $Payload $name
            foreach ($flag in @('valid','highDynamicRangeInput','autoExposure')) { Boolean $context $flag $name }
            Require (UInt (Member $context 'generation')) "$name.generation"
            if ((Member $context 'valid') -is [bool] -and (Member $context 'valid')) { Require (UInt (Member $context 'generation') ([uint64]::MaxValue) 1) "$name.valid generation" }
        }
        Boolean $Payload 'sourceColorContractChanged' 'payload'
        $eyes=Member $Payload 'lastSuccessfulEyeDispatches'
        Require ($eyes -is [array] -and $eyes.Count -eq 2) 'lastSuccessfulEyeDispatches (two entries)'
        $dispatches=@((Member $Payload 'lastSuccessfulDispatch'))
        if ($eyes -is [array]) { $dispatches += @($eyes) }
        for ($i=0;$i -lt $dispatches.Count;$i++) {
            $d=$dispatches[$i]; $path="dispatch[$i]"; $valid=Member $d 'valid'
            foreach ($flag in @('valid','highDynamicRangeInput','autoExposure','exposureResourceBound')) { Boolean $d $flag $path }
            foreach ($name in @('frame','path','contextIndex','renderWidth','renderHeight','displayWidth','displayHeight')) { Require (UInt (Member $d $name) ([uint32]::MaxValue)) "$path.$name" }
            foreach ($name in @('serial','contextGeneration')) { Require (UInt (Member $d $name)) "$path.$name" }
            Require (Number (Member $d 'preExposure')) "$path.preExposure"
            Require (UInt (Member $d 'path') 4) "$path.path (native FSR path 0..4)"
            if ($valid -is [bool] -and $valid) {
                Require (UInt (Member $d 'path') 4 1) "$path.valid active FSR path"
                foreach ($name in @('renderWidth','renderHeight','displayWidth','displayHeight')) { Require (UInt (Member $d $name) ([uint32]::MaxValue) 1) "$path.valid $name" }
                foreach ($name in @('serial','contextGeneration','dispatchQpc')) { Require (UInt (Member $d $name) ([uint64]::MaxValue) 1) "$path.valid $name" }
                Require (UInt (Member $d 'contextIndex') 1) "$path.contextIndex (eye 0 or 1)"
                foreach ($name in @('configuredSharpnessAtDispatch','effectiveSharpness')) { Require (Number (Member $d $name)) "$path.$name" }
                Boolean $d 'sharpeningEnabled' $path
            } elseif ($valid -is [bool]) {
                foreach ($name in @('configuredSharpnessAtDispatch','effectiveSharpness','sharpeningEnabled','dispatchQpc')) { Require ($d.PSObject.Properties[$name] -and $null -eq (Member $d $name)) "$path.invalid $name must be explicit null" }
            }
        }
        # Acceptance proves schema only. Stale, unmatched or inactive eyes remain raw
        # observations, not same-frame vendor/HDR/RS experiment qualification.
    }
    else { Require $false 'unregistered read contract' }
    return @($reasons)
}
