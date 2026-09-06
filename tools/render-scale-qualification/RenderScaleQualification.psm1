# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\devbench-control\DevBenchControl.psm1') -Force

function Get-CSXPropertyValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        return $(if ($InputObject.Contains($Name)) { $InputObject[$Name] } else { $Default })
    }
    $property = $InputObject.PSObject.Properties[$Name]
    return $(if ($property) { $property.Value } else { $Default })
}

function Get-CSXPathValue {
    param($InputObject, [Parameter(Mandatory)][string]$Path, $Default = $null)
    $value = $InputObject
    foreach ($part in $Path.Split('.')) {
        $sentinel = [object]::new()
        $next = Get-CSXPropertyValue -InputObject $value -Name $part -Default $sentinel
        if ([object]::ReferenceEquals($next, $sentinel)) { return $Default }
        $value = $next
    }
    return $value
}

function Write-CSXJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 80)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $fullPath
}

function Write-CSXTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Value, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $fullPath
}

function Get-CSXFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Evidence file does not exist: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CSXObjectSha256 {
    param([Parameter(Mandatory)]$Value)
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-CSXProtocol {
    param([Parameter(Mandatory)]$Protocol)
    if ([string]$Protocol.schema -ne 'csx-render-scale-pr-v1' -or [int]$Protocol.protocolRevision -ne 4) {
        throw 'The protocol must be csx-render-scale-pr-v1 revision 4.'
    }
    if ([string]$Protocol.requiredMethodsCommit -ne 'b46edeaed14c41ad41225641c3a4943f1db25db6') {
        throw 'The protocol does not bind the required DLSS trace methods commit.'
    }
    if ([string]$Protocol.transitionTimingOrigin -ne 'qualification_dispatch') {
        throw 'The protocol must measure transitions from the server dispatch mark.'
    }
    if ([string]$Protocol.transitionExecution -ne 'fail_fast_top_level_mcp') {
        throw 'The protocol must fail fast on every top-level transition MCP call.'
    }
    if ([string]$Protocol.fixtureManifestSchema -ne 'csx-render-scale-fixture-v1' -or [int]$Protocol.thresholds.stressRecordSchemaVersion -ne 13) {
        throw 'The protocol must bind fixture schema v1 and stress-record schema v13.'
    }
    if ([int]$Protocol.timeBudget.endToEndMs -ne 600000 -or [int]$Protocol.timeBudget.orchestrationMs -ne 585000 -or
        [int]$Protocol.timeBudget.captureAssaysMs -ne 495000 -or [int]$Protocol.timeBudget.visualEvaluationMs -ne 90000 -or
        [int]$Protocol.timeBudget.evidenceFinalizationMs -ne 15000 -or [int]$Protocol.timeBudget.recoveryMs -ne 30000 -or
        [int]$Protocol.timeBudget.recoveryMinimumElapsedMs -ne 29900 -or [int]$Protocol.timeBudget.recoveryMaximumElapsedMs -ne 35000) {
        throw 'The protocol must preserve the 600 second unattended cap and 30 second recovery barriers.'
    }
    if ([int]$Protocol.cocAssay.transitionCount -ne 20) { throw 'COC assay must contain exactly 20 transitions.' }
    if ([string]$Protocol.fixture.startCellEditorId -ne 'WindhelmExterior01' -or
        [string]$Protocol.fixture.interiorCellEditorId -ne 'WhiterunDragonsreach' -or
        [string]$Protocol.cocAssay.firstTarget -ne 'WhiterunDragonsreach' -or
        [string]$Protocol.cocAssay.secondTarget -ne 'WindhelmExterior01') {
        throw 'The canonical protocol requires the exact Windhelm/Dragonsreach COC fixture.'
    }
    $foveation = $Protocol.fixture.foveation
    if (-not [bool]$foveation.foveatedVendorDispatch -or [double]$foveation.foveatedCenterArea -ne 0.3 -or
        -not [bool]$foveation.peripheryTAAEnable -or [double]$foveation.peripheryTAACenterArea -ne 0.3 -or
        [double]$foveation.peripheryTAAOuterScale -ne 0.7) {
        throw 'The canonical protocol requires foveation 0.3 plus periphery TAA 0.3/0.7.'
    }
    $nvidiaInterior = $Protocol.fixture.profiles.nvidiaInterior
    $amdInterior = $Protocol.fixture.profiles.amdInterior
    $sharedExterior = $Protocol.fixture.profiles.sharedExterior
    if ([string]$nvidiaInterior.method -ne 'dlss' -or [int]$nvidiaInterior.qualityModeValue -ne 0 -or
        [bool]$nvidiaInterior.renderScaleMode -or [string]$nvidiaInterior.dlssProfile -ne 'K' -or
        [int]$nvidiaInterior.dlssPresetValue -ne 1 -or [string]$amdInterior.method -ne 'fsr' -or
        [int]$amdInterior.qualityModeValue -ne 0 -or [bool]$amdInterior.renderScaleMode -or
        [string]$sharedExterior.method -ne 'fsr' -or [int]$sharedExterior.qualityModeValue -ne 1 -or
        -not [bool]$sharedExterior.renderScaleMode) {
        throw 'The canonical protocol requires exact NVIDIA DLAA/K, AMD AA, and shared FSR Hoshipa profiles.'
    }
    if ((@($Protocol.cocAssay.diagnostics) -join ',') -ne 'render_scale_stress,cpu_performance' -or
        [int]$Protocol.menuAssay.traceReadLimit -ne 16) {
        throw 'The canonical protocol requires both diagnostics and the exact DLSS trace read bound.'
    }
    foreach ($matrixName in @('nvidiaMatrix', 'amdMatrix')) {
        $matrix = @($Protocol.menuAssay.$matrixName)
        if ($matrix.Count -ne 25) { throw "$matrixName must contain exactly 25 transitions." }
        for ($i = 0; $i -lt $matrix.Count; $i++) {
            if ([int]$matrix[$i].ordinal -ne $i + 1) { throw "$matrixName ordinals must be contiguous from 1 to 25." }
            $labels = @('native_aa', 'hoshipa', 'ultra_quality', 'quality', 'balanced', 'performance', 'ultra_performance')
            $quality = [int]$matrix[$i].qualityModeValue
            if ($quality -lt 0 -or $quality -gt 6 -or [string]$matrix[$i].qualityMode -ne $labels[$quality] -or [bool]$matrix[$i].renderScaleMode -ne ($quality -ne 0)) {
                throw "$matrixName has incoherent quality label/value/render-scale state at ordinal $($i + 1)."
            }
            if ($i -gt 0) {
                $left = "$($matrix[$i - 1].method)|$($matrix[$i - 1].qualityModeValue)|$($matrix[$i - 1].renderScaleMode)"
                $right = "$($matrix[$i].method)|$($matrix[$i].qualityModeValue)|$($matrix[$i].renderScaleMode)"
                if ($left -eq $right) { throw "$matrixName contains an adjacent duplicate at ordinal $($i + 1)." }
            }
        }
        $last = $matrix[-1]
        if ($last.method -ne 'fsr' -or $last.qualityMode -ne 'hoshipa' -or -not [bool]$last.renderScaleMode) {
            throw "$matrixName must finish at FSR Hoshipa with render scale active."
        }
    }
    $canonicalNvidia = @(
        'dlss|0','dlss|1','dlss|2','dlss|3','dlss|4','dlss|5','dlss|6','fsr|6','fsr|5','fsr|4','fsr|3','fsr|2','fsr|1','fsr|0','dlss|0','fsr|0','fsr|1','dlss|1','dlss|6','fsr|6','fsr|0','dlss|0','dlss|1','fsr|0','fsr|1'
    )
    $canonicalAmd = @(
        'fsr|0','fsr|1','fsr|2','fsr|3','fsr|4','fsr|5','fsr|6','fsr|0','fsr|6','fsr|0','fsr|1','fsr|0','fsr|2','fsr|3','fsr|0','fsr|4','fsr|0','fsr|5','fsr|0','fsr|6','fsr|1','fsr|6','fsr|0','fsr|6','fsr|1'
    )
    $actualNvidia = @($Protocol.menuAssay.nvidiaMatrix | ForEach-Object { "$($_.method)|$([int]$_.qualityModeValue)" })
    $actualAmd = @($Protocol.menuAssay.amdMatrix | ForEach-Object { "$($_.method)|$([int]$_.qualityModeValue)" })
    if (($actualNvidia -join ',') -ne ($canonicalNvidia -join ',') -or ($actualAmd -join ',') -ne ($canonicalAmd -join ',')) {
        throw 'The canonical protocol requires the exact NVIDIA and AMD menu orders.'
    }
    $nvidiaMethods = @($Protocol.menuAssay.nvidiaMatrix.method | Sort-Object -Unique)
    if ('dlss' -notin $nvidiaMethods -or 'fsr' -notin $nvidiaMethods) { throw 'NVIDIA matrix must exercise DLSS and FSR.' }
    if (@($Protocol.menuAssay.amdMatrix | Where-Object method -ne 'fsr').Count -ne 0) { throw 'AMD matrix must be FSR-only.' }
    if ([int]$Protocol.visualAssay.replicates -ne 3 -or [int]$Protocol.visualAssay.frameCount -ne 16 -or
        [string]$Protocol.visualAssay.schedule.basis -ne 'wall_clock' -or
        [int]$Protocol.visualAssay.schedule.intervalMs -ne 4000 -or
        [int]$Protocol.visualAssay.schedule.startDelayMs -ne 0 -or
        [string]$Protocol.visualAssay.schedule.pausePolicy -ne 'hold' -or
        [string]$Protocol.visualAssay.source.kind -ne 'hmd_submission' -or
        [string]$Protocol.visualAssay.source.fallback -ne 'reject' -or
        (@($Protocol.visualAssay.outputs) -join ',') -ne 'side_by_side,left_eye,right_eye' -or
        [string]$Protocol.visualAssay.format -ne 'png' -or
        [string]$Protocol.visualAssay.colourContract -ne 'sdr_srgb' -or
        [string]$Protocol.visualAssay.overwrite -ne 'never' -or
        (@($Protocol.visualAssay.reviewOrdinals) -join ',') -ne '1,8,16') {
        throw 'Visual assay must be three 16-frame, one-minute sequences reviewed at 1/8/16.'
    }
    $evaluation = $Protocol.visualAssay.evaluation
    if ([string]$evaluation.mode -ne 'unattended_image_model' -or [bool]$evaluation.humanAllowed -or
        [string]$evaluation.provider -ne 'codex_cli' -or [string]$evaluation.model -ne 'gpt-5.6-sol' -or
        [int]$evaluation.promptRevision -ne 1 -or [string]$evaluation.promptFile -ne 'visual-review.prompt.v1.md' -or
        [string]$evaluation.promptSha256 -ne '1d0926fc81e2b4b3dc7f51eee2b30ef08ce40fd9715aeeeda674b71aed46ac04' -or
        [string]$evaluation.outputSchemaFile -ne 'visual-review.output-schema.v1.json' -or
        [string]$evaluation.outputSchemaSha256 -ne 'bab27931bd21dfe86c7675d4e37f37061031adbf124576952e03ddfb16d54470' -or
        [int]$evaluation.presentationPasses -ne 2 -or [string]$evaluation.presentationOrder -ne 'blinded_swapped_ab' -or
        [int]$evaluation.parallelReplicates -ne 3 -or [string]$evaluation.minimumConfidence -ne 'medium' -or
        [int]$evaluation.timeoutMs -ne 90000 -or [string]$evaluation.failurePolicy -ne 'fail_closed') {
        throw 'Visual evaluation must use the exact zero-human, swapped-order Codex vision contract.'
    }
    if (-not [bool]$Protocol.thresholds.prBaselineRequired -or
        [int]$Protocol.thresholds.visualRequestedFramesPerReplicate -ne 16 -or
        [int]$Protocol.thresholds.visualWrittenFramesPerReplicate -ne 16 -or
        [int]$Protocol.thresholds.visualDroppedFramesPerReplicate -ne 0 -or
        [int]$Protocol.thresholds.visualFailedFramesPerReplicate -ne 0 -or
        [int]$Protocol.thresholds.visualMinimumElapsedMsPerReplicate -ne 59000 -or
        [int]$Protocol.thresholds.visualMaximumElapsedMsPerReplicate -ne 65000) {
        throw 'The protocol must require a PR baseline and exact 16/0 visual capture counts.'
    }
    $allocated = [int]$Protocol.timeBudget.cocAssayMs + [int]$Protocol.timeBudget.menuAssayMs +
        [int]$Protocol.timeBudget.visualAssayMs + 2 * [int]$Protocol.timeBudget.recoveryMs
    if ($allocated -ne [int]$Protocol.timeBudget.captureAssaysMs -or
        $allocated + [int]$Protocol.timeBudget.visualEvaluationMs -ne [int]$Protocol.timeBudget.orchestrationMs -or
        [int]$Protocol.timeBudget.orchestrationMs + [int]$Protocol.timeBudget.evidenceFinalizationMs -ne [int]$Protocol.timeBudget.endToEndMs) {
        throw 'Capture, vision, and finalization allocations do not exactly fit the unattended cap.'
    }
    $canonicalProtocolSha256 = 'b0842394300f5c9e87f08afcd1b09d64aa551d1c1fc157d432710df046865074'
    if ((Get-CSXObjectSha256 -Value $Protocol) -ne $canonicalProtocolSha256) {
        throw 'The revision-4 protocol definition changed; publish a new protocol revision instead.'
    }
}

function Get-CSXQualificationProtocol {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Protocol does not exist: $fullPath" }
    $raw = Get-Content -LiteralPath $fullPath -Raw
    $protocol = $raw | ConvertFrom-Json -Depth 100
    Assert-CSXProtocol -Protocol $protocol
    return [pscustomobject][ordered]@{
        path = $fullPath
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        protocol = $protocol
    }
}

function Get-CSXFixtureManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Fixture manifest does not exist: $fullPath" }
    $manifest = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json -Depth 50
    if ([string]$manifest.schema -ne 'csx-render-scale-fixture-v1') { throw 'Fixture manifest schema must be csx-render-scale-fixture-v1.' }
    foreach ($pathName in @(
        'fixtureId', 'save.id', 'save.sha256', 'camera.id', 'camera.configurationSha256',
        'vrFpsStabilizer.version', 'vrFpsStabilizer.configurationSha256',
        'gpu.vendor', 'gpu.deviceId', 'gpu.driverVersion',
        'hmd.model', 'hmd.runtime', 'hmd.runtimeVersion',
        'attestation.operatorId', 'attestation.recordedUtc'
    )) {
        $value = [string](Get-CSXPathValue $manifest $pathName)
        if ($value -notmatch '\S') { throw "Fixture manifest requires '$pathName'." }
        if ($value -match '^(replace[-_ ]|example$|placeholder$|unknown$|todo$|changeme$)') { throw "Fixture manifest '$pathName' still contains an example placeholder." }
    }
    foreach ($pathName in @('save.sha256', 'camera.configurationSha256', 'vrFpsStabilizer.configurationSha256')) {
        $hash = [string](Get-CSXPathValue $manifest $pathName)
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$' -or $hash -match '^0{64}$') { throw "Fixture manifest '$pathName' must be a real, nonzero SHA-256." }
    }
    if (-not [string]::Equals([string]$manifest.gpu.vendor, $GpuVendor, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture GPU vendor '$($manifest.gpu.vendor)' does not match requested matrix '$GpuVendor'."
    }
    $refreshHz = [double](Get-CSXPathValue $manifest 'hmd.refreshHz' 0)
    if (-not [double]::IsFinite($refreshHz) -or $refreshHz -le 0) { throw "Fixture manifest requires a positive finite 'hmd.refreshHz'." }
    $expectedAttestedFields = @('save', 'camera', 'vrFpsStabilizer', 'hmd')
    if ((@($manifest.attestation.operatorAttestedFields) -join ',') -ne ($expectedAttestedFields -join ',')) {
        throw 'Fixture manifest must explicitly attest save, camera, vrFpsStabilizer, and hmd in that order.'
    }
    $attestedUtc = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$manifest.attestation.recordedUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$attestedUtc)) {
        throw 'Fixture manifest attestation.recordedUtc must be an ISO-8601 timestamp.'
    }
    return [pscustomobject][ordered]@{
        path = $fullPath
        sha256 = Get-CSXFileSha256 $fullPath
        manifest = $manifest
    }
}

function Convert-CSXAdapterId {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Label)
    if ($Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) {
        $number = [uint64]$Value
        if ($number -gt [uint32]::MaxValue) { throw "$Label exceeds a 32-bit adapter identifier." }
        return [uint32]$number
    }
    $text = ([string]$Value).Trim()
    if ($text -match '^0[xX]([0-9A-Fa-f]{1,8})$') { return [Convert]::ToUInt32($Matches[1], 16) }
    $parsed = [uint32]0
    if ([uint32]::TryParse($text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    throw "$Label must be a decimal or 0x-prefixed 32-bit adapter identifier."
}

function Get-CSXLiveGpuFixtureEvidence {
    param(
        [Parameter(Mandatory)]$Adapter,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor
    )
    if (-not [bool](Get-CSXPropertyValue $Adapter 'available' $false) -or
        -not [bool](Get-CSXPropertyValue $Adapter 'driverVersionAvailable' $false)) {
        throw 'Live D3D adapter or driver identity is unavailable.'
    }
    $expectedVendorId = if ($GpuVendor -eq 'NVIDIA') { [uint32]0x10DE } else { [uint32]0x1002 }
    $liveVendorId = Convert-CSXAdapterId -Value (Get-CSXPropertyValue $Adapter 'vendorId') -Label 'Live vendor ID'
    $liveDeviceId = Convert-CSXAdapterId -Value (Get-CSXPropertyValue $Adapter 'deviceId') -Label 'Live device ID'
    $manifestDeviceId = Convert-CSXAdapterId -Value (Get-CSXPathValue $Manifest 'gpu.deviceId') -Label 'Manifest GPU device ID'
    $liveDriver = ([string](Get-CSXPropertyValue $Adapter 'driverVersion')).Trim()
    $manifestDriver = ([string](Get-CSXPathValue $Manifest 'gpu.driverVersion')).Trim()
    if ($liveVendorId -ne $expectedVendorId) {
        throw "The live D3D adapter vendor does not match the selected $GpuVendor matrix."
    }
    if ($liveDeviceId -ne $manifestDeviceId) { throw 'The live D3D adapter device ID differs from the fixture manifest.' }
    if ([string]::IsNullOrWhiteSpace($liveDriver) -or
        -not [string]::Equals($liveDriver, $manifestDriver, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The live D3D driver version differs from the fixture manifest.'
    }
    return [pscustomobject][ordered]@{
        verified = $true
        matrixVendor = $GpuVendor
        vendorId = ('0x{0:X4}' -f $liveVendorId)
        deviceId = ('0x{0:X4}' -f $liveDeviceId)
        driverVersion = $liveDriver
        description = [string](Get-CSXPropertyValue $Adapter 'description')
        luidHigh = Get-CSXPropertyValue $Adapter 'luidHigh'
        luidLow = Get-CSXPropertyValue $Adapter 'luidLow'
    }
}

function ConvertTo-CSXHashtable {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 80 -Compress | ConvertFrom-Json -AsHashtable -Depth 80)
}

function Add-CSXExactRuntimeToProfile {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime)
    $method = [string](Get-CSXPropertyValue $Profile 'method')
    if ($method -notin @('dlss', 'fsr')) { throw "Unsupported qualification profile method '$method'." }
    $qualityMode = Get-CSXPropertyValue $Profile 'qualityModeValue'
    if ($null -eq $qualityMode) { throw 'Qualification profiles require numeric qualityModeValue.' }
    $target = [ordered]@{
        method = $method
        qualityMode = [int]$qualityMode
        renderScaleMode = [bool](Get-CSXPropertyValue $Profile 'renderScaleMode')
    }
    if ($method -eq 'dlss') {
        $profile = [string](Get-CSXPropertyValue $Profile 'dlssProfile' 'K')
        if ($profile -notin @('J', 'K', 'L', 'M', 'F', 'E')) { throw "Unsupported DLSS profile '$profile'." }
        $target['dlssProfile'] = $profile
    }
    else { $target['fsrRuntime'] = $FsrRuntime }
    return $target
}

function Get-CSXFoveationTarget {
    param([Parameter(Mandatory)]$Protocol)
    $source = $Protocol.fixture.foveation
    return [ordered]@{
        foveatedVendorDispatch = [bool]$source.foveatedVendorDispatch
        foveatedCenterArea = [double]$source.foveatedCenterArea
        peripheryTAAEnable = [bool]$source.peripheryTAAEnable
        peripheryTAACenterArea = [double]$source.peripheryTAACenterArea
        peripheryTAAOuterScale = [double]$source.peripheryTAAOuterScale
    }
}

function New-CSXCocScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$RunId
    )
    $foveation = Get-CSXFoveationTarget $Protocol
    $interior = if ($GpuVendor -eq 'NVIDIA') { $Protocol.fixture.profiles.nvidiaInterior } else { $Protocol.fixture.profiles.amdInterior }
    $exterior = $Protocol.fixture.profiles.sharedExterior
    $steps = [Collections.Generic.List[object]]::new()
    for ($ordinal = 1; $ordinal -le [int]$Protocol.cocAssay.transitionCount; $ordinal++) {
        $isInterior = ($ordinal % 2) -eq 1
        $cell = if ($isInterior) { [string]$Protocol.fixture.interiorCellEditorId } else { [string]$Protocol.fixture.startCellEditorId }
        $profile = Add-CSXExactRuntimeToProfile -Profile $(if ($isInterior) { $interior } else { $exterior }) -FsrRuntime $FsrRuntime
        $transitionId = [uint64]$ordinal
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-begin"
            args = [ordered]@{ action = 'qualification_begin'; transitionId = $transitionId; ownerId = $RunId; expectedBuildId = $ExpectedBuildId }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-dispatch"
            args = [ordered]@{ action = 'qualification_dispatch'; transitionId = $transitionId; ownerId = $RunId; expectedBuildId = $ExpectedBuildId }
        })
        $steps.Add([ordered]@{
            tool = 'console'
            label = "coc-$($ordinal.ToString('D2'))-command"
            args = [ordered]@{ action = 'exec'; command = "coc $cell"; capture = $false }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-wait"
            args = [ordered]@{
                action = 'qualification_wait'
                transitionId = $transitionId
                timeoutMs = [int]$Protocol.timeBudget.cocTransitionMs
                expectedCellEditorId = $cell
                target = $profile
                foveation = $foveation
                ownerId = $RunId
                expectedBuildId = $ExpectedBuildId
            }
        })
    }
    return [ordered]@{ action = 'run'; async = $false; steps = @($steps); continueOnError = $false }
}

function New-CSXMenuScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$ExpectedCellEditorId,
        [Parameter(Mandatory)][string]$RunId
    )
    $matrixName = if ($GpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' }
    $matrix = @($Protocol.menuAssay.$matrixName)
    $foveation = Get-CSXFoveationTarget $Protocol
    $steps = [Collections.Generic.List[object]]::new()
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'; label = 'menu-dlss_trace_status-preflight'
        args = [ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $ExpectedBuildId }
    })
    if ($GpuVendor -eq 'AMD') {
        foreach ($action in @('dlss_trace_reset', 'dlss_trace_start', 'dlss_trace_stop')) {
            $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "amd-capability-$action"; args = [ordered]@{ action = $action; expectedBuildId = $ExpectedBuildId } })
        }
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = 'amd-capability-dlss_trace_read'
            args = [ordered]@{ action = 'dlss_trace_read'; afterSequence = 0; limit = [int]$Protocol.menuAssay.traceReadLimit; expectedBuildId = $ExpectedBuildId }
        })
    }
    foreach ($entry in $matrix) {
        $ordinal = [int]$entry.ordinal
        $prefix = "menu-$($ordinal.ToString('D2'))"
        $isDLSS = [string]$entry.method -eq 'dlss'
        if ($isDLSS) {
            foreach ($action in @('dlss_trace_reset', 'dlss_trace_start')) {
                $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-$action"; args = [ordered]@{ action = $action; expectedBuildId = $ExpectedBuildId } })
            }
        }
        $transitionId = [uint64](100 + $ordinal)
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = "$prefix-begin"
            args = [ordered]@{ action = 'qualification_begin'; transitionId = $transitionId; ownerId = $RunId; expectedBuildId = $ExpectedBuildId }
        })
        $apply = [ordered]@{
            action = 'apply'; method = [string]$entry.method; enabled = [bool]$entry.renderScaleMode
            qualityMode = [int]$entry.qualityModeValue; expectedBuildId = $ExpectedBuildId
        }
        if ($isDLSS) { $apply['dlssPreset'] = 1 }
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = "$prefix-dispatch"
            args = [ordered]@{ action = 'qualification_dispatch'; transitionId = $transitionId; ownerId = $RunId; expectedBuildId = $ExpectedBuildId }
        })
        $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-apply"; args = $apply })
        $target = Add-CSXExactRuntimeToProfile -Profile $entry -FsrRuntime $FsrRuntime
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = "$prefix-wait"
            args = [ordered]@{
                action = 'qualification_wait'; transitionId = $transitionId
                timeoutMs = [int]$Protocol.timeBudget.menuTransitionMs
                expectedCellEditorId = $ExpectedCellEditorId; target = $target
                foveation = $foveation; ownerId = $RunId; expectedBuildId = $ExpectedBuildId
            }
        })
        if ($isDLSS) {
            $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-dlss_trace_stop"; args = [ordered]@{ action = 'dlss_trace_stop'; expectedBuildId = $ExpectedBuildId } })
            $steps.Add([ordered]@{
                tool = 'communityshaders.renderscale'; label = "$prefix-dlss_trace_read"
                args = [ordered]@{ action = 'dlss_trace_read'; afterSequence = 0; limit = [int]$Protocol.menuAssay.traceReadLimit; expectedBuildId = $ExpectedBuildId }
            })
        }
    }
    return [pscustomobject][ordered]@{ matrixName = $matrixName; matrix = $matrix; scenario = [ordered]@{ action = 'run'; async = $false; steps = @($steps); continueOnError = $false } }
}

function New-CSXRecoveryScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$RecoveryLabel
    )
    return [ordered]@{
        action = 'run'
        async = $false
        steps = @(
            [ordered]@{ wait = [int]$Protocol.timeBudget.recoveryMs; label = "$RecoveryLabel-recovery-30000ms" },
            [ordered]@{
                tool = 'inspect'; label = "$RecoveryLabel-recovery-scene"
                args = [ordered]@{ kind = 'scene' }
            },
            [ordered]@{
                tool = 'inspect'; label = "$RecoveryLabel-recovery-health"
                args = [ordered]@{ kind = 'health' }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-qualification-status"
                args = [ordered]@{ action = 'qualification_status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-dlss-trace-status"
                args = [ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-renderscale-status"
                args = [ordered]@{ action = 'status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.upscaling_api'; label = "$RecoveryLabel-recovery-upscaling-snapshot"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-upscaling"; action = 'snapshot'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.feature_api'; label = "$RecoveryLabel-recovery-feature-settings"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-settings"; action = 'settings'; featureShortName = 'Upscaling'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.screenshot'; label = "$RecoveryLabel-recovery-screenshot-status"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-screenshot"; action = 'status' }
            }
        )
        continueOnError = $false
        expected = [ordered]@{
            cellEditorId = [string]$Protocol.fixture.startCellEditorId
            target = Add-CSXExactRuntimeToProfile -Profile $Protocol.fixture.profiles.sharedExterior -FsrRuntime $FsrRuntime
            foveation = Get-CSXFoveationTarget $Protocol
        }
    }
}

function New-CSXVisualSequenceRequest {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Replicate,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )
    $encoding = [ordered]@{ format = [string]$Protocol.visualAssay.format; colourContract = [string]$Protocol.visualAssay.colourContract }
    $outputs = @($Protocol.visualAssay.outputs | ForEach-Object {
        [ordered]@{ view = [string]$_; encoding = $encoding; nameSuffix = ([string]$_ -replace '_', '-') }
    })
    return [ordered]@{
        contractMajor = 1; clientId = 'csx-render-scale-qualification'
        commandId = "$RunId-visual-$($Replicate.ToString('D2'))-start"; action = 'sequence_start'
        sequence = [ordered]@{
            frameCount = [int]$Protocol.visualAssay.frameCount; useSettings = $false
            schedule = ConvertTo-CSXHashtable $Protocol.visualAssay.schedule
            backpressure = [ordered]@{ policy = 'skip'; maximumConsecutiveSkips = 10 }
            failurePolicy = 'continue'
            capture = [ordered]@{
                source = ConvertTo-CSXHashtable $Protocol.visualAssay.source
                outputs = $outputs
                destination = [ordered]@{ policy = 'absolute'; directory = [IO.Path]::GetFullPath($DestinationDirectory); baseName = "$RunId-rep-$($Replicate.ToString('D2'))"; overwrite = 'never' }
                clipboard = 'none'
                tags = [ordered]@{ suite = 'csx-render-scale-pr-v1'; replicate = [string]$Replicate }
            }
            packaging = [ordered]@{ frameManifest = $true; previewVideo = [ordered]@{ requested = $false; required = $false } }
        }
    }
}

function Invoke-CSXRetriedWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Headers,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][ValidateRange(1, 600)][int]$TimeoutSeconds
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $remaining = $TimeoutSeconds - [int][Math]::Ceiling($watch.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { throw 'DevBench HTTP retry budget expired.' }
        try {
            return Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -Headers $Headers -Body $Body -TimeoutSec $remaining
        }
        catch {
            $statusCode = 0
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $statusCode = [int]$_.Exception.Response.StatusCode }
            $retryable = $statusCode -in @(429, 502, 503, 504) -or
                $_.Exception.Message -match '(?i)timed out|timeout|temporarily unavailable|connection (was )?(closed|reset|refused)|forcibly closed'
            if (-not $retryable -or $attempt -eq 3) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

function New-CSXInfrastructureException {
    param([Parameter(Mandatory)][string]$Message, [Exception]$InnerException)
    $exception = if ($InnerException) {
        [InvalidOperationException]::new($Message, $InnerException)
    }
    else { [InvalidOperationException]::new($Message) }
    $exception.Data['CSXFailureClass'] = 'infrastructure'
    return $exception
}

function New-CSXMcpConnection {
    param([Parameter(Mandatory)]$Runtime, [string]$ClientName = 'CSXRenderScaleQualification')
    $port = [int](Get-CSXPropertyValue $Runtime 'port')
    if ($port -lt 1 -or $port -gt 65535) { throw 'Runtime metadata has an invalid port.' }
    $endpoint = "http://127.0.0.1:$port/mcp"
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $body = [ordered]@{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params = [ordered]@{ protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = [ordered]@{ name = $ClientName; version = '1.0' } }
    } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-CSXRetriedWebRequest -Uri $endpoint -Headers $baseHeaders -Body $body -TimeoutSeconds 15
    $sessionHeader = $response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $headers = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-CSXRetriedWebRequest -Uri $endpoint -Headers $headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSeconds 15 | Out-Null
    return [pscustomobject][ordered]@{
        endpoint = $endpoint; headers = $headers; sessionId = $sessionId; requestId = 1L
        transcript = [Collections.Generic.List[object]]::new()
        serviceSessions = @{}
    }
}

function Invoke-CSXMcpTool {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)]$Arguments,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [switch]$AllowSemanticFailure
    )
    $Connection.requestId = [long]$Connection.requestId + 1L
    $transcriptRecorded = $false
    $request = [ordered]@{
        jsonrpc = '2.0'; id = $Connection.requestId; method = 'tools/call'
        params = [ordered]@{ name = $Tool; arguments = $Arguments }
    }
    $started = [DateTime]::UtcNow
    $body = $request | ConvertTo-Json -Depth 100 -Compress
    try {
        try {
            # A lost response is an uncertain mutation outcome; never replay tools/call.
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Connection.endpoint -Headers $Connection.headers -Body $body -TimeoutSec $TimeoutSeconds
        }
        catch {
            throw (New-CSXInfrastructureException -Message "DevBench tools/call transport failed for '$Tool'; the request was not replayed." -InnerException $_.Exception)
        }
        try { $rpc = $response.Content | ConvertFrom-Json -Depth 100 }
        catch { throw (New-CSXInfrastructureException -Message "DevBench returned malformed JSON-RPC for '$Tool'." -InnerException $_.Exception) }
        if ($rpc.PSObject.Properties['error']) {
            throw (New-CSXInfrastructureException -Message "DevBench tools/call failed: $($rpc.error | ConvertTo-Json -Depth 20 -Compress)")
        }
        if ($rpc.result.PSObject.Properties['isError'] -and [bool]$rpc.result.isError) {
            throw (New-CSXInfrastructureException -Message "DevBench tool '$Tool' failed: $(($rpc.result.content | ForEach-Object text) -join "`n")")
        }
        $content = [Collections.Generic.List[object]]::new()
        foreach ($item in @($rpc.result.content)) {
            if ($item.type -eq 'text') {
                try { $content.Add(($item.text | ConvertFrom-Json -Depth 100)) } catch { $content.Add([string]$item.text) }
            }
            else { $content.Add($item) }
        }
        $value = if ($content.Count -eq 1) { $content[0] } else { @($content) }
        $errorValue = Get-CSXPropertyValue $value 'error'
        $okValue = Get-CSXPropertyValue $value 'ok' $true
        $semanticFailure = $null -ne $errorValue -or $okValue -eq $false
        if ($semanticFailure) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $value; ok = $false
                error = $(if ($null -ne $errorValue) { [string]$errorValue } else { 'semantic failure' })
            })
            $transcriptRecorded = $true
            if (-not $AllowSemanticFailure) {
                throw "DevBench tool '$Tool' returned semantic failure: $($value | ConvertTo-Json -Depth 30 -Compress)"
            }
        }
        $serverSession = Get-CSXPathValue $value 'server.sessionId'
        if ($serverSession) {
            if ($Connection.serviceSessions.ContainsKey($Tool) -and $Connection.serviceSessions[$Tool] -ne $serverSession) {
                throw (New-CSXInfrastructureException -Message "Service session changed for '$Tool'.")
            }
            $Connection.serviceSessions[$Tool] = [string]$serverSession
        }
        if (-not $transcriptRecorded) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $value; ok = $true; error = $null
            })
            $transcriptRecorded = $true
        }
        return $value
    }
    catch {
        if (-not $transcriptRecorded) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $null; ok = $false; error = $_.Exception.Message
            })
        }
        throw
    }
}

function Get-CSXRemainingMilliseconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch, [Parameter(Mandatory)][int]$BudgetMs)
    return [Math]::Max(0, $BudgetMs - [int][Math]::Ceiling($Stopwatch.Elapsed.TotalMilliseconds))
}

function Get-CSXBoundedTimeoutSeconds {
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$BudgetMs,
        [Parameter(Mandatory)][int]$OperationCapMs
    )
    $remaining = Get-CSXRemainingMilliseconds -Stopwatch $Stopwatch -BudgetMs $BudgetMs
    $bounded = [Math]::Min($remaining, $OperationCapMs)
    if ($bounded -lt 1000) { throw 'Less than one whole second remains on the orchestration deadline.' }
    return [Math]::Floor($bounded / 1000.0)
}

function Get-CSXNearestRankPercentile {
    param([Parameter(Mandatory)][double[]]$Values, [Parameter(Mandatory)][ValidateRange(0, 1)][double]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-CSXMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-CSXMetricSummary {
    param([AllowEmptyCollection()][double[]]$Values, [switch]$IncludeRate)
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [pscustomobject][ordered]@{ count = 0; total = $null; min = $null; median = $null; mean = $null; sampleStandardDeviation = $null; coefficientOfVariation = $null; p95 = $null; max = $null; transitionsPerMinute = $null }
    }
    $measure = $Values | Measure-Object -Sum -Average -Minimum -Maximum
    $mean = [double]$measure.Average
    $variance = if ($Values.Count -gt 1) { [double](($Values | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum) / ($Values.Count - 1) } else { 0.0 }
    $sd = [Math]::Sqrt($variance)
    return [pscustomobject][ordered]@{
        count = $Values.Count; total = [double]$measure.Sum; min = [double]$measure.Minimum
        median = Get-CSXMedian -Values $Values
        mean = $mean; sampleStandardDeviation = $sd
        coefficientOfVariation = $(if ($mean -ne 0) { $sd / $mean } else { $null })
        p95 = Get-CSXNearestRankPercentile -Values $Values -Percentile 0.95
        max = [double]$measure.Maximum
        transitionsPerMinute = $(if ($IncludeRate -and [double]$measure.Sum -gt 0) { 60000.0 * $Values.Count / [double]$measure.Sum } else { $null })
    }
}

function Get-CSXWilsonInterval {
    param([Parameter(Mandatory)][int]$Failures, [Parameter(Mandatory)][int]$Trials)
    if ($Trials -le 0 -or $Failures -lt 0 -or $Failures -gt $Trials) { return [pscustomobject][ordered]@{ lower = $null; upper = $null; confidence = 0.95 } }
    $z = 1.95996398454005
    $p = [double]$Failures / $Trials
    $denominator = 1.0 + ($z * $z / $Trials)
    $center = ($p + ($z * $z / (2.0 * $Trials))) / $denominator
    $half = $z * [Math]::Sqrt(($p * (1.0 - $p) / $Trials) + ($z * $z / (4.0 * $Trials * $Trials))) / $denominator
    return [pscustomobject][ordered]@{ lower = [Math]::Max(0.0, $center - $half); upper = [Math]::Min(1.0, $center + $half); confidence = 0.95 }
}

function Get-CSXQualificationWaitRecords {
    param(
        [Parameter(Mandatory)]$ScenarioResult,
        [Parameter(Mandatory)][string]$LabelPrefix,
        $PreparationResponse
    )
    $records = [Collections.Generic.List[object]]::new()
    foreach ($step in @($ScenarioResult.results)) {
        $label = [string](Get-CSXPropertyValue $step 'label')
        if ($label -notmatch "^$([regex]::Escape($LabelPrefix))-(?<ordinal>\d{2})-wait$") { continue }
        $payload = Get-CSXPropertyValue $step 'result'
        $satisfied = [bool](Get-CSXPropertyValue $payload 'satisfied' $false)
        $elapsed = Get-CSXPathValue $payload 'timing.elapsedMs' (Get-CSXPropertyValue $payload 'elapsedMs')
        $transitionEpoch = Get-CSXPathValue $payload `
            'observation.physical.stable.transitionEpoch'
        if ($null -eq $transitionEpoch) {
            $transitionEpoch = Get-CSXPathValue $payload `
                'observation.upscalingSnapshot.stable.transitionEpoch'
        }
        $preparation = if ($null -ne $PreparationResponse -and
            $null -ne $transitionEpoch) {
            Get-DevBenchRenderScalePreparationTelemetry `
                -Response $PreparationResponse -TransitionEpoch $transitionEpoch
        } elseif ($null -ne $PreparationResponse) {
            Get-DevBenchRenderScalePreparationTelemetry `
                -Response $PreparationResponse
        } else {
            Get-DevBenchRenderScalePreparationTelemetry -Response $null
        }
        $records.Add([pscustomobject][ordered]@{
            ordinal = [int]$Matches.ordinal; transitionId = [uint64](Get-CSXPropertyValue $payload 'transitionId')
            satisfied = $satisfied; elapsedMs = $(if ($null -ne $elapsed) { [double]$elapsed } else { $null })
            target = Get-CSXPropertyValue $payload 'target'; foveation = Get-CSXPropertyValue $payload 'foveation'
            diagnostics = Get-CSXPropertyValue $payload 'diagnostics'; raw = $payload
            resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $payload
            preparation = $preparation
        })
    }
    return @($records | Sort-Object ordinal)
}

function Get-CSXResourcePublicationSummary {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Records)

    $samples = @($Records | ForEach-Object { $_.resourcePublication })
    $available = @($samples | Where-Object { [bool]$_.available })
    return [pscustomobject][ordered]@{
        samples = $samples
        availableSamples = $available.Count
        currentSamples = @($available | Where-Object { [bool]$_.current }).Count
        completeSamples = @($available | Where-Object { [bool]$_.complete }).Count
        deferredSetupAcknowledgedSamples = @($available | Where-Object { [bool]$_.deferredSetupAcknowledged }).Count
        dimensionsMatchSamples = @($available | Where-Object { [bool]$_.dimensionsMatch }).Count
        deviceMatchSamples = @($available | Where-Object { [bool]$_.deviceMatches }).Count
        contextMatchSamples = @($available | Where-Object { [bool]$_.contextMatches }).Count
        latest = $(if ($samples.Count -gt 0) { $samples[-1] } else { Get-DevBenchResourcePublicationTelemetry -Response $null })
    }
}

function Test-CSXFoveationEvidence {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Target)
    $expectedReceipt = Get-CSXPropertyValue $Evidence 'target' (Get-CSXPropertyValue $Evidence 'expected')
    $observed = Get-CSXPropertyValue $Evidence 'observed'
    if ($null -eq $observed) { $observed = $Evidence }
    $settings = Get-CSXPropertyValue $observed 'settings'
    $physical = Get-CSXPropertyValue $observed 'physical'
    if ($null -eq $expectedReceipt -or $null -eq $settings -or $null -eq $physical) { return $false }
    $tolerance = [double](Get-CSXPropertyValue $Evidence 'floatTolerance' (Get-CSXPropertyValue $expectedReceipt 'floatTolerance' 0.0001))
    foreach ($name in @('foveatedVendorDispatch', 'peripheryTAAEnable')) {
        if ([bool](Get-CSXPropertyValue $expectedReceipt $name) -ne [bool](Get-CSXPropertyValue $Expected $name)) { return $false }
        if ([bool](Get-CSXPropertyValue $settings $name) -ne [bool](Get-CSXPropertyValue $Expected $name)) { return $false }
    }
    foreach ($name in @('foveatedCenterArea', 'peripheryTAACenterArea', 'peripheryTAAOuterScale')) {
        if ([Math]::Abs([double](Get-CSXPropertyValue $expectedReceipt $name) - [double](Get-CSXPropertyValue $Expected $name)) -gt $tolerance) { return $false }
        if ([Math]::Abs([double](Get-CSXPropertyValue $settings $name) - [double](Get-CSXPropertyValue $Expected $name)) -gt $tolerance) { return $false }
    }
    $active = [bool](Get-CSXPropertyValue $Target 'renderScaleMode')
    $physicalVendor = Get-CSXPropertyValue $physical 'foveatedVendorDispatch'
    $physicalPeriphery = Get-CSXPropertyValue $physical 'peripheryTAAEnable' (Get-CSXPropertyValue $physical 'peripheryTAA')
    if ($null -eq $physicalVendor -or $null -eq $physicalPeriphery) { return $false }
    if ([bool]$physicalVendor -ne ($active -and [bool]$Expected.foveatedVendorDispatch)) { return $false }
    if ([bool]$physicalPeriphery -ne ($active -and [bool]$Expected.peripheryTAAEnable)) { return $false }
    return $true
}

function Test-CSXDLSSCaptureSummary {
    param([Parameter(Mandatory)]$Summary, [switch]$RequireDispatch, [switch]$RequireZeroDispatch)
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($field in @('droppedRecords', 'duplicatedConstantsFailures', 'evaluateFailures')) {
        if ([uint64](Get-CSXPropertyValue $Summary $field ([uint64]::MaxValue)) -ne 0) { $errors.Add("$field is nonzero or missing") }
    }
    if ([bool](Get-CSXPropertyValue $Summary 'lastDuplicatedConstantsFailureFound' $true)) { $errors.Add('a duplicated-constants failure is pinned') }
    if ([bool](Get-CSXPropertyValue $Summary 'lastEvaluateFailureFound' $true)) { $errors.Add('an evaluate failure is pinned') }
    $total = [uint64](Get-CSXPropertyValue $Summary 'totalRecords' 0)
    $evaluations = [uint64](Get-CSXPropertyValue $Summary 'evaluateCalls' 0)
    $constants = [uint64](Get-CSXPropertyValue $Summary 'setConstantsCalls' 0)
    if ($RequireDispatch -and ($total -eq 0 -or $evaluations -eq 0 -or $constants -eq 0)) { $errors.Add('no DLSS constants/evaluation dispatch evidence was captured') }
    if ($RequireZeroDispatch -and ($total -ne 0 -or $evaluations -ne 0 -or $constants -ne 0)) { $errors.Add('AMD capability-only trace unexpectedly captured a DLSS dispatch') }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors); partialRawDetail = [uint64](Get-CSXPropertyValue $Summary 'overwrittenRecords' 0) -gt 0 }
}

function Test-CSXDLSSRetainedRecords {
    param([Parameter(Mandatory)]$Capture, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][int]$ExpectedQualityMode)
    $errors = [Collections.Generic.List[string]]::new()
    $records = @($Capture.records)
    $retained = [uint64](Get-CSXPropertyValue $Summary 'retainedRecords' ([uint64]::MaxValue))
    $total = [uint64](Get-CSXPropertyValue $Summary 'totalRecords' 0)
    $overwritten = [uint64](Get-CSXPropertyValue $Summary 'overwrittenRecords' ([uint64]::MaxValue))
    $capacity = [uint64](Get-CSXPropertyValue $Summary 'capacity' 0)
    $expectedCount = [int][Math]::Min(16u, $retained)
    if ($retained -eq [uint64]::MaxValue -or $overwritten -eq [uint64]::MaxValue -or
        $overwritten -gt $total -or $retained -ne $total - $overwritten -or
        $capacity -lt $retained -or $records.Count -ne $expectedCount -or $expectedCount -eq 0) {
        $errors.Add('bounded read cardinality does not match the complete retained-record summary')
    }
    if ([uint64](Get-CSXPropertyValue $Capture 'afterSequence' ([uint64]::MaxValue)) -ne 0 -or
        [int](Get-CSXPropertyValue $Capture 'limit' 0) -ne 16) { $errors.Add('bounded read paging contract changed') }
    $availableFrom = [uint64](Get-CSXPropertyValue $Capture 'availableFromSequence' ([uint64]::MaxValue))
    $latest = [uint64](Get-CSXPropertyValue $Capture 'latestSequence' ([uint64]::MaxValue))
    $lastReturned = [uint64](Get-CSXPropertyValue $Capture 'lastReturnedSequence' ([uint64]::MaxValue))
    $expectedAvailableFrom = if ($retained -gt 0 -and $retained -le $total) { $total - $retained + 1u } else { 0u }
    $expectedLastReturned = if ($expectedCount -gt 0) { $expectedAvailableFrom + [uint64]$expectedCount - 1u } else { 0u }
    $expectedMore = $retained -gt [uint64]$expectedCount
    $expectedOverwrittenRequest = $expectedAvailableFrom -gt 1u
    if ($availableFrom -ne $expectedAvailableFrom -or $latest -ne $total -or $lastReturned -ne $expectedLastReturned -or
        [bool](Get-CSXPropertyValue $Capture 'moreAvailable' (-not $expectedMore)) -ne $expectedMore -or
        [bool](Get-CSXPropertyValue $Capture 'requestedSequenceOverwritten' (-not $expectedOverwrittenRequest)) -ne $expectedOverwrittenRequest) {
        $errors.Add('bounded read paging metadata is incomplete or inconsistent')
    }
    $sequences = [Collections.Generic.List[uint64]]::new()
    $evaluations = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $current = Get-CSXPropertyValue $record 'current'
        $signature = Get-CSXPropertyValue $current 'signature'
        $sequence = [uint64](Get-CSXPropertyValue $current 'sequence' 0)
        $stage = [string](Get-CSXPropertyValue $current 'stage')
        $eye = [int](Get-CSXPropertyValue $signature 'eye' -1)
        $requestedViewport = Get-CSXPropertyValue $signature 'requestedViewport'
        $resolvedViewport = Get-CSXPropertyValue $signature 'resolvedViewport'
        if ($sequence -eq 0 -or [uint64](Get-CSXPropertyValue $current 'timestampQPC' 0) -eq 0 -or
            [uint64](Get-CSXPropertyValue $current 'threadID' 0) -eq 0 -or [uint64](Get-CSXPropertyValue $current 'compositorCycle' 0) -eq 0) {
            $errors.Add('a retained record omitted sequence, QPC, thread, or compositor-cycle identity')
        }
        if ($stage -notin @('constants_cache_reuse', 'set_constants', 'evaluate') -or [int](Get-CSXPropertyValue $current 'resultCode' -1) -ne 0) {
            $errors.Add('a retained record has an invalid stage or non-success result')
        }
        if ([uint64](Get-CSXPropertyValue $signature 'traceSessionID' 0) -ne [uint64]$Summary.sessionID -or
            [uint64](Get-CSXPropertyValue $signature 'frameToken' 0) -eq 0 -or $eye -notin @(0, 1) -or
            $null -eq $requestedViewport -or $null -eq $resolvedViewport -or [int]$resolvedViewport -ne $eye -or
            [uint64](Get-CSXPathValue $signature 'output.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'output.height' 0) -eq 0 -or
            [uint64](Get-CSXPathValue $signature 'extentIn.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'extentIn.height' 0) -eq 0 -or
            [uint64](Get-CSXPathValue $signature 'extentOut.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'extentOut.height' 0) -eq 0 -or
            [int](Get-CSXPropertyValue $signature 'qualityMode' -1) -ne $ExpectedQualityMode -or [int](Get-CSXPropertyValue $signature 'dlssPreset' -1) -ne 1) {
            $errors.Add('a retained record has invalid session, frame, eye, dimensions, quality, or preset identity')
        }
        $constants = Get-CSXPropertyValue $signature 'streamlineConstants'
        $resources = Get-CSXPropertyValue $signature 'resources'
        if ($null -eq $constants -or $null -eq $resources -or $null -eq (Get-CSXPropertyValue $constants 'cameraFOV')) {
            $errors.Add('a retained record omitted Streamline constants or resource identity')
        }
        foreach ($resourceName in @('colorIn', 'colorOut', 'depth', 'motionVectors')) {
            $resource = [string](Get-CSXPropertyValue $resources $resourceName)
            if ($resource -notmatch '^0x[0-9A-Fa-f]{16}$' -or $resource -eq '0x0000000000000000') {
                $errors.Add("a retained record has invalid $resourceName resource identity")
            }
        }
        if ($stage -eq 'evaluate') {
            $previous = Get-CSXPropertyValue $record 'previousConstants'
            $previousSignature = Get-CSXPropertyValue $previous 'signature'
            if (-not [bool](Get-CSXPropertyValue $record 'previousConstantsFound' $false) -or $null -eq $previous -or
                [int](Get-CSXPropertyValue $previous 'resultCode' -1) -ne 0 -or
                [uint64](Get-CSXPropertyValue $previousSignature 'traceSessionID' 0) -ne [uint64]$Summary.sessionID) {
                $errors.Add('an evaluation record is not correlated to successful constants')
            }
            else {
                foreach ($path in @('frameToken', 'resolvedViewport', 'eye', 'output.width', 'output.height', 'qualityMode', 'dlssPreset')) {
                    if ([string](Get-CSXPathValue $previousSignature $path) -ne [string](Get-CSXPathValue $signature $path)) {
                        $errors.Add("an evaluation/constants pair disagrees on $path")
                    }
                }
                if ([uint64](Get-CSXPropertyValue $previous 'compositorCycle' 0) -ne [uint64](Get-CSXPropertyValue $current 'compositorCycle' 0)) {
                    $errors.Add('an evaluation/constants pair disagrees on compositor cycle')
                }
                foreach ($resourceName in @('colorIn', 'colorOut', 'depth', 'motionVectors')) {
                    if ([string](Get-CSXPathValue $previousSignature "resources.$resourceName") -ne [string](Get-CSXPathValue $signature "resources.$resourceName")) {
                        $errors.Add("an evaluation/constants pair disagrees on $resourceName resource")
                    }
                }
            }
        }
        $sequences.Add($sequence)
        if ($stage -eq 'evaluate') { $evaluations.Add($current) }
    }
    if (@($sequences | Sort-Object -Unique).Count -ne $records.Count -or
        (@($sequences) -join ',') -ne (@($sequences | Sort-Object) -join ',') -or
        (@($sequences) -join ',') -ne (@(for ($sequence = $expectedAvailableFrom; $sequence -le $expectedLastReturned; $sequence++) { $sequence }) -join ',')) {
        $errors.Add('retained record sequences are duplicate, unordered, or incomplete')
    }
    $stereoPairFound = $false
    foreach ($group in @($evaluations | Group-Object { "$(Get-CSXPropertyValue $_ 'compositorCycle')|$(Get-CSXPathValue $_ 'signature.frameToken')|$(Get-CSXPathValue $_ 'signature.frame')" })) {
        $eyes = @($group.Group | ForEach-Object { [int](Get-CSXPathValue $_ 'signature.eye' -1) } | Sort-Object -Unique)
        if (($eyes -join ',') -ne '0,1') { continue }
        $viewports = @($group.Group | ForEach-Object { [int](Get-CSXPathValue $_ 'signature.resolvedViewport' -1) } | Sort-Object -Unique)
        if (($viewports -join ',') -ne '0,1') { continue }
        $identities = @($group.Group | ForEach-Object {
            "$(Get-CSXPathValue $_ 'signature.output.width')|$(Get-CSXPathValue $_ 'signature.output.height')|$(Get-CSXPathValue $_ 'signature.qualityMode')|$(Get-CSXPathValue $_ 'signature.dlssPreset')"
        } | Sort-Object -Unique)
        if ($identities.Count -eq 1) { $stereoPairFound = $true; break }
    }
    if (-not $stereoPairFound) { $errors.Add('bounded records contain no coherent two-eye evaluation pair') }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; records = $records.Count; stereoPairFound = $stereoPairFound; errors = @($errors | Select-Object -Unique) }
}

function Test-CSXDLSSScenarioEvidence {
    param([Parameter(Mandatory)]$ScenarioResult, [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor)
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $groups = [Collections.Generic.List[object]]::new()
    $preflightSteps = @($ScenarioResult.results | Where-Object label -eq 'menu-dlss_trace_status-preflight')
    $preflight = $preflightSteps | Select-Object -First 1
    $preflightSummary = Get-CSXPathValue $preflight 'result.capture'
    if ($preflightSteps.Count -ne 1 -or [string](Get-CSXPathValue $preflight 'result.action') -ne 'dlss_trace_status' -or
        $null -eq $preflightSummary -or [bool](Get-CSXPropertyValue $preflightSummary 'active' $true)) {
        $errors.Add('Menu DLSS trace preflight was missing, duplicated, mislabeled, or active.')
    }
    if ($GpuVendor -eq 'AMD') {
        $amdSteps = [ordered]@{}
        foreach ($action in @('reset', 'start', 'stop', 'read')) {
            $matches = @($ScenarioResult.results | Where-Object label -eq "amd-capability-dlss_trace_$action")
            if ($matches.Count -ne 1) { $errors.Add("AMD DLSS trace requires exactly one $action receipt.") }
            $amdSteps[$action] = $matches | Select-Object -First 1
        }
        $reset = $amdSteps.reset
        $start = $amdSteps.start
        $stop = $amdSteps.stop
        $read = $amdSteps.read
        $resetSummary = Get-CSXPathValue $reset 'result.capture'
        $startSummary = Get-CSXPathValue $start 'result.capture'
        $stopSummary = Get-CSXPathValue $stop 'result.capture'
        $readCapture = Get-CSXPathValue $read 'result.capture'
        $readSummary = Get-CSXPropertyValue $readCapture 'summary'
        if ($null -eq $resetSummary -or $null -eq $startSummary -or $null -eq $stopSummary -or $null -eq $readSummary) { $errors.Add('AMD DLSS trace lifecycle evidence is missing.') }
        else {
            if ([string](Get-CSXPathValue $reset 'result.action') -ne 'dlss_trace_reset' -or [string](Get-CSXPathValue $start 'result.action') -ne 'dlss_trace_start' -or
                [string](Get-CSXPathValue $stop 'result.action') -ne 'dlss_trace_stop' -or [string](Get-CSXPathValue $read 'result.action') -ne 'dlss_trace_read') {
                $errors.Add('AMD DLSS trace lifecycle action identity changed.')
            }
            if ([bool]$resetSummary.active -or -not [bool]$startSummary.active -or [bool]$stopSummary.active -or [bool]$readSummary.active) { $errors.Add('AMD DLSS trace lifecycle states are incoherent.') }
            if ([uint64]$startSummary.sessionID -ne [uint64]$stopSummary.sessionID -or [uint64]$stopSummary.sessionID -ne [uint64]$readSummary.sessionID) { $errors.Add('AMD DLSS trace session identity changed.') }
            foreach ($summary in @($resetSummary, $readSummary)) {
                $zero = Test-CSXDLSSCaptureSummary -Summary $summary -RequireZeroDispatch
                foreach ($error in $zero.errors) { $errors.Add("AMD trace: $error") }
            }
            if (@($readCapture.records).Count -ne 0 -or [uint64](Get-CSXPropertyValue $readCapture 'afterSequence' ([uint64]::MaxValue)) -ne 0 -or [int](Get-CSXPropertyValue $readCapture 'limit' 0) -ne 16 -or
                [uint64](Get-CSXPropertyValue $readCapture 'availableFromSequence' ([uint64]::MaxValue)) -ne 0 -or
                [uint64](Get-CSXPropertyValue $readCapture 'latestSequence' ([uint64]::MaxValue)) -ne 0 -or
                [uint64](Get-CSXPropertyValue $readCapture 'lastReturnedSequence' ([uint64]::MaxValue)) -ne 0 -or
                [bool](Get-CSXPropertyValue $readCapture 'moreAvailable' $true) -or
                [bool](Get-CSXPropertyValue $readCapture 'requestedSequenceOverwritten' $true)) {
                $errors.Add('AMD capability-only trace read was not the exact empty bounded page.')
            }
            $groups.Add([pscustomobject][ordered]@{ kind = 'capability_only'; ordinal = $null; summary = $readSummary; validation = [pscustomobject]@{ ok = $errors.Count -eq 0 } })
        }
    }
    else {
        $waitSteps = @($ScenarioResult.results | Where-Object { [string]$_.label -match '^menu-\d{2}-wait$' })
        $expectedOrdinals = @($waitSteps | Where-Object { [string](Get-CSXPathValue $_ 'result.target.method') -eq 'dlss' } | ForEach-Object {
            if ([string]$_.label -match '^menu-(?<ordinal>\d{2})-wait$') { [int]$Matches.ordinal }
        } | Sort-Object -Unique)
        if ($waitSteps.Count -ne 25 -or $expectedOrdinals.Count -eq 0) { $errors.Add('NVIDIA trace validation did not receive the complete 25-wait canonical matrix.') }
        foreach ($ordinal in $expectedOrdinals) {
            $prefix = "menu-$($ordinal.ToString('D2'))"
            foreach ($action in @('reset', 'start', 'stop', 'read')) {
                if (@($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_$action").Count -ne 1) {
                    $errors.Add("menu ${ordinal}: expected exactly one dlss_trace_$action receipt")
                }
            }
        }
        $readSteps = @($ScenarioResult.results | Where-Object { [string]$_.label -match '^menu-\d{2}-dlss_trace_read$' })
        foreach ($read in $readSteps) {
            if ([string]$read.label -notmatch '^menu-(?<ordinal>\d{2})-dlss_trace_read$') { continue }
            $ordinal = [int]$Matches.ordinal
            $prefix = "menu-$($ordinal.ToString('D2'))"
            $reset = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_reset") | Select-Object -First 1
            $start = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_start") | Select-Object -First 1
            $stop = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_stop") | Select-Object -First 1
            $wait = @($ScenarioResult.results | Where-Object label -eq "$prefix-wait") | Select-Object -First 1
            $resetSummary = Get-CSXPathValue $reset 'result.capture'
            $startSummary = Get-CSXPathValue $start 'result.capture'
            $stopSummary = Get-CSXPathValue $stop 'result.capture'
            $capture = Get-CSXPathValue $read 'result.capture'
            $summary = Get-CSXPropertyValue $capture 'summary'
            if ($null -eq $resetSummary -or $null -eq $startSummary -or $null -eq $stopSummary -or $null -eq $summary -or $null -eq $wait) {
                $errors.Add("DLSS trace evidence is missing for menu ordinal $ordinal.")
                continue
            }
            if ([string](Get-CSXPathValue $reset 'result.action') -ne 'dlss_trace_reset' -or [string](Get-CSXPathValue $start 'result.action') -ne 'dlss_trace_start' -or
                [string](Get-CSXPathValue $stop 'result.action') -ne 'dlss_trace_stop' -or [string](Get-CSXPathValue $read 'result.action') -ne 'dlss_trace_read') {
                $errors.Add("DLSS trace action identity changed at menu ordinal $ordinal.")
            }
            $resetCheck = Test-CSXDLSSCaptureSummary -Summary $resetSummary -RequireZeroDispatch
            foreach ($error in $resetCheck.errors) { $errors.Add("menu ${ordinal} reset: $error") }
            if ([bool]$resetSummary.active -or -not [bool]$startSummary.active -or [bool]$stopSummary.active -or [bool]$summary.active) { $errors.Add("DLSS trace lifecycle is incoherent at menu ordinal $ordinal.") }
            if ([uint64]$startSummary.sessionID -ne [uint64]$stopSummary.sessionID -or [uint64]$stopSummary.sessionID -ne [uint64]$summary.sessionID) { $errors.Add("DLSS trace session mismatch at menu ordinal $ordinal.") }
            foreach ($counter in @('totalRecords', 'overwrittenRecords', 'droppedRecords', 'setConstantsCalls', 'evaluateCalls', 'duplicatedConstantsFailures', 'evaluateFailures')) {
                if ([uint64](Get-CSXPropertyValue $stopSummary $counter ([uint64]::MaxValue)) -ne [uint64](Get-CSXPropertyValue $summary $counter ([uint64]::MaxValue))) {
                    $errors.Add("menu ${ordinal}: stop/read counter '$counter' changed")
                }
            }
            $checked = Test-CSXDLSSCaptureSummary -Summary $summary -RequireDispatch
            foreach ($error in $checked.errors) { $errors.Add("menu ${ordinal}: $error") }
            $recordCheck = Test-CSXDLSSRetainedRecords -Capture $capture -Summary $summary -ExpectedQualityMode ([int](Get-CSXPathValue $wait 'result.target.qualityMode' -1))
            foreach ($error in $recordCheck.errors) { $errors.Add("menu ${ordinal}: $error") }
            if ($checked.partialRawDetail) { $warnings.Add("menu ${ordinal}: ring overwrite produced partial raw detail; pinned counters remain authoritative.") }
            $groups.Add([pscustomobject][ordered]@{ kind = 'dlss_dispatch'; ordinal = $ordinal; summary = $summary; validation = [pscustomobject][ordered]@{ summary = $checked; records = $recordCheck } })
        }
        if ($groups.Count -eq 0) { $errors.Add('No scoped NVIDIA DLSS trace sessions were preserved.') }
        $expectedGroups = $expectedOrdinals.Count
        if ($groups.Count -ne $expectedGroups -or $readSteps.Count -ne $expectedGroups) { $errors.Add("Scoped NVIDIA trace evidence count $($groups.Count) differs from the $expectedGroups canonical DLSS transitions.") }
    }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; groups = @($groups); errors = @($errors | Select-Object -Unique); warnings = @($warnings | Select-Object -Unique) }
}

function Get-CSXPairedComparison {
    param([Parameter(Mandatory)][object[]]$Candidate, [Parameter(Mandatory)][object[]]$Baseline)
    if ($Candidate.Count -ne $Baseline.Count) { throw 'Candidate and baseline transition counts differ.' }
    $deltas = [Collections.Generic.List[double]]::new()
    $percent = [Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $Candidate.Count; $i++) {
        if ([int]$Candidate[$i].ordinal -ne [int]$Baseline[$i].ordinal) { throw "Paired transition ordinal mismatch at index $i." }
        $candidateMs = [double]$Candidate[$i].elapsedMs
        $baselineMs = [double]$Baseline[$i].elapsedMs
        if ($candidateMs -lt 0 -or $baselineMs -le 0) { throw "Invalid paired timing at ordinal $($Candidate[$i].ordinal)." }
        $deltas.Add($candidateMs - $baselineMs)
        $percent.Add(100.0 * ($candidateMs - $baselineMs) / $baselineMs)
    }
    $candidateSummary = Get-CSXMetricSummary -Values ([double[]]@($Candidate.elapsedMs)) -IncludeRate
    $baselineSummary = Get-CSXMetricSummary -Values ([double[]]@($Baseline.elapsedMs)) -IncludeRate
    $aggregate = [ordered]@{}
    foreach ($metric in @('total', 'median', 'mean', 'p95', 'max')) {
        $candidateValue = [double](Get-CSXPropertyValue $candidateSummary $metric)
        $baselineValue = [double](Get-CSXPropertyValue $baselineSummary $metric)
        if ($baselineValue -le 0) { throw "Baseline aggregate $metric must be positive." }
        $aggregate[$metric] = [pscustomobject][ordered]@{
            candidateMs = $candidateValue
            baselineMs = $baselineValue
            deltaMs = $candidateValue - $baselineValue
            percent = 100.0 * ($candidateValue - $baselineValue) / $baselineValue
        }
    }
    return [pscustomobject][ordered]@{
        count = $Candidate.Count
        candidate = $candidateSummary
        baseline = $baselineSummary
        aggregateDelta = [pscustomobject]$aggregate
        pairedOrdinalDelta = [pscustomobject][ordered]@{
            milliseconds = Get-CSXMetricSummary -Values ([double[]]@($deltas))
            percent = Get-CSXMetricSummary -Values ([double[]]@($percent))
        }
    }
}

function Assert-CSXVisualIndexSet {
    param([Parameter(Mandatory)]$VisualIndex, [Parameter(Mandatory)][string]$Label, [string]$ExpectedRunId = '')
    if ([string]$VisualIndex.schema -ne 'csx-render-scale-visual-index-v1') { throw "$Label visual index schema is invalid." }
    if ($ExpectedRunId -and [string]$VisualIndex.runId -ne $ExpectedRunId) { throw "$Label visual index run identity is invalid." }
    $samples = @($VisualIndex.samples)
    if ($samples.Count -ne 9) { throw "$Label visual index must contain exactly nine review samples." }
    $identities = @($samples | ForEach-Object { "$([int]$_.replicate):$([int]$_.ordinal)" })
    $expected = @(foreach ($replicate in 1..3) { foreach ($ordinal in @(1, 8, 16)) { "${replicate}:${ordinal}" } })
    if (@($identities | Sort-Object -Unique).Count -ne 9 -or (@($identities | Sort-Object) -join ',') -ne (@($expected | Sort-Object) -join ',')) {
        throw "$Label visual index has duplicate, missing, or unexpected sample identities."
    }
    foreach ($sample in $samples) {
        $artifacts = @($sample.artifacts)
        $views = @($artifacts | ForEach-Object { [string]$_.view })
        if ($artifacts.Count -ne 3 -or @($views | Sort-Object -Unique).Count -ne 3 -or
            (@($views | Sort-Object) -join ',') -ne 'left_eye,right_eye,side_by_side') {
            throw "$Label visual sample $($sample.replicate)/$($sample.ordinal) must bind the three exact views once each."
        }
        $paths = @($artifacts | ForEach-Object { [string]$_.path })
        $hashes = @($artifacts | ForEach-Object { [string]$_.sha256 })
        if (@($paths | Sort-Object -Unique).Count -ne 3 -or @($hashes | Where-Object { $_ -match '^[a-f0-9]{64}$' }).Count -ne 3) {
            throw "$Label visual sample $($sample.replicate)/$($sample.ordinal) has duplicate paths or invalid SHA-256 bindings."
        }
    }
}

function Resolve-CSXEvidencePath {
    param([Parameter(Mandatory)][string]$EvidenceRoot, [Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Review artifact path must be relative: $RelativePath" }
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Review artifact escapes the evidence root: $RelativePath" }
    Assert-CSXEvidencePathNoReparse -EvidenceRoot $EvidenceRoot -ResolvedPath $resolved -Label 'Evidence artifact'
    return $resolved
}

function Assert-CSXEvidencePathNoReparse {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ResolvedPath,
        [Parameter(Mandatory)][string]$Label
    )
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolved = [IO.Path]::GetFullPath($ResolvedPath)
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not [string]::Equals($resolved, $root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path escapes the evidence root: $ResolvedPath"
    }
    if (-not (Test-Path -LiteralPath $root)) { throw "$Label evidence root is missing: $root" }
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label evidence root is a reparse point: $root"
    }
    if ([string]::Equals($resolved, $root, [StringComparison]::OrdinalIgnoreCase)) { return }
    $current = $root
    foreach ($component in ([IO.Path]::GetRelativePath($root, $resolved) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($component)) { continue }
        $current = Join-Path $current $component
        if (-not (Test-Path -LiteralPath $current)) { break }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label path traverses a reparse point: $current"
        }
    }
}

function Resolve-CSXContainedEvidencePath {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$RecordedPath,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($RecordedPath)) { throw "$Label path is missing." }
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = if ([IO.Path]::IsPathRooted($RecordedPath)) {
        [IO.Path]::GetFullPath($RecordedPath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $root $RecordedPath))
    }
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path escapes the evidence root: $RecordedPath"
    }
    Assert-CSXEvidencePathNoReparse -EvidenceRoot $EvidenceRoot -ResolvedPath $resolved -Label $Label
    return $resolved
}

function Add-CSXUniqueVisualEvidencePath {
    param(
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, string]]$Paths,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Paths.ContainsKey($Path)) { throw "$Label reuses evidence path '$Path' already owned by '$($Paths[$Path])'." }
    $Paths.Add($Path, $Label)
}

function Read-CSXHashBoundVisualJson {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, string]]$Paths
    )
    if (-not (Test-CSXSha256Text $ExpectedSha256)) { throw "$Label SHA-256 is missing or invalid." }
    $path = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath $RelativePath
    Add-CSXUniqueVisualEvidencePath -Paths $Paths -Path $path -Label $Label
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label is missing: $path" }
    $actualSha256 = Get-CSXFileSha256 $path
    if (-not [string]::Equals($actualSha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label SHA-256 binding does not match."
    }
    try { $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
    return [pscustomobject][ordered]@{ path = $path; sha256 = $actualSha256; value = $value }
}

function Get-CSXValidatedPngDimensions {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 57) { throw "$Label is too short to contain PNG IHDR, IDAT, and IEND chunks." }
        $signature = [byte[]]::new(8)
        if ($stream.Read($signature, 0, $signature.Length) -ne $signature.Length -or
            ($signature -join ',') -ne '137,80,78,71,13,10,26,10') {
            throw "$Label does not have a valid PNG signature."
        }
        $width = [uint32]0
        $height = [uint32]0
        $foundIdat = $false
        $foundIend = $false
        $chunkIndex = 0
        while ($stream.Position -lt $stream.Length) {
            $chunkHeader = [byte[]]::new(8)
            if ($stream.Read($chunkHeader, 0, 8) -ne 8) { throw "$Label has a truncated PNG chunk header." }
            $length = [uint64](([uint32]$chunkHeader[0] -shl 24) -bor ([uint32]$chunkHeader[1] -shl 16) -bor
                ([uint32]$chunkHeader[2] -shl 8) -bor [uint32]$chunkHeader[3])
            $type = [Text.Encoding]::ASCII.GetString($chunkHeader, 4, 4)
            if ($length + 4 -gt [uint64]($stream.Length - $stream.Position)) { throw "$Label has a truncated PNG '$type' chunk." }
            if ($chunkIndex -eq 0) {
                if ($type -cne 'IHDR' -or $length -ne 13) { throw "$Label does not begin with the required PNG IHDR chunk." }
                $ihdr = [byte[]]::new(13)
                if ($stream.Read($ihdr, 0, 13) -ne 13) { throw "$Label has a truncated PNG IHDR payload." }
                $width = [uint32](([uint32]$ihdr[0] -shl 24) -bor ([uint32]$ihdr[1] -shl 16) -bor ([uint32]$ihdr[2] -shl 8) -bor [uint32]$ihdr[3])
                $height = [uint32](([uint32]$ihdr[4] -shl 24) -bor ([uint32]$ihdr[5] -shl 16) -bor ([uint32]$ihdr[6] -shl 8) -bor [uint32]$ihdr[7])
                if ($width -eq 0 -or $height -eq 0 -or $ihdr[10] -ne 0 -or $ihdr[11] -ne 0 -or $ihdr[12] -gt 1) {
                    throw "$Label has invalid PNG IHDR dimensions or methods."
                }
            }
            else {
                if ($type -ceq 'IHDR') { throw "$Label contains more than one PNG IHDR chunk." }
                if ($type -ceq 'IDAT') { if ($length -gt 0) { $foundIdat = $true } }
                if ($type -ceq 'IEND') {
                    if ($length -ne 0 -or -not $foundIdat) { throw "$Label has an invalid PNG IEND/IDAT sequence." }
                    $foundIend = $true
                }
                [void]$stream.Seek([int64]$length, [IO.SeekOrigin]::Current)
            }
            $crc = [byte[]]::new(4)
            if ($stream.Read($crc, 0, 4) -ne 4) { throw "$Label has a truncated PNG chunk CRC." }
            $chunkIndex++
            if ($foundIend) {
                if ($stream.Position -ne $stream.Length -or ($crc -join ',') -ne '174,66,96,130') {
                    throw "$Label does not end with the canonical terminal PNG IEND chunk."
                }
                break
            }
        }
        if (-not $foundIend) { throw "$Label omits the terminal PNG IEND chunk." }
        return [pscustomobject][ordered]@{ width = $width; height = $height }
    }
    finally { $stream.Dispose() }
}

function Resolve-CSXPortableVisualPath {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$RecordedPath,
        [Parameter(Mandatory)][string]$RecordedDestination,
        [Parameter(Mandatory)][string]$BundledDestination,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($RecordedPath)) { throw "$Label path is missing." }
    if (-not [IO.Path]::IsPathRooted($RecordedPath)) {
        return Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath $RecordedPath
    }
    $recorded = [IO.Path]::GetFullPath($RecordedPath)
    $currentRoot = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($recorded.StartsWith($currentRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Assert-CSXEvidencePathNoReparse -EvidenceRoot $EvidenceRoot -ResolvedPath $recorded -Label $Label
        return $recorded
    }
    if (-not [IO.Path]::IsPathRooted($RecordedDestination)) { throw "$Label recorded destination is not absolute." }
    $sourceRoot = [IO.Path]::GetFullPath($RecordedDestination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $recorded.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path escapes its immutable recorded sequence destination: $RecordedPath"
    }
    $relative = [IO.Path]::GetRelativePath($sourceRoot, $recorded)
    $resolved = [IO.Path]::GetFullPath((Join-Path $BundledDestination $relative))
    $bundleRoot = [IO.Path]::GetFullPath($BundledDestination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($bundleRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label translated path escapes the bundled sequence directory." }
    Assert-CSXEvidencePathNoReparse -EvidenceRoot $EvidenceRoot -ResolvedPath $resolved -Label $Label
    return $resolved
}

function Test-CSXVisualArtifactEvidence {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$VisualIndex
    )
    $errors = [Collections.Generic.List[string]]::new()
    $paths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sequenceRequestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $childRequestIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reviewChildren = @{}
    $totalChildren = 0
    $totalArtifacts = 0
    $runIntervals = [Collections.Generic.List[object]]::new()
    $runElapsedTotalMs = 0.0
    $screenshotSessionId = $null
    $indexValid = $true
    $protocol = $null
    try { $protocol = (Get-CSXQualificationProtocol -Path (Join-Path $EvidenceRoot 'protocol.json')).protocol }
    catch { $errors.Add("Candidate visual protocol validation failed: $($_.Exception.Message)") }
    try { Assert-CSXVisualIndexSet -VisualIndex $VisualIndex -Label 'Candidate' -ExpectedRunId ([string]$Raw.runId) }
    catch { $errors.Add($_.Exception.Message); $indexValid = $false }

    $runs = @(Get-CSXPathValue $Raw 'assays.visual.runs' @())
    if ($runs.Count -ne 3) { $errors.Add("Candidate visual artifact evidence contains $($runs.Count) runs, expected exactly three.") }
    foreach ($replicate in 1..3) {
        $matches = @($runs | Where-Object { (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $_ 'replicate')) -and [double](Get-CSXPropertyValue $_ 'replicate') -eq $replicate })
        if ($matches.Count -ne 1) {
            $errors.Add("Candidate visual replicate $replicate is missing or duplicated.")
            continue
        }
        $run = $matches[0]
        try {
            $requestId = [string](Get-CSXPropertyValue $run 'requestId')
            if ($requestId -notmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
                -not $sequenceRequestIds.Add($requestId)) {
                throw "Visual replicate $replicate has a missing or reused sequence request ID."
            }
            $replicateRoot = "visual/rep-$($replicate.ToString('D2'))"
            foreach ($pathContract in @(
                [pscustomobject]@{ name = 'sequenceRequestPath'; expected = "$replicateRoot/sequence.request.json" },
                [pscustomobject]@{ name = 'terminalReceiptPath'; expected = "$replicateRoot/sequence.terminal.json" },
                [pscustomobject]@{ name = 'childReceiptsPath'; expected = "$replicateRoot/children.receipts.json" }
            )) {
                if ([string](Get-CSXPropertyValue $run $pathContract.name) -cne $pathContract.expected) {
                    throw "Visual replicate $replicate $($pathContract.name) is not its exact canonical path."
                }
            }
            $requestRecord = Read-CSXHashBoundVisualJson -EvidenceRoot $EvidenceRoot `
                -RelativePath ([string](Get-CSXPropertyValue $run 'sequenceRequestPath')) `
                -ExpectedSha256 ([string](Get-CSXPropertyValue $run 'sequenceRequestSha256')) `
                -Label "Visual replicate $replicate sequence request" -Paths $paths
            $request = $requestRecord.value
            $recordedDestination = [string](Get-CSXPathValue $request 'sequence.capture.destination.directory')
            $bundledDestination = Split-Path -Parent $requestRecord.path
            if ($null -eq $protocol -or -not [IO.Path]::IsPathRooted($recordedDestination) -or
                [string](Get-CSXPathValue $request 'sequence.capture.destination.policy') -ne 'absolute' -or
                [IO.Path]::GetFileName([IO.Path]::GetFullPath($recordedDestination).TrimEnd([IO.Path]::DirectorySeparatorChar)) -ne "rep-$($replicate.ToString('D2'))") {
                throw "Visual replicate $replicate sequence request destination is not the exact absolute replicate directory."
            }
            $expectedRequest = New-CSXVisualSequenceRequest -Protocol $protocol -RunId ([string]$Raw.runId) -Replicate $replicate -DestinationDirectory $recordedDestination
            if (($request | ConvertTo-Json -Depth 100 -Compress) -cne ($expectedRequest | ConvertTo-Json -Depth 100 -Compress)) {
                throw "Visual replicate $replicate sequence request differs from the canonical protocol request."
            }
            $shortRequestId = ($requestId -replace '-', '').Substring(0, 8)
            $expectedManifestRelativePath = "$replicateRoot/CS_sequence_$shortRequestId/sequence.json"
            if ([string](Get-CSXPropertyValue $run 'manifestPath') -cne $expectedManifestRelativePath) {
                throw "Visual replicate $replicate manifestPath is not its exact request-owned canonical path."
            }
            $manifestRecord = Read-CSXHashBoundVisualJson -EvidenceRoot $EvidenceRoot `
                -RelativePath ([string](Get-CSXPropertyValue $run 'manifestPath')) `
                -ExpectedSha256 ([string](Get-CSXPropertyValue $run 'manifestSha256')) `
                -Label "Visual replicate $replicate final manifest" -Paths $paths
            $terminalRecord = Read-CSXHashBoundVisualJson -EvidenceRoot $EvidenceRoot `
                -RelativePath ([string](Get-CSXPropertyValue $run 'terminalReceiptPath')) `
                -ExpectedSha256 ([string](Get-CSXPropertyValue $run 'terminalReceiptSha256')) `
                -Label "Visual replicate $replicate terminal receipt" -Paths $paths
            $childrenRecord = Read-CSXHashBoundVisualJson -EvidenceRoot $EvidenceRoot `
                -RelativePath ([string](Get-CSXPropertyValue $run 'childReceiptsPath')) `
                -ExpectedSha256 ([string](Get-CSXPropertyValue $run 'childReceiptsSha256')) `
                -Label "Visual replicate $replicate child-receipt set" -Paths $paths

            $manifest = $manifestRecord.value
            $terminal = Get-CSXPropertyValue $terminalRecord.value 'result'
            $terminalSessionId = [string](Get-CSXPathValue $terminalRecord.value 'server.sessionId')
            if ([string]::IsNullOrWhiteSpace($terminalSessionId)) { throw "Visual replicate $replicate terminal receipt omitted the screenshot service session." }
            if ($null -eq $screenshotSessionId) { $screenshotSessionId = $terminalSessionId }
            elseif ($screenshotSessionId -cne $terminalSessionId) { throw "Visual replicate $replicate terminal receipt changed screenshot service session." }
            if ($null -eq $terminal -or (Get-CSXPropertyValue $terminalRecord.value 'ok') -isnot [bool] -or
                -not [bool](Get-CSXPropertyValue $terminalRecord.value 'ok') -or
                [string](Get-CSXPropertyValue $terminal 'state') -ne 'completed' -or
                [string](Get-CSXPropertyValue $terminal 'kind') -ne 'sequence' -or
                [string](Get-CSXPropertyValue $terminal 'clientId') -ne 'csx-render-scale-qualification' -or
                [string](Get-CSXPropertyValue $terminal 'commandId') -ne "$($Raw.runId)-visual-$($replicate.ToString('D2'))-start" -or
                [string](Get-CSXPropertyValue $terminal 'requestId') -ne $requestId -or
                @(Get-CSXPropertyValue $terminal 'warnings' @()).Count -ne 0 -or
                $null -ne (Get-CSXPropertyValue $terminal 'error') -or
                @(Get-CSXPropertyValue $terminal 'artifacts' @()).Count -ne 1) {
                throw "Visual replicate $replicate terminal receipt identity/state is invalid."
            }
            foreach ($name in @('expected', 'terminal', 'successful')) {
                if (-not (Test-CSXNumberEquals (Get-CSXPathValue $terminal "artifactProgress.$name") 1)) {
                    throw "Visual replicate $replicate terminal artifactProgress.$name is not one."
                }
            }
            $effective = Get-CSXPropertyValue $terminal 'effective'
            if (-not (Test-CSXJsonSemanticIdentity $effective (Get-CSXPropertyValue $request 'sequence')) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $effective 'frameCount') 16) -or
                [string](Get-CSXPathValue $effective 'schedule.basis') -ne 'wall_clock' -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $effective 'schedule.intervalMs') 4000) -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $effective 'schedule.startDelayMs') 0) -or
                [string](Get-CSXPathValue $effective 'schedule.pausePolicy') -ne 'hold') {
                throw "Visual replicate $replicate terminal receipt changed the exact wall-clock sequence schedule."
            }
            $counts = Get-CSXPropertyValue $terminal 'counts'
            foreach ($name in @('requested', 'scheduled', 'acquired', 'written')) {
                if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $counts $name) 16)) {
                    throw "Visual replicate $replicate terminal count '$name' is not 16."
                }
            }
            foreach ($name in @('dropped', 'failed', 'inFlight')) {
                if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $counts $name) 0)) {
                    throw "Visual replicate $replicate terminal count '$name' is not zero."
                }
            }
            $acceptedUtc = [DateTimeOffset]::MinValue
            $terminalUtc = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $terminal 'acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedUtc) -or
                -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $terminal 'terminalUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$terminalUtc)) {
                throw "Visual replicate $replicate terminal receipt timestamps are invalid."
            }
            $terminalElapsedMs = ($terminalUtc - $acceptedUtc).TotalMilliseconds
            if ($terminalElapsedMs -lt 59000 -or $terminalElapsedMs -gt 65000) {
                throw "Visual replicate $replicate terminal elapsed time is outside 59000-65000 ms."
            }

            if ([string](Get-CSXPropertyValue $manifest 'state') -ne 'final' -or
                [string](Get-CSXPropertyValue $manifest 'requestId') -ne $requestId -or
                [string](Get-CSXPathValue $manifest 'contract.name') -ne 'csx.screenshot' -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $manifest 'contract.major') 1) -or
                [string](Get-CSXPropertyValue $manifest 'sessionId') -ne $terminalSessionId -or
                [string](Get-CSXPathValue $manifest 'capture.source.kind') -ne 'hmd_submission' -or
                [string](Get-CSXPathValue $manifest 'capture.source.fallback') -ne 'reject' -or
                [string](Get-CSXPathValue $manifest 'capture.destination.overwrite') -ne 'never') {
                throw "Visual replicate $replicate final manifest identity or capture contract is invalid."
            }
            $terminalManifestPath = Resolve-CSXPortableVisualPath -EvidenceRoot $EvidenceRoot `
                -RecordedPath ([string](Get-CSXPathValue $terminal 'manifest.finalPath')) `
                -RecordedDestination $recordedDestination -BundledDestination $bundledDestination `
                -Label "Visual replicate $replicate terminal manifest"
            $recordedSequenceDirectory = Split-Path -Parent ([IO.Path]::GetFullPath([string](Get-CSXPathValue $terminal 'manifest.finalPath')))
            $expectedSequenceDirectory = Join-Path ([IO.Path]::GetFullPath($recordedDestination)) "CS_sequence_$shortRequestId"
            if (-not [string]::Equals($recordedSequenceDirectory, $expectedSequenceDirectory, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals((Split-Path -Parent $terminalManifestPath), (Split-Path -Parent $manifestRecord.path), [StringComparison]::OrdinalIgnoreCase)) {
                throw "Visual replicate $replicate manifest is not in its exact request-owned sequence directory."
            }
            if (-not [string]::Equals($terminalManifestPath, $manifestRecord.path, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Visual replicate $replicate terminal receipt points to a different final manifest."
            }
            $terminalManifestArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($artifact in @(Get-CSXPropertyValue $terminal 'artifacts' @())) {
                $artifactPath = Resolve-CSXPortableVisualPath -EvidenceRoot $EvidenceRoot `
                    -RecordedPath ([string](Get-CSXPropertyValue $artifact 'path')) `
                    -RecordedDestination $recordedDestination -BundledDestination $bundledDestination `
                    -Label "Visual replicate $replicate terminal artifact"
                if ([string]::Equals($artifactPath, $manifestRecord.path, [StringComparison]::OrdinalIgnoreCase)) {
                    $terminalManifestArtifacts.Add($artifact)
                }
            }
            if ($terminalManifestArtifacts.Count -ne 1 -or
                (Get-CSXPropertyValue $terminalManifestArtifacts[0] 'committed') -isnot [bool] -or
                -not [bool](Get-CSXPropertyValue $terminalManifestArtifacts[0] 'committed') -or
                $null -ne (Get-CSXPropertyValue $terminalManifestArtifacts[0] 'integrityError') -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $terminalManifestArtifacts[0] 'bytes') (Get-Item -LiteralPath $manifestRecord.path).Length) -or
                -not [string]::Equals([string](Get-CSXPropertyValue $terminalManifestArtifacts[0] 'sha256'), $manifestRecord.sha256,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "Visual replicate $replicate terminal receipt does not hash-bind one committed final manifest."
            }

            foreach ($name in @('requested', 'scheduled', 'written')) {
                if (-not (Test-CSXNumberEquals (Get-CSXPathValue $manifest "counts.$name") 16)) { throw "Visual replicate $replicate manifest count '$name' is not 16." }
            }
            foreach ($name in @('dropped', 'failed', 'inFlight')) {
                if (-not (Test-CSXNumberEquals (Get-CSXPathValue $manifest "counts.$name") 0)) { throw "Visual replicate $replicate manifest count '$name' is not zero." }
            }
            $manifestPackagingPath = Resolve-CSXPortableVisualPath -EvidenceRoot $EvidenceRoot `
                -RecordedPath ([string](Get-CSXPathValue $manifest 'packaging.frameManifest.path')) `
                -RecordedDestination $recordedDestination -BundledDestination $bundledDestination `
                -Label "Visual replicate $replicate manifest packaging"
            if (-not [string]::Equals($manifestPackagingPath, $manifestRecord.path, [StringComparison]::OrdinalIgnoreCase) -or
                -not [bool](Get-CSXPathValue $manifest 'packaging.frameManifest.requested' $false) -or
                [string](Get-CSXPathValue $manifest 'packaging.frameManifest.state') -ne 'written' -or
                [bool](Get-CSXPathValue $manifest 'packaging.previewVideo.requested' $true) -or
                [bool](Get-CSXPathValue $manifest 'packaging.previewVideo.required' $true) -or
                [string](Get-CSXPathValue $manifest 'packaging.previewVideo.state') -ne 'not_requested') {
                throw "Visual replicate $replicate manifest packaging contract is invalid."
            }

            $manifestChildren = @(Get-CSXPropertyValue $manifest 'children' @())
            $manifestOrdinals = @($manifestChildren | ForEach-Object { [int](Get-CSXPropertyValue $_ 'ordinal' -1) })
            if ($manifestChildren.Count -ne 16 -or @($manifestOrdinals | Sort-Object -Unique).Count -ne 16 -or
                (@($manifestOrdinals | Sort-Object) -join ',') -ne ((1..16) -join ',')) {
                throw "Visual replicate $replicate final manifest does not contain the exact 16 unique child ordinals."
            }
            $childWrappers = @($childrenRecord.value)
            $wrapperOrdinals = @($childWrappers | ForEach-Object { [int](Get-CSXPropertyValue $_ 'ordinal' -1) })
            if ($childWrappers.Count -ne 16 -or @($wrapperOrdinals | Sort-Object -Unique).Count -ne 16 -or
                (@($wrapperOrdinals | Sort-Object) -join ',') -ne ((1..16) -join ',')) {
                throw "Visual replicate $replicate child-receipt set does not contain the exact 16 unique ordinals."
            }

            $childAcceptedTimes = [Collections.Generic.List[DateTimeOffset]]::new()
            foreach ($ordinal in 1..16) {
                try {
                    $wrapper = @($childWrappers | Where-Object { [int](Get-CSXPropertyValue $_ 'ordinal' -1) -eq $ordinal })[0]
                    $childReceipt = Get-CSXPropertyValue $wrapper 'receipt'
                    $child = Get-CSXPropertyValue $childReceipt 'result'
                    $childRequestId = [string](Get-CSXPropertyValue $child 'requestId')
                    if ((Get-CSXPropertyValue $childReceipt 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $childReceipt 'ok') -or
                        [string](Get-CSXPathValue $childReceipt 'server.sessionId') -ne $terminalSessionId -or
                        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $wrapper 'replicate') $replicate) -or
                        [string](Get-CSXPropertyValue $wrapper 'requestId') -ne $childRequestId -or
                        [string]::IsNullOrWhiteSpace($childRequestId) -or
                        [string](Get-CSXPropertyValue $child 'state') -ne 'completed' -or
                        [string](Get-CSXPropertyValue $child 'kind') -ne 'sequence_frame' -or
                        [string](Get-CSXPropertyValue $child 'clientId') -ne "sequence:$requestId" -or
                        [string](Get-CSXPropertyValue $child 'commandId') -ne "frame:$ordinal" -or
                        [string](Get-CSXPropertyValue $child 'parentRequestId') -ne $requestId -or
                        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $child 'sequenceOrdinal') $ordinal)) {
                        throw "child receipt identity/state is invalid."
                    }
                    if (-not $childRequestIds.Add($childRequestId)) { throw "child request ID is reused across visual evidence." }
                    $manifestChild = @($manifestChildren | Where-Object { [int](Get-CSXPropertyValue $_ 'ordinal' -1) -eq $ordinal })[0]
                    if ([string](Get-CSXPropertyValue $manifestChild 'requestId') -ne $childRequestId -or
                        [string](Get-CSXPropertyValue $manifestChild 'state') -ne 'completed') {
                        throw "final-manifest child binding is invalid."
                    }
                    $wrapperAcceptedUtc = [DateTimeOffset]::MinValue
                    $childAcceptedUtc = [DateTimeOffset]::MinValue
                    $childTerminalUtc = [DateTimeOffset]::MinValue
                    if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $wrapper 'acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$wrapperAcceptedUtc) -or
                        -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $child 'acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$childAcceptedUtc) -or
                        -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $child 'terminalUtc'), [Globalization.CultureInfo]::InvariantCulture,
                            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$childTerminalUtc) -or
                        $wrapperAcceptedUtc.ToUniversalTime() -ne $childAcceptedUtc.ToUniversalTime() -or
                        $childAcceptedUtc -lt $acceptedUtc -or $childAcceptedUtc -gt $terminalUtc -or
                        $childTerminalUtc -lt $childAcceptedUtc -or $childTerminalUtc -gt $terminalUtc) {
                        throw "accepted/terminal timestamp is invalid or outside the sequence interval."
                    }
                    $childAcceptedTimes.Add($childAcceptedUtc)
                    if ([string](Get-CSXPathValue $child 'effective.source.kind') -ne 'hmd_submission' -or
                        [string](Get-CSXPathValue $child 'effective.source.fallback') -ne 'reject' -or
                        [string](Get-CSXPathValue $child 'effective.destination.overwrite') -ne 'never' -or
                        @(Get-CSXPropertyValue $child 'warnings' @()).Count -ne 0 -or
                        $null -ne (Get-CSXPropertyValue $child 'error')) {
                        throw "capture source/fallback/overwrite or warning/error state is invalid."
                    }
                    foreach ($name in @('expected', 'terminal', 'successful')) {
                        if (-not (Test-CSXNumberEquals (Get-CSXPathValue $child "artifactProgress.$name") 3)) {
                            throw "artifactProgress.$name is not three."
                        }
                    }
                    $outputs = @(Get-CSXPathValue $child 'effective.outputs' @())
                    $outputViews = @($outputs | ForEach-Object { [string](Get-CSXPropertyValue $_ 'view') })
                    $outputSuffixes = @($outputs | ForEach-Object { [string](Get-CSXPropertyValue $_ 'nameSuffix') })
                    $canonicalSuffixes = @('left_eye|left-eye', 'right_eye|right-eye', 'side_by_side|side-by-side')
                    $actualViewSuffixes = @($outputs | ForEach-Object { "$([string](Get-CSXPropertyValue $_ 'view'))|$([string](Get-CSXPropertyValue $_ 'nameSuffix'))" })
                    if ($outputs.Count -ne 3 -or @($outputViews | Sort-Object -Unique).Count -ne 3 -or
                        (@($outputViews | Sort-Object) -join ',') -ne 'left_eye,right_eye,side_by_side' -or
                        @($outputSuffixes | Where-Object { [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique).Count -ne 0 -or
                        @($outputSuffixes | Sort-Object -Unique).Count -ne 3 -or
                        (@($actualViewSuffixes | Sort-Object) -join ',') -ne (@($canonicalSuffixes | Sort-Object) -join ',')) {
                        throw "effective output view/suffix set is invalid."
                    }
                    if ([string](Get-CSXPathValue $child 'effective.destination.policy') -ne 'absolute' -or
                        [string](Get-CSXPathValue $child 'effective.destination.overwrite') -ne 'never' -or
                        [string](Get-CSXPathValue $child 'effective.destination.baseName') -ne "frame_$($ordinal.ToString('D6'))" -or
                        -not [string]::Equals([IO.Path]::GetFullPath([string](Get-CSXPathValue $child 'effective.destination.directory')), $recordedSequenceDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "effective destination is not the canonical sequence-frame destination."
                    }
                    foreach ($output in $outputs) {
                        if ([string](Get-CSXPathValue $output 'encoding.format') -ne 'png' -or
                            [string](Get-CSXPathValue $output 'encoding.colourContract') -ne 'sdr_srgb') {
                            throw "output encoding is not PNG/sdr_srgb."
                        }
                    }
                    $embeddedArtifacts = @(Get-CSXPropertyValue $child 'artifacts' @())
                    $normalizedArtifacts = @(Get-CSXPropertyValue $wrapper 'artifacts' @())
                    $normalizedViews = @($normalizedArtifacts | ForEach-Object { [string](Get-CSXPropertyValue $_ 'view') })
                    if ($embeddedArtifacts.Count -ne 3 -or $normalizedArtifacts.Count -ne 3 -or
                        @($normalizedViews | Sort-Object -Unique).Count -ne 3 -or
                        (@($normalizedViews | Sort-Object) -join ',') -ne 'left_eye,right_eye,side_by_side') {
                        throw "embedded or normalized artifact set is not the exact three views."
                    }
                    $boundArtifacts = [Collections.Generic.List[object]]::new()
                    foreach ($output in $outputs) {
                        $view = [string](Get-CSXPropertyValue $output 'view')
                        $suffix = [string](Get-CSXPropertyValue $output 'nameSuffix')
                        $embeddedMatches = @($embeddedArtifacts | Where-Object {
                            [IO.Path]::GetFileNameWithoutExtension([string](Get-CSXPropertyValue $_ 'path')).EndsWith("_$suffix", [StringComparison]::Ordinal)
                        })
                        $normalizedMatches = @($normalizedArtifacts | Where-Object { [string](Get-CSXPropertyValue $_ 'view') -eq $view })
                        if ($embeddedMatches.Count -ne 1 -or $normalizedMatches.Count -ne 1) {
                            throw "view '$view' is not bound to exactly one embedded and normalized artifact."
                        }
                        $embedded = $embeddedMatches[0]
                        $normalized = $normalizedMatches[0]
                        if ((Get-CSXPropertyValue $embedded 'committed') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $embedded 'committed')) {
                            throw "view '$view' artifact is not committed."
                        }
                        $normalizedPathText = [string](Get-CSXPropertyValue $normalized 'path')
                        $normalizedPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath $normalizedPathText
                        Add-CSXUniqueVisualEvidencePath -Paths $paths -Path $normalizedPath `
                            -Label "Visual replicate $replicate ordinal $ordinal view $view"
                        $embeddedPath = Resolve-CSXPortableVisualPath -EvidenceRoot $EvidenceRoot `
                            -RecordedPath ([string](Get-CSXPropertyValue $embedded 'path')) `
                            -RecordedDestination $recordedDestination -BundledDestination $bundledDestination `
                            -Label "Visual replicate $replicate ordinal $ordinal view $view embedded artifact"
                        if (-not [string]::Equals($normalizedPath, $embeddedPath, [StringComparison]::OrdinalIgnoreCase) -or
                            -not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
                            throw "view '$view' normalized/embedded artifact paths differ or the file is missing."
                        }
                        $expectedFileName = "frame_$($ordinal.ToString('D6'))_$suffix.png"
                        $expectedRelativeArtifactPath = "$replicateRoot/CS_sequence_$shortRequestId/$expectedFileName"
                        if ($normalizedPathText -cne $expectedRelativeArtifactPath -or
                            $null -ne (Get-CSXPropertyValue $embedded 'integrityError') -or
                            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $embedded 'bytes') (Get-Item -LiteralPath $normalizedPath).Length)) {
                            throw "view '$view' artifact layout, length, or integrity state is invalid."
                        }
                        $actualSha256 = Get-CSXFileSha256 $normalizedPath
                        $normalizedSha256 = [string](Get-CSXPropertyValue $normalized 'sha256')
                        $embeddedSha256 = [string](Get-CSXPropertyValue $embedded 'sha256')
                        if (-not (Test-CSXSha256Text $normalizedSha256) -or
                            -not [string]::Equals($actualSha256, $normalizedSha256, [StringComparison]::OrdinalIgnoreCase) -or
                            -not [string]::Equals($actualSha256, $embeddedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                            throw "view '$view' artifact SHA-256 binding does not match."
                        }
                        $dimensions = Get-CSXValidatedPngDimensions -Path $normalizedPath `
                            -Label "Visual replicate $replicate ordinal $ordinal view $view"
                        $recordedWidth = Get-CSXPropertyValue $normalized 'width'
                        $recordedHeight = Get-CSXPropertyValue $normalized 'height'
                        if (-not (Test-CSXNumberEquals $recordedWidth $dimensions.width) -or
                            -not (Test-CSXNumberEquals $recordedHeight $dimensions.height)) {
                            throw "view '$view' recorded and actual PNG dimensions differ."
                        }
                        $boundArtifacts.Add([pscustomobject][ordered]@{
                            view = $view; path = $normalizedPathText; fullPath = $normalizedPath
                            sha256 = $actualSha256; width = $dimensions.width; height = $dimensions.height
                        })
                    }
                    $left = @($boundArtifacts | Where-Object view -eq 'left_eye')[0]
                    $right = @($boundArtifacts | Where-Object view -eq 'right_eye')[0]
                    $stereo = @($boundArtifacts | Where-Object view -eq 'side_by_side')[0]
                    if ($left.width -ne $right.width -or $left.height -ne $right.height -or
                        [uint64]$stereo.width -ne 2 * [uint64]$left.width -or $stereo.height -ne $left.height) {
                        throw "equal-eye and side-by-side PNG geometry is invalid."
                    }
                    $manifestArtifact = Get-CSXPropertyValue $manifestChild 'artifact'
                    if ($null -eq $manifestArtifact -or $null -ne (Get-CSXPropertyValue $manifestChild 'error')) {
                        throw "final-manifest completed child omitted its committed artifact or retained an error."
                    }
                    else {
                        $manifestArtifactSha256 = [string](Get-CSXPropertyValue $manifestArtifact 'sha256')
                        if (-not (Test-CSXSha256Text $manifestArtifactSha256) -or
                            @($boundArtifacts | Where-Object { [string]::Equals($_.sha256, $manifestArtifactSha256, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
                            throw "final-manifest artifact binding does not identify one child artifact."
                        }
                        $manifestArtifactPathText = [string](Get-CSXPropertyValue $manifestArtifact 'path')
                        if (-not [string]::IsNullOrWhiteSpace($manifestArtifactPathText)) {
                            $manifestArtifactPath = Resolve-CSXPortableVisualPath -EvidenceRoot $EvidenceRoot `
                                -RecordedPath $manifestArtifactPathText `
                                -RecordedDestination $recordedDestination -BundledDestination $bundledDestination `
                                -Label "Visual replicate $replicate ordinal $ordinal manifest child artifact"
                            if (@($boundArtifacts | Where-Object { [string]::Equals($_.fullPath, $manifestArtifactPath, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
                                throw "final-manifest child artifact path differs from the receipt artifacts."
                            }
                        }
                    }
                    if ($ordinal -in @(1, 8, 16)) { $reviewChildren["${replicate}:$ordinal"] = @($boundArtifacts) }
                    $totalChildren++
                    $totalArtifacts += $boundArtifacts.Count
                }
                catch { $errors.Add("Visual replicate $replicate ordinal $ordinal validation failed: $($_.Exception.Message)") }
            }
            if ($childAcceptedTimes.Count -eq 16) {
                for ($i = 1; $i -lt $childAcceptedTimes.Count; $i++) {
                    $cadenceMs = ($childAcceptedTimes[$i] - $childAcceptedTimes[$i - 1]).TotalMilliseconds
                    if ($cadenceMs -lt 3000 -or $cadenceMs -gt 5000) {
                        throw "Visual replicate $replicate child acceptance cadence is outside 3000-5000 ms."
                    }
                }
                $childSpanMs = ($childAcceptedTimes[-1] - $childAcceptedTimes[0]).TotalMilliseconds
                if ($childSpanMs -lt 59000 -or $childSpanMs -gt 65000) {
                    throw "Visual replicate $replicate child acceptance span is outside 59000-65000 ms."
                }
            }
            if (-not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $run 'elapsedMs')) -or
                -not (Test-CSXNumberClose (Get-CSXPropertyValue $run 'elapsedMs') $terminalElapsedMs)) {
                throw "Visual replicate $replicate raw elapsedMs differs from its terminal wall-clock interval."
            }
            $runElapsedTotalMs += $terminalElapsedMs
            $runIntervals.Add([pscustomobject][ordered]@{ replicate = $replicate; acceptedUtc = $acceptedUtc; terminalUtc = $terminalUtc })
        }
        catch { $errors.Add($_.Exception.Message) }
    }
    if ($totalChildren -ne 48 -or $totalArtifacts -ne 144) {
        $errors.Add("Candidate visual artifact evidence validates $totalChildren/48 children and $totalArtifacts/144 PNG artifacts.")
    }
    if ($runIntervals.Count -eq 3) {
        $orderedIntervals = @($runIntervals | Sort-Object replicate)
        for ($index = 1; $index -lt $orderedIntervals.Count; $index++) {
            if ($orderedIntervals[$index].acceptedUtc -lt $orderedIntervals[$index - 1].terminalUtc) {
                $errors.Add('Candidate visual replicate wall-clock intervals overlap or are out of order.')
            }
        }
        $visualWallClockMs = Get-CSXPathValue $Raw 'assays.visual.wallClockMs'
        $wholeSpanMs = ($orderedIntervals[-1].terminalUtc - $orderedIntervals[0].acceptedUtc).TotalMilliseconds
        if (-not (Test-CSXFiniteNonNegativeNumber $visualWallClockMs) -or [double]$visualWallClockMs -lt $runElapsedTotalMs -or
            [double]$visualWallClockMs -lt $wholeSpanMs -or ($null -ne $protocol -and [double]$visualWallClockMs -gt [double]$protocol.timeBudget.visualAssayMs)) {
            $errors.Add('Candidate visual aggregate wallClockMs does not contain the recomputed sequential capture span within budget.')
        }
    }

    if ($indexValid) {
        foreach ($replicate in 1..3) {
            foreach ($ordinal in @(1, 8, 16)) {
                $key = "${replicate}:$ordinal"
                $sample = @($VisualIndex.samples | Where-Object {
                    [int](Get-CSXPropertyValue $_ 'replicate' -1) -eq $replicate -and [int](Get-CSXPropertyValue $_ 'ordinal' -1) -eq $ordinal
                })[0]
                $children = @($reviewChildren[$key])
                $indexArtifacts = @(Get-CSXPropertyValue $sample 'artifacts' @())
                if ($children.Count -ne 3 -or $indexArtifacts.Count -ne 3) {
                    $errors.Add("Candidate visual index sample $key is not backed by the validated child receipt's three artifacts.")
                    continue
                }
                foreach ($indexArtifact in $indexArtifacts) {
                    try {
                        $view = [string](Get-CSXPropertyValue $indexArtifact 'view')
                        $childMatches = @($children | Where-Object view -eq $view)
                        if ($childMatches.Count -ne 1) { throw "view '$view' is not uniquely present in the validated child receipt." }
                        $child = $childMatches[0]
                        $indexPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $indexArtifact 'path'))
                        if (-not [string]::Equals($indexPath, $child.fullPath, [StringComparison]::OrdinalIgnoreCase) -or
                            -not [string]::Equals([string](Get-CSXPropertyValue $indexArtifact 'sha256'), $child.sha256, [StringComparison]::OrdinalIgnoreCase) -or
                            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $indexArtifact 'width') $child.width) -or
                            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $indexArtifact 'height') $child.height)) {
                            throw "view '$view' path/hash/dimensions differ from the validated child receipt."
                        }
                    }
                    catch { $errors.Add("Candidate visual index sample $key validation failed: $($_.Exception.Message)") }
                }
            }
        }
    }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors | Select-Object -Unique) }
}

function Test-CSXAutomationArtifactInventory {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)]$Raw
    )
    $errors = [Collections.Generic.List[string]]::new()
    $inventory = $null
    $inventoryPath = $null
    $entriesByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $mutableNames = @(
        '.csx-render-scale-qualification.lock', 'automation-artifacts.json', 'run.raw.json', 'run.json',
        'visual-review.json', 'failures.json',
        'pr-summary.md', 'qualification-summary.md'
    )
    $binding = Get-CSXPropertyValue $Raw 'artifactInventory'
    try {
        if ($null -eq $binding -or [string](Get-CSXPropertyValue $binding 'schema') -ne 'csx-render-scale-automation-artifacts-v1' -or
            [string](Get-CSXPropertyValue $binding 'path') -ne 'automation-artifacts.json' -or
            -not (Test-CSXSha256Text (Get-CSXPropertyValue $binding 'sha256')) -or
            -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $binding 'entryCount')) -or
            [double](Get-CSXPropertyValue $binding 'entryCount') -ne [Math]::Truncate([double](Get-CSXPropertyValue $binding 'entryCount'))) {
            throw 'Raw automation artifact inventory binding is missing or invalid.'
        }
        $inventoryPath = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath ([string](Get-CSXPropertyValue $binding 'path'))
        if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) { throw 'Automation artifact inventory file is missing.' }
        if (-not [string]::Equals((Get-CSXFileSha256 $inventoryPath), [string](Get-CSXPropertyValue $binding 'sha256'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Automation artifact inventory SHA-256 binding does not match.'
        }
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -Depth 100
        if ([string](Get-CSXPropertyValue $inventory 'schema') -ne 'csx-render-scale-automation-artifacts-v1' -or
            [string](Get-CSXPropertyValue $inventory 'runId') -ne [string](Get-CSXPropertyValue $Raw 'runId') -or
            -not [string]::Equals([string](Get-CSXPropertyValue $inventory 'candidateBuildId'), [string](Get-CSXPathValue $Raw 'runtime.buildId'), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string](Get-CSXPropertyValue $inventory 'protocolSha256'), [string](Get-CSXPathValue $Raw 'protocol.sha256'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Automation artifact inventory run/build/protocol identity does not match run.raw.'
        }
        $entries = @(Get-CSXPropertyValue $inventory 'entries' @())
        if ($entries.Count -ne [int](Get-CSXPropertyValue $binding 'entryCount')) {
            throw 'Automation artifact inventory entry count does not match run.raw.'
        }
        foreach ($entry in $entries) {
            $relative = [string](Get-CSXPropertyValue $entry 'path')
            if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
                $relative.Contains('\') -or $relative.StartsWith('baseline/', [StringComparison]::OrdinalIgnoreCase) -or
                $relative -in $mutableNames) {
                throw "Automation artifact inventory contains an invalid or excluded path: $relative"
            }
            $resolved = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath $relative
            $canonical = [IO.Path]::GetRelativePath($root, $resolved).Replace('\', '/')
            if (-not [string]::Equals($relative, $canonical, [StringComparison]::Ordinal)) {
                throw "Automation artifact inventory path is not canonical: $relative"
            }
            if (-not $entriesByPath.TryAdd($relative, $entry)) {
                throw "Automation artifact inventory contains a duplicate or case-colliding path: $relative"
            }
            $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
            if ($extension -notin @('.json', '.jsonl', '.csv', '.png', '.md') -or [string](Get-CSXPropertyValue $entry 'kind') -ne $extension.Substring(1)) {
                throw "Automation artifact inventory kind does not match its supported extension: $relative"
            }
            $byteLength = Get-CSXPropertyValue $entry 'byteLength'
            $sha256 = [string](Get-CSXPropertyValue $entry 'sha256')
            if (-not (Test-CSXFiniteNonNegativeNumber $byteLength) -or [double]$byteLength -ne [Math]::Truncate([double]$byteLength) -or
                [double]$byteLength -le 0 -or -not (Test-CSXSha256Text $sha256) -or
                -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                throw "Automation artifact inventory metadata or file is invalid: $relative"
            }
            $file = Get-Item -LiteralPath $resolved
            if ([uint64]$file.Length -ne [uint64]$byteLength -or
                -not [string]::Equals((Get-CSXFileSha256 $resolved), $sha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Automation artifact inventory length/hash binding does not match: $relative"
            }
        }
        if (@($entries | Where-Object { [string](Get-CSXPropertyValue $_ 'kind') -eq 'png' }).Count -ne 144) {
            throw 'Automation artifact inventory must hash-bind exactly 144 PNG captures.'
        }
        $required = @(
            'protocol.json', 'fixture-manifest.json', 'binding/authoritative-list.json', 'binding/raw-session-identity.json',
            'preflight-retained-diagnostics.json', 'transitions.json', 'transitions.csv',
            'coc/transitions.json', 'coc/transitions.csv', 'menu/transitions.json', 'menu/transitions.csv',
            'coc/scenario.request.json', 'coc/scenario.result.json', 'coc/diagnostics.json', 'coc/stress-record.json', 'coc/cpu-record.json',
            'menu/scenario.request.json', 'menu/scenario.result.json', 'menu/diagnostics.json', 'menu/stress-record.json', 'menu/cpu-record.json', 'menu/dlss-traces.json',
            'recovery-1.json', 'recovery-2.json', 'mcp-transcript.json', 'visual-index.json', 'visual/fixture-observations.json',
            'visual/diagnostics.json', 'visual/stress-record.json', 'visual/cpu-record.json',
            'visual-review/prompt.v1.md', 'visual-review/output-schema.v1.json',
            'visual-review/preflight.json', 'visual-review/execution.json',
            'visual/rep-01/sequence.request.json', 'visual/rep-01/sequence.terminal.json', 'visual/rep-01/children.receipts.json',
            'visual/rep-02/sequence.request.json', 'visual/rep-02/sequence.terminal.json', 'visual/rep-02/children.receipts.json',
            'visual/rep-03/sequence.request.json', 'visual/rep-03/sequence.terminal.json', 'visual/rep-03/children.receipts.json'
        )
        foreach ($relative in $required) {
            if (-not $entriesByPath.ContainsKey($relative)) { throw "Automation artifact inventory omits required producer evidence: $relative" }
        }
        foreach ($run in @(Get-CSXPathValue $Raw 'assays.visual.runs' @())) {
            foreach ($name in @('manifestPath', 'sequenceRequestPath', 'terminalReceiptPath', 'childReceiptsPath')) {
                $relative = [string](Get-CSXPropertyValue $run $name)
                if (-not $entriesByPath.ContainsKey($relative)) { throw "Automation artifact inventory omits visual run path '$name': $relative" }
            }
        }
        foreach ($batch in @(Get-CSXPathValue $Raw 'assays.visual.automatedReview.batches' @())) {
            foreach ($name in @('requestPath', 'responsePath', 'eventsPath', 'stderrPath', 'receiptPath')) {
                $relative = [string](Get-CSXPropertyValue $batch $name)
                if (-not $entriesByPath.ContainsKey($relative)) {
                    throw "Automation artifact inventory omits automated visual-review path '$name': $relative"
                }
            }
        }
        Assert-CSXEvidencePathNoReparse -EvidenceRoot $root -ResolvedPath $root -Label 'Automation artifact inventory'
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force)) {
            Assert-CSXEvidencePathNoReparse -EvidenceRoot $root -ResolvedPath $directory.FullName -Label 'Automation artifact inventory directory'
        }
        $actualPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
            $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
            if ($relative.StartsWith('baseline/', [StringComparison]::OrdinalIgnoreCase) -or $relative -in $mutableNames) { continue }
            if ([IO.Path]::GetExtension($relative).ToLowerInvariant() -notin @('.json', '.jsonl', '.csv', '.png', '.md')) {
                throw "Unsupported file is present in the closed automation artifact envelope: $relative"
            }
            Assert-CSXEvidencePathNoReparse -EvidenceRoot $root -ResolvedPath $file.FullName -Label 'Automation artifact inventory file'
            if (-not $actualPaths.Add($relative)) { throw "Evidence directory contains duplicate or case-colliding producer paths: $relative" }
        }
        foreach ($relative in $actualPaths) {
            if (-not $entriesByPath.ContainsKey($relative)) { throw "Uninventoried automation producer artifact is present: $relative" }
        }
        foreach ($relative in $entriesByPath.Keys) {
            if (-not $actualPaths.Contains($relative)) { throw "Inventoried automation producer artifact is absent: $relative" }
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    return [pscustomobject][ordered]@{
        ok = $errors.Count -eq 0
        errors = @($errors | Select-Object -Unique)
        inventory = $inventory
        inventoryPath = $inventoryPath
        entriesByPath = $entriesByPath
    }
}

function Read-CSXProducerJson {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Label
    )
    $path = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label is missing: $RelativePath" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
}

function Get-CSXStressTransitionProjection {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][ValidateSet('coc', 'menu')][string]$Assay
    )
    $requests = @($Record.events | Where-Object type -eq 'Request' | Sort-Object sequence)
    $metrics = @($Record.metrics | Sort-Object transitionEpoch)
    $requestEpochs = @($requests | ForEach-Object { [string](Get-CSXPropertyValue $_ 'transitionEpoch') })
    $metricEpochs = @($metrics | ForEach-Object { [string](Get-CSXPropertyValue $_ 'transitionEpoch') })
    $terminalGate = @($Record.acceptance.gates | Where-Object name -eq 'terminal_state')
    $projection = [pscustomobject][ordered]@{
        requestEvents = $requests.Count
        uniqueRequestEpochs = @($requestEpochs | Sort-Object -Unique).Count
        metrics = $metrics.Count
        uniqueMetricEpochs = @($metricEpochs | Sort-Object -Unique).Count
        coalescedDuplicateCount = Get-CSXPathValue $Record 'session.coalescedDuplicateCount'
        overwrittenEvents = Get-CSXPathValue $Record 'session.overwrittenEvents'
        terminalMetricClear = $terminalGate.Count -eq 1 -and [bool]$terminalGate[0].passed
        exactMenuCrossBindings = @()
    }
    if ($Assay -eq 'menu' -and $requests.Count -eq 25 -and $Rows.Count -eq 25) {
        $bindings = [Collections.Generic.List[object]]::new()
        for ($index = 0; $index -lt 25; $index++) {
            $row = @($Rows | Where-Object { [int](Get-CSXPropertyValue $_ 'ordinal' -1) -eq $index + 1 })
            if ($row.Count -ne 1) { throw "Menu stress source row $($index + 1) is missing or duplicated." }
            $request = $requests[$index]
            $epoch = Get-CSXPropertyValue $request 'transitionEpoch'
            $metric = @($metrics | Where-Object { Test-CSXNumberEquals (Get-CSXPropertyValue $_ 'transitionEpoch') $epoch })
            if ($metric.Count -ne 1 -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $request 'requestID') (Get-CSXPathValue $row[0] 'receipts.mutation.requestID')) -or
                -not (Test-CSXNumberEquals $epoch (Get-CSXPathValue $row[0] 'receipts.mutation.transitionEpoch')) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $metric[0] 'requestID') (Get-CSXPropertyValue $request 'requestID')) -or
                -not [bool](Get-CSXPropertyValue $metric[0] 'completed' $false) -or [bool](Get-CSXPropertyValue $metric[0] 'superseded' $true) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $request 'occurrences') 1)) {
                throw "Menu stress source apply/request/metric identity failed at ordinal $($index + 1)."
            }
            $method = ([string](Get-CSXPropertyValue $request 'method')).TrimStart('k').ToLowerInvariant()
            $metricMethod = ([string](Get-CSXPropertyValue $metric[0] 'method')).TrimStart('k').ToLowerInvariant()
            if ($method -ne [string](Get-CSXPropertyValue $row[0] 'method') -or $metricMethod -ne $method -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $request 'qualityMode') (Get-CSXPropertyValue $row[0] 'qualityMode')) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $metric[0] 'qualityMode') (Get-CSXPropertyValue $row[0] 'qualityMode')) -or
                [bool](Get-CSXPropertyValue $request 'active') -ne [bool](Get-CSXPropertyValue $row[0] 'renderScaleMode')) {
                throw "Menu stress source target identity failed at ordinal $($index + 1)."
            }
            $bindings.Add([pscustomobject][ordered]@{
                ordinal = $index + 1; requestID = Get-CSXPropertyValue $request 'requestID'; transitionEpoch = $epoch
                method = $method; qualityMode = Get-CSXPropertyValue $request 'qualityMode'; renderScaleMode = [bool](Get-CSXPropertyValue $request 'active')
            })
        }
        $projection.exactMenuCrossBindings = @($bindings)
    }
    return $projection
}

function Test-CSXScenarioSourceIdentity {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)]$ExpectedRequest,
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][ValidateSet('coc', 'menu')][string]$Assay
    )
    if (-not (Test-CSXJsonIdentity $Request $ExpectedRequest)) { throw "$Assay scenario request differs from the canonical plan." }
    $requestSteps = @($Request.steps)
    $resultSteps = @($Result.results)
    if ((Get-CSXPropertyValue $Result 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $Result 'ok') -or
        (Get-CSXPropertyValue $Result 'aborted') -isnot [bool] -or [bool](Get-CSXPropertyValue $Result 'aborted') -or
        $resultSteps.Count -ne $requestSteps.Count) {
        throw "$Assay scenario result is incomplete, failed, or aborted."
    }
    for ($index = 0; $index -lt $requestSteps.Count; $index++) {
        if ([string](Get-CSXPropertyValue $resultSteps[$index] 'label') -cne [string](Get-CSXPropertyValue $requestSteps[$index] 'label') -or
            (Get-CSXPropertyValue $resultSteps[$index] 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $resultSteps[$index] 'ok') -or
            $null -eq (Get-CSXPropertyValue $resultSteps[$index] 'result')) {
            throw "$Assay scenario result step $($index + 1) does not match its fail-fast request step."
        }
    }
    foreach ($row in $Rows) {
        $ordinal = [int](Get-CSXPropertyValue $row 'ordinal')
        $prefix = "$Assay-$($ordinal.ToString('D2'))"
        $labels = [ordered]@{
            begin = "$prefix-begin"; dispatch = "$prefix-dispatch"
            mutation = "$prefix-$(if ($Assay -eq 'coc') { 'command' } else { 'apply' })"; wait = "$prefix-wait"
        }
        foreach ($name in $labels.Keys) {
            $matches = @($resultSteps | Where-Object { [string](Get-CSXPropertyValue $_ 'label') -ceq $labels[$name] })
            if ($matches.Count -ne 1 -or -not (Test-CSXJsonIdentity (Get-CSXPathValue $row "receipts.$name") (Get-CSXPropertyValue $matches[0] 'result'))) {
                throw "$Assay scenario receipt '$($labels[$name])' differs from run.raw."
            }
        }
    }
}

function Test-CSXProducerArtifactEvidence {
    param(
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Protocol
    )
    $errors = [Collections.Generic.List[string]]::new()
    $source = @{}
    $runId = [string](Get-CSXPropertyValue $Raw 'runId')
    $buildId = [string](Get-CSXPathValue $Raw 'runtime.buildId')
    $gpuVendor = [string](Get-CSXPathValue $Raw 'fixture.gpuVendor')
    $fsrRuntime = [string](Get-CSXPathValue $Raw 'fixture.fsrRuntime')
    try {
        $authoritativeBinding = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath 'binding/authoritative-list.json' -Label 'Authoritative tools/list binding'
        $rawSessionIdentity = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath 'binding/raw-session-identity.json' -Label 'Raw MCP session identity'
        if ((Get-CSXPropertyValue $authoritativeBinding 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $authoritativeBinding 'ok') -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $authoritativeBinding 'runtimeIdentity') (Get-CSXPathValue $Raw 'runtime.binding'))) {
            throw 'Authoritative tools/list runtime identity differs from run.raw.'
        }
        if ((Get-CSXPropertyValue $rawSessionIdentity 'verified') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $rawSessionIdentity 'verified') -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $rawSessionIdentity 'pid') (Get-CSXPathValue $Raw 'runtime.binding.listenerPid')) -or
            -not [string]::Equals([string](Get-CSXPropertyValue $rawSessionIdentity 'exe'), [string](Get-CSXPathValue $Raw 'runtime.health.exe'), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string](Get-CSXPropertyValue $rawSessionIdentity 'processPath'), [string](Get-CSXPathValue $Raw 'runtime.binding.process.path'), [StringComparison]::OrdinalIgnoreCase) -or
            [string](Get-CSXPropertyValue $rawSessionIdentity 'processStartTimeUtc') -ne [string](Get-CSXPathValue $Raw 'runtime.binding.process.startTimeUtc')) {
            throw 'Raw MCP session identity does not project the authoritative binding and health identity.'
        }
        $allRows = @(Get-CSXPathValue $Raw 'assays.coc.records' @()) + @(Get-CSXPathValue $Raw 'assays.menu.records' @())
        $allTransitions = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath 'transitions.json' -Label 'Combined transitions'
        if ([string](Get-CSXPropertyValue $allTransitions 'schema') -ne 'csx-render-scale-transitions-v1' -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $allTransitions 'rows') $allRows)) {
            throw 'Combined transition artifact differs from run.raw rows.'
        }
        foreach ($assay in @('coc', 'menu')) {
            $assayTransitions = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath "$assay/transitions.json" -Label "$assay transitions"
            if ([string](Get-CSXPropertyValue $assayTransitions 'schema') -ne 'csx-render-scale-transitions-v1' -or
                [string](Get-CSXPropertyValue $assayTransitions 'assay') -ne $assay -or
                -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $assayTransitions 'rows') (Get-CSXPathValue $Raw "assays.$assay.records"))) {
                throw "$assay transition artifact differs from run.raw rows."
            }
        }
        $source['runtime.health'] = Get-CSXPathValue $Raw 'runtime.health'
        foreach ($assay in @('coc', 'menu')) {
            $expectedPaths = if ($assay -eq 'coc') {
                [ordered]@{ scenarioRequest = 'coc/scenario.request.json'; scenarioResult = 'coc/scenario.result.json'; diagnostics = 'coc/diagnostics.json'; stressRecord = 'coc/stress-record.json'; cpuRecord = 'coc/cpu-record.json' }
            }
            else {
                [ordered]@{ scenarioRequest = 'menu/scenario.request.json'; scenarioResult = 'menu/scenario.result.json'; diagnostics = 'menu/diagnostics.json'; stressRecord = 'menu/stress-record.json'; cpuRecord = 'menu/cpu-record.json'; dlssTraces = 'menu/dlss-traces.json' }
            }
            foreach ($name in $expectedPaths.Keys) {
                if ([string](Get-CSXPathValue $Raw "assays.$assay.evidence.$name") -ne $expectedPaths[$name]) {
                    throw "$assay raw evidence path '$name' is not canonical."
                }
                $source["$assay.$name"] = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath $expectedPaths[$name] -Label "$assay $name"
            }
            $expectedRequest = if ($assay -eq 'coc') {
                New-CSXCocScenario -Protocol $Protocol -GpuVendor $gpuVendor -FsrRuntime $fsrRuntime -ExpectedBuildId $buildId -RunId $runId
            }
            else {
                (New-CSXMenuScenario -Protocol $Protocol -GpuVendor $gpuVendor -FsrRuntime $fsrRuntime -ExpectedBuildId $buildId `
                    -ExpectedCellEditorId ([string]$Protocol.fixture.startCellEditorId) -RunId $runId).scenario
            }
            Test-CSXScenarioSourceIdentity -Request $source["$assay.scenarioRequest"] -Result $source["$assay.scenarioResult"] `
                -ExpectedRequest $expectedRequest -Rows @(Get-CSXPathValue $Raw "assays.$assay.records" @()) -Assay $assay
            $scenarioWallMs = Get-CSXPropertyValue $source["$assay.scenarioResult"] 'wallClockMs'
            $rawWallMs = Get-CSXPathValue $Raw "assays.$assay.wallClockMs"
            if (-not (Test-CSXFiniteNonNegativeNumber $scenarioWallMs) -or -not (Test-CSXFiniteNonNegativeNumber $rawWallMs) -or
                [double]$rawWallMs -lt [double]$scenarioWallMs -or [double]$rawWallMs - [double]$scenarioWallMs -gt 1000.0) {
                throw "$assay raw wall clock does not contain its scenario execution interval."
            }
            $diagnostics = $source["$assay.diagnostics"]
            $stressResponse = Get-CSXPropertyValue $diagnostics 'stress'
            $cpuResponse = Get-CSXPropertyValue $diagnostics 'cpu'
            $stressRecord = $source["$assay.stressRecord"]
            $cpuRecord = $source["$assay.cpuRecord"]
            if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $stressResponse 'record') $stressRecord) -or
                -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $cpuResponse 'cpuPerformance') $cpuRecord)) {
                throw "$assay diagnostic response differs from its immutable stress/CPU record."
            }
            if ([string](Get-CSXPathValue $stressResponse 'producer.buildId') -ne $buildId -or
                [string](Get-CSXPathValue $cpuResponse 'producer.buildId') -ne $buildId -or
                [string](Get-CSXPropertyValue $stressResponse 'action') -ne 'stop' -or
                [string](Get-CSXPropertyValue $cpuResponse 'action') -ne 'cpu_performance_stop') {
                throw "$assay diagnostic stop producer/action identity is invalid."
            }
            $stressId = Get-CSXPathValue $stressResponse 'status.session.id'
            $firstRawRow = @(Get-CSXPathValue $Raw "assays.$assay.records" @())[0]
            if (-not (Test-CSXNumberEquals $stressId (Get-CSXPathValue $stressRecord 'session.id')) -or
                -not (Test-CSXNumberEquals $stressId (Get-CSXPathValue $firstRawRow 'receipts.begin.baseline.stressSessionId')) -or
                [bool](Get-CSXPathValue $stressResponse 'status.session.active' $true) -or
                [bool](Get-CSXPathValue $stressRecord 'session.active' $true) -or
                [string](Get-CSXPropertyValue $stressRecord 'schema') -ne 'community-shaders.vr-render-scale.iteration' -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $stressRecord 'schemaVersion') $Protocol.thresholds.stressRecordSchemaVersion) -or
                (Get-CSXPathValue $stressRecord 'acceptance.accepted') -isnot [bool] -or -not [bool](Get-CSXPathValue $stressRecord 'acceptance.accepted')) {
                throw "$assay stress record session/schema/verdict identity is invalid."
            }
            foreach ($row in @(Get-CSXPathValue $Raw "assays.$assay.records" @())) {
                if (-not (Test-CSXNumberEquals (Get-CSXPathValue $row 'receipts.begin.baseline.stressSessionId') $stressId) -or
                    -not (Test-CSXNumberEquals (Get-CSXPathValue $row 'receipts.wait.baseline.stressSessionId') $stressId)) {
                    throw "$assay raw transition is bound to a different stress session."
                }
            }
            $stressProjection = Get-CSXStressTransitionProjection -Record $stressRecord -Rows @(Get-CSXPathValue $Raw "assays.$assay.records" @()) -Assay $assay
            if (-not (Test-CSXJsonIdentity $stressProjection (Get-CSXPathValue $Raw "assays.$assay.stressTransitions"))) {
                throw "$assay stress transition projection differs from its immutable stress record."
            }
            $cpuSessionId = Get-CSXPropertyValue $cpuRecord 'sessionId'
            if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $cpuRecord 'schemaVersion') 1) -or
                -not (Test-CSXNumberEquals $cpuSessionId (Get-CSXPathValue $cpuResponse 'cpuPerformance.sessionId')) -or
                [decimal]$cpuSessionId -le 0 -or [bool](Get-CSXPropertyValue $cpuRecord 'active' $true) -or
                [string](Get-CSXPropertyValue $cpuRecord 'state') -ne 'stopped' -or
                (Get-CSXPathValue $cpuRecord 'window.initialized') -isnot [bool] -or -not [bool](Get-CSXPathValue $cpuRecord 'window.initialized')) {
                throw "$assay CPU record does not preserve one stopped nonzero owned session."
            }
            $source["$assay.stressSessionId"] = $stressId
            $source["$assay.cpuSessionId"] = $cpuSessionId
        }
        if ([decimal]$source['menu.stressSessionId'] -le [decimal]$source['coc.stressSessionId'] -or
            [decimal]$source['menu.cpuSessionId'] -le [decimal]$source['coc.cpuSessionId']) {
            throw 'Menu diagnostic session IDs are not monotonic successors of the COC sessions.'
        }
        $traceFile = $source['menu.dlssTraces']
        if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $traceFile 'readLimit') $Protocol.menuAssay.traceReadLimit) -or
            [string](Get-CSXPropertyValue $traceFile 'detail') -ne 'bounded_partial_raw_records_with_authoritative_summary_and_pinned_failures' -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $traceFile 'evidence') (Get-CSXPathValue $Raw 'assays.menu.dlssTrace.evidence'))) {
            throw 'Menu DLSS trace artifact differs from run.raw or the canonical read contract.'
        }
    }
    catch { $errors.Add($_.Exception.Message) }

    foreach ($number in 1..2) {
        $name = if ($number -eq 1) { 'one' } else { 'two' }
        try {
            $relative = "recovery-$number.json"
            if ([string](Get-CSXPathValue $Raw "recoveries.$name.evidence") -ne $relative) { throw "Recovery $name evidence path is not canonical." }
            $recovery = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath $relative -Label "Recovery $name"
            $expectedRequest = New-CSXRecoveryScenario -Protocol $Protocol -ExpectedBuildId $buildId -RunId $runId -FsrRuntime $fsrRuntime -RecoveryLabel $name
            if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $recovery 'request') $expectedRequest) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $recovery 'requestedDurationMs') 30000) -or
                -not (Test-CSXNumberClose (Get-CSXPropertyValue $recovery 'wallClockMs') (Get-CSXPathValue $Raw "recoveries.$name.wallClockMs"))) {
                throw "Recovery $name request/duration/raw wall-clock identity is invalid."
            }
            $result = Get-CSXPropertyValue $recovery 'result'
            $steps = @($result.results)
            if ((Get-CSXPropertyValue $result 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $result 'ok') -or
                (Get-CSXPropertyValue $result 'aborted') -isnot [bool] -or [bool](Get-CSXPropertyValue $result 'aborted') -or
                $steps.Count -ne @($expectedRequest.steps).Count) { throw "Recovery $name result is incomplete, failed, or aborted." }
            for ($index = 0; $index -lt $steps.Count; $index++) {
                $isWaitStep = $null -ne (Get-CSXPropertyValue $expectedRequest.steps[$index] 'wait')
                if ([string](Get-CSXPropertyValue $steps[$index] 'label') -cne [string](Get-CSXPropertyValue $expectedRequest.steps[$index] 'label') -or
                    (Get-CSXPropertyValue $steps[$index] 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $steps[$index] 'ok') -or
                    (-not $isWaitStep -and $null -eq (Get-CSXPropertyValue $steps[$index] 'result'))) { throw "Recovery $name step $($index + 1) differs from its request." }
            }
            $evidence = Get-CSXPropertyValue $recovery 'evidence'
            $evidenceLabels = [ordered]@{
                scene = "$name-recovery-scene"; health = "$name-recovery-health"; qualification = "$name-recovery-qualification-status"
                trace = "$name-recovery-dlss-trace-status"; renderScale = "$name-recovery-renderscale-status"
                upscaling = "$name-recovery-upscaling-snapshot"; settings = "$name-recovery-feature-settings"; screenshot = "$name-recovery-screenshot-status"
            }
            foreach ($property in $evidenceLabels.Keys) {
                $match = @($steps | Where-Object { [string](Get-CSXPropertyValue $_ 'label') -ceq $evidenceLabels[$property] })
                if ($match.Count -ne 1 -or -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $evidence $property) (Get-CSXPropertyValue $match[0] 'result'))) {
                    throw "Recovery $name evidence projection '$property' differs from its scenario result."
                }
            }
            $wait = @($steps | Where-Object { [string](Get-CSXPropertyValue $_ 'label') -ceq "$name-recovery-30000ms" })
            if ($wait.Count -ne 1 -or -not (Test-CSXNumberEquals (Get-CSXPropertyValue $wait[0] 'ms') 30000) -or
                -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $evidence 'wait') $wait[0])) { throw "Recovery $name wait evidence differs from its exact barrier result." }
            if (-not [string]::Equals([string](Get-CSXPathValue $evidence 'scene.cell.editorId'), [string]$Protocol.fixture.startCellEditorId, [StringComparison]::OrdinalIgnoreCase) -or
                [bool](Get-CSXPathValue $evidence 'qualification.qualification.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'trace.capture.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'renderScale.status.session.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'renderScale.status.cpuPerformance.active' $true) -or
                [string](Get-CSXPathValue $evidence 'renderScale.producer.buildId') -ne $buildId) {
                throw "Recovery $name does not prove the exact exterior cell and inactive owned sessions."
            }
        }
        catch { $errors.Add($_.Exception.Message) }
    }

    try {
        $visualObservationPath = [string](Get-CSXPathValue $Raw 'assays.visual.fixtureObservationsPath')
        $visualObservationSha256 = [string](Get-CSXPathValue $Raw 'assays.visual.fixtureObservationsSha256')
        if ($visualObservationPath -ne 'visual/fixture-observations.json' -or -not (Test-CSXSha256Text $visualObservationSha256)) {
            throw 'Visual fixture-observation path/hash binding is missing or noncanonical.'
        }
        $visualObservationFullPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath $visualObservationPath
        if ((Get-CSXFileSha256 $visualObservationFullPath) -ne $visualObservationSha256) { throw 'Visual fixture-observation SHA-256 binding does not match.' }
        $visualObservationSet = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath $visualObservationPath -Label 'Visual fixture observations'
        $observations = @(Get-CSXPropertyValue $visualObservationSet 'observations' @())
        $expectedLabels = @('visual-before-1', 'visual-after-1', 'visual-after-2', 'visual-after-3')
        if ([string](Get-CSXPropertyValue $visualObservationSet 'schema') -ne 'csx-render-scale-visual-fixture-observations-v1' -or
            [string](Get-CSXPropertyValue $visualObservationSet 'runId') -ne $runId -or $observations.Count -ne 4 -or
            (@($observations | ForEach-Object { [string](Get-CSXPropertyValue $_ 'label') }) -join ',') -cne ($expectedLabels -join ',')) {
            throw 'Visual fixture observations do not preserve the exact schema/run/label order.'
        }
        $summary = @($observations | ForEach-Object { [pscustomobject][ordered]@{ label = [string]$_.label; ok = [bool]$_.result.ok } })
        if (-not (Test-CSXJsonIdentity $summary (Get-CSXPathValue $Raw 'assays.visual.fixtureObservations'))) {
            throw 'Visual fixture-observation summary differs from its immutable source evidence.'
        }
        $expectedTarget = Add-CSXExactRuntimeToProfile -Profile $Protocol.fixture.profiles.sharedExterior -FsrRuntime $fsrRuntime
        $expectedFoveation = Get-CSXFoveationTarget $Protocol
        foreach ($observation in $observations) {
            $label = [string](Get-CSXPropertyValue $observation 'label')
            $expectedRequest = New-CSXRecoveryScenario -Protocol $Protocol -ExpectedBuildId $buildId -RunId $runId -FsrRuntime $fsrRuntime -RecoveryLabel $label
            $expectedRequest.steps = @($expectedRequest.steps | Where-Object { -not $_.Contains('wait') })
            $request = Get-CSXPropertyValue $observation 'request'
            $result = Get-CSXPropertyValue $observation 'result'
            $evidence = Get-CSXPropertyValue $observation 'evidence'
            if (-not (Test-CSXJsonIdentity $request $expectedRequest) -or (Get-CSXPropertyValue $result 'ok') -isnot [bool] -or
                -not [bool](Get-CSXPropertyValue $result 'ok') -or [bool](Get-CSXPropertyValue $result 'aborted' $true) -or
                @(Get-CSXPropertyValue $result 'results' @()).Count -ne @($expectedRequest.steps).Count -or
                $null -ne (Get-CSXPropertyValue $evidence 'wait')) {
                throw "Visual fixture observation '$label' request/result contract is invalid."
            }
            $observationSteps = @(Get-CSXPropertyValue $result 'results' @())
            for ($index = 0; $index -lt $observationSteps.Count; $index++) {
                if ([string](Get-CSXPropertyValue $observationSteps[$index] 'label') -cne [string](Get-CSXPropertyValue $expectedRequest.steps[$index] 'label') -or
                    (Get-CSXPropertyValue $observationSteps[$index] 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $observationSteps[$index] 'ok') -or
                    $null -eq (Get-CSXPropertyValue $observationSteps[$index] 'result')) {
                    throw "Visual fixture observation '$label' step $($index + 1) differs from its request."
                }
            }
            $evidenceLabels = [ordered]@{
                scene = "$label-recovery-scene"; health = "$label-recovery-health"; qualification = "$label-recovery-qualification-status"
                trace = "$label-recovery-dlss-trace-status"; renderScale = "$label-recovery-renderscale-status"
                upscaling = "$label-recovery-upscaling-snapshot"; settings = "$label-recovery-feature-settings"; screenshot = "$label-recovery-screenshot-status"
            }
            foreach ($property in $evidenceLabels.Keys) {
                $match = @($result.results | Where-Object { [string](Get-CSXPropertyValue $_ 'label') -ceq $evidenceLabels[$property] })
                if ($match.Count -ne 1 -or -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $evidence $property) (Get-CSXPropertyValue $match[0] 'result'))) {
                    throw "Visual fixture observation '$label' evidence '$property' differs from its result."
                }
            }
            if (-not [string]::Equals([string](Get-CSXPathValue $evidence 'scene.cell.editorId'), [string]$Protocol.fixture.startCellEditorId, [StringComparison]::OrdinalIgnoreCase) -or
                [bool](Get-CSXPathValue $evidence 'qualification.qualification.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'trace.capture.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'renderScale.status.session.active' $true) -or
                [bool](Get-CSXPathValue $evidence 'renderScale.status.cpuPerformance.active' $true) -or
                [string](Get-CSXPathValue $evidence 'renderScale.producer.buildId') -ne $buildId) {
                throw "Visual fixture observation '$label' does not prove exact exterior/inactive state."
            }
            foreach ($profileName in @('requested', 'effective', 'stable')) {
                $profile = Get-CSXPathValue $evidence "upscaling.snapshot.profiles.$profileName"
                $method = Get-CSXPropertyValue $profile 'method'; if ($method -isnot [string]) { $method = Get-CSXPropertyValue $method 'name' }
                $quality = Get-CSXPropertyValue $profile 'qualityMode'; if ($quality -isnot [string]) { $quality = Get-CSXPropertyValue $quality 'name' }
                $runtime = Get-CSXPropertyValue $profile 'fsrRuntime'; if ($runtime -isnot [string]) { $runtime = Get-CSXPropertyValue $runtime 'name' }
                if (([string]$method).ToLowerInvariant() -ne 'fsr' -or ([string]$quality).ToLowerInvariant() -ne 'hoshipa' -or
                    -not [bool](Get-CSXPropertyValue $profile 'renderScaleMode') -or ([string]$runtime).ToLowerInvariant() -ne $fsrRuntime) {
                    throw "Visual fixture observation '$label' upscaling profile '$profileName' is not exact exterior FSR Hoshipa."
                }
            }
            $settings = Get-CSXPathValue $evidence 'settings.result.settings'
            $settingsMapping = [ordered]@{
                foveatedVendorDispatch = @('foveatedVendorDispatch'); foveatedCenterArea = @('foveatedCenterArea')
                peripheryTAAEnable = @('periphery_taa_enable', 'peripheryTAAEnable')
                peripheryTAACenterArea = @('periphery_taa_center_area', 'peripheryTAACenterArea')
                peripheryTAAOuterScale = @('periphery_taa_outer_scale', 'peripheryTAAOuterScale')
            }
            foreach ($field in $settingsMapping.Keys) {
                $actual = $null
                foreach ($sourceName in $settingsMapping[$field]) { $candidate = Get-CSXPropertyValue $settings $sourceName; if ($null -ne $candidate) { $actual = $candidate; break } }
                $wanted = Get-CSXPropertyValue $expectedFoveation $field
                if ($null -eq $actual -or ($wanted -is [bool] -and [bool]$actual -ne [bool]$wanted) -or
                    ($wanted -isnot [bool] -and [Math]::Abs([double]$actual - [double]$wanted) -gt 0.0001)) {
                    throw "Visual fixture observation '$label' setting '$field' differs from the protocol fixture."
                }
            }
        }
        $source['visual.fixtureObservations'] = $observations
    }
    catch { $errors.Add($_.Exception.Message) }

    try {
        $transcript = @(Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath 'mcp-transcript.json' -Label 'MCP transcript')
        if ($transcript.Count -eq 0 -or @($transcript | Where-Object { (Get-CSXPropertyValue $_ 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $_ 'ok') -or $null -ne (Get-CSXPropertyValue $_ 'error') }).Count -ne 0) {
            throw 'MCP transcript is empty or contains a failed/uncertain call in a passing run.'
        }
        foreach ($row in $transcript) {
            $started = [DateTimeOffset]::MinValue; $completed = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $row 'startedUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started) -or
                -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $row 'completedUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completed) -or $completed -lt $started) {
                throw 'MCP transcript contains an invalid call interval.'
            }
            if ([string](Get-CSXPropertyValue $row 'tool') -eq 'communityshaders.renderscale' -and
                [string](Get-CSXPathValue $row 'response.producer.buildId') -ne $buildId) { throw 'MCP transcript contains a render-scale response from another build.' }
        }
        $requiredReceipts = [Collections.Generic.List[object]]::new()
        $requiredReceipts.Add([pscustomobject]@{
            tool = 'inspect'; arguments = [ordered]@{ kind = 'health' }; exactArguments = $true
            response = $source['runtime.health']; responseMode = 'exact'; label = 'runtime-health-binding'
        })
        foreach ($assay in @('coc', 'menu')) {
            foreach ($diagnostic in @(
                [pscustomobject]@{ action = 'reset'; mode = 'diagnostic_reset'; label = "$assay/stress-reset" },
                [pscustomobject]@{ action = 'cpu_performance_reset'; mode = 'diagnostic_reset'; label = "$assay/cpu-reset" },
                [pscustomobject]@{ action = 'start'; mode = 'stress_start'; label = "$assay/stress-start" },
                [pscustomobject]@{ action = 'cpu_performance_start'; mode = 'cpu_start'; label = "$assay/cpu-start" }
            )) {
                $requiredReceipts.Add([pscustomobject]@{
                    tool = 'communityshaders.renderscale'
                    arguments = [ordered]@{ action = $diagnostic.action; expectedBuildId = $buildId }
                    exactArguments = $true; response = $null; responseMode = $diagnostic.mode
                    assay = $assay; label = $diagnostic.label
                })
            }
            foreach ($step in @($source["$assay.scenarioResult"].results)) {
                $requestStep = @($source["$assay.scenarioRequest"].steps | Where-Object { [string]$_.label -ceq [string]$step.label })[0]
                $expectedArguments = $requestStep.args | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -AsHashtable
                if ([string](Get-CSXPropertyValue $expectedArguments 'action') -eq 'dlss_trace_stop') {
                    $expectedArguments['expectedSessionId'] = Get-CSXPathValue $step.result 'capture.sessionID'
                }
                $requiredReceipts.Add([pscustomobject]@{ tool = [string]$requestStep.tool; arguments = $expectedArguments; exactArguments = $true; response = $step.result; responseMode = 'exact'; label = "$assay/$($step.label)" })
            }
            foreach ($kind in @('cpu', 'stress')) {
                $action = if ($kind -eq 'cpu') { 'cpu_performance_stop' } else { 'stop' }
                $expectedId = $source["$assay.$($kind)SessionId"]
                $requiredReceipts.Add([pscustomobject]@{
                    tool = 'communityshaders.renderscale'; arguments = [ordered]@{ action = $action; expectedSessionId = $expectedId; expectedBuildId = $buildId }
                    exactArguments = $true; response = Get-CSXPropertyValue $source["$assay.diagnostics"] $kind; responseMode = 'exact'; label = "$assay/$kind-stop"
                })
            }
            $number = if ($assay -eq 'coc') { 1 } else { 2 }
            $recovery = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath "recovery-$number.json" -Label "Recovery transcript $number"
            $requiredReceipts.Add([pscustomobject]@{ tool = 'scenario'; arguments = $recovery.request; exactArguments = $true; response = $recovery.result; responseMode = 'exact'; label = "recovery-$number" })
        }

        $observations = @($source['visual.fixtureObservations'])
        $beforeObservation = @($observations | Where-Object { [string]$_.label -ceq 'visual-before-1' })[0]
        $requiredReceipts.Add([pscustomobject]@{
            tool = 'scenario'; arguments = $beforeObservation.request; exactArguments = $true
            response = $beforeObservation.result; responseMode = 'exact'; label = 'visual-before-1'
        })
        $visualRuns = @(Get-CSXPathValue $Raw 'assays.visual.runs' @() | Sort-Object replicate)
        foreach ($run in $visualRuns) {
            $request = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath ([string]$run.sequenceRequestPath) -Label 'Visual sequence-start request'
            $terminal = Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath ([string]$run.terminalReceiptPath) -Label 'Visual terminal transcript receipt'
            $requiredReceipts.Add([pscustomobject]@{
                tool = 'communityshaders.screenshot'; arguments = $request; exactArguments = $true
                response = $null; responseMode = 'sequence_start'; request = $request; terminal = $terminal
                label = "visual-$($run.replicate)-start"
            })
            $requiredReceipts.Add([pscustomobject]@{
                tool = 'communityshaders.screenshot'; arguments = [ordered]@{
                    contractMajor = 1; clientId = 'csx-render-scale-qualification'; action = 'request_get'
                    requestId = [string](Get-CSXPathValue $terminal 'result.requestId')
                }
                exactArguments = $false; response = $terminal; responseMode = 'terminal_poll'
                replicate = [int]$run.replicate; label = "visual-$($run.replicate)-terminal"
            })
            $afterLabel = "visual-after-$([int]$run.replicate)"
            $afterObservation = @($observations | Where-Object { [string]$_.label -ceq $afterLabel })[0]
            $requiredReceipts.Add([pscustomobject]@{
                tool = 'scenario'; arguments = $afterObservation.request; exactArguments = $true
                response = $afterObservation.result; responseMode = 'exact'; label = $afterLabel
            })
        }
        foreach ($run in $visualRuns) {
            foreach ($child in @((Read-CSXProducerJson -EvidenceRoot $EvidenceRoot -RelativePath ([string]$run.childReceiptsPath) -Label 'Visual child transcript receipts'))) {
                $requiredReceipts.Add([pscustomobject]@{
                    tool = 'communityshaders.screenshot'; arguments = [ordered]@{
                        contractMajor = 1; clientId = 'csx-render-scale-qualification'
                        commandId = "$runId-visual-$($run.replicate)-child-$($child.ordinal)"
                        action = 'request_get'; requestId = [string](Get-CSXPathValue $child 'receipt.result.requestId')
                    }
                    exactArguments = $true; response = $child.receipt; responseMode = 'exact'; label = "visual-$($run.replicate)-child-$($child.ordinal)"
                })
            }
        }
        $nextTranscriptIndex = 0
        foreach ($required in $requiredReceipts) {
            $matchedIndex = -1
            for ($index = $nextTranscriptIndex; $index -lt $transcript.Count; $index++) {
                $row = $transcript[$index]
                if ([string](Get-CSXPropertyValue $row 'tool') -cne $required.tool) { continue }
                $actualArguments = Get-CSXPropertyValue $row 'arguments'
                $argumentsMatch = if ([bool]$required.exactArguments) {
                    Test-CSXJsonIdentity $actualArguments $required.arguments
                }
                else {
                    $matched = $true
                    foreach ($property in @($required.arguments.Keys)) {
                        if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $actualArguments $property) $required.arguments[$property])) { $matched = $false; break }
                    }
                    $matched
                }
                if (-not $argumentsMatch) { continue }
                if ([string]$required.responseMode -eq 'exact' -or [string]$required.responseMode -eq 'terminal_poll') {
                    if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'response') $required.response)) { continue }
                }
                $matchedIndex = $index
                break
            }
            if ($matchedIndex -lt 0) { throw "MCP transcript does not contain the required ordered request/receipt binding for $($required.label)." }
            $matchedRow = $transcript[$matchedIndex]
            $matchedResponse = Get-CSXPropertyValue $matchedRow 'response'
            switch ([string]$required.responseMode) {
                'stress_start' {
                    if ([string](Get-CSXPropertyValue $matchedResponse 'action') -ne 'start' -or
                        -not [bool](Get-CSXPathValue $matchedResponse 'status.session.active' $false) -or
                        -not (Test-CSXNumberEquals (Get-CSXPathValue $matchedResponse 'status.session.id') $source["$($required.assay).stressSessionId"])) {
                        throw "$($required.label) transcript receipt did not establish the exact owned stress session."
                    }
                }
                'cpu_start' {
                    if ([string](Get-CSXPropertyValue $matchedResponse 'action') -ne 'cpu_performance_start' -or
                        -not [bool](Get-CSXPathValue $matchedResponse 'cpuPerformance.active' $false) -or
                        -not (Test-CSXNumberEquals (Get-CSXPathValue $matchedResponse 'cpuPerformance.sessionId') $source["$($required.assay).cpuSessionId"])) {
                        throw "$($required.label) transcript receipt did not establish the exact owned CPU session."
                    }
                }
                'sequence_start' {
                    $startResult = Get-CSXPropertyValue $matchedResponse 'result'
                    $terminalResult = Get-CSXPropertyValue $required.terminal 'result'
                    if ((Get-CSXPropertyValue $matchedResponse 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $matchedResponse 'ok') -or
                        $null -ne (Get-CSXPropertyValue $matchedResponse 'error') -or [string](Get-CSXPropertyValue $startResult 'state') -ne 'running' -or
                        [string](Get-CSXPropertyValue $startResult 'kind') -ne 'sequence' -or
                        [string](Get-CSXPropertyValue $startResult 'requestId') -ne [string](Get-CSXPropertyValue $terminalResult 'requestId') -or
                        [string](Get-CSXPropertyValue $startResult 'clientId') -ne 'csx-render-scale-qualification' -or
                        [string](Get-CSXPropertyValue $startResult 'commandId') -ne [string](Get-CSXPropertyValue $terminalResult 'commandId') -or
                        [string](Get-CSXPropertyValue $startResult 'acceptedUtc') -ne [string](Get-CSXPropertyValue $terminalResult 'acceptedUtc') -or
                        -not (Test-CSXJsonSemanticIdentity (Get-CSXPropertyValue $startResult 'effective') (Get-CSXPropertyValue $required.request 'sequence')) -or
                        [string](Get-CSXPathValue $matchedResponse 'server.sessionId') -ne [string](Get-CSXPathValue $required.terminal 'server.sessionId')) {
                        throw "$($required.label) transcript receipt did not establish the exact terminal sequence identity."
                    }
                }
                'terminal_poll' {
                    $pollCommandId = [string](Get-CSXPathValue $matchedRow 'arguments.commandId')
                    if ($pollCommandId -notmatch "^$([regex]::Escape($runId))-visual-$($required.replicate.ToString('D2'))-poll-[a-f0-9]{32}$") {
                        throw "$($required.label) transcript poll command identity is invalid."
                    }
                }
            }
            $nextTranscriptIndex = $matchedIndex + 1
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors | Select-Object -Unique) }
}

function Get-CSXAutomatedVisualCategoryNames {
    return @('sharpness', 'blur', 'shimmer', 'stereoAlignment', 'equalEyeScale', 'geometryCorrespondence')
}

function Get-CSXVisualSampleForReplicateOrdinal {
    param([Parameter(Mandatory)]$VisualIndex, [Parameter(Mandatory)][int]$Replicate, [Parameter(Mandatory)][int]$Ordinal)
    $matches = @($VisualIndex.samples | Where-Object {
        [int](Get-CSXPropertyValue $_ 'replicate' 0) -eq $Replicate -and
        [int](Get-CSXPropertyValue $_ 'ordinal' 0) -eq $Ordinal
    })
    if ($matches.Count -ne 1) { throw "Visual index does not contain exactly one sample for replicate $Replicate, ordinal $Ordinal." }
    return $matches[0]
}

function Assert-CSXExactObjectProperties {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    $actualNames = @(Get-CSXPropertyNames $Value | Sort-Object -CaseSensitive)
    $expectedNames = @($Expected | Sort-Object -CaseSensitive)
    if (($actualNames -join ',') -cne ($expectedNames -join ',')) {
        throw "$Label properties are not the exact closed contract."
    }
}

function Test-CSXArrayProperty {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -is [Collections.IDictionary]) {
        if (-not $Value.Contains($Name)) { return $false }
        $propertyValue = $Value[$Name]
    }
    else {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -eq $property) { return $false }
        $propertyValue = $property.Value
    }
    return $propertyValue -is [Collections.IEnumerable] -and $propertyValue -isnot [string] -and
        $propertyValue -isnot [Collections.IDictionary] -and $propertyValue -isnot [pscustomobject]
}

function Read-CSXHashBoundVisualFile {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, string]]$Paths
    )
    if (-not (Test-CSXSha256Text $ExpectedSha256)) { throw "$Label SHA-256 is missing or invalid." }
    $path = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath $RelativePath
    Add-CSXUniqueVisualEvidencePath -Paths $Paths -Path $path -Label $Label
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label is missing: $RelativePath" }
    $sha256 = Get-CSXFileSha256 $path
    if (-not [string]::Equals($sha256, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label SHA-256 binding does not match."
    }
    return [pscustomobject][ordered]@{ path = $path; sha256 = $sha256 }
}

function Read-CSXAutomatedReviewJson {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[string, string]]$Paths
    )
    return Read-CSXHashBoundVisualJson -EvidenceRoot $EvidenceDirectory -RelativePath $RelativePath `
        -ExpectedSha256 $ExpectedSha256 -Label $Label -Paths $Paths
}

function New-CSXAutomatedVisualPromptText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PromptSourceText,
        [Parameter(Mandatory)]$RequestArtifact
    )
    if ([string](Get-CSXPropertyValue $RequestArtifact 'schema') -ne 'csx-render-scale-image-model-request-v1') {
        throw 'Automated visual prompt request schema is invalid.'
    }
    $body = Get-CSXPropertyValue $RequestArtifact 'body'
    $requestSha256 = [string](Get-CSXPropertyValue $RequestArtifact 'requestSha256')
    if (-not (Test-CSXSha256Text $requestSha256) -or (Get-CSXObjectSha256 -Value $body) -ne $requestSha256.ToLowerInvariant()) {
        throw 'Automated visual prompt request body hash is invalid.'
    }
    $bodyJson = $body | ConvertTo-Json -Depth 100 -Compress
    return $PromptSourceText + "`n`n# Bound request`nRequest SHA-256: $requestSha256`nRequest body: $bodyJson`n"
}

function Test-CSXAutomatedVisualTelemetry {
    param([Parameter(Mandatory)][string]$EvidenceDirectory, [Parameter(Mandatory)]$RunRaw)
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $runId = [string](Get-CSXPropertyValue $RunRaw 'runId')
        $buildId = [string](Get-CSXPathValue $RunRaw 'runtime.buildId')
        $relative = [string](Get-CSXPathValue $RunRaw 'assays.visual.fixtureObservationsPath')
        $expectedSha256 = [string](Get-CSXPathValue $RunRaw 'assays.visual.fixtureObservationsSha256')
        if ($relative -cne 'visual/fixture-observations.json' -or -not (Test-CSXSha256Text $expectedSha256)) {
            throw 'Automated render-scale latch evidence does not bind the canonical visual fixture-observation file.'
        }
        $path = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath $relative
        if ((Get-CSXFileSha256 $path) -cne $expectedSha256.ToLowerInvariant()) {
            throw 'Automated render-scale latch fixture-observation SHA-256 binding does not match.'
        }
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
        $observations = @(Get-CSXPropertyValue $record 'observations' @())
        $labels = @('visual-before-1', 'visual-after-1', 'visual-after-2', 'visual-after-3')
        if ([string](Get-CSXPropertyValue $record 'schema') -ne 'csx-render-scale-visual-fixture-observations-v1' -or
            [string](Get-CSXPropertyValue $record 'runId') -ne $runId -or
            $observations.Count -ne 4 -or (@($observations | ForEach-Object { [string](Get-CSXPropertyValue $_ 'label') }) -join ',') -cne ($labels -join ',')) {
            throw 'Automated render-scale latch fixture observations do not preserve the exact schema, run, and label order.'
        }
        $summary = @($observations | ForEach-Object {
            [pscustomobject][ordered]@{ label = [string](Get-CSXPropertyValue $_ 'label'); ok = [bool](Get-CSXPathValue $_ 'result.ok' $false) }
        })
        if (-not (Test-CSXJsonIdentity $summary (Get-CSXPathValue $RunRaw 'assays.visual.fixtureObservations')) -or
            @($summary | Where-Object { -not $_.ok }).Count -ne 0) {
            throw 'Automated render-scale latch fixture-observation summary is not an exact four-point pass.'
        }

        $visualEvidence = Get-CSXPathValue $RunRaw 'assays.visual.evidence'
        Assert-CSXExactObjectProperties -Value $visualEvidence -Expected @('diagnostics', 'stressRecord', 'cpuRecord') `
            -Label 'Automated render-scale latch evidence'
        $expectedPaths = [ordered]@{
            diagnostics = 'visual/diagnostics.json'
            stressRecord = 'visual/stress-record.json'
            cpuRecord = 'visual/cpu-record.json'
        }
        foreach ($name in $expectedPaths.Keys) {
            if ([string](Get-CSXPropertyValue $visualEvidence $name) -cne $expectedPaths[$name]) {
                throw "Automated render-scale latch evidence path '$name' is not canonical."
            }
        }
        $diagnostics = Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath $expectedPaths.diagnostics -Label 'Visual diagnostics'
        $stressRecord = Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath $expectedPaths.stressRecord -Label 'Visual stress record'
        $cpuRecord = Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath $expectedPaths.cpuRecord -Label 'Visual CPU record'
        $stressResponse = Get-CSXPropertyValue $diagnostics 'stress'
        $cpuResponse = Get-CSXPropertyValue $diagnostics 'cpu'
        if (-not (Test-CSXJsonIdentity (Get-CSXPathValue $stressResponse 'status.lastRecord') $stressRecord) -or
            -not (Test-CSXJsonIdentity (Get-CSXPathValue $cpuResponse 'cpuPerformance.lastRecord') $cpuRecord)) {
            throw 'Visual diagnostic stops do not contain the exact immutable stress and CPU records.'
        }
        if ([string](Get-CSXPropertyValue $stressResponse 'action') -ne 'stop' -or
            [string](Get-CSXPropertyValue $cpuResponse 'action') -ne 'cpu_performance_stop' -or
            -not [string]::Equals([string](Get-CSXPathValue $stressResponse 'producer.buildId'), $buildId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string](Get-CSXPathValue $cpuResponse 'producer.buildId'), $buildId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Visual diagnostic stop producer/action identity is invalid.'
        }
        $protocol = (Get-CSXQualificationProtocol -Path (Join-Path $EvidenceDirectory 'protocol.json')).protocol
        $stressSessionId = Get-CSXPathValue $stressResponse 'status.session.id'
        $cpuSessionId = Get-CSXPathValue $cpuResponse 'cpuPerformance.sessionId'
        if (-not (Test-CSXNumberEquals $stressSessionId (Get-CSXPathValue $stressRecord 'session.id')) -or
            [decimal]$stressSessionId -le 0 -or [bool](Get-CSXPathValue $stressResponse 'status.session.active' $true) -or
            [bool](Get-CSXPathValue $stressRecord 'session.active' $true) -or
            [string](Get-CSXPropertyValue $stressRecord 'schema') -ne 'community-shaders.vr-render-scale.iteration' -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $stressRecord 'schemaVersion') $protocol.thresholds.stressRecordSchemaVersion) -or
            (Get-CSXPathValue $stressRecord 'acceptance.accepted') -isnot [bool] -or
            -not [bool](Get-CSXPathValue $stressRecord 'acceptance.accepted') -or
            (Get-CSXPathValue $stressRecord 'verdict.accepted') -isnot [bool] -or
            -not [bool](Get-CSXPathValue $stressRecord 'verdict.accepted') -or
            -not (Test-CSXNumberEquals (Get-CSXPathValue $stressRecord 'session.coalescedDuplicateCount') 0) -or
            -not (Test-CSXNumberEquals (Get-CSXPathValue $stressRecord 'session.overwrittenEvents') 0)) {
            throw 'Visual stress record is not one clean, accepted, inactive task-owned session.'
        }
        foreach ($gateSet in @('acceptance.gates', 'verdict.gates')) {
            $gates = @(Get-CSXPathValue $stressRecord $gateSet @())
            if ($gates.Count -eq 0 -or @($gates | Where-Object {
                    (Get-CSXPropertyValue $_ 'passed') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $_ 'passed')
                }).Count -ne 0) {
                throw "Visual stress record $gateSet does not contain an explicit all-pass gate set."
            }
        }
        if (-not (Test-CSXNumberEquals $cpuSessionId (Get-CSXPropertyValue $cpuRecord 'sessionId')) -or
            [decimal]$cpuSessionId -le 0 -or [bool](Get-CSXPathValue $cpuResponse 'cpuPerformance.active' $true) -or
            [string](Get-CSXPathValue $cpuResponse 'cpuPerformance.state') -ne 'stopped' -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cpuRecord 'schemaVersion') 1) -or
            [bool](Get-CSXPropertyValue $cpuRecord 'active' $true) -or [string](Get-CSXPropertyValue $cpuRecord 'state') -ne 'stopped' -or
            (Get-CSXPathValue $cpuRecord 'window.initialized') -isnot [bool] -or -not [bool](Get-CSXPathValue $cpuRecord 'window.initialized')) {
            throw 'Visual CPU record is not one initialized, stopped, inactive task-owned session.'
        }
        $stressStartFrame = Get-CSXPathValue $stressRecord 'session.startFrame'
        $stressEndFrame = Get-CSXPathValue $stressRecord 'session.endFrame'
        $cpuStartFrame = Get-CSXPathValue $cpuRecord 'window.startFrame'
        $cpuEndFrame = Get-CSXPathValue $cpuRecord 'window.endFrame'
        foreach ($frame in @($stressStartFrame, $stressEndFrame, $cpuStartFrame, $cpuEndFrame)) {
            if (-not (Test-CSXFiniteNonNegativeNumber $frame) -or [double]$frame -ne [Math]::Truncate([double]$frame)) {
                throw 'Visual diagnostic records omit the required finite frame-window proof.'
            }
        }
        if ([decimal]$stressEndFrame -lt [decimal]$stressStartFrame -or [decimal]$cpuEndFrame -lt [decimal]$cpuStartFrame -or
            [decimal]$cpuStartFrame -gt [decimal]$stressStartFrame -or [decimal]$cpuEndFrame -lt [decimal]$stressEndFrame) {
            throw 'Visual CPU/stress frame windows do not prove enclosure of the diagnostic session.'
        }

        $runs = @(Get-CSXPathValue $RunRaw 'assays.visual.runs' @() | Sort-Object replicate)
        if ($runs.Count -ne 3 -or (@($runs | ForEach-Object { [int](Get-CSXPropertyValue $_ 'replicate') }) -join ',') -ne '1,2,3') {
            throw 'Visual diagnostic enclosure requires the exact three ordered capture replicates.'
        }
        $captureIntervals = [Collections.Generic.List[object]]::new()
        foreach ($run in $runs) {
            $terminal = Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath ([string](Get-CSXPropertyValue $run 'terminalReceiptPath')) `
                -Label "Visual replicate $($run.replicate) terminal receipt"
            $accepted = [DateTimeOffset]::MinValue
            $completed = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string](Get-CSXPathValue $terminal 'result.acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$accepted) -or
                -not [DateTimeOffset]::TryParse([string](Get-CSXPathValue $terminal 'result.terminalUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completed) -or $completed -lt $accepted) {
                throw "Visual replicate $($run.replicate) omits the required accepted/terminal UTC enclosure proof."
            }
            $captureIntervals.Add([pscustomobject][ordered]@{ acceptedUtc = $accepted; terminalUtc = $completed })
        }
        for ($index = 1; $index -lt $captureIntervals.Count; $index++) {
            if ($captureIntervals[$index].acceptedUtc -lt $captureIntervals[$index - 1].terminalUtc) {
                throw 'Visual capture intervals overlap or are out of order.'
            }
        }

        $transcript = @(Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath 'mcp-transcript.json' -Label 'MCP transcript')
        $matches = [ordered]@{
            stressStart = [Collections.Generic.List[object]]::new()
            cpuStart = [Collections.Generic.List[object]]::new()
            cpuStop = [Collections.Generic.List[object]]::new()
            stressStop = [Collections.Generic.List[object]]::new()
            firstObservation = [Collections.Generic.List[object]]::new()
            lastObservation = [Collections.Generic.List[object]]::new()
        }
        for ($index = 0; $index -lt $transcript.Count; $index++) {
            $row = $transcript[$index]
            $tool = [string](Get-CSXPropertyValue $row 'tool')
            $action = [string](Get-CSXPathValue $row 'arguments.action')
            $candidate = [pscustomobject][ordered]@{ index = $index; row = $row }
            if ($tool -eq 'communityshaders.renderscale' -and $action -eq 'start' -and
                (Test-CSXNumberEquals (Get-CSXPathValue $row 'response.status.session.id') $stressSessionId) -and
                [string](Get-CSXPathValue $row 'response.producer.buildId') -eq $buildId) { $matches.stressStart.Add($candidate) }
            if ($tool -eq 'communityshaders.renderscale' -and $action -eq 'cpu_performance_start' -and
                (Test-CSXNumberEquals (Get-CSXPathValue $row 'response.cpuPerformance.sessionId') $cpuSessionId) -and
                [string](Get-CSXPathValue $row 'response.producer.buildId') -eq $buildId) { $matches.cpuStart.Add($candidate) }
            if ($tool -eq 'communityshaders.renderscale' -and $action -eq 'cpu_performance_stop' -and
                (Test-CSXNumberEquals (Get-CSXPathValue $row 'arguments.expectedSessionId') $cpuSessionId)) { $matches.cpuStop.Add($candidate) }
            if ($tool -eq 'communityshaders.renderscale' -and $action -eq 'stop' -and
                (Test-CSXNumberEquals (Get-CSXPathValue $row 'arguments.expectedSessionId') $stressSessionId)) { $matches.stressStop.Add($candidate) }
            if ($tool -eq 'scenario' -and (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'arguments') $observations[0].request) -and
                (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'response') $observations[0].result)) { $matches.firstObservation.Add($candidate) }
            if ($tool -eq 'scenario' -and (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'arguments') $observations[3].request) -and
                (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'response') $observations[3].result)) { $matches.lastObservation.Add($candidate) }
        }
        foreach ($name in $matches.Keys) {
            if ($matches[$name].Count -ne 1) { throw "Visual diagnostic transcript does not contain exactly one $name binding." }
        }
        $stressStart = $matches.stressStart[0]
        $cpuStart = $matches.cpuStart[0]
        $cpuStop = $matches.cpuStop[0]
        $stressStop = $matches.stressStop[0]
        $firstObservation = $matches.firstObservation[0]
        $lastObservation = $matches.lastObservation[0]
        if (-not ($stressStart.index -lt $cpuStart.index -and $cpuStart.index -lt $firstObservation.index -and
                $firstObservation.index -lt $lastObservation.index -and $lastObservation.index -lt $cpuStop.index -and
                $cpuStop.index -lt $stressStop.index)) {
            throw 'Visual diagnostic transcript does not surround the complete fixture/capture interval in task-owned order.'
        }
        if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $cpuStop.row 'response') $cpuResponse) -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $stressStop.row 'response') $stressResponse) -or
            [string](Get-CSXPathValue $stressStart.row 'arguments.expectedBuildId') -ne $buildId -or
            [string](Get-CSXPathValue $cpuStart.row 'arguments.expectedBuildId') -ne $buildId -or
            [string](Get-CSXPathValue $cpuStop.row 'arguments.expectedBuildId') -ne $buildId -or
            [string](Get-CSXPathValue $stressStop.row 'arguments.expectedBuildId') -ne $buildId) {
            throw 'Visual diagnostic transcript does not preserve exact owned start/stop request and response bindings.'
        }
        $stressStarted = [DateTimeOffset]::MinValue
        $cpuStarted = [DateTimeOffset]::MinValue
        $cpuStopped = [DateTimeOffset]::MinValue
        $stressStopped = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $stressStart.row 'completedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$stressStarted) -or
            -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $cpuStart.row 'completedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$cpuStarted) -or
            -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $cpuStop.row 'startedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$cpuStopped) -or
            -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $stressStop.row 'startedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$stressStopped)) {
            throw 'Visual diagnostic transcript omits required UTC interval proof.'
        }
        if ($stressStarted -gt $captureIntervals[0].acceptedUtc -or $cpuStarted -gt $captureIntervals[0].acceptedUtc -or
            $cpuStopped -lt $captureIntervals[-1].terminalUtc -or $stressStopped -lt $captureIntervals[-1].terminalUtc) {
            throw 'Visual diagnostic UTC interval does not enclose all three capture replicates.'
        }

        $producer = Test-CSXProducerArtifactEvidence -EvidenceRoot $EvidenceDirectory -Raw $RunRaw -Protocol $protocol
        if (-not $producer.ok) { throw "Automated render-scale latch telemetry is not fully validated: $($producer.errors -join ' ')" }
    }
    catch { $errors.Add($_.Exception.Message) }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors | Select-Object -Unique) }
}

function Test-CSXAutomatedVisualReviewEvidence {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        $BaselineVisualIndex = $null
    )
    $integrityErrors = [Collections.Generic.List[string]]::new()
    $qualityErrors = [Collections.Generic.List[string]]::new()
    $projected = [Collections.Generic.List[object]]::new()
    $paths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourceFiles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $runId = [string](Get-CSXPropertyValue $RunRaw 'runId')
    $prMode = [bool](Get-CSXPropertyValue $RunRaw 'prMode' $false)
    $mode = if ($prMode) { 'pr_baseline' } else { 'standalone' }
    $automated = Get-CSXPathValue $RunRaw 'assays.visual.automatedReview'
    $latestCompletedUtc = [DateTimeOffset]::MinValue
    try {
        if ([int](Get-CSXPathValue $RunRaw 'protocol.revision' 0) -ne 4) {
            throw 'Automated visual review evidence requires protocol revision 4.'
        }
        if ($runId -notmatch '^rsq-[A-Za-z0-9_-]{8,80}$') {
            throw 'Automated visual review run identity is outside the response-schema contract.'
        }
        $protocol = (Get-CSXQualificationProtocol -Path (Join-Path $EvidenceDirectory 'protocol.json')).protocol
        $evaluation = $protocol.visualAssay.evaluation
        Assert-CSXVisualIndexSet -VisualIndex $VisualIndex -Label 'Candidate' -ExpectedRunId $runId
        $baselineRoot = $null
        $baselinePrefix = $null
        if ($prMode) {
            if ($null -eq $BaselineVisualIndex) { throw 'Automated PR visual review requires the bundled baseline visual index.' }
            Assert-CSXVisualIndexSet -VisualIndex $BaselineVisualIndex -Label 'Baseline' `
                -ExpectedRunId ([string](Get-CSXPathValue $RunRaw 'baseline.baselineRunId'))
            $baselineRunPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory `
                -RelativePath ([string](Get-CSXPathValue $RunRaw 'baseline.path'))
            $baselineRoot = Split-Path -Parent $baselineRunPath
            $baselinePrefix = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($EvidenceDirectory), $baselineRoot).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($baselinePrefix) -or $baselinePrefix.StartsWith('../') -or $baselinePrefix -eq '..') {
                throw 'Automated PR visual review baseline root is not contained by the candidate evidence root.'
            }
        }

        Assert-CSXExactObjectProperties -Value $automated -Expected @(
            'schema', 'provider', 'model', 'promptRevision', 'promptPath', 'promptSourceSha256',
            'outputSchemaPath', 'outputSchemaSourceSha256', 'preflightPath', 'preflightSha256',
            'executionPath', 'executionSha256', 'deadlineSeconds', 'durationMs', 'batches'
        ) -Label 'Automated visual-review envelope'
        if ([string](Get-CSXPropertyValue $automated 'schema') -ne 'csx-render-scale-automated-review-v1' -or
            [string](Get-CSXPropertyValue $automated 'provider') -ne [string]$evaluation.provider -or
            [string](Get-CSXPropertyValue $automated 'model') -ne [string]$evaluation.model -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $automated 'promptRevision') $evaluation.promptRevision) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $automated 'deadlineSeconds') ([double]$evaluation.timeoutMs / 1000.0)) -or
            -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $automated 'durationMs')) -or
            [double](Get-CSXPropertyValue $automated 'durationMs') -gt [double]$evaluation.timeoutMs) {
            throw 'Automated visual-review envelope identity, deadline, or duration is invalid.'
        }
        if ([string](Get-CSXPropertyValue $automated 'promptPath') -cne 'visual-review/prompt.v1.md' -or
            [string](Get-CSXPropertyValue $automated 'promptSourceSha256') -cne [string]$evaluation.promptSha256 -or
            [string](Get-CSXPropertyValue $automated 'outputSchemaPath') -cne 'visual-review/output-schema.v1.json' -or
            [string](Get-CSXPropertyValue $automated 'outputSchemaSourceSha256') -cne [string]$evaluation.outputSchemaSha256 -or
            [string](Get-CSXPropertyValue $automated 'preflightPath') -cne 'visual-review/preflight.json' -or
            [string](Get-CSXPropertyValue $automated 'executionPath') -cne 'visual-review/execution.json') {
            throw 'Automated visual-review source/preflight/execution paths or source hashes are not canonical.'
        }
        $promptRecord = Read-CSXHashBoundVisualFile -EvidenceDirectory $EvidenceDirectory `
            -RelativePath ([string]$automated.promptPath) -ExpectedSha256 ([string]$automated.promptSourceSha256) `
            -Label 'Automated visual-review prompt source' -Paths $paths
        $schemaRecord = Read-CSXHashBoundVisualFile -EvidenceDirectory $EvidenceDirectory `
            -RelativePath ([string]$automated.outputSchemaPath) -ExpectedSha256 ([string]$automated.outputSchemaSourceSha256) `
            -Label 'Automated visual-review output schema source' -Paths $paths
        $preflightRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
            -RelativePath ([string]$automated.preflightPath) -ExpectedSha256 ([string]$automated.preflightSha256) `
            -Label 'Automated visual-review provider preflight' -Paths $paths
        $executionRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
            -RelativePath ([string]$automated.executionPath) -ExpectedSha256 ([string]$automated.executionSha256) `
            -Label 'Automated visual-review provider execution' -Paths $paths
        $preflight = $preflightRecord.value
        $execution = $executionRecord.value
        Assert-CSXExactObjectProperties -Value $preflight -Expected @(
            'schema', 'ok', 'executablePath', 'version', 'versionText', 'versionSha256', 'rootHelpSha256',
            'execHelpSha256', 'features', 'missingFeatures', 'errors'
        ) -Label 'Automated visual-review provider preflight'
        if ([string](Get-CSXPropertyValue $preflight 'schema') -ne 'csx-codex-visual-review-preflight-v1' -or
            (Get-CSXPropertyValue $preflight 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $preflight 'ok') -or
            -not [IO.Path]::IsPathFullyQualified([string](Get-CSXPropertyValue $preflight 'executablePath')) -or
            [string](Get-CSXPropertyValue $preflight 'version') -notmatch '\S' -or
            [string](Get-CSXPropertyValue $preflight 'versionText') -notmatch '\S' -or
            -not (Test-CSXSha256Text (Get-CSXPropertyValue $preflight 'versionSha256')) -or
            -not (Test-CSXSha256Text (Get-CSXPropertyValue $preflight 'rootHelpSha256')) -or
            -not (Test-CSXSha256Text (Get-CSXPropertyValue $preflight 'execHelpSha256')) -or
            -not (Test-CSXArrayProperty $preflight 'missingFeatures') -or
            -not (Test-CSXArrayProperty $preflight 'errors') -or
            @(Get-CSXPropertyValue $preflight 'missingFeatures' @()).Count -ne 0 -or
            @(Get-CSXPropertyValue $preflight 'errors' @()).Count -ne 0) {
            throw 'Automated visual-review provider preflight is not a successful fully identified Codex CLI preflight.'
        }
        $featureNames = @(Get-CSXPropertyNames (Get-CSXPropertyValue $preflight 'features'))
        if ($featureNames.Count -eq 0 -or @($featureNames | Where-Object {
                (Get-CSXPropertyValue (Get-CSXPropertyValue $preflight 'features') $_) -isnot [bool] -or
                -not [bool](Get-CSXPropertyValue (Get-CSXPropertyValue $preflight 'features') $_)
            }).Count -ne 0) {
            throw 'Automated visual-review provider preflight does not prove all required Codex CLI features.'
        }
        Assert-CSXExactObjectProperties -Value $execution -Expected @(
            'schema', 'ok', 'provider', 'model', 'preflight', 'deadlineSeconds', 'deadlineReached',
            'startedUtc', 'completedUtc', 'durationMs', 'batches', 'errors'
        ) -Label 'Automated visual-review provider execution'
        if ([string](Get-CSXPropertyValue $execution 'schema') -ne 'csx-codex-visual-review-execution-v1' -or
            (Get-CSXPropertyValue $execution 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $execution 'ok') -or
            [string](Get-CSXPropertyValue $execution 'provider') -ne [string]$automated.provider -or
            [string](Get-CSXPropertyValue $execution 'model') -ne [string]$automated.model -or
            -not (Test-CSXJsonSemanticIdentity (Get-CSXPropertyValue $execution 'preflight') $preflight) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $execution 'deadlineSeconds') (Get-CSXPropertyValue $automated 'deadlineSeconds')) -or
            (Get-CSXPropertyValue $execution 'deadlineReached') -isnot [bool] -or [bool](Get-CSXPropertyValue $execution 'deadlineReached') -or
            -not (Test-CSXArrayProperty $execution 'errors') -or
            @(Get-CSXPropertyValue $execution 'errors' @()).Count -ne 0 -or
            -not (Test-CSXNumberClose (Get-CSXPropertyValue $execution 'durationMs') (Get-CSXPropertyValue $automated 'durationMs'))) {
            throw 'Automated visual-review provider execution is not one successful exact preflight-bound invocation.'
        }
        $executionStarted = [DateTimeOffset]::MinValue
        $executionCompleted = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $execution 'startedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$executionStarted) -or
            -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $execution 'completedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$executionCompleted) -or
            $executionCompleted -lt $executionStarted -or
            -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $execution 'durationMs')) -or
            [double](Get-CSXPropertyValue $execution 'durationMs') -gt [double]$evaluation.timeoutMs) {
            throw 'Automated visual-review provider execution interval is invalid or exceeded its deadline.'
        }
        $latestCompletedUtc = $executionCompleted
        $executionDuration = [double](Get-CSXPropertyValue $execution 'durationMs')
        if ([Math]::Abs(($executionCompleted - $executionStarted).TotalMilliseconds - $executionDuration) -gt
            [Math]::Max(2000.0, $executionDuration * 0.1)) {
            throw 'Automated visual-review provider execution duration differs materially from its UTC interval.'
        }
        $latestCaptureTerminal = [DateTimeOffset]::MinValue
        foreach ($run in @(Get-CSXPathValue $RunRaw 'assays.visual.runs' @())) {
            $terminal = Read-CSXProducerJson -EvidenceRoot $EvidenceDirectory -RelativePath ([string](Get-CSXPropertyValue $run 'terminalReceiptPath')) `
                -Label "Automated visual review capture $($run.replicate) terminal"
            $terminalUtc = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string](Get-CSXPathValue $terminal 'result.terminalUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$terminalUtc)) {
                throw "Automated visual review capture $($run.replicate) terminal UTC is invalid."
            }
            if ($terminalUtc -gt $latestCaptureTerminal) { $latestCaptureTerminal = $terminalUtc }
        }
        if ($latestCaptureTerminal -eq [DateTimeOffset]::MinValue -or $executionStarted -lt $latestCaptureTerminal) {
            throw 'Automated visual evaluation did not start after all visual captures completed.'
        }

        $batches = @(Get-CSXPropertyValue $automated 'batches' @())
        $executionBatches = @(Get-CSXPropertyValue $execution 'batches' @())
        if ($batches.Count -ne 6 -or $executionBatches.Count -ne 6) {
            throw 'Automated visual review must contain exactly six raw and provider execution batches.'
        }
        $expectedKeys = @(foreach ($presentationPass in 1..2) { foreach ($replicate in 1..3) { "$presentationPass`:$replicate" } })
        $actualKeys = @($batches | ForEach-Object {
            "$([int](Get-CSXPropertyValue $_ 'presentationPass'))`:$([int](Get-CSXPropertyValue $_ 'replicate'))"
        })
        $executionKeys = @($executionBatches | ForEach-Object {
            "$([int](Get-CSXPropertyValue $_ 'presentationPass'))`:$([int](Get-CSXPropertyValue $_ 'replicate'))"
        })
        if (($actualKeys -join ',') -cne ($expectedKeys -join ',') -or ($executionKeys -join ',') -cne ($expectedKeys -join ',')) {
            throw 'Automated visual-review batches are not the exact canonical pass/replicate sequence.'
        }

        $promptSourceText = [IO.File]::ReadAllText($promptRecord.path, [Text.Encoding]::UTF8)
        $batchRecords = @{}
        foreach ($batchOffset in 0..5) {
            $batch = $batches[$batchOffset]
            $providerBatch = $executionBatches[$batchOffset]
            Assert-CSXExactObjectProperties -Value $batch -Expected @(
                'replicate', 'presentationPass', 'requestPath', 'requestFileSha256', 'requestSha256',
                'responsePath', 'responseSha256', 'eventsPath', 'eventsSha256', 'stderrPath', 'stderrSha256',
                'receiptPath', 'receiptSha256'
            ) -Label 'Automated visual-review batch envelope'
            $expectedPresentationPass = [Math]::Floor($batchOffset / 3) + 1
            $expectedReplicate = ($batchOffset % 3) + 1
            if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $batch 'presentationPass') $expectedPresentationPass) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $batch 'replicate') $expectedReplicate)) {
                throw 'Automated visual-review batch identity is not an exact integer pass/replicate ordinal.'
            }
            $replicate = [int](Get-CSXPropertyValue $batch 'replicate')
            $presentationPass = [int](Get-CSXPropertyValue $batch 'presentationPass')
            $key = "$presentationPass`:$replicate"
            $prefix = "visual-review/pass-$($presentationPass.ToString('D2'))/rep-$($replicate.ToString('D2'))"
            $canonicalPaths = [ordered]@{
                requestPath = "$prefix/request.json"; responsePath = "$prefix/response.json"
                eventsPath = "$prefix/events.jsonl"; stderrPath = "$prefix/stderr.json"; receiptPath = "$prefix/receipt.json"
            }
            foreach ($pathName in $canonicalPaths.Keys) {
                if ([string](Get-CSXPropertyValue $batch $pathName) -cne $canonicalPaths[$pathName]) {
                    throw "Automated visual batch $key $pathName is not canonical."
                }
            }
            $requestRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
                -RelativePath ([string]$batch.requestPath) -ExpectedSha256 ([string]$batch.requestFileSha256) `
                -Label "Automated visual batch $key request" -Paths $paths
            $responseRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
                -RelativePath ([string]$batch.responsePath) -ExpectedSha256 ([string]$batch.responseSha256) `
                -Label "Automated visual batch $key response" -Paths $paths
            $receiptRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
                -RelativePath ([string]$batch.receiptPath) -ExpectedSha256 ([string]$batch.receiptSha256) `
                -Label "Automated visual batch $key receipt" -Paths $paths
            $eventsRecord = Read-CSXHashBoundVisualFile -EvidenceDirectory $EvidenceDirectory `
                -RelativePath ([string]$batch.eventsPath) -ExpectedSha256 ([string]$batch.eventsSha256) `
                -Label "Automated visual batch $key events" -Paths $paths
            $stderrRecord = Read-CSXAutomatedReviewJson -EvidenceDirectory $EvidenceDirectory `
                -RelativePath ([string]$batch.stderrPath) -ExpectedSha256 ([string]$batch.stderrSha256) `
                -Label "Automated visual batch $key stderr" -Paths $paths
            $request = $requestRecord.value
            $response = $responseRecord.value
            $receipt = $receiptRecord.value
            $stderr = $stderrRecord.value
            Assert-CSXExactObjectProperties -Value $request -Expected @('schema', 'requestSha256', 'body') `
                -Label "Automated visual batch $key request"
            Assert-CSXExactObjectProperties -Value (Get-CSXPropertyValue $request 'body') -Expected @(
                'runId', 'replicate', 'presentationPass', 'mode', 'sampleOrdinals', 'attachmentOrder'
            ) -Label "Automated visual batch $key request body"
            $requestSha256 = [string](Get-CSXPropertyValue $request 'requestSha256')
            if ([string](Get-CSXPropertyValue $request 'schema') -ne 'csx-render-scale-image-model-request-v1' -or
                -not (Test-CSXSha256Text $requestSha256) -or $requestSha256 -cne $requestSha256.ToLowerInvariant() -or
                (Get-CSXObjectSha256 -Value (Get-CSXPropertyValue $request 'body')) -cne $requestSha256 -or
                [string](Get-CSXPropertyValue $batch 'requestSha256') -cne $requestSha256) {
                throw "Automated visual batch $key request self-hash binding is invalid."
            }
            $body = Get-CSXPropertyValue $request 'body'
            $sampleOrdinals = @(Get-CSXPropertyValue $body 'sampleOrdinals' @())
            if ([string](Get-CSXPropertyValue $body 'runId') -ne $runId -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $body 'replicate') $replicate) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $body 'presentationPass') $presentationPass) -or
                [string](Get-CSXPropertyValue $body 'mode') -ne $mode -or
                $sampleOrdinals.Count -ne 3 -or -not (Test-CSXNumberEquals $sampleOrdinals[0] 1) -or
                -not (Test-CSXNumberEquals $sampleOrdinals[1] 8) -or -not (Test-CSXNumberEquals $sampleOrdinals[2] 16)) {
                throw "Automated visual batch $key request body identity is invalid."
            }
            $effectivePrompt = New-CSXAutomatedVisualPromptText -PromptSourceText $promptSourceText -RequestArtifact $request
            $effectivePromptSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($effectivePrompt))).ToLowerInvariant()

            $expectedCandidatePosition = if ($prMode) { if ($presentationPass -eq 1) { 'first' } else { 'second' } } else { 'only' }
            $attachments = @(Get-CSXPropertyValue $body 'attachmentOrder' @())
            $expectedAttachmentCount = if ($prMode) { 18 } else { 9 }
            if ($attachments.Count -ne $expectedAttachmentCount) {
                throw "Automated visual batch $key request has an invalid attachment count."
            }
            $attachmentKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $attachmentSignature = [Collections.Generic.List[string]]::new()
            foreach ($attachmentOffset in 0..($attachments.Count - 1)) {
                $attachment = $attachments[$attachmentOffset]
                Assert-CSXExactObjectProperties -Value $attachment -Expected @(
                    'attachmentIndex', 'neutralSet', 'ordinal', 'view', 'width', 'height', 'byteLength', 'sha256', 'aliasName'
                ) -Label "Automated visual batch $key attachment $($attachmentOffset + 1)"
                $attachmentIndex = [int](Get-CSXPropertyValue $attachment 'attachmentIndex')
                $neutralSet = [string](Get-CSXPropertyValue $attachment 'neutralSet')
                $ordinal = [int](Get-CSXPropertyValue $attachment 'ordinal')
                $view = [string](Get-CSXPropertyValue $attachment 'view')
                $expectedNeutralSets = if ($prMode) { @('first', 'second') } else { @('only') }
                if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $attachment 'attachmentIndex') ($attachmentOffset + 1)) -or
                    $neutralSet -notin $expectedNeutralSets -or
                    -not (Test-CSXNumberEquals (Get-CSXPropertyValue $attachment 'ordinal') $ordinal) -or
                    $ordinal -notin @(1, 8, 16) -or $view -notin @('left_eye', 'right_eye', 'side_by_side')) {
                    throw "Automated visual batch $key attachment $($attachmentOffset + 1) identity is invalid."
                }
                $attachmentKey = "$neutralSet|$ordinal|$view"
                if (-not $attachmentKeys.Add($attachmentKey)) { throw "Automated visual batch $key duplicates attachment $attachmentKey." }
                $attachmentSignature.Add($attachmentKey)
                $expectedAliasName = "$neutralSet/ordinal-$($ordinal.ToString('D2'))-$view.png"
                if ([string](Get-CSXPropertyValue $attachment 'aliasName') -cne $expectedAliasName) {
                    throw "Automated visual batch $key attachment $attachmentIndex alias is not the exact neutral name."
                }
                $sourceRole = if (-not $prMode -or $neutralSet -eq $expectedCandidatePosition) { 'candidate' } else { 'baseline' }
                $sourceIndex = if ($sourceRole -eq 'candidate') { $VisualIndex } else { $BaselineVisualIndex }
                $sourceSample = Get-CSXVisualSampleForReplicateOrdinal -VisualIndex $sourceIndex -Replicate $replicate -Ordinal $ordinal
                $artifactMatches = @($sourceSample.artifacts | Where-Object { [string](Get-CSXPropertyValue $_ 'view') -ceq $view })
                if ($artifactMatches.Count -ne 1) { throw "Automated visual batch $key cannot resolve source artifact $attachmentKey." }
                $artifact = $artifactMatches[0]
                $artifactRelative = [string](Get-CSXPropertyValue $artifact 'path')
                $sourcePath = if ($sourceRole -eq 'candidate') { $artifactRelative } else { "$baselinePrefix/$artifactRelative" }
                $sourceFullPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath $sourcePath
                if (-not $sourceFiles.ContainsKey($sourceFullPath)) {
                    $sourceItem = Get-Item -LiteralPath $sourceFullPath
                    $sourceFiles.Add($sourceFullPath, [pscustomobject][ordered]@{
                        byteLength = [uint64]$sourceItem.Length; sha256 = Get-CSXFileSha256 $sourceFullPath
                    })
                }
                $sourceFile = $sourceFiles[$sourceFullPath]
                if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $attachment 'width') (Get-CSXPropertyValue $artifact 'width')) -or
                    -not (Test-CSXNumberEquals (Get-CSXPropertyValue $attachment 'height') (Get-CSXPropertyValue $artifact 'height')) -or
                    -not (Test-CSXNumberEquals (Get-CSXPropertyValue $attachment 'byteLength') $sourceFile.byteLength) -or
                    [string](Get-CSXPropertyValue $attachment 'sha256') -cne [string](Get-CSXPropertyValue $artifact 'sha256') -or
                    [string]$sourceFile.sha256 -cne [string](Get-CSXPropertyValue $artifact 'sha256')) {
                    throw "Automated visual batch $key attachment $attachmentIndex does not bind the exact source artifact."
                }
            }
            if ($attachmentKeys.Count -ne $expectedAttachmentCount) {
                throw "Automated visual batch $key does not contain each expected neutral artifact exactly once."
            }

            Assert-CSXExactObjectProperties -Value $response -Expected @(
                'schema', 'provider', 'model', 'promptRevision', 'runId', 'requestSha256', 'replicate',
                'presentationPass', 'mode', 'samples', 'overallVerdict'
            ) -Label "Automated visual batch $key response"
            if ([string](Get-CSXPropertyValue $response 'schema') -ne 'csx-render-scale-image-model-response-v1' -or
                [string](Get-CSXPropertyValue $response 'provider') -ne [string]$automated.provider -or
                [string](Get-CSXPropertyValue $response 'model') -ne [string]$automated.model -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $response 'promptRevision') (Get-CSXPropertyValue $automated 'promptRevision')) -or
                [string](Get-CSXPropertyValue $response 'runId') -ne $runId -or
                [string](Get-CSXPropertyValue $response 'requestSha256') -cne $requestSha256 -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $response 'replicate') $replicate) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $response 'presentationPass') $presentationPass) -or
                [string](Get-CSXPropertyValue $response 'mode') -ne $mode) {
                throw "Automated visual batch $key response identity does not echo its exact request and invocation."
            }
            $responseSamples = @(Get-CSXPropertyValue $response 'samples' @())
            if ($responseSamples.Count -ne 3 -or (@($responseSamples | ForEach-Object { [int](Get-CSXPropertyValue $_ 'ordinal') }) -join ',') -ne '1,8,16' -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $responseSamples[0] 'ordinal') 1) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $responseSamples[1] 'ordinal') 8) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $responseSamples[2] 'ordinal') 16)) {
                throw "Automated visual batch $key response does not contain the exact ordered review samples."
            }
            $hasIndeterminate = $false
            $hasLocalFailure = $false
            foreach ($responseSample in $responseSamples) {
                $ordinal = [int](Get-CSXPropertyValue $responseSample 'ordinal')
                Assert-CSXExactObjectProperties -Value $responseSample -Expected @('ordinal', 'categories') `
                    -Label "Automated visual batch $key ordinal $ordinal response"
                $categories = Get-CSXPropertyValue $responseSample 'categories'
                Assert-CSXExactObjectProperties -Value $categories -Expected (Get-CSXAutomatedVisualCategoryNames) `
                    -Label "Automated visual batch $key ordinal $ordinal categories"
                foreach ($categoryName in @(Get-CSXAutomatedVisualCategoryNames)) {
                    $rating = Get-CSXPropertyValue $categories $categoryName
                    Assert-CSXExactObjectProperties -Value $rating -Expected @('verdict', 'confidence', 'observation', 'evidenceViews') `
                        -Label "Automated visual batch $key ordinal $ordinal category '$categoryName'"
                    $verdict = [string](Get-CSXPropertyValue $rating 'verdict')
                    $confidence = [string](Get-CSXPropertyValue $rating 'confidence')
                    $observation = [string](Get-CSXPropertyValue $rating 'observation')
                    $evidenceViews = @(Get-CSXPropertyValue $rating 'evidenceViews' @())
                    $allowedVerdicts = if ($prMode) { @('first_better', 'tie', 'second_better', 'indeterminate') } else { @('pass', 'fail', 'indeterminate') }
                    if ($verdict -notin $allowedVerdicts -or $confidence -notin @('low', 'medium', 'high') -or
                        [string]::IsNullOrWhiteSpace($observation) -or $observation.Length -gt 500 -or
                        $evidenceViews.Count -lt 1 -or $evidenceViews.Count -gt 3 -or
                        @($evidenceViews | Sort-Object -Unique).Count -ne $evidenceViews.Count -or
                        @($evidenceViews | Where-Object { [string]$_ -notin @('left_eye', 'right_eye', 'side_by_side') }).Count -ne 0) {
                        throw "Automated visual batch $key ordinal $ordinal category '$categoryName' rating is outside the closed response schema."
                    }
                    if ($confidence -eq 'low') {
                        $qualityErrors.Add("Automated visual batch $key ordinal $ordinal category '$categoryName' has low confidence.")
                    }
                    if ($verdict -eq 'indeterminate') {
                        $hasIndeterminate = $true
                        $qualityErrors.Add("Automated visual batch $key ordinal $ordinal category '$categoryName' is indeterminate.")
                    }
                    elseif (-not $prMode -and $verdict -eq 'fail') { $hasLocalFailure = $true }
                }
            }
            $overallVerdict = [string](Get-CSXPropertyValue $response 'overallVerdict')
            if ($overallVerdict -notin @('pass', 'fail', 'indeterminate')) {
                throw "Automated visual batch $key response overall verdict is invalid."
            }
            $expectedOverall = if ($hasIndeterminate) { @('fail', 'indeterminate') } elseif ($hasLocalFailure) { @('fail') } else { @('pass') }
            if ($overallVerdict -notin $expectedOverall) {
                throw "Automated visual batch $key overall verdict contradicts its category ratings."
            }
            if ($overallVerdict -ne 'pass') { $qualityErrors.Add("Automated visual batch $key overall verdict is $overallVerdict.") }

            Assert-CSXExactObjectProperties -Value $receipt -Expected @(
                'schema', 'runId', 'replicate', 'presentationPass', 'mode', 'provider', 'model', 'candidatePosition',
                'requestPath', 'requestSha256', 'responsePath', 'responseSha256', 'eventsPath', 'eventsSha256',
                'promptRevision', 'promptSourceSha256', 'promptEffectiveSha256', 'outputSchemaSourceSha256',
                'codexVersion', 'codexVersionSha256', 'codexRootHelpSha256', 'codexExecHelpSha256',
                'imageBindings', 'execution', 'errors'
            ) -Label "Automated visual batch $key receipt"
            if ([string](Get-CSXPropertyValue $receipt 'schema') -ne 'csx-render-scale-image-model-receipt-v1' -or
                [string](Get-CSXPropertyValue $receipt 'runId') -ne $runId -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $receipt 'replicate') $replicate) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $receipt 'presentationPass') $presentationPass) -or
                [string](Get-CSXPropertyValue $receipt 'mode') -ne $mode -or
                [string](Get-CSXPropertyValue $receipt 'provider') -ne [string]$automated.provider -or
                [string](Get-CSXPropertyValue $receipt 'model') -ne [string]$automated.model -or
                [string](Get-CSXPropertyValue $receipt 'candidatePosition') -ne $expectedCandidatePosition -or
                [string](Get-CSXPropertyValue $receipt 'requestPath') -cne [string]$batch.requestPath -or
                [string](Get-CSXPropertyValue $receipt 'requestSha256') -cne $requestSha256 -or
                [string](Get-CSXPropertyValue $receipt 'responsePath') -cne [string]$batch.responsePath -or
                [string](Get-CSXPropertyValue $receipt 'responseSha256') -cne $responseRecord.sha256 -or
                [string](Get-CSXPropertyValue $receipt 'eventsPath') -cne [string]$batch.eventsPath -or
                [string](Get-CSXPropertyValue $receipt 'eventsSha256') -cne $eventsRecord.sha256 -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $receipt 'promptRevision') (Get-CSXPropertyValue $automated 'promptRevision')) -or
                [string](Get-CSXPropertyValue $receipt 'promptSourceSha256') -cne $promptRecord.sha256 -or
                [string](Get-CSXPropertyValue $receipt 'promptEffectiveSha256') -cne $effectivePromptSha256 -or
                [string](Get-CSXPropertyValue $receipt 'outputSchemaSourceSha256') -cne $schemaRecord.sha256 -or
                [string](Get-CSXPropertyValue $receipt 'codexVersion') -ne [string](Get-CSXPropertyValue $preflight 'version') -or
                [string](Get-CSXPropertyValue $receipt 'codexVersionSha256') -cne [string](Get-CSXPropertyValue $preflight 'versionSha256') -or
                [string](Get-CSXPropertyValue $receipt 'codexRootHelpSha256') -cne [string](Get-CSXPropertyValue $preflight 'rootHelpSha256') -or
                [string](Get-CSXPropertyValue $receipt 'codexExecHelpSha256') -cne [string](Get-CSXPropertyValue $preflight 'execHelpSha256') -or
                -not (Test-CSXArrayProperty $receipt 'errors') -or
                @(Get-CSXPropertyValue $receipt 'errors' @()).Count -ne 0) {
                throw "Automated visual batch $key receipt identity or source/request/response binding is invalid."
            }
            Assert-CSXExactObjectProperties -Value $stderr -Expected @('schema', 'text') -Label "Automated visual batch $key stderr artifact"
            if ([string](Get-CSXPropertyValue $stderr 'schema') -ne 'csx-codex-visual-review-stderr-v1' -or
                [string](Get-CSXPropertyValue $stderr 'text') -ne '') {
                throw "Automated visual batch $key preserved non-empty stderr."
            }

            $receiptBindings = @(Get-CSXPropertyValue $receipt 'imageBindings' @())
            if ($receiptBindings.Count -ne $attachments.Count) {
                throw "Automated visual batch $key receipt image binding count differs from the request."
            }
            foreach ($attachmentOffset in 0..($attachments.Count - 1)) {
                $attachment = $attachments[$attachmentOffset]
                $binding = $receiptBindings[$attachmentOffset]
                Assert-CSXExactObjectProperties -Value $binding -Expected @(
                    'attachmentIndex', 'neutralSet', 'sourceRole', 'sourcePath', 'aliasPath', 'byteLength', 'sha256'
                ) -Label "Automated visual batch $key receipt image $($attachmentOffset + 1)"
                $neutralSet = [string](Get-CSXPropertyValue $attachment 'neutralSet')
                $sourceRole = if (-not $prMode -or $neutralSet -eq $expectedCandidatePosition) { 'candidate' } else { 'baseline' }
                $sourceIndex = if ($sourceRole -eq 'candidate') { $VisualIndex } else { $BaselineVisualIndex }
                $sourceSample = Get-CSXVisualSampleForReplicateOrdinal -VisualIndex $sourceIndex -Replicate $replicate `
                    -Ordinal ([int](Get-CSXPropertyValue $attachment 'ordinal'))
                $sourceArtifact = @($sourceSample.artifacts | Where-Object {
                    [string](Get-CSXPropertyValue $_ 'view') -ceq [string](Get-CSXPropertyValue $attachment 'view')
                })[0]
                $sourceRelative = [string](Get-CSXPropertyValue $sourceArtifact 'path')
                if ($sourceRole -eq 'baseline') { $sourceRelative = "$baselinePrefix/$sourceRelative" }
                $sourceFullPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath $sourceRelative
                if (-not $sourceFiles.ContainsKey($sourceFullPath)) {
                    $sourceItem = Get-Item -LiteralPath $sourceFullPath
                    $sourceFiles.Add($sourceFullPath, [pscustomobject][ordered]@{
                        byteLength = [uint64]$sourceItem.Length; sha256 = Get-CSXFileSha256 $sourceFullPath
                    })
                }
                $sourceFile = $sourceFiles[$sourceFullPath]
                $aliasPath = [string](Get-CSXPropertyValue $binding 'aliasPath')
                if (-not [IO.Path]::IsPathFullyQualified($aliasPath)) { throw "Automated visual batch $key receipt alias path is not absolute." }
                $aliasFullPath = Resolve-CSXContainedEvidencePath -EvidenceRoot $EvidenceDirectory -RecordedPath $aliasPath `
                    -Label "Automated visual batch $key receipt alias"
                $aliasRelative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($EvidenceDirectory), $aliasFullPath).Replace('\', '/')
                $aliasName = [string](Get-CSXPropertyValue $attachment 'aliasName')
                $aliasPattern = '^visual-review/\.aliases-[A-Fa-f0-9-]{32,36}/pass-' + $presentationPass.ToString('D2') +
                    '-rep-' + $replicate.ToString('D2') + '/' + [regex]::Escape($aliasName) + '$'
                if ($aliasRelative -cnotmatch $aliasPattern) {
                    throw "Automated visual batch $key receipt alias path is outside its task-owned neutral alias tree."
                }
                if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $binding 'attachmentIndex') ($attachmentOffset + 1)) -or
                    [string](Get-CSXPropertyValue $binding 'neutralSet') -ne $neutralSet -or
                    [string](Get-CSXPropertyValue $binding 'sourceRole') -ne $sourceRole -or
                    [string](Get-CSXPropertyValue $binding 'sourcePath') -cne $sourceRelative -or
                    -not (Test-CSXNumberEquals (Get-CSXPropertyValue $binding 'byteLength') (Get-CSXPropertyValue $attachment 'byteLength')) -or
                    [string](Get-CSXPropertyValue $binding 'sha256') -cne [string](Get-CSXPropertyValue $attachment 'sha256') -or
                    [uint64]$sourceFile.byteLength -ne [uint64](Get-CSXPropertyValue $binding 'byteLength') -or
                    [string]$sourceFile.sha256 -cne [string](Get-CSXPropertyValue $binding 'sha256')) {
                    throw "Automated visual batch $key receipt image $($attachmentOffset + 1) does not disclose the exact sealed source mapping."
                }
            }

            Assert-CSXExactObjectProperties -Value $providerBatch -Expected @(
                'presentationPass', 'replicate', 'ok', 'status', 'processId', 'exitCode', 'timedOut', 'startedUtc',
                'completedUtc', 'durationMs', 'promptSha256', 'imageBindings', 'outputSchemaPath', 'responsePath',
                'eventsPath', 'stdout', 'stdoutJsonl', 'stderr', 'response', 'responseText', 'responseSha256',
                'eventsSha256', 'errors'
            ) -Label "Automated visual batch $key provider execution"
            if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $providerBatch 'presentationPass') $presentationPass) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $providerBatch 'replicate') $replicate) -or
                (Get-CSXPropertyValue $providerBatch 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $providerBatch 'ok') -or
                [string](Get-CSXPropertyValue $providerBatch 'status') -ne 'completed' -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $providerBatch 'processId')) -or
                [double](Get-CSXPropertyValue $providerBatch 'processId') -le 0 -or
                [double](Get-CSXPropertyValue $providerBatch 'processId') -ne [Math]::Truncate([double](Get-CSXPropertyValue $providerBatch 'processId')) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $providerBatch 'exitCode') 0) -or
                (Get-CSXPropertyValue $providerBatch 'timedOut') -isnot [bool] -or [bool](Get-CSXPropertyValue $providerBatch 'timedOut') -or
                [string](Get-CSXPropertyValue $providerBatch 'promptSha256') -cne $effectivePromptSha256 -or
                -not [string]::Equals([string](Get-CSXPropertyValue $providerBatch 'outputSchemaPath'), $schemaRecord.path, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string](Get-CSXPropertyValue $providerBatch 'responsePath'), $responseRecord.path, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string](Get-CSXPropertyValue $providerBatch 'eventsPath'), $eventsRecord.path, [StringComparison]::OrdinalIgnoreCase) -or
                [string](Get-CSXPropertyValue $providerBatch 'responseSha256') -cne $responseRecord.sha256 -or
                [string](Get-CSXPropertyValue $providerBatch 'eventsSha256') -cne $eventsRecord.sha256 -or
                [string](Get-CSXPropertyValue $providerBatch 'stderr') -ne '' -or
                -not (Test-CSXArrayProperty $providerBatch 'errors') -or
                @(Get-CSXPropertyValue $providerBatch 'errors' @()).Count -ne 0 -or
                -not (Test-CSXJsonSemanticIdentity (Get-CSXPropertyValue $providerBatch 'response') $response) -or
                [string](Get-CSXPropertyValue $providerBatch 'responseText') -cne [IO.File]::ReadAllText($responseRecord.path, [Text.Encoding]::UTF8) -or
                [string](Get-CSXPropertyValue $providerBatch 'stdout') -cne [IO.File]::ReadAllText($eventsRecord.path, [Text.Encoding]::UTF8)) {
                throw "Automated visual batch $key provider execution does not cross-bind its exact successful process artifacts."
            }
            $providerBindings = @(Get-CSXPropertyValue $providerBatch 'imageBindings' @())
            if ($providerBindings.Count -ne $receiptBindings.Count) {
                throw "Automated visual batch $key provider image binding count differs from its receipt."
            }
            for ($imageOffset = 0; $imageOffset -lt $providerBindings.Count; $imageOffset++) {
                $providerBinding = $providerBindings[$imageOffset]
                Assert-CSXExactObjectProperties -Value $providerBinding -Expected @('path', 'byteLength', 'sha256') `
                    -Label "Automated visual batch $key provider image $($imageOffset + 1)"
                $receiptBinding = $receiptBindings[$imageOffset]
                if (-not [string]::Equals([string](Get-CSXPropertyValue $providerBinding 'path'), [string](Get-CSXPropertyValue $receiptBinding 'aliasPath'), [StringComparison]::OrdinalIgnoreCase) -or
                    -not (Test-CSXNumberEquals (Get-CSXPropertyValue $providerBinding 'byteLength') (Get-CSXPropertyValue $receiptBinding 'byteLength')) -or
                    [string](Get-CSXPropertyValue $providerBinding 'sha256') -cne [string](Get-CSXPropertyValue $receiptBinding 'sha256')) {
                    throw "Automated visual batch $key provider image order/hash differs from its sealed receipt."
                }
            }
            $eventObjects = [Collections.Generic.List[object]]::new()
            foreach ($eventLine in @(([IO.File]::ReadAllText($eventsRecord.path, [Text.Encoding]::UTF8) -split '\r?\n') | Where-Object { $_ -match '\S' })) {
                try { $eventObjects.Add(($eventLine | ConvertFrom-Json -Depth 100)) }
                catch { throw "Automated visual batch $key events contain invalid JSON Lines: $($_.Exception.Message)" }
            }
            if ($eventObjects.Count -eq 0 -or
                -not (Test-CSXJsonSemanticIdentity @($eventObjects) @(Get-CSXPropertyValue $providerBatch 'stdoutJsonl' @()))) {
                throw "Automated visual batch $key event JSON Lines do not match the provider execution projection."
            }
            $eventJson = @($eventObjects) | ConvertTo-Json -Depth 100 -Compress
            if ($eventJson -match '(?i)"type":"(?:command_execution|mcp_tool_call|web_search|file_change|computer_initialize_state)"') {
                throw "Automated visual batch $key used a non-image tool despite the image-only review contract."
            }
            if (@($eventObjects | Where-Object { [string](Get-CSXPropertyValue $_ 'type') -in @('turn.failed', 'error') }).Count -ne 0) {
                throw "Automated visual batch $key events contain a failed provider turn."
            }
            $agentMessages = @($eventObjects | Where-Object {
                [string](Get-CSXPathValue $_ 'item.type') -eq 'agent_message' -and
                [string](Get-CSXPathValue $_ 'item.text') -match '\S'
            })
            if ($agentMessages.Count -eq 0) {
                throw "Automated visual batch $key events omit the attributable final agent message."
            }
            try { $eventResponse = [string](Get-CSXPathValue $agentMessages[-1] 'item.text') | ConvertFrom-Json -Depth 100 }
            catch { throw "Automated visual batch $key final agent message is not the schema response JSON: $($_.Exception.Message)" }
            if (-not (Test-CSXJsonSemanticIdentity $eventResponse $response)) {
                throw "Automated visual batch $key final agent message differs from the response artifact."
            }
            Assert-CSXExactObjectProperties -Value (Get-CSXPropertyValue $receipt 'execution') -Expected @(
                'ok', 'status', 'exitCode', 'timedOut', 'startedUtc', 'completedUtc', 'durationMs'
            ) -Label "Automated visual batch $key receipt execution"
            $expectedReceiptExecution = [pscustomobject][ordered]@{
                ok = Get-CSXPropertyValue $providerBatch 'ok'; status = Get-CSXPropertyValue $providerBatch 'status'
                exitCode = Get-CSXPropertyValue $providerBatch 'exitCode'; timedOut = Get-CSXPropertyValue $providerBatch 'timedOut'
                startedUtc = Get-CSXPropertyValue $providerBatch 'startedUtc'; completedUtc = Get-CSXPropertyValue $providerBatch 'completedUtc'
                durationMs = Get-CSXPropertyValue $providerBatch 'durationMs'
            }
            if (-not (Test-CSXJsonSemanticIdentity (Get-CSXPropertyValue $receipt 'execution') $expectedReceiptExecution)) {
                throw "Automated visual batch $key receipt execution differs from the provider execution."
            }
            $batchStarted = [DateTimeOffset]::MinValue
            $batchCompleted = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $providerBatch 'startedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$batchStarted) -or
                -not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $providerBatch 'completedUtc'), [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$batchCompleted) -or
                $batchCompleted -lt $batchStarted -or $batchStarted -lt $executionStarted.AddSeconds(-2) -or
                $batchCompleted -gt $executionCompleted.AddSeconds(2) -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $providerBatch 'durationMs'))) {
                throw "Automated visual batch $key provider interval is invalid or outside the execution interval."
            }
            $batchDuration = [double](Get-CSXPropertyValue $providerBatch 'durationMs')
            if ([Math]::Abs(($batchCompleted - $batchStarted).TotalMilliseconds - $batchDuration) -gt
                [Math]::Max(2000.0, $batchDuration * 0.1)) {
                throw "Automated visual batch $key provider duration differs materially from its UTC interval."
            }
            if ($batchCompleted -gt $latestCompletedUtc) { $latestCompletedUtc = $batchCompleted }
            $batchRecords[$key] = [pscustomobject][ordered]@{
                request = $request; response = $response; receipt = $receipt; attachmentSignature = @($attachmentSignature)
                requestSha256 = $requestSha256; responseSha256 = $responseRecord.sha256; receiptSha256 = $receiptRecord.sha256
            }
        }

        if (-not $prMode) {
            foreach ($replicate in 1..3) {
                $passOne = @($batchRecords["1`:$replicate"].attachmentSignature)
                $passTwo = @($batchRecords["2`:$replicate"].attachmentSignature)
                [array]::Reverse($passOne)
                if (($passOne -join ',') -cne ($passTwo -join ',')) {
                    throw "Automated local visual replicate $replicate did not use the exact reversed second-pass attachment order."
                }
            }
        }

        $telemetry = Test-CSXAutomatedVisualTelemetry -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw
        if (-not $telemetry.ok) {
            foreach ($telemetryError in $telemetry.errors) { $integrityErrors.Add([string]$telemetryError) }
        }
        foreach ($replicate in 1..3) {
            $firstRecord = $batchRecords["1`:$replicate"]
            $secondRecord = $batchRecords["2`:$replicate"]
            foreach ($ordinal in @(1, 8, 16)) {
                $candidateSample = Get-CSXVisualSampleForReplicateOrdinal -VisualIndex $VisualIndex -Replicate $replicate -Ordinal $ordinal
                $baselineArtifacts = if ($prMode) {
                    @((Get-CSXVisualSampleForReplicateOrdinal -VisualIndex $BaselineVisualIndex -Replicate $replicate -Ordinal $ordinal).artifacts)
                }
                else { @() }
                $firstSample = @($firstRecord.response.samples | Where-Object { [int](Get-CSXPropertyValue $_ 'ordinal') -eq $ordinal })[0]
                $secondSample = @($secondRecord.response.samples | Where-Object { [int](Get-CSXPropertyValue $_ 'ordinal') -eq $ordinal })[0]
                $verdictProjection = [ordered]@{}
                foreach ($categoryName in @(Get-CSXAutomatedVisualCategoryNames)) {
                    $firstRating = Get-CSXPropertyValue (Get-CSXPropertyValue $firstSample 'categories') $categoryName
                    $secondRating = Get-CSXPropertyValue (Get-CSXPropertyValue $secondSample 'categories') $categoryName
                    $firstVerdict = [string](Get-CSXPropertyValue $firstRating 'verdict')
                    $secondVerdict = [string](Get-CSXPropertyValue $secondRating 'verdict')
                    if ($prMode) {
                        $normalize = {
                            param([string]$Value, [string]$CandidatePosition)
                            if ($Value -eq 'tie') { return 'tie' }
                            if (($Value -eq 'first_better' -and $CandidatePosition -eq 'first') -or
                                ($Value -eq 'second_better' -and $CandidatePosition -eq 'second')) { return 'candidate_better' }
                            if ($Value -eq 'indeterminate') { return 'indeterminate' }
                            return 'candidate_worse'
                        }
                        $firstNormalized = & $normalize $firstVerdict 'first'
                        $secondNormalized = & $normalize $secondVerdict 'second'
                        if ($firstNormalized -ne $secondNormalized) {
                            $qualityErrors.Add("Automated visual replicate $replicate ordinal $ordinal category '$categoryName' disagrees after the blinded order swap.")
                        }
                        $passed = $firstNormalized -eq $secondNormalized -and $firstNormalized -in @('tie', 'candidate_better')
                        if (-not $passed) {
                            $qualityErrors.Add("Automated visual replicate $replicate ordinal $ordinal category '$categoryName' is a regression or inconclusive.")
                        }
                        $verdictProjection[$categoryName] = if ($passed) { 'no_regression' } else { 'regression' }
                    }
                    else {
                        if ($firstVerdict -ne $secondVerdict) {
                            $qualityErrors.Add("Automated local visual replicate $replicate ordinal $ordinal category '$categoryName' disagrees between passes.")
                        }
                        $passed = $firstVerdict -eq 'pass' -and $secondVerdict -eq 'pass'
                        if (-not $passed) {
                            $qualityErrors.Add("Automated local visual replicate $replicate ordinal $ordinal category '$categoryName' did not pass both model passes.")
                        }
                        $verdictProjection[$categoryName] = if ($passed) { 'pass' } else { 'fail' }
                    }
                }
                $verdictProjection['renderScaleLatch'] = if ($telemetry.ok) {
                    $(if ($prMode) { 'no_regression' } else { 'pass' })
                }
                else { $(if ($prMode) { 'regression' } else { 'fail' }) }
                $projected.Add([pscustomobject][ordered]@{
                    replicate = $replicate; ordinal = $ordinal; candidateArtifacts = @($candidateSample.artifacts)
                    baselineArtifacts = @($baselineArtifacts); verdicts = [pscustomobject]$verdictProjection
                    modelEvidence = [pscustomobject][ordered]@{
                        pass1 = Get-CSXPropertyValue $firstSample 'categories'
                        pass2 = Get-CSXPropertyValue $secondSample 'categories'
                    }
                    sourceBatches = @(
                        [pscustomobject][ordered]@{
                            presentationPass = 1; requestSha256 = $firstRecord.requestSha256
                            responseSha256 = $firstRecord.responseSha256; receiptSha256 = $firstRecord.receiptSha256
                        },
                        [pscustomobject][ordered]@{
                            presentationPass = 2; requestSha256 = $secondRecord.requestSha256
                            responseSha256 = $secondRecord.responseSha256; receiptSha256 = $secondRecord.receiptSha256
                        }
                    )
                    renderScaleLatchSource = 'validated_telemetry'
                })
            }
        }
    }
    catch { $integrityErrors.Add($_.Exception.Message) }
    $integrityOk = $integrityErrors.Count -eq 0
    $qualityPassed = $integrityOk -and $qualityErrors.Count -eq 0 -and $projected.Count -eq 9
    return [pscustomobject][ordered]@{
        ok = $integrityOk -and $qualityPassed; integrityOk = $integrityOk; qualityPassed = $qualityPassed
        errors = @(@($integrityErrors) + @($qualityErrors) | Select-Object -Unique)
        integrityErrors = @($integrityErrors | Select-Object -Unique)
        qualityErrors = @($qualityErrors | Select-Object -Unique)
        provider = Get-CSXPropertyValue $automated 'provider'; model = Get-CSXPropertyValue $automated 'model'
        promptRevision = Get-CSXPropertyValue $automated 'promptRevision'
        reviewedUtc = $(if ($latestCompletedUtc -ne [DateTimeOffset]::MinValue) {
                $latestCompletedUtc.ToUniversalTime().ToString('o')
            } else { $null })
        samples = @($projected)
    }
}

function New-CSXAutomatedVisualReview {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        $BaselineVisualIndex = $null
    )
    $evidence = Test-CSXAutomatedVisualReviewEvidence -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw -VisualIndex $VisualIndex -BaselineVisualIndex $BaselineVisualIndex
    if (-not $evidence.integrityOk) { throw "Automated visual-review evidence is invalid: $($evidence.integrityErrors -join ' ')" }
    $prMode = [bool](Get-CSXPropertyValue $RunRaw 'prMode' $false)
    $rawPath = Join-Path $EvidenceDirectory 'run.raw.json'
    $automated = Get-CSXPathValue $RunRaw 'assays.visual.automatedReview'
    return [pscustomobject][ordered]@{
        schema = 'csx-render-scale-visual-review-v2'; comparisonMode = $(if ($prMode) { 'pr_baseline' } else { 'standalone' })
        runId = [string]$RunRaw.runId; protocolSha256 = [string]$RunRaw.protocol.sha256; runRawSha256 = Get-CSXFileSha256 $rawPath
        baselineRunSha256 = $(if ($prMode) { [string]$RunRaw.baseline.runSha256 } else { $null })
        automatedEvidence = [pscustomobject][ordered]@{
            schema = [string]$automated.schema; provider = [string]$automated.provider; model = [string]$automated.model
            promptRevision = [int]$automated.promptRevision
            promptPath = [string]$automated.promptPath; promptSourceSha256 = [string]$automated.promptSourceSha256
            outputSchemaPath = [string]$automated.outputSchemaPath; outputSchemaSourceSha256 = [string]$automated.outputSchemaSourceSha256
            preflightPath = [string]$automated.preflightPath; preflightSha256 = [string]$automated.preflightSha256
            executionPath = [string]$automated.executionPath; executionSha256 = [string]$automated.executionSha256
            deadlineSeconds = [double]$automated.deadlineSeconds; durationMs = [double]$automated.durationMs
            batches = @($automated.batches)
        }
        reviewer = [pscustomobject][ordered]@{ id = "$($evidence.provider)/$($evidence.model)"; kind = 'image_model' }
        reviewedUtc = $evidence.reviewedUtc; samples = @($evidence.samples)
        overallVerdict = $(if ($evidence.qualityPassed) { 'pass' } else { 'fail' })
    }
}

function Test-CSXAutomatedVisualReview {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        [Parameter(Mandatory)]$Review,
        $BaselineVisualIndex = $null
    )
    $errors = [Collections.Generic.List[string]]::new()
    $reviewIntegrityOk = $true
    $evidence = Test-CSXAutomatedVisualReviewEvidence -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw -VisualIndex $VisualIndex -BaselineVisualIndex $BaselineVisualIndex
    foreach ($error in $evidence.errors) { $errors.Add([string]$error) }
    if (-not $evidence.integrityOk) { $reviewIntegrityOk = $false }
    if ([string](Get-CSXPropertyValue $Review 'schema') -ne 'csx-render-scale-visual-review-v2' -or
        [string](Get-CSXPathValue $Review 'reviewer.kind') -ne 'image_model') {
        $errors.Add('Protocol revision 4 requires visual-review-v2 from an image_model; human review is forbidden.')
        $reviewIntegrityOk = $false
    }
    if ($evidence.integrityOk) {
        try {
            $expected = New-CSXAutomatedVisualReview -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw -VisualIndex $VisualIndex -BaselineVisualIndex $BaselineVisualIndex
            if (-not (Test-CSXJsonSemanticIdentity $Review $expected)) {
                $errors.Add('Automated visual review is not the exact mechanical projection of its hash-bound model and telemetry evidence.')
                $reviewIntegrityOk = $false
            }
        }
        catch { $errors.Add($_.Exception.Message); $reviewIntegrityOk = $false }
    }
    return [pscustomobject][ordered]@{
        ok = $reviewIntegrityOk -and $errors.Count -eq 0 -and $evidence.qualityPassed
        integrityOk = $reviewIntegrityOk; qualityPassed = $evidence.qualityPassed
        errors = @($errors | Select-Object -Unique)
        integrityErrors = @(@($evidence.integrityErrors) + @($errors | Where-Object { $_ -notin $evidence.qualityErrors }) | Select-Object -Unique)
        qualityErrors = @($evidence.qualityErrors)
        reviewer = Get-CSXPropertyValue $Review 'reviewer'; reviewedUtc = Get-CSXPropertyValue $Review 'reviewedUtc'
        provider = $evidence.provider; model = $evidence.model; promptRevision = $evidence.promptRevision
    }
}

function Test-CSXVisualReview {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        [Parameter(Mandatory)]$Review,
        $BaselineVisualIndex = $null
    )
    if ([int](Get-CSXPathValue $RunRaw 'protocol.revision' 0) -ne 4) {
        return [pscustomobject][ordered]@{
            ok = $false; integrityOk = $false; qualityPassed = $false
            errors = @('Only protocol revision 4 automated image-model visual review evidence is accepted.')
            reviewer = Get-CSXPropertyValue $Review 'reviewer'; reviewedUtc = Get-CSXPropertyValue $Review 'reviewedUtc'
        }
    }
    return Test-CSXAutomatedVisualReview -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw -VisualIndex $VisualIndex -Review $Review -BaselineVisualIndex $BaselineVisualIndex
}

function Test-CSXFlattenedBaselineVisualReview {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        [Parameter(Mandatory)]$Review
    )
    if ([int](Get-CSXPathValue $RunRaw 'protocol.revision' 0) -ne 4) {
        return [pscustomobject][ordered]@{
            ok = $false; integrityOk = $false; qualityPassed = $false
            errors = @('Only protocol revision 4 automated image-model baseline review evidence is accepted.')
            reviewer = Get-CSXPropertyValue $Review 'reviewer'; reviewedUtc = Get-CSXPropertyValue $Review 'reviewedUtc'
        }
    }
    if ([bool](Get-CSXPropertyValue $RunRaw 'prMode' $false)) {
        return [pscustomobject][ordered]@{
            ok = $false; integrityOk = $false; qualityPassed = $false
            errors = @('A flattened PR baseline requires its automated comparison index; recursive visual baselines are not accepted by revision 4.')
            reviewer = Get-CSXPropertyValue $Review 'reviewer'; reviewedUtc = Get-CSXPropertyValue $Review 'reviewedUtc'
        }
    }
    return Test-CSXAutomatedVisualReview -EvidenceDirectory $EvidenceDirectory -RunRaw $RunRaw -VisualIndex $VisualIndex -Review $Review
}

function Test-CSXSha256Text {
    param($Value)
    return [string]$Value -match '^[A-Fa-f0-9]{64}$'
}

function Test-CSXFiniteNonNegativeNumber {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
    try { $number = [double]$Value } catch { return $false }
    return [double]::IsFinite($number) -and $number -ge 0
}

function Test-CSXNumberEquals {
    param($Value, [Parameter(Mandatory)]$Expected)
    if ($null -eq $Value -or $null -eq $Expected -or $Value -is [bool] -or $Expected -is [bool] -or
        $Value -is [string] -or $Expected -is [string]) { return $false }
    try {
        $actualInteger = [decimal]$Value
        $expectedInteger = [decimal]$Expected
    }
    catch { return $false }
    return $actualInteger -ge 0 -and $expectedInteger -ge 0 -and
        $actualInteger -eq [decimal]::Truncate($actualInteger) -and
        $expectedInteger -eq [decimal]::Truncate($expectedInteger) -and
        $actualInteger -eq $expectedInteger
}

function Test-CSXExplicitNullProperty {
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    $missing = [object]::new()
    $value = Get-CSXPropertyValue -InputObject $InputObject -Name $Name -Default $missing
    return -not [object]::ReferenceEquals($value, $missing) -and $null -eq $value
}

function Test-CSXNumberClose {
    param($Actual, $Expected)
    if (-not (Test-CSXFiniteNonNegativeNumber $Actual) -or -not (Test-CSXFiniteNonNegativeNumber $Expected)) { return $false }
    $scale = [Math]::Max(1.0, [Math]::Abs([double]$Expected))
    return [Math]::Abs([double]$Actual - [double]$Expected) -le 0.000001 * $scale
}

function Test-CSXSignedNumberClose {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected -or $Actual -is [bool] -or $Expected -is [bool] -or
        $Actual -is [string] -or $Expected -is [string]) { return $false }
    try {
        $actualNumber = [double]$Actual
        $expectedNumber = [double]$Expected
    }
    catch { return $false }
    if (-not [double]::IsFinite($actualNumber) -or -not [double]::IsFinite($expectedNumber)) { return $false }
    $scale = [Math]::Max(1.0, [Math]::Abs($expectedNumber))
    return [Math]::Abs($actualNumber - $expectedNumber) -le 0.000001 * $scale
}

function Test-CSXJsonIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $null -eq $Actual -and $null -eq $Expected }
    return ($Actual | ConvertTo-Json -Depth 100 -Compress) -ceq ($Expected | ConvertTo-Json -Depth 100 -Compress)
}

function Test-CSXJsonSemanticIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $null -eq $Actual -and $null -eq $Expected }
    $actualIsObject = $Actual -is [Collections.IDictionary] -or $Actual -is [pscustomobject]
    $expectedIsObject = $Expected -is [Collections.IDictionary] -or $Expected -is [pscustomobject]
    if ($actualIsObject -or $expectedIsObject) {
        if (-not $actualIsObject -or -not $expectedIsObject) { return $false }
        $actualNames = @(Get-CSXPropertyNames $Actual | Sort-Object -CaseSensitive)
        $expectedNames = @(Get-CSXPropertyNames $Expected | Sort-Object -CaseSensitive)
        if ($actualNames.Count -ne $expectedNames.Count) { return $false }
        for ($nameIndex = 0; $nameIndex -lt $actualNames.Count; $nameIndex++) {
            if ([string]$actualNames[$nameIndex] -cne [string]$expectedNames[$nameIndex]) { return $false }
        }
        foreach ($name in $expectedNames) {
            $actualName = @(Get-CSXPropertyNames $Actual | Where-Object { $_ -ceq $name })
            if ($actualName.Count -ne 1 -or -not (Test-CSXJsonSemanticIdentity (Get-CSXPropertyValue $Actual $name) (Get-CSXPropertyValue $Expected $name))) {
                return $false
            }
        }
        return $true
    }
    $actualIsArray = $Actual -is [Collections.IEnumerable] -and $Actual -isnot [string]
    $expectedIsArray = $Expected -is [Collections.IEnumerable] -and $Expected -isnot [string]
    if ($actualIsArray -or $expectedIsArray) {
        if (-not $actualIsArray -or -not $expectedIsArray) { return $false }
        $actualItems = @($Actual); $expectedItems = @($Expected)
        if ($actualItems.Count -ne $expectedItems.Count) { return $false }
        for ($index = 0; $index -lt $actualItems.Count; $index++) {
            if (-not (Test-CSXJsonSemanticIdentity $actualItems[$index] $expectedItems[$index])) { return $false }
        }
        return $true
    }
    if ($Actual -is [bool] -or $Expected -is [bool]) {
        return $Actual -is [bool] -and $Expected -is [bool] -and [bool]$Actual -eq [bool]$Expected
    }
    if ($Actual -is [DateTime] -or $Actual -is [DateTimeOffset] -or
        $Expected -is [DateTime] -or $Expected -is [DateTimeOffset]) {
        try { return [DateTimeOffset]$Actual -eq [DateTimeOffset]$Expected }
        catch { return $false }
    }
    if ($Actual -isnot [string] -and $Expected -isnot [string]) {
        try { return [decimal]$Actual -eq [decimal]$Expected } catch {}
    }
    return $Actual -is [string] -and $Expected -is [string] -and [string]::Equals([string]$Actual, [string]$Expected, [StringComparison]::Ordinal)
}

function Test-CSXMetricSummaryIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    foreach ($name in @('count', 'total', 'min', 'median', 'mean', 'sampleStandardDeviation', 'coefficientOfVariation', 'p95', 'max', 'transitionsPerMinute')) {
        $missing = [object]::new()
        $actualValue = Get-CSXPropertyValue -InputObject $Actual -Name $name -Default $missing
        $expectedValue = Get-CSXPropertyValue -InputObject $Expected -Name $name -Default $missing
        if ([object]::ReferenceEquals($actualValue, $missing) -or [object]::ReferenceEquals($expectedValue, $missing)) { return $false }
        if ($null -eq $expectedValue) {
            if ($null -ne $actualValue) { return $false }
        }
        elseif (-not (Test-CSXNumberClose $actualValue $expectedValue)) { return $false }
    }
    return $true
}

function Get-CSXPropertyNames {
    param($InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [Collections.IDictionary]) { return @($InputObject.Keys | ForEach-Object { [string]$_ }) }
    return @($InputObject.PSObject.Properties.Name)
}

function Test-CSXProfileIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    $method = [string](Get-CSXPropertyValue $Expected 'method')
    $names = @('method', 'qualityMode', 'renderScaleMode') + $(if ($method -eq 'dlss') { @('dlssProfile') } else { @('fsrRuntime') })
    if ((@(Get-CSXPropertyNames $Actual | Sort-Object) -join ',') -ne (@($names | Sort-Object) -join ',')) { return $false }
    if ([string](Get-CSXPropertyValue $Actual 'method') -ne $method -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $Actual 'qualityMode') ([double](Get-CSXPropertyValue $Expected 'qualityMode'))) -or
        (Get-CSXPropertyValue $Actual 'renderScaleMode') -isnot [bool] -or
        [bool](Get-CSXPropertyValue $Actual 'renderScaleMode') -ne [bool](Get-CSXPropertyValue $Expected 'renderScaleMode')) { return $false }
    $specific = if ($method -eq 'dlss') { 'dlssProfile' } else { 'fsrRuntime' }
    return [string](Get-CSXPropertyValue $Actual $specific) -eq [string](Get-CSXPropertyValue $Expected $specific)
}

function Test-CSXFoveationTargetIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    $names = @('foveatedVendorDispatch', 'foveatedCenterArea', 'peripheryTAAEnable', 'peripheryTAACenterArea', 'peripheryTAAOuterScale')
    if ((@(Get-CSXPropertyNames $Actual | Sort-Object) -join ',') -ne (@($names | Sort-Object) -join ',')) { return $false }
    foreach ($name in @('foveatedVendorDispatch', 'peripheryTAAEnable')) {
        if ((Get-CSXPropertyValue $Actual $name) -isnot [bool] -or
            [bool](Get-CSXPropertyValue $Actual $name) -ne [bool](Get-CSXPropertyValue $Expected $name)) { return $false }
    }
    foreach ($name in @('foveatedCenterArea', 'peripheryTAACenterArea', 'peripheryTAAOuterScale')) {
        if (-not (Test-CSXNumberClose (Get-CSXPropertyValue $Actual $name) (Get-CSXPropertyValue $Expected $name))) { return $false }
    }
    return $true
}

function Test-CSXTransitionRecordSet {
    param(
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][ValidateSet('coc', 'menu')][string]$Assay,
        [Parameter(Mandatory)][string]$EvidenceLabel
    )
    $errors = [Collections.Generic.List[string]]::new()
    $records = @(Get-CSXPathValue $Raw "assays.$Assay.records" @())
    $expectedCount = if ($Assay -eq 'coc') { 20 } else { 25 }
    $runId = [string](Get-CSXPropertyValue $Raw 'runId')
    $buildId = [string](Get-CSXPathValue $Raw 'runtime.buildId')
    $vendor = [string](Get-CSXPathValue $Raw 'fixture.gpuVendor')
    $fsrRuntime = [string](Get-CSXPathValue $Raw 'fixture.fsrRuntime')
    $matrixName = if ($vendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' }
    $matrix = @($Protocol.menuAssay.$matrixName)
    $foveation = Get-CSXFoveationTarget $Protocol
    $diagnosticPaths = @(
        'stress.failureEvents', 'presentation.vendorFailureStretchEyeObservations', 'presentation.boundsMismatchFallbackEyeObservations',
        'failures.fidelityMismatches', 'failures.transition', 'failures.outOfMemory', 'failures.deviceLost',
        'failures.dlssLifecycle', 'failures.fsrLifecycle', 'failures.memoryTrim', 'failures.retirementFence',
        'dlssTrace.droppedRecords', 'dlssTrace.duplicatedConstantsFailures', 'dlssTrace.evaluateFailures'
    )
    $breakdown = [ordered]@{}
    foreach ($path in $diagnosticPaths) { $breakdown[$path] = 0L }
    $failureCount = 0L
    $diagnosticFailureLowerBound = 0L
    $failedTransitions = 0
    $times = [Collections.Generic.List[double]]::new()
    $stressSessionIds = [Collections.Generic.List[string]]::new()
    $cellFormIds = [ordered]@{}
    if ($records.Count -ne $expectedCount) { $errors.Add("$EvidenceLabel $Assay record count is $($records.Count), expected $expectedCount.") }

    for ($ordinal = 1; $ordinal -le $expectedCount; $ordinal++) {
        $matches = @($records | Where-Object { Test-CSXNumberEquals (Get-CSXPropertyValue $_ 'ordinal') $ordinal })
        if ($matches.Count -ne 1) {
            $errors.Add("$EvidenceLabel $Assay ordinal $ordinal is missing or duplicated.")
            continue
        }
        $row = $matches[0]
        $transitionId = if ($Assay -eq 'coc') { $ordinal } else { 100 + $ordinal }
        $expectedCell = if ($Assay -eq 'coc' -and $ordinal % 2 -eq 1) {
            [string]$Protocol.fixture.interiorCellEditorId
        }
        else { [string]$Protocol.fixture.startCellEditorId }
        $profile = if ($Assay -eq 'coc') {
            if ($ordinal % 2 -eq 1) {
                if ($vendor -eq 'NVIDIA') { $Protocol.fixture.profiles.nvidiaInterior } else { $Protocol.fixture.profiles.amdInterior }
            }
            else { $Protocol.fixture.profiles.sharedExterior }
        }
        else { $matrix[$ordinal - 1] }
        $expectedTarget = Add-CSXExactRuntimeToProfile -Profile $profile -FsrRuntime $fsrRuntime
        $receipts = Get-CSXPropertyValue $row 'receipts'
        $begin = Get-CSXPropertyValue $receipts 'begin'
        $dispatch = Get-CSXPropertyValue $receipts 'dispatch'
        $mutation = Get-CSXPropertyValue $receipts 'mutation'
        $wait = Get-CSXPropertyValue $receipts 'wait'

        $stressSessionId = Get-CSXPathValue $begin 'baseline.stressSessionId'
        $stressSessionInvalid = -not (Test-CSXFiniteNonNegativeNumber $stressSessionId) -or
            [double]$stressSessionId -le 0 -or [Math]::Truncate([double]$stressSessionId) -ne [double]$stressSessionId -or
            -not (Test-CSXNumberEquals (Get-CSXPathValue $wait 'baseline.stressSessionId') $stressSessionId)
        if (-not $stressSessionInvalid) { $stressSessionIds.Add([string]$stressSessionId) }

        $identityInvalid = $false
        foreach ($receiptSpec in @(
            [pscustomobject]@{ value = $begin; action = 'qualification_begin'; accepted = $true },
            [pscustomobject]@{ value = $dispatch; action = 'qualification_dispatch'; accepted = $true },
            [pscustomobject]@{ value = $wait; action = 'qualification_wait'; accepted = $false }
        )) {
            $receipt = $receiptSpec.value
            if ($null -eq $receipt -or [string](Get-CSXPropertyValue $receipt 'action') -ne $receiptSpec.action -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $receipt 'transitionId') $transitionId) -or
                [string](Get-CSXPropertyValue $receipt 'ownerId') -ne $runId -or
                [string](Get-CSXPathValue $receipt 'producer.buildId') -ne $buildId) { $identityInvalid = $true }
            if ($receiptSpec.accepted -and ((Get-CSXPropertyValue $receipt 'accepted') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $receipt 'accepted'))) {
                $identityInvalid = $true
            }
        }
        if ([string](Get-CSXPropertyValue $row 'assay') -ne $Assay -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $row 'transitionId') $transitionId) -or
            [string](Get-CSXPropertyValue $row 'ownerId') -ne $runId -or
            [string](Get-CSXPropertyValue $row 'outcome') -ne 'stable' -or
            (Get-CSXPropertyValue $row 'satisfied') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $row 'satisfied')) { $identityInvalid = $true }
        if ($stressSessionInvalid -or -not (Test-CSXJsonIdentity (Get-CSXPathValue $wait 'baseline') (Get-CSXPathValue $begin 'baseline'))) {
            $identityInvalid = $true
        }
        if ($identityInvalid) { $errors.Add("$EvidenceLabel $Assay ordinal $ordinal has invalid owner-bound begin/dispatch/wait receipt identity.") }

        if ([string](Get-CSXPropertyValue $wait 'outcome') -ne 'stable' -or
            (Get-CSXPropertyValue $wait 'satisfied') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $wait 'satisfied') -or
            @(Get-CSXPropertyValue $wait 'failureReasons' @()).Count -ne 0) {
            $errors.Add("$EvidenceLabel $Assay ordinal $ordinal wait receipt is not failure-free and stable.")
        }

        $targetInvalid = -not (Test-CSXProfileIdentity (Get-CSXPropertyValue $row 'target') $expectedTarget) -or
            -not (Test-CSXProfileIdentity (Get-CSXPropertyValue $wait 'target') $expectedTarget) -or
            [string](Get-CSXPropertyValue $row 'method') -ne [string](Get-CSXPropertyValue $expectedTarget 'method') -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $row 'qualityMode') ([double](Get-CSXPropertyValue $expectedTarget 'qualityMode'))) -or
            (Get-CSXPropertyValue $row 'renderScaleMode') -isnot [bool] -or
            [bool](Get-CSXPropertyValue $row 'renderScaleMode') -ne [bool](Get-CSXPropertyValue $expectedTarget 'renderScaleMode')
        if ([string](Get-CSXPropertyValue $expectedTarget 'method') -eq 'dlss') {
            $targetInvalid = $targetInvalid -or [string](Get-CSXPropertyValue $row 'dlssProfile') -ne [string](Get-CSXPropertyValue $expectedTarget 'dlssProfile') -or
                $null -ne (Get-CSXPropertyValue $row 'fsrRuntime')
        }
        else {
            $targetInvalid = $targetInvalid -or [string](Get-CSXPropertyValue $row 'fsrRuntime') -ne $fsrRuntime -or
                $null -ne (Get-CSXPropertyValue $row 'dlssProfile')
        }
        if ($targetInvalid) { $errors.Add("$EvidenceLabel $Assay ordinal $ordinal profile does not match the canonical target/matrix.") }

        $currentCellFormId = Get-CSXPathValue $wait 'currentCell.formId'
        $rowExpectedCell = Get-CSXPropertyValue $row 'expectedCell'
        $waitExpectedCell = Get-CSXPropertyValue $wait 'expectedCell'
        $currentCell = Get-CSXPropertyValue $wait 'currentCell'
        $cellInvalid = (@(Get-CSXPropertyNames $rowExpectedCell | Sort-Object) -join ',') -ne 'editorId,formId' -or
            (@(Get-CSXPropertyNames $waitExpectedCell | Sort-Object) -join ',') -ne 'editorId' -or
            (@(Get-CSXPropertyNames $currentCell | Sort-Object) -join ',') -ne 'editorId,formId' -or
            -not (Test-CSXExplicitNullProperty $rowExpectedCell 'formId') -or
            [string](Get-CSXPathValue $row 'expectedCell.editorId') -ne $expectedCell -or
            [string](Get-CSXPathValue $wait 'expectedCell.editorId') -ne $expectedCell -or
            [string](Get-CSXPathValue $wait 'currentCell.editorId') -ne $expectedCell -or
            -not (Test-CSXFiniteNonNegativeNumber $currentCellFormId) -or [double]$currentCellFormId -le 0 -or
            [Math]::Truncate([double]$currentCellFormId) -ne [double]$currentCellFormId -or
            -not (Test-CSXFoveationTargetIdentity (Get-CSXPropertyValue $row 'foveationTarget') $foveation) -or
            -not (Test-CSXFoveationTargetIdentity (Get-CSXPropertyValue $wait 'foveationTarget') $foveation) -or
            -not (Test-CSXFoveationEvidence -Evidence (Get-CSXPropertyValue $wait 'foveation') -Expected $foveation -Target $expectedTarget) -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'target') (Get-CSXPropertyValue $wait 'target')) -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'foveationTarget') (Get-CSXPropertyValue $wait 'foveationTarget'))
        if (-not $cellInvalid) {
            $formIdText = [string]$currentCellFormId
            if ($cellFormIds.Contains($expectedCell) -and [string]$cellFormIds[$expectedCell] -ne $formIdText) { $cellInvalid = $true }
            else { $cellFormIds[$expectedCell] = $formIdText }
        }
        if ($cellInvalid) {
            $errors.Add("$EvidenceLabel $Assay ordinal $ordinal does not prove the exact cell and foveation target.")
        }

        if ($Assay -eq 'coc') {
            if ($null -eq $mutation -or (Get-CSXPropertyValue $mutation 'queued') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $mutation 'queued')) {
                $errors.Add("$EvidenceLabel COC ordinal $ordinal console mutation was not queued.")
            }
        }
        else {
            $disposition = [string](Get-CSXPropertyValue $mutation 'disposition')
            if ($null -eq $mutation -or [string](Get-CSXPropertyValue $mutation 'action') -ne 'apply' -or
                (Get-CSXPropertyValue $mutation 'accepted') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $mutation 'accepted') -or
                $disposition -notin @('applied_synchronously', 'queued', 'deferred') -or
                [string](Get-CSXPathValue $mutation 'producer.buildId') -ne $buildId -or
                [string](Get-CSXPropertyValue $mutation 'method') -ne [string](Get-CSXPropertyValue $expectedTarget 'method') -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $mutation 'qualityMode') ([double](Get-CSXPropertyValue $expectedTarget 'qualityMode'))) -or
                (Get-CSXPropertyValue $mutation 'enabled') -isnot [bool] -or
                [bool](Get-CSXPropertyValue $mutation 'enabled') -ne [bool](Get-CSXPropertyValue $expectedTarget 'renderScaleMode') -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $mutation 'requestID')) -or [double](Get-CSXPropertyValue $mutation 'requestID') -le 0 -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $mutation 'transitionEpoch')) -or [double](Get-CSXPropertyValue $mutation 'transitionEpoch') -le 0 -or
                ([string](Get-CSXPropertyValue $expectedTarget 'method') -eq 'dlss' -and -not (Test-CSXNumberEquals (Get-CSXPropertyValue $mutation 'dlssPreset') 1))) {
                $errors.Add("$EvidenceLabel menu ordinal $ordinal apply receipt does not match the canonical matrix.")
            }
        }

        $beginTick = Get-CSXPathValue $begin 'baseline.timing.beginTick'
        $beginFrequency = Get-CSXPathValue $begin 'baseline.timing.tickFrequency'
        $beginFrame = Get-CSXPathValue $begin 'baseline.frame'
        $dispatchTick = Get-CSXPathValue $dispatch 'timing.dispatchTick'
        $dispatchFrequency = Get-CSXPathValue $dispatch 'timing.tickFrequency'
        $dispatchFrame = Get-CSXPropertyValue $dispatch 'dispatchFrame'
        $waitTiming = Get-CSXPropertyValue $wait 'timing'
        $stableTick = Get-CSXPropertyValue $waitTiming 'stableTick'
        $stableFrame = Get-CSXPathValue $wait 'frames.stable'
        $elapsedMs = Get-CSXPropertyValue $waitTiming 'elapsedMs'
        $elapsedFrames = Get-CSXPropertyValue $waitTiming 'elapsedFrames'
        $timingInvalid = [string](Get-CSXPathValue $begin 'baseline.timing.clock') -ne 'query_performance_counter' -or
            [string](Get-CSXPathValue $dispatch 'timing.clock') -ne 'query_performance_counter' -or
            [string](Get-CSXPathValue $dispatch 'timing.elapsedOrigin') -ne 'qualification_dispatch' -or
            [string](Get-CSXPropertyValue $waitTiming 'clock') -ne 'query_performance_counter' -or
            [string](Get-CSXPropertyValue $waitTiming 'elapsedOrigin') -ne 'qualification_dispatch' -or
            -not (Test-CSXFiniteNonNegativeNumber $beginTick) -or [double]$beginTick -le 0 -or
            -not (Test-CSXFiniteNonNegativeNumber $beginFrequency) -or [double]$beginFrequency -le 0 -or
            -not (Test-CSXFiniteNonNegativeNumber $beginFrame) -or
            -not (Test-CSXFiniteNonNegativeNumber $dispatchTick) -or [double]$dispatchTick -lt [double]$beginTick -or
            -not (Test-CSXNumberEquals $dispatchFrequency $beginFrequency) -or
            -not (Test-CSXFiniteNonNegativeNumber $dispatchFrame) -or [double]$dispatchFrame -le 0 -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $waitTiming 'beginTick') $beginTick) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $waitTiming 'dispatchTick') $dispatchTick) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $waitTiming 'tickFrequency') $beginFrequency) -or
            -not (Test-CSXFiniteNonNegativeNumber $stableTick) -or [double]$stableTick -lt [double]$dispatchTick -or
            -not (Test-CSXNumberEquals (Get-CSXPathValue $wait 'frames.begin') $beginFrame) -or
            -not (Test-CSXNumberEquals (Get-CSXPathValue $wait 'frames.dispatch') $dispatchFrame) -or
            -not (Test-CSXFiniteNonNegativeNumber $stableFrame) -or [double]$stableFrame -le [double]$dispatchFrame -or
            -not (Test-CSXFiniteNonNegativeNumber $elapsedMs) -or
            -not (Test-CSXFiniteNonNegativeNumber $elapsedFrames) -or
            -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $row 'qpcTiming') $waitTiming)
        if (-not $timingInvalid) {
            $expectedElapsedMs = ([double]$stableTick - [double]$dispatchTick) * 1000.0 / [double]$beginFrequency
            $expectedElapsedFrames = [double]$stableFrame - [double]$dispatchFrame
            $timingInvalid = -not (Test-CSXNumberClose $elapsedMs $expectedElapsedMs) -or
                -not (Test-CSXNumberEquals $elapsedFrames $expectedElapsedFrames) -or
                -not (Test-CSXNumberClose (Get-CSXPropertyValue $row 'elapsedMs') $expectedElapsedMs) -or
                -not (Test-CSXNumberEquals (Get-CSXPropertyValue $row 'elapsedFrames') $expectedElapsedFrames) -or
                -not (Test-CSXNumberClose (Get-CSXPathValue $row 'qpcTiming.elapsedMs') $expectedElapsedMs) -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $row 'qpcTiming.elapsedFrames') $expectedElapsedFrames)
            if (-not $timingInvalid) { $times.Add([double]$elapsedMs) }
        }
        if ($timingInvalid) { $errors.Add("$EvidenceLabel $Assay ordinal $ordinal does not prove finite dispatch-to-stable QPC timing.") }

        $diagnostics = Get-CSXPropertyValue $wait 'diagnostics'
        $delta = Get-CSXPropertyValue $diagnostics 'delta'
        $recordMaximum = 0L
        $diagnosticsInvalid = $null -eq $delta
        foreach ($path in $diagnosticPaths) {
            $value = Get-CSXPathValue $delta $path
            if (-not (Test-CSXFiniteNonNegativeNumber $value) -or [Math]::Truncate([double]$value) -ne [double]$value) {
                $diagnosticsInvalid = $true
                continue
            }
            $count = [long]$value
            $breakdown[$path] += $count
            if ($count -gt $recordMaximum) { $recordMaximum = $count }
        }
        if ($diagnosticsInvalid) { $errors.Add("$EvidenceLabel $Assay ordinal $ordinal diagnostics are missing or non-integral.") }
        $failureCount += [long](Get-CSXPathValue $delta 'stress.failureEvents' 0)
        $diagnosticFailureLowerBound += $recordMaximum
        if ($timingInvalid -or [string](Get-CSXPropertyValue $wait 'outcome') -ne 'stable' -or
            -not [bool](Get-CSXPropertyValue $wait 'satisfied' $false) -or $recordMaximum -gt 0) { $failedTransitions++ }
    }
    if (@($records | ForEach-Object { [string](Get-CSXPropertyValue $_ 'transitionId') } | Sort-Object -Unique).Count -ne $expectedCount) {
        $errors.Add("$EvidenceLabel $Assay transition IDs are not unique.")
    }
    $expectedOrdinals = @(1..$expectedCount)
    $expectedTransitionIds = @($expectedOrdinals | ForEach-Object { if ($Assay -eq 'coc') { $_ } else { 100 + $_ } })
    if ((@($records | ForEach-Object { Get-CSXPropertyValue $_ 'ordinal' }) -join ',') -ne ($expectedOrdinals -join ',') -or
        (@($records | ForEach-Object { Get-CSXPropertyValue $_ 'transitionId' }) -join ',') -ne ($expectedTransitionIds -join ',')) {
        $errors.Add("$EvidenceLabel $Assay records are not in the canonical ordinal/transition-ID order.")
    }
    if (@($stressSessionIds | Sort-Object -Unique).Count -ne 1) {
        $errors.Add("$EvidenceLabel $Assay begin receipts do not share one positive stress session ID.")
    }
    return [pscustomobject][ordered]@{
        ok = $errors.Count -eq 0; errors = @($errors); records = $records; times = @($times)
        failureCount = $failureCount; diagnosticFailureLowerBound = $diagnosticFailureLowerBound
        failedTransitions = $failedTransitions; failureBreakdown = [pscustomobject]$breakdown; cellFormIds = [pscustomobject]$cellFormIds
    }
}

function Get-CSXMenuStrataSummary {
    param([Parameter(Mandatory)][object[]]$Rows)
    $byMethod = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        $byMethod[$method] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object method -eq $method | ForEach-Object elapsedMs)) -IncludeRate
    }
    $byRenderScale = [ordered]@{
        off = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { -not $_.renderScaleMode } | ForEach-Object elapsedMs)) -IncludeRate
        on = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object renderScaleMode | ForEach-Object elapsedMs)) -IncludeRate
    }
    $combined = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        foreach ($state in @($false, $true)) {
            $key = "$method-render-scale-$(if ($state) { 'on' } else { 'off' })"
            $combined[$key] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { $_.method -eq $method -and $_.renderScaleMode -eq $state } | ForEach-Object elapsedMs)) -IncludeRate
        }
    }
    return [pscustomobject][ordered]@{ byMethod = [pscustomobject]$byMethod; byRenderScaleState = [pscustomobject]$byRenderScale; combined = [pscustomobject]$combined }
}

function Test-CSXStrataIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    foreach ($groupName in @('byMethod', 'byRenderScaleState', 'combined')) {
        $actualGroup = Get-CSXPropertyValue $Actual $groupName
        $expectedGroup = Get-CSXPropertyValue $Expected $groupName
        if ((@(Get-CSXPropertyNames $actualGroup | Sort-Object) -join ',') -ne (@(Get-CSXPropertyNames $expectedGroup | Sort-Object) -join ',')) { return $false }
        foreach ($name in @(Get-CSXPropertyNames $expectedGroup)) {
            if (-not (Test-CSXMetricSummaryIdentity (Get-CSXPropertyValue $actualGroup $name) (Get-CSXPropertyValue $expectedGroup $name))) { return $false }
        }
    }
    return $true
}

function Test-CSXPairedCriticalIdentity {
    param($Actual, $Expected)
    if ($null -eq $Actual -or $null -eq $Expected -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $Actual 'count') (Get-CSXPropertyValue $Expected 'count'))) { return $false }
    foreach ($name in @('candidate', 'baseline')) {
        if (-not (Test-CSXMetricSummaryIdentity (Get-CSXPropertyValue $Actual $name) (Get-CSXPropertyValue $Expected $name))) { return $false }
    }
    foreach ($metric in @('total', 'median', 'mean', 'p95', 'max')) {
        foreach ($name in @('candidateMs', 'baselineMs', 'deltaMs', 'percent')) {
            $actualValue = Get-CSXPathValue $Actual "aggregateDelta.$metric.$name"
            $expectedValue = Get-CSXPathValue $Expected "aggregateDelta.$metric.$name"
            if (-not (Test-CSXSignedNumberClose $actualValue $expectedValue)) { return $false }
        }
    }
    foreach ($group in @('milliseconds', 'percent')) {
        $actualSummary = Get-CSXPathValue $Actual "pairedOrdinalDelta.$group"
        $expectedSummary = Get-CSXPathValue $Expected "pairedOrdinalDelta.$group"
        foreach ($name in @('count', 'total', 'min', 'median', 'mean', 'sampleStandardDeviation', 'coefficientOfVariation', 'p95', 'max')) {
            $actualValue = Get-CSXPropertyValue $actualSummary $name
            $expectedValue = Get-CSXPropertyValue $expectedSummary $name
            if ($null -eq $expectedValue) {
                if ($null -ne $actualValue) { return $false }
            }
            elseif (-not (Test-CSXSignedNumberClose $actualValue $expectedValue)) { return $false }
        }
        if (-not (Test-CSXExplicitNullProperty $actualSummary 'transitionsPerMinute')) { return $false }
    }
    foreach ($name in @('median', 'p95')) {
        foreach ($field in @('candidateMs', 'baselineMs', 'deltaMs', 'percent')) {
            if (-not (Test-CSXSignedNumberClose (Get-CSXPathValue $Actual "aggregateDelta.$name.$field") (Get-CSXPathValue $Expected "aggregateDelta.$name.$field"))) {
                return $false
            }
        }
    }
    return $true
}

function Test-CSXCoreQualificationEvidence {
    param(
        [Parameter(Mandatory)]$Raw,
        [Parameter(Mandatory)]$Protocol,
        [string]$EvidenceLabel = 'Candidate'
    )
    $errors = [Collections.Generic.List[string]]::new()
    $recordSets = [ordered]@{
        coc = Test-CSXTransitionRecordSet -Raw $Raw -Protocol $Protocol -Assay coc -EvidenceLabel $EvidenceLabel
        menu = Test-CSXTransitionRecordSet -Raw $Raw -Protocol $Protocol -Assay menu -EvidenceLabel $EvidenceLabel
    }
    foreach ($assay in @('coc', 'menu')) {
        $result = $recordSets[$assay]
        foreach ($error in $result.errors) { $errors.Add([string]$error) }
        $evidence = Get-CSXPathValue $Raw "assays.$assay"
        $expectedCount = if ($assay -eq 'coc') { 20 } else { 25 }
        $expectedStatistics = Get-CSXMetricSummary -Values ([double[]]@($result.times)) -IncludeRate
        $expectedWilson = Get-CSXWilsonInterval -Failures ([int]$result.failedTransitions) -Trials $expectedCount
        $aggregateInvalid = -not (Test-CSXNumberEquals (Get-CSXPropertyValue $evidence 'completed') $expectedCount) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $evidence 'failureCount') $result.failureCount) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $evidence 'diagnosticFailureLowerBound') $result.diagnosticFailureLowerBound) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $evidence 'failedTransitions') $result.failedTransitions) -or
            -not (Test-CSXMetricSummaryIdentity (Get-CSXPropertyValue $evidence 'statistics') $expectedStatistics)
        foreach ($name in @('lower', 'upper', 'confidence')) {
            if (-not (Test-CSXNumberClose (Get-CSXPathValue $evidence "failureWilson95.$name") (Get-CSXPropertyValue $expectedWilson $name))) { $aggregateInvalid = $true }
        }
        $recordedFailureBreakdown = Get-CSXPropertyValue $evidence 'failureBreakdown'
        if ((@(Get-CSXPropertyNames $recordedFailureBreakdown | Sort-Object) -join ',') -ne
            (@(Get-CSXPropertyNames $result.failureBreakdown | Sort-Object) -join ',')) { $aggregateInvalid = $true }
        foreach ($path in @(Get-CSXPropertyNames $result.failureBreakdown)) {
            if (-not (Test-CSXNumberEquals (Get-CSXPropertyValue $recordedFailureBreakdown $path) (Get-CSXPropertyValue $result.failureBreakdown $path))) {
                $aggregateInvalid = $true
            }
        }
        if ($aggregateInvalid -or $result.failureCount -ne 0 -or $result.diagnosticFailureLowerBound -ne 0 -or $result.failedTransitions -ne 0) {
            $errors.Add("$EvidenceLabel $assay core evidence counts, failure aggregates, Wilson interval, or full statistics are inconsistent.")
        }
    }

    $coc = Get-CSXPathValue $Raw 'assays.coc'
    $cocRows = @($recordSets.coc.records)
    $expectedCocStrata = [pscustomobject][ordered]@{
        interior = Get-CSXMetricSummary -Values ([double[]]@($cocRows | Where-Object { [int]$_.ordinal % 2 -eq 1 } | ForEach-Object elapsedMs)) -IncludeRate
        exterior = Get-CSXMetricSummary -Values ([double[]]@($cocRows | Where-Object { [int]$_.ordinal % 2 -eq 0 } | ForEach-Object elapsedMs)) -IncludeRate
    }
    foreach ($name in @('interior', 'exterior')) {
        if (-not (Test-CSXMetricSummaryIdentity (Get-CSXPathValue $coc "strata.$name") (Get-CSXPropertyValue $expectedCocStrata $name))) {
            $errors.Add("$EvidenceLabel COC '$name' stratum does not match the transition records.")
        }
    }
    if ([string](Get-CSXPropertyValue $recordSets.coc.cellFormIds ([string]$Protocol.fixture.startCellEditorId)) -ne
        [string](Get-CSXPropertyValue $recordSets.menu.cellFormIds ([string]$Protocol.fixture.startCellEditorId))) {
        $errors.Add("$EvidenceLabel COC and menu records disagree on the exact exterior cell form ID.")
    }
    $cocValidation = Get-CSXPropertyValue $coc 'validation'
    $cocStretch = Get-CSXPropertyValue $coc 'stretch'
    $cocStress = Get-CSXPropertyValue $coc 'stressTransitions'
    if ((Get-CSXPropertyValue $cocValidation 'scenarioOk') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $cocValidation 'scenarioOk') -or
        -not (Test-CSXExplicitNullProperty $cocValidation 'stretchError') -or
        -not (Test-CSXExplicitNullProperty $cocValidation 'stressRecordError') -or
        (Get-CSXPropertyValue $cocStretch 'recordAccepted') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $cocStretch 'recordAccepted') -or
        -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $cocStretch 'maxFrames')) -or
        [double](Get-CSXPropertyValue $cocStretch 'maxFrames') -gt [double]$Protocol.thresholds.maximumPresentationStretchEpisodeFrames -or
        -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $cocStretch 'meanFrames')) -or
        [double](Get-CSXPropertyValue $cocStretch 'meanFrames') -gt [double]$Protocol.thresholds.maximumMeanPresentationStretchEpisodeFrames -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'requestEvents') 20) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'uniqueRequestEpochs') 20) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'metrics') 20) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'uniqueMetricEpochs') 20) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'coalescedDuplicateCount') 0) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $cocStress 'overwrittenEvents') 0) -or
        (Get-CSXPropertyValue $cocStress 'terminalMetricClear') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $cocStress 'terminalMetricClear')) {
        $errors.Add("$EvidenceLabel COC validation/stress evidence or presentation-stretch gate is invalid.")
    }

    $menu = Get-CSXPathValue $Raw 'assays.menu'
    $menuRows = @($recordSets.menu.records)
    if ([string](Get-CSXPropertyValue $menu 'matrixName') -ne [string](Get-CSXPathValue $Raw 'fixture.matrixName') -or
        -not (Test-CSXStrataIdentity (Get-CSXPropertyValue $menu 'strata') (Get-CSXMenuStrataSummary -Rows $menuRows))) {
        $errors.Add("$EvidenceLabel menu matrix name or full strata do not match the transition records.")
    }
    $menuValidation = Get-CSXPropertyValue $menu 'validation'
    $menuStretch = Get-CSXPropertyValue $menu 'stretch'
    $menuStress = Get-CSXPropertyValue $menu 'stressTransitions'
    $menuBindings = @(Get-CSXPropertyValue $menuStress 'exactMenuCrossBindings' @())
    $bindingInvalid = $menuBindings.Count -ne 25
    for ($ordinal = 1; $ordinal -le 25 -and -not $bindingInvalid; $ordinal++) {
        $binding = @($menuBindings | Where-Object { Test-CSXNumberEquals (Get-CSXPropertyValue $_ 'ordinal') $ordinal })
        $row = $menuRows[$ordinal - 1]
        if ($binding.Count -ne 1 -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $binding[0] 'requestID') (Get-CSXPathValue $row 'receipts.mutation.requestID')) -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $binding[0] 'transitionEpoch') (Get-CSXPathValue $row 'receipts.mutation.transitionEpoch')) -or
            [string](Get-CSXPropertyValue $binding[0] 'method') -ne [string](Get-CSXPropertyValue $row 'method') -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $binding[0] 'qualityMode') (Get-CSXPropertyValue $row 'qualityMode')) -or
            (Get-CSXPropertyValue $binding[0] 'renderScaleMode') -isnot [bool] -or
            [bool](Get-CSXPropertyValue $binding[0] 'renderScaleMode') -ne [bool](Get-CSXPropertyValue $row 'renderScaleMode')) { $bindingInvalid = $true }
    }
    if ((Get-CSXPropertyValue $menuValidation 'scenarioOk') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $menuValidation 'scenarioOk') -or
        -not (Test-CSXExplicitNullProperty $menuValidation 'stretchError') -or
        -not (Test-CSXExplicitNullProperty $menuValidation 'stressRecordError') -or
        (Get-CSXPropertyValue $menuStretch 'recordAccepted') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $menuStretch 'recordAccepted') -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'requestEvents') 25) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'uniqueRequestEpochs') 25) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'metrics') 25) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'uniqueMetricEpochs') 25) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'coalescedDuplicateCount') 0) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $menuStress 'overwrittenEvents') 0) -or
        (Get-CSXPropertyValue $menuStress 'terminalMetricClear') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $menuStress 'terminalMetricClear') -or $bindingInvalid) {
        $errors.Add("$EvidenceLabel menu validation/stress evidence is invalid or not cross-bound to all 25 apply receipts.")
    }

    $gpuVendor = [string](Get-CSXPathValue $Raw 'fixture.gpuVendor')
    $trace = Get-CSXPathValue $menu 'dlssTrace.evidence'
    $traceGroups = @(Get-CSXPropertyValue $trace 'groups' @())
    $expectedTraceOutcome = if ($gpuVendor -eq 'NVIDIA') { 'dispatch_validated' } else { 'capability_lifecycle_only_zero_dispatch' }
    $traceInvalid = (Get-CSXPropertyValue $trace 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $trace 'ok') -or
        @(Get-CSXPropertyValue $trace 'errors' @()).Count -ne 0 -or [string](Get-CSXPathValue $menu 'dlssTrace.outcome') -ne $expectedTraceOutcome
    if ($gpuVendor -eq 'NVIDIA') {
        $expectedOrdinals = @($Protocol.menuAssay.nvidiaMatrix | Where-Object method -eq 'dlss' | ForEach-Object { [int]$_.ordinal })
        if ($traceGroups.Count -ne $expectedOrdinals.Count) { $traceInvalid = $true }
        foreach ($ordinal in $expectedOrdinals) {
            $group = @($traceGroups | Where-Object { Test-CSXNumberEquals (Get-CSXPropertyValue $_ 'ordinal') $ordinal })
            if ($group.Count -ne 1 -or [string](Get-CSXPropertyValue $group[0] 'kind') -ne 'dlss_dispatch' -or
                (Get-CSXPathValue $group[0] 'validation.summary.ok') -isnot [bool] -or -not [bool](Get-CSXPathValue $group[0] 'validation.summary.ok') -or
                (Get-CSXPathValue $group[0] 'validation.records.ok') -isnot [bool] -or -not [bool](Get-CSXPathValue $group[0] 'validation.records.ok') -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $group[0] 'summary.droppedRecords') 0) -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $group[0] 'summary.duplicatedConstantsFailures') 0) -or
                -not (Test-CSXNumberEquals (Get-CSXPathValue $group[0] 'summary.evaluateFailures') 0) -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPathValue $group[0] 'summary.setConstantsCalls')) -or [double](Get-CSXPathValue $group[0] 'summary.setConstantsCalls') -le 0 -or
                -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPathValue $group[0] 'summary.evaluateCalls')) -or [double](Get-CSXPathValue $group[0] 'summary.evaluateCalls') -le 0) { $traceInvalid = $true }
        }
    }
    elseif ($traceGroups.Count -ne 1 -or [string](Get-CSXPropertyValue $traceGroups[0] 'kind') -ne 'capability_only' -or
        (Get-CSXPathValue $traceGroups[0] 'validation.ok') -isnot [bool] -or -not [bool](Get-CSXPathValue $traceGroups[0] 'validation.ok') -or
        -not (Test-CSXNumberEquals (Get-CSXPathValue $traceGroups[0] 'summary.totalRecords') 0) -or
        -not (Test-CSXNumberEquals (Get-CSXPathValue $traceGroups[0] 'summary.setConstantsCalls') 0) -or
        -not (Test-CSXNumberEquals (Get-CSXPathValue $traceGroups[0] 'summary.evaluateCalls') 0)) { $traceInvalid = $true }
    if ($traceInvalid) { $errors.Add("$EvidenceLabel menu DLSS trace evidence is incomplete or internally inconsistent.") }

    foreach ($name in @('one', 'two')) {
        $recovery = Get-CSXPathValue $Raw "recoveries.$name"
        if ([string](Get-CSXPropertyValue $recovery 'state') -ne 'PASS' -or
            -not (Test-CSXNumberEquals (Get-CSXPropertyValue $recovery 'requestedDurationMs') 30000) -or
            -not (Test-CSXFiniteNonNegativeNumber (Get-CSXPropertyValue $recovery 'wallClockMs')) -or
            [double](Get-CSXPropertyValue $recovery 'wallClockMs') -lt [double]$Protocol.timeBudget.recoveryMinimumElapsedMs -or
            [double](Get-CSXPropertyValue $recovery 'wallClockMs') -gt [double]$Protocol.timeBudget.recoveryMaximumElapsedMs -or
            [string](Get-CSXPropertyValue $recovery 'evidence') -notmatch '\S') {
            $errors.Add("$EvidenceLabel recovery barrier '$name' is not a complete 30-second PASS.")
        }
    }

    $visual = Get-CSXPathValue $Raw 'assays.visual'
    $visualRuns = @(Get-CSXPropertyValue $visual 'runs' @())
    $visualObservations = @(Get-CSXPropertyValue $visual 'fixtureObservations' @())
    if ([string](Get-CSXPropertyValue $visual 'state') -ne 'complete' -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $visual 'completedReplicates') 3) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $visual 'requestedFrames') 48) -or
        -not (Test-CSXNumberEquals (Get-CSXPropertyValue $visual 'validatedChildReceipts') 48) -or
        $visualRuns.Count -ne 3 -or (@($visualRuns.replicate | Sort-Object -Unique) -join ',') -ne '1,2,3' -or
        @($visualRuns | Where-Object { [string](Get-CSXPropertyValue $_ 'childReceiptsPath') -notmatch '\S' }).Count -ne 0 -or
        (@(Get-CSXPropertyValue $visual 'reviewOrdinals' @()) -join ',') -ne '1,8,16' -or
        $visualObservations.Count -ne 4 -or @($visualObservations | Where-Object { (Get-CSXPropertyValue $_ 'ok') -isnot [bool] -or -not [bool](Get-CSXPropertyValue $_ 'ok') }).Count -ne 0 -or
        [string](Get-CSXPropertyValue $visual 'indexPath') -ne 'visual-index.json' -or
        -not (Test-CSXSha256Text (Get-CSXPropertyValue $visual 'indexSha256'))) {
        $errors.Add("$EvidenceLabel visual core evidence does not prove three complete replicates, 48 child receipts, and a hash-bound index.")
    }
    return @($errors)
}

function Test-CSXFinalizerEnvelope {
    param([Parameter(Mandatory)][string]$EvidenceRoot, [Parameter(Mandatory)]$Raw, [switch]$SkipBaselineComparison)
    $errors = [Collections.Generic.List[string]]::new()
    $prModeValue = Get-CSXPropertyValue $Raw 'prMode'
    $prMode = $prModeValue -is [bool] -and [bool]$prModeValue
    if ($prModeValue -isnot [bool]) { $errors.Add('Raw prMode must be an explicit boolean.') }
    $expectedRawSchema = if ($prMode) { 'csx-render-scale-pr-v1-raw' } else { 'csx-render-scale-local-v1-raw' }
    if ([string](Get-CSXPropertyValue $Raw 'schema') -ne $expectedRawSchema) {
        $errors.Add("Raw schema does not match prMode; expected '$expectedRawSchema'.")
    }
    if ([string](Get-CSXPropertyValue $Raw 'runId') -notmatch '\S') { $errors.Add('Raw runId is missing.') }

    $candidateBuildId = ([string](Get-CSXPathValue $Raw 'runtime.buildId')).ToLowerInvariant()
    if ($candidateBuildId -notmatch '^[a-f0-9]{64}$') { $errors.Add('Candidate Build ID is not a valid SHA-256 identity.') }

    $protocolRecord = $null
    $protocolPath = Join-Path $EvidenceRoot 'protocol.json'
    if (-not (Test-Path -LiteralPath $protocolPath -PathType Leaf)) {
        $errors.Add('Canonical protocol.json is missing from the evidence directory.')
    }
    else {
        try {
            $protocolRecord = Get-CSXQualificationProtocol -Path $protocolPath
            if ([string](Get-CSXPathValue $Raw 'protocol.schema') -ne 'csx-render-scale-pr-v1' -or
                [int](Get-CSXPathValue $Raw 'protocol.revision' -1) -ne [int]$protocolRecord.protocol.protocolRevision -or
                [string](Get-CSXPathValue $Raw 'protocol.sha256') -ne [string]$protocolRecord.sha256 -or
                [string](Get-CSXPathValue $Raw 'protocol.requiredMethodsCommit') -ne [string]$protocolRecord.protocol.requiredMethodsCommit) {
                $errors.Add('Raw protocol identity does not match the canonical protocol.json.')
            }
            if ([string](Get-CSXPathValue $Raw 'protocol.requiredMethodsCommit') -ne 'b46edeaed14c41ad41225641c3a4943f1db25db6' -or
                -not (Test-CSXSha256Text (Get-CSXPathValue $Raw 'protocol.sha256'))) {
                $errors.Add('Raw protocol does not bind the canonical protocol and its required methods commit.')
            }
        }
        catch { $errors.Add("Canonical protocol validation failed: $($_.Exception.Message)") }
    }

    $fixture = Get-CSXPropertyValue $Raw 'fixture'
    $fixtureInputs = Get-CSXPropertyValue $fixture 'inputs'
    $fixtureManifest = Get-CSXPropertyValue $fixture 'manifest'
    $fixtureFingerprint = [string](Get-CSXPropertyValue $fixture 'fingerprint')
    if ($null -eq $fixtureInputs -or $null -eq $fixtureManifest) {
        $errors.Add('Raw fixture inputs or manifest identity are missing.')
    }
    else {
        if (-not (Test-CSXSha256Text $fixtureFingerprint) -or
            (Get-CSXObjectSha256 -Value $fixtureInputs) -ne $fixtureFingerprint.ToLowerInvariant()) {
            $errors.Add('Raw fixture fingerprint is missing or does not hash the recorded fixture inputs.')
        }
        if ([string](Get-CSXPropertyValue $fixtureManifest 'schema') -ne 'csx-render-scale-fixture-v1' -or
            [string](Get-CSXPathValue $fixtureInputs 'fixtureManifest.schema') -ne 'csx-render-scale-fixture-v1') {
            $errors.Add('Raw fixture does not bind fixture-manifest schema v1.')
        }
        if ([string](Get-CSXPathValue $fixtureInputs 'protocolSha256') -ne [string](Get-CSXPathValue $Raw 'protocol.sha256')) {
            $errors.Add('Raw fixture inputs do not bind the candidate protocol SHA-256.')
        }
        if (($fixtureManifest | ConvertTo-Json -Depth 100 -Compress) -ne
            ((Get-CSXPathValue $fixtureInputs 'fixtureManifest') | ConvertTo-Json -Depth 100 -Compress)) {
            $errors.Add('Raw fixture manifest identity differs between the summary and fingerprinted inputs.')
        }
        $gpuVendor = [string](Get-CSXPropertyValue $fixture 'gpuVendor')
        $expectedMatrix = if ($gpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } elseif ($gpuVendor -eq 'AMD') { 'amdMatrix' } else { $null }
        if ($null -eq $expectedMatrix -or [string](Get-CSXPropertyValue $fixture 'matrixName') -ne $expectedMatrix -or
            [string](Get-CSXPathValue $fixtureInputs 'gpuVendor') -ne $gpuVendor -or
            [string](Get-CSXPathValue $fixtureInputs 'matrixName') -ne $expectedMatrix) {
            $errors.Add('Raw fixture GPU vendor and matrix identity are inconsistent.')
        }
        try {
            $manifestPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $fixtureManifest 'path'))
            $manifestRecord = Get-CSXFixtureManifest -Path $manifestPath -GpuVendor $gpuVendor
            if ([string]$manifestRecord.sha256 -ne [string](Get-CSXPropertyValue $fixtureManifest 'sha256') -or
                [string]$manifestRecord.manifest.fixtureId -ne [string](Get-CSXPropertyValue $fixtureManifest 'fixtureId') -or
                ($manifestRecord.manifest | ConvertTo-Json -Depth 100 -Compress) -ne
                    ((Get-CSXPropertyValue $fixtureManifest 'identity') | ConvertTo-Json -Depth 100 -Compress)) {
                $errors.Add('Copied fixture manifest does not match its hash-bound raw identity.')
            }
        }
        catch { $errors.Add("Copied fixture manifest validation failed: $($_.Exception.Message)") }
    }

    $automatedPassed = Get-CSXPathValue $Raw 'automatedGates.passed'
    if ($automatedPassed -isnot [bool] -or -not [bool]$automatedPassed) { $errors.Add('Automated gates are not explicitly passed.') }
    if (@(Get-CSXPathValue $Raw 'automatedGates.failures' @()).Count -ne 0) { $errors.Add('Automated gate failures are present.') }
    $withinBudget = Get-CSXPathValue $Raw 'time.within600Seconds'
    $deadlineAfterBinding = Get-CSXPathValue $Raw 'time.deadlineStartsAfterRuntimeBinding'
    $captureAssaysMs = Get-CSXPathValue $Raw 'time.captureAssaysElapsedMs'
    $visualEvaluationMs = Get-CSXPathValue $Raw 'time.visualEvaluationElapsedMs'
    $orchestrationMs = Get-CSXPathValue $Raw 'time.orchestrationElapsedMs'
    $performanceMs = Get-CSXPathValue $Raw 'time.performanceElapsedMs'
    try {
        Assert-CSXExactObjectProperties -Value (Get-CSXPropertyValue $Raw 'time') -Expected @(
            'deadlineStartsAfterRuntimeBinding', 'captureAssaysElapsedMs', 'visualEvaluationElapsedMs',
            'orchestrationElapsedMs', 'performanceElapsedMs', 'within600Seconds'
        ) -Label 'Raw time evidence'
    }
    catch { $errors.Add($_.Exception.Message) }
    if ($deadlineAfterBinding -isnot [bool] -or -not [bool]$deadlineAfterBinding -or
        $withinBudget -isnot [bool] -or -not [bool]$withinBudget -or
        -not (Test-CSXFiniteNonNegativeNumber $captureAssaysMs) -or [double]$captureAssaysMs -gt 495000 -or
        -not (Test-CSXFiniteNonNegativeNumber $visualEvaluationMs) -or [double]$visualEvaluationMs -gt 90000 -or
        -not (Test-CSXFiniteNonNegativeNumber $orchestrationMs) -or [double]$orchestrationMs -gt 585000 -or
        -not (Test-CSXFiniteNonNegativeNumber $performanceMs) -or
        -not (Test-CSXNumberClose $performanceMs $captureAssaysMs) -or
        [double]$orchestrationMs + 5.0 -lt [double]$captureAssaysMs + [double]$visualEvaluationMs) {
        $errors.Add('Raw timing does not prove capture <=495 seconds, vision <=90 seconds, and orchestration <=585 seconds within the 600-second package cap.')
    }
    if ($null -ne $protocolRecord) {
        try {
            foreach ($error in @(Test-CSXCoreQualificationEvidence -Raw $Raw -Protocol $protocolRecord.protocol)) { $errors.Add([string]$error) }
        }
        catch { $errors.Add("Candidate core evidence validation failed: $($_.Exception.Message)") }
        try {
            $producerEvidence = Test-CSXProducerArtifactEvidence -EvidenceRoot $EvidenceRoot -Raw $Raw -Protocol $protocolRecord.protocol
            foreach ($error in $producerEvidence.errors) { $errors.Add([string]$error) }
        }
        catch { $errors.Add("Candidate producer evidence validation failed: $($_.Exception.Message)") }
    }
    try {
        $artifactInventory = Test-CSXAutomationArtifactInventory -EvidenceRoot $EvidenceRoot -Raw $Raw
        foreach ($error in $artifactInventory.errors) { $errors.Add([string]$error) }
    }
    catch { $errors.Add("Candidate automation artifact inventory validation failed: $($_.Exception.Message)") }

    $baseline = Get-CSXPropertyValue $Raw 'baseline'
    if ($SkipBaselineComparison) {
        # A baseline export validates its own immutable candidate evidence without recursively requiring its historical comparison bundle.
    }
    elseif (-not $prMode) {
        if ($null -ne $baseline) { $errors.Add('Local qualification raw evidence must have a null baseline.') }
    }
    elseif ($null -eq $baseline) {
        $errors.Add('PR qualification raw evidence is missing its bundled baseline metadata.')
    }
    else {
        $baselineRun = $null
        $baselineRunPath = $null
        $baselineIndexPath = $null
        $baselineRaw = $null
        $baselineReview = $null
        $baselineRoot = $null
        try {
            $baselineRunPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $baseline 'path'))
            if (-not (Test-Path -LiteralPath $baselineRunPath -PathType Leaf)) { throw 'Bundled baseline run is missing.' }
            $actualRunHash = Get-CSXFileSha256 $baselineRunPath
            if (-not (Test-CSXSha256Text (Get-CSXPropertyValue $baseline 'runSha256')) -or
                $actualRunHash -ne [string](Get-CSXPropertyValue $baseline 'runSha256')) {
                $errors.Add('Bundled baseline run SHA-256 does not match its metadata.')
            }
            $baselineRun = Get-Content -LiteralPath $baselineRunPath -Raw | ConvertFrom-Json -Depth 100
        }
        catch { $errors.Add("Bundled baseline run validation failed: $($_.Exception.Message)") }

        try {
            $baselineIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $baseline 'visualIndexPath'))
            if (-not (Test-Path -LiteralPath $baselineIndexPath -PathType Leaf)) { throw 'Bundled baseline visual index is missing.' }
            $actualIndexHash = Get-CSXFileSha256 $baselineIndexPath
            if (-not (Test-CSXSha256Text (Get-CSXPropertyValue $baseline 'visualIndexSha256')) -or
                $actualIndexHash -ne [string](Get-CSXPropertyValue $baseline 'visualIndexSha256')) {
                $errors.Add('Bundled baseline visual-index SHA-256 does not match its metadata.')
            }
            $baselineIndex = Get-Content -LiteralPath $baselineIndexPath -Raw | ConvertFrom-Json -Depth 100
            Assert-CSXVisualIndexSet -VisualIndex $baselineIndex -Label 'Baseline' -ExpectedRunId ([string](Get-CSXPropertyValue $baseline 'baselineRunId'))
        }
        catch { $errors.Add("Bundled baseline visual-index validation failed: $($_.Exception.Message)") }

        try {
            $baselineRawPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $baseline 'rawPath'))
            $baselineReviewPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $baseline 'visualReviewPath'))
            $baselineInventoryPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceRoot -RelativePath ([string](Get-CSXPropertyValue $baseline 'artifactInventoryPath'))
            $baselineRoot = Split-Path -Parent $baselineRunPath
            foreach ($path in @($baselineRawPath, $baselineReviewPath, $baselineInventoryPath, $baselineIndexPath)) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                    -not [string]::Equals((Split-Path -Parent $path), $baselineRoot, [StringComparison]::OrdinalIgnoreCase) -and
                    -not $path.StartsWith(($baselineRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Bundled baseline companion is missing or outside its exact bundle root: $path"
                }
            }
            foreach ($bindingSpec in @(
                [pscustomobject]@{ path = $baselineRawPath; hash = Get-CSXPropertyValue $baseline 'rawSha256'; label = 'run.raw' },
                [pscustomobject]@{ path = $baselineReviewPath; hash = Get-CSXPropertyValue $baseline 'visualReviewSha256'; label = 'visual review' },
                [pscustomobject]@{ path = $baselineInventoryPath; hash = Get-CSXPropertyValue $baseline 'artifactInventorySha256'; label = 'artifact inventory' }
            )) {
                if (-not (Test-CSXSha256Text $bindingSpec.hash) -or (Get-CSXFileSha256 $bindingSpec.path) -ne [string]$bindingSpec.hash) {
                    throw "Bundled baseline $($bindingSpec.label) SHA-256 does not match its candidate metadata."
                }
            }
            $baselineRaw = Get-Content -LiteralPath $baselineRawPath -Raw | ConvertFrom-Json -Depth 100
            $baselineReview = Get-Content -LiteralPath $baselineReviewPath -Raw | ConvertFrom-Json -Depth 100
            $baselineInventory = Get-Content -LiteralPath $baselineInventoryPath -Raw | ConvertFrom-Json -Depth 100
            if (@($baselineInventory.entries).Count -ne [int](Get-CSXPropertyValue $baseline 'artifactInventoryEntryCount') -or
                -not (Test-CSXJsonIdentity (Get-CSXPropertyValue $baselineRaw 'artifactInventory') ([pscustomobject][ordered]@{
                    schema = 'csx-render-scale-automation-artifacts-v1'; path = 'automation-artifacts.json'
                    sha256 = [string](Get-CSXPropertyValue $baseline 'artifactInventorySha256'); entryCount = @($baselineInventory.entries).Count
                }))) {
                throw 'Bundled baseline raw/inventory companion binding is invalid.'
            }
            $baselineEnvelope = Test-CSXFinalizerEnvelope -EvidenceRoot $baselineRoot -Raw $baselineRaw -SkipBaselineComparison
            if (-not $baselineEnvelope.ok) { throw "Bundled baseline raw envelope is invalid: $($baselineEnvelope.errors -join ' ')" }
            if ($null -eq $baselineIndexPath) { throw 'Bundled baseline visual index was not loaded.' }
            $baselineIndexForArtifacts = Get-Content -LiteralPath $baselineIndexPath -Raw | ConvertFrom-Json -Depth 100
            $baselineVisualArtifacts = Test-CSXVisualArtifactEvidence -EvidenceRoot $baselineRoot -Raw $baselineRaw -VisualIndex $baselineIndexForArtifacts
            if (-not $baselineVisualArtifacts.ok) { throw "Bundled baseline visual artifact envelope is invalid: $($baselineVisualArtifacts.errors -join ' ')" }
            $baselineReviewResult = Test-CSXFlattenedBaselineVisualReview -EvidenceDirectory $baselineRoot -RunRaw $baselineRaw -VisualIndex $baselineIndexForArtifacts -Review $baselineReview
            if (-not $baselineReviewResult.ok) { throw "Bundled baseline visual review snapshot is invalid: $($baselineReviewResult.errors -join ' ')" }
            foreach ($name in @('runId', 'prMode', 'protocol', 'fixture', 'runtime', 'time', 'assays', 'recoveries', 'baseline', 'artifactInventory', 'automatedGates')) {
                if (-not (Test-CSXJsonIdentity (Get-CSXPropertyValue $baselineRun $name) (Get-CSXPropertyValue $baselineRaw $name))) {
                    throw "Bundled baseline final projection '$name' differs from run.raw."
                }
            }
            if ([string](Get-CSXPathValue $baselineRun 'visualReview.state') -ne 'PASS' -or
                -not (Test-CSXJsonIdentity (Get-CSXPathValue $baselineRun 'visualReview.result') $baselineReviewResult)) {
                throw 'Bundled baseline final visual-review result differs from its validated snapshot.'
            }
        }
        catch { $errors.Add("Bundled baseline raw/review/artifact validation failed: $($_.Exception.Message)") }

        if ($null -ne $baselineRun) {
            $baselineBuildId = ([string](Get-CSXPathValue $baselineRun 'runtime.buildId')).ToLowerInvariant()
            $metadataBuildId = ([string](Get-CSXPropertyValue $baseline 'baselineBuildId')).ToLowerInvariant()
            $expectedBuildId = ([string](Get-CSXPropertyValue $baseline 'expectedBaselineBuildId')).ToLowerInvariant()
            $baselinePrMode = Get-CSXPropertyValue $baselineRun 'prMode'
            $isPrBaseline = [string](Get-CSXPropertyValue $baselineRun 'schema') -eq 'csx-render-scale-pr-v1' -and
                [string](Get-CSXPropertyValue $baselineRun 'status') -eq 'PASS' -and $baselinePrMode -is [bool] -and [bool]$baselinePrMode
            $isLocalBootstrap = [string](Get-CSXPropertyValue $baselineRun 'schema') -eq 'csx-render-scale-local-v1' -and
                [string](Get-CSXPropertyValue $baselineRun 'status') -eq 'LOCAL_PASS' -and $baselinePrMode -is [bool] -and -not [bool]$baselinePrMode
            if ((-not $isPrBaseline -and -not $isLocalBootstrap) -or
                [string](Get-CSXPropertyValue $baselineRun 'runId') -ne [string](Get-CSXPropertyValue $baseline 'baselineRunId')) {
                $errors.Add('Bundled baseline is not an identity-matched finalized PASS or LOCAL_PASS qualification.')
            }
            if (-not (Test-CSXSha256Text $baselineBuildId) -or $baselineBuildId -ne $metadataBuildId -or
                $baselineBuildId -ne $expectedBuildId -or $baselineBuildId -eq $candidateBuildId) {
                $errors.Add('Bundled baseline Build ID metadata is invalid, mismatched, or self-comparing.')
            }
            if ([string](Get-CSXPropertyValue $baseline 'candidateRunId') -ne [string](Get-CSXPropertyValue $Raw 'runId')) {
                $errors.Add('Bundled baseline metadata is bound to a different candidate run.')
            }
            foreach ($path in @('schema', 'revision', 'sha256', 'requiredMethodsCommit')) {
                if ([string](Get-CSXPathValue $baselineRun "protocol.$path") -ne [string](Get-CSXPathValue $Raw "protocol.$path")) {
                    $errors.Add("Bundled baseline protocol '$path' differs from the candidate.")
                }
            }
            if (((Get-CSXPropertyValue $baselineRun 'fixture') | ConvertTo-Json -Depth 100 -Compress) -ne ($fixture | ConvertTo-Json -Depth 100 -Compress) -or
                [string](Get-CSXPathValue $baselineRun 'fixture.fingerprint') -ne $fixtureFingerprint -or
                [string](Get-CSXPathValue $baselineRun 'fixture.manifest.schema') -ne 'csx-render-scale-fixture-v1') {
                $errors.Add('Bundled baseline fixture identity differs from the candidate.')
            }
            if ((Get-CSXPathValue $baselineRun 'automatedGates.passed') -isnot [bool] -or
                -not [bool](Get-CSXPathValue $baselineRun 'automatedGates.passed') -or
                @(Get-CSXPathValue $baselineRun 'automatedGates.failures' @()).Count -ne 0 -or
                @(Get-CSXPathValue $baselineRun 'automatedGates.infrastructureErrors' @()).Count -ne 0 -or
                @(Get-CSXPropertyValue $baselineRun 'errors' @()).Count -ne 0 -or
                @(Get-CSXPropertyValue $baselineRun 'infrastructureErrors' @()).Count -ne 0 -or
                [string](Get-CSXPathValue $baselineRun 'visualReview.state') -ne 'PASS') {
                $errors.Add('Bundled baseline does not preserve passed automated and visual gates.')
            }
            $baselineDeadlineAfterBinding = Get-CSXPathValue $baselineRun 'time.deadlineStartsAfterRuntimeBinding'
            $baselineWithinBudget = Get-CSXPathValue $baselineRun 'time.within600Seconds'
            $baselineCaptureAssaysMs = Get-CSXPathValue $baselineRun 'time.captureAssaysElapsedMs'
            $baselineVisualEvaluationMs = Get-CSXPathValue $baselineRun 'time.visualEvaluationElapsedMs'
            $baselineOrchestrationMs = Get-CSXPathValue $baselineRun 'time.orchestrationElapsedMs'
            $baselinePerformanceMs = Get-CSXPathValue $baselineRun 'time.performanceElapsedMs'
            try {
                Assert-CSXExactObjectProperties -Value (Get-CSXPropertyValue $baselineRun 'time') -Expected @(
                    'deadlineStartsAfterRuntimeBinding', 'captureAssaysElapsedMs', 'visualEvaluationElapsedMs',
                    'orchestrationElapsedMs', 'performanceElapsedMs', 'within600Seconds'
                ) -Label 'Bundled baseline time evidence'
            }
            catch { $errors.Add($_.Exception.Message) }
            if ($baselineDeadlineAfterBinding -isnot [bool] -or -not [bool]$baselineDeadlineAfterBinding -or
                $baselineWithinBudget -isnot [bool] -or -not [bool]$baselineWithinBudget -or
                -not (Test-CSXFiniteNonNegativeNumber $baselineCaptureAssaysMs) -or [double]$baselineCaptureAssaysMs -gt 495000 -or
                -not (Test-CSXFiniteNonNegativeNumber $baselineVisualEvaluationMs) -or [double]$baselineVisualEvaluationMs -gt 90000 -or
                -not (Test-CSXFiniteNonNegativeNumber $baselineOrchestrationMs) -or [double]$baselineOrchestrationMs -gt 585000 -or
                -not (Test-CSXFiniteNonNegativeNumber $baselinePerformanceMs) -or
                -not (Test-CSXNumberClose $baselinePerformanceMs $baselineCaptureAssaysMs) -or
                [double]$baselineOrchestrationMs + 5.0 -lt [double]$baselineCaptureAssaysMs + [double]$baselineVisualEvaluationMs) {
                $errors.Add('Bundled baseline timing does not prove capture <=495 seconds, vision <=90 seconds, and orchestration <=585 seconds.')
            }
            if ($null -ne $protocolRecord) {
                try {
                    foreach ($error in @(Test-CSXCoreQualificationEvidence -Raw $baselineRun -Protocol $protocolRecord.protocol -EvidenceLabel 'Bundled baseline')) {
                        $errors.Add([string]$error)
                    }
                }
                catch { $errors.Add("Bundled baseline core evidence validation failed: $($_.Exception.Message)") }
            }
            if ($null -ne $baselineIndexPath) {
                try {
                    $baselineRunRoot = Split-Path -Parent $baselineRunPath
                    $runIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $baselineRunRoot -RelativePath ([string](Get-CSXPathValue $baselineRun 'assays.visual.indexPath'))
                    if (-not [string]::Equals($runIndexPath, $baselineIndexPath, [StringComparison]::OrdinalIgnoreCase) -or
                        (Get-CSXFileSha256 $runIndexPath) -ne [string](Get-CSXPathValue $baselineRun 'assays.visual.indexSha256')) {
                        $errors.Add('Bundled baseline run does not bind the bundled visual index.')
                    }
                }
                catch { $errors.Add("Bundled baseline run visual-index binding failed: $($_.Exception.Message)") }
            }
            if ($null -ne $protocolRecord) {
                try {
                    $cocComparison = Get-CSXPairedComparison -Candidate @($Raw.assays.coc.records) -Baseline @($baselineRun.assays.coc.records)
                    $menuComparison = Get-CSXPairedComparison -Candidate @($Raw.assays.menu.records) -Baseline @($baselineRun.assays.menu.records)
                    if (-not (Test-CSXPairedCriticalIdentity (Get-CSXPropertyValue $baseline 'cocPaired') $cocComparison) -or
                        -not (Test-CSXPairedCriticalIdentity (Get-CSXPropertyValue $baseline 'menuPaired') $menuComparison)) {
                        $errors.Add('PR baseline paired performance evidence does not match the candidate and baseline transition records.')
                    }
                    $cocSpeedGate = [double]$cocComparison.aggregateDelta.median.percent -le [double]$protocolRecord.protocol.thresholds.cocMedianRegressionPercent -and
                        [double]$cocComparison.aggregateDelta.p95.percent -le [double]$protocolRecord.protocol.thresholds.cocP95RegressionPercent
                    $menuSpeedGate = [double]$menuComparison.aggregateDelta.median.percent -le [double]$protocolRecord.protocol.thresholds.menuMedianRegressionPercent -and
                        [double]$menuComparison.aggregateDelta.p95.percent -le [double]$protocolRecord.protocol.thresholds.menuP95RegressionPercent
                    $recordedCocGate = Get-CSXPathValue $baseline 'gates.cocAggregateMedianP95'
                    $recordedMenuGate = Get-CSXPathValue $baseline 'gates.menuAggregateMedianP95'
                    if ($recordedCocGate -isnot [bool] -or [bool]$recordedCocGate -ne $cocSpeedGate -or -not $cocSpeedGate -or
                        $recordedMenuGate -isnot [bool] -or [bool]$recordedMenuGate -ne $menuSpeedGate -or -not $menuSpeedGate) {
                        $errors.Add('PR baseline performance comparison gates are not recomputed, identity-matched passes.')
                    }
                }
                catch { $errors.Add("PR baseline performance comparison validation failed: $($_.Exception.Message)") }
            }
        }
    }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; prMode = $prMode; errors = @($errors | Select-Object -Unique) }
}

function Update-CSXQualificationReport {
    param([Parameter(Mandatory)][string]$EvidenceDirectory)
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    $rawPath = Join-Path $root 'run.raw.json'
    $indexPath = Join-Path $root 'visual-index.json'
    if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf) -or -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'run.raw.json and visual-index.json are required.' }
    $raw = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json -Depth 100
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 100
    $errors = [Collections.Generic.List[string]]::new()
    $infrastructureErrors = [Collections.Generic.List[string]]::new()
    $envelope = Test-CSXFinalizerEnvelope -EvidenceRoot $root -Raw $raw
    foreach ($error in $envelope.errors) { $errors.Add([string]$error) }
    $prMode = [bool]$envelope.prMode
    try {
        Assert-CSXVisualIndexSet -VisualIndex $index -Label 'Candidate' -ExpectedRunId ([string]$raw.runId)
        if ((Get-CSXFileSha256 $indexPath) -ne [string](Get-CSXPathValue $raw 'assays.visual.indexSha256')) { $errors.Add('Candidate visual-index SHA-256 binding does not match.') }
    }
    catch { $errors.Add($_.Exception.Message) }
    try {
        $visualArtifacts = Test-CSXVisualArtifactEvidence -EvidenceRoot $root -Raw $raw -VisualIndex $index
        foreach ($error in $visualArtifacts.errors) { $errors.Add([string]$error) }
    }
    catch { $errors.Add("Candidate visual artifact validation failed: $($_.Exception.Message)") }
    foreach ($failure in @(Get-CSXPathValue $raw 'automatedGates.failures' @())) { $errors.Add([string]$failure) }
    foreach ($failure in @(Get-CSXPathValue $raw 'automatedGates.infrastructureErrors' @())) { $infrastructureErrors.Add([string]$failure) }
    $reviewState = 'FAIL'
    $reviewResult = $null
    $reviewPath = Join-Path $root 'visual-review.json'
    if (Test-Path -LiteralPath $reviewPath -PathType Leaf) {
        try {
            $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json -Depth 100
            $baselineIndex = $null
            if ($prMode) {
                $baselineIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath ([string]$raw.baseline.visualIndexPath)
                if (-not (Test-Path -LiteralPath $baselineIndexPath -PathType Leaf)) { throw "Baseline visual index is missing: $baselineIndexPath" }
                $baselineIndex = Get-Content -LiteralPath $baselineIndexPath -Raw | ConvertFrom-Json -Depth 100
                Assert-CSXVisualIndexSet -VisualIndex $baselineIndex -Label 'Baseline' -ExpectedRunId ([string]$raw.baseline.baselineRunId)
                if ((Get-CSXFileSha256 $baselineIndexPath) -ne [string]$raw.baseline.visualIndexSha256) { throw 'Bundled baseline visual-index SHA-256 changed.' }
            }
            $reviewResult = Test-CSXVisualReview -EvidenceDirectory $root -RunRaw $raw -VisualIndex $index -Review $review -BaselineVisualIndex $baselineIndex
            if ($reviewResult.ok) { $reviewState = 'PASS' }
            else {
                if ((Get-CSXPropertyValue $reviewResult 'integrityOk') -isnot [bool] -or
                    -not [bool](Get-CSXPropertyValue $reviewResult 'integrityOk')) {
                    foreach ($error in @(Get-CSXPropertyValue $reviewResult 'integrityErrors' @())) {
                        $infrastructureErrors.Add([string]$error)
                    }
                    if (@(Get-CSXPropertyValue $reviewResult 'integrityErrors' @()).Count -eq 0) {
                        foreach ($error in $reviewResult.errors) { $infrastructureErrors.Add([string]$error) }
                    }
                    foreach ($error in @(Get-CSXPropertyValue $reviewResult 'qualityErrors' @())) { $errors.Add([string]$error) }
                }
                else { foreach ($error in $reviewResult.errors) { $errors.Add([string]$error) } }
                $reviewState = 'FAIL'
            }
        }
        catch { $infrastructureErrors.Add("Visual review validation failed: $($_.Exception.Message)"); $reviewState = 'FAIL' }
    }
    else {
        $infrastructureErrors.Add('Protocol revision 4 requires the same-run automated image-model visual review; no review file was produced.')
    }
    $status = if ($infrastructureErrors.Count -gt 0) {
        'INFRASTRUCTURE_ERROR'
    }
    elseif ($errors.Count -gt 0) { 'FAIL' }
    elseif ($reviewState -eq 'PASS') { $(if ($prMode) { 'PASS' } else { 'LOCAL_PASS' }) }
    else { 'FAIL' }
    $report = [pscustomobject][ordered]@{
        schema = $(if ($prMode) { 'csx-render-scale-pr-v1' } else { 'csx-render-scale-local-v1' }); status = $status; runId = $raw.runId
        generatedUtc = [DateTime]::UtcNow.ToString('o'); prMode = $prMode
        protocol = $raw.protocol; fixture = $raw.fixture; runtime = $raw.runtime
        time = $raw.time; assays = $raw.assays; recoveries = Get-CSXPropertyValue $raw 'recoveries'; baseline = $raw.baseline
        artifactInventory = Get-CSXPropertyValue $raw 'artifactInventory'
        automatedGates = $raw.automatedGates
        visualReview = [pscustomobject][ordered]@{ state = $reviewState; result = $reviewResult; path = $(if (Test-Path -LiteralPath $reviewPath) { $reviewPath } else { $null }) }
        warnings = @($raw.warnings); errors = @(@($errors) + @($infrastructureErrors) | Select-Object -Unique); infrastructureErrors = @($infrastructureErrors | Select-Object -Unique)
        evidenceDirectory = $root
    }
    $runPath = Write-CSXJsonFile -Path (Join-Path $root 'run.json') -Value $report
    Write-CSXJsonFile -Path (Join-Path $root 'failures.json') -Value ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-qualification-failures-v1'
        runId = $raw.runId
        status = $status
        errors = @($errors | Select-Object -Unique)
        infrastructureErrors = @($infrastructureErrors | Select-Object -Unique)
        warnings = @($raw.warnings)
    }) | Out-Null
    $cocCompleted = Get-CSXPathValue $raw 'assays.coc.completed' 0
    $cocMedian = Get-CSXPathValue $raw 'assays.coc.statistics.median'
    $cocP95 = Get-CSXPathValue $raw 'assays.coc.statistics.p95'
    $cocMax = Get-CSXPathValue $raw 'assays.coc.statistics.max'
    $cocFailures = Get-CSXPathValue $raw 'assays.coc.failureCount' 0
    $cocWilsonLower = Get-CSXPathValue $raw 'assays.coc.failureWilson95.lower'
    $cocWilsonUpper = Get-CSXPathValue $raw 'assays.coc.failureWilson95.upper'
    $stretchMeanFrames = Get-CSXPathValue $raw 'assays.coc.stretch.meanFrames'
    $stretchMeanMs = Get-CSXPathValue $raw 'assays.coc.stretch.meanMs'
    $stretchMaxFrames = Get-CSXPathValue $raw 'assays.coc.stretch.maxFrames'
    $stretchMaxMs = Get-CSXPathValue $raw 'assays.coc.stretch.maxMs'
    $menuName = Get-CSXPathValue $raw 'assays.menu.matrixName' 'not-run'
    $menuCompleted = Get-CSXPathValue $raw 'assays.menu.completed' 0
    $menuMedian = Get-CSXPathValue $raw 'assays.menu.statistics.median'
    $menuP95 = Get-CSXPathValue $raw 'assays.menu.statistics.p95'
    $traceOutcome = Get-CSXPathValue $raw 'assays.menu.dlssTrace.outcome' 'not-run'
    $visualCompleted = Get-CSXPathValue $raw 'assays.visual.completedReplicates' 0
    $cocStats = Get-CSXPathValue $raw 'assays.coc.statistics'
    $menuStats = Get-CSXPathValue $raw 'assays.menu.statistics'
    $baselineBuild = Get-CSXPathValue $raw 'baseline.baselineBuildId' 'not applicable'
    $baselineRun = Get-CSXPathValue $raw 'baseline.baselineRunId' 'not applicable'
    $fixtureId = Get-CSXPathValue $raw 'fixture.manifest.fixtureId' 'unknown'
    $fixtureFingerprint = Get-CSXPathValue $raw 'fixture.fingerprint' 'unknown'
    $liveGpuDevice = Get-CSXPathValue $raw 'fixture.inputs.verification.liveGpu.deviceId' 'unknown'
    $liveGpuDriver = Get-CSXPathValue $raw 'fixture.inputs.verification.liveGpu.driverVersion' 'unknown'
    $fixtureOperator = Get-CSXPathValue $raw 'fixture.inputs.verification.operatorAttestation.operatorId' 'unknown'
    $fixtureAttestedUtc = Get-CSXPathValue $raw 'fixture.inputs.verification.operatorAttestation.recordedUtc' 'unknown'
    $recoveryOne = Get-CSXPathValue $raw 'recoveries.one.state' 'not-run'
    $recoveryTwo = Get-CSXPathValue $raw 'recoveries.two.state' 'not-run'
    $recoveryOneWall = Get-CSXPathValue $raw 'recoveries.one.wallClockMs' 'not-run'
    $recoveryTwoWall = Get-CSXPathValue $raw 'recoveries.two.wallClockMs' 'not-run'
    $traceGroups = @(Get-CSXPathValue $raw 'assays.menu.dlssTrace.evidence.groups' @())
    $traceSetConstants = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'setConstantsCalls' 0) } | Measure-Object -Sum).Sum)
    $traceEvaluates = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'evaluateCalls' 0) } | Measure-Object -Sum).Sum)
    $traceDropped = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'droppedRecords' 0) } | Measure-Object -Sum).Sum)
    $cocDelta = Get-CSXPathValue $raw 'baseline.cocPaired.aggregateDelta'
    $menuDelta = Get-CSXPathValue $raw 'baseline.menuPaired.aggregateDelta'
    $cocPublication = Get-CSXPathValue $raw 'assays.coc.resourcePublication'
    $menuPublication = Get-CSXPathValue $raw 'assays.menu.resourcePublication'
    $publicationLine = "- Resource publication: COC current $((Get-CSXPropertyValue $cocPublication 'currentSamples' 0))/$((Get-CSXPropertyValue $cocPublication 'availableSamples' 0)); menu current $((Get-CSXPropertyValue $menuPublication 'currentSamples' 0))/$((Get-CSXPropertyValue $menuPublication 'availableSamples' 0)). Per-transition generation, dimension, completion, deferred-setup, and D3D identity fields are retained in transitions.json/CSV."
    $cocPreparation = Get-CSXPathValue $raw 'assays.coc.preparation'
    $menuPreparation = Get-CSXPathValue $raw 'assays.menu.preparation'
    $visualPreparation = Get-CSXPathValue $raw 'assays.visual.preparation'
    $preparationLine = "- Preparation telemetry: COC $((Get-CSXPropertyValue $cocPreparation 'eventCount' 0)) events; menu $((Get-CSXPropertyValue $menuPreparation 'eventCount' 0)) events; visual $((Get-CSXPropertyValue $visualPreparation 'eventCount' 0)) events. Raw transition-filtered stage records are retained in transitions.json and preparation-events.csv; the visual session trace is retained with its assay."
    $speedLine = if ($prMode) {
        $cocMedianDelta = Get-CSXPathValue $cocDelta 'median.percent' 'unavailable'
        $cocP95Delta = Get-CSXPathValue $cocDelta 'p95.percent' 'unavailable'
        $menuMedianDelta = Get-CSXPathValue $menuDelta 'median.percent' 'unavailable'
        $menuP95Delta = Get-CSXPathValue $menuDelta 'p95.percent' 'unavailable'
        "- Speed vs baseline: COC median $cocMedianDelta%, p95 $cocP95Delta%; menu median $menuMedianDelta%, p95 $menuP95Delta%."
    }
    else { '- Speed vs baseline: not applicable (standalone run).' }
    $visualQualityLine = if ($reviewState -eq 'PASS') {
        '- Visual quality: all 9 checkpoints (3 replicates x frames 1/8/16) passed sharpness, blur, shimmer, stereo alignment, equal-eye scale, geometry correspondence, and render-scale latch.'
    }
    else { "- Visual quality: $reviewState; all nine checkpoints and seven quality categories have not passed." }
    $markdown = @(
        '## Render-scale qualification', '',
        "- Protocol: csx-render-scale-pr-v1 revision $($raw.protocol.revision), SHA-256 $($raw.protocol.sha256).",
        "- Required DLSS trace methods: commit $(Get-CSXPathValue $raw 'protocol.requiredMethodsCommit' 'unknown'); dlss_trace_status, dlss_trace_reset, dlss_trace_start, dlss_trace_stop, dlss_trace_read.",
        "- Result: **$status**; GPU matrix: $(Get-CSXPathValue $raw 'fixture.gpuVendor' 'unknown') / $menuName.",
        "- Candidate build: $($raw.runtime.buildId); baseline build/run: $baselineBuild / $baselineRun.",
        "- Fixture: $fixtureId; fingerprint $fixtureFingerprint.",
        "- Live GPU: $liveGpuDevice; driver $liveGpuDriver. Operator-attested fixture: $fixtureOperator at $fixtureAttestedUtc.",
        "- Time: $($raw.time.captureAssaysElapsedMs) ms capture/performance (limit 495000 ms); $($raw.time.visualEvaluationElapsedMs) ms unattended vision (limit 90000 ms); $($raw.time.orchestrationElapsedMs) ms orchestration (limit 585000 ms); 600000 ms package cap including finalization.",
        "- Recovery barriers: first $recoveryOne / $recoveryOneWall ms; second $recoveryTwo / $recoveryTwoWall ms (30,000 ms requested each).",
        "- COC: $cocCompleted/20 stable; wall $((Get-CSXPathValue $raw 'assays.coc.wallClockMs')) ms; total $((Get-CSXPropertyValue $cocStats 'total')) ms; min $((Get-CSXPropertyValue $cocStats 'min')) ms; median $cocMedian ms; mean $((Get-CSXPropertyValue $cocStats 'mean')) ms; SD $((Get-CSXPropertyValue $cocStats 'sampleStandardDeviation')) ms; CV $((Get-CSXPropertyValue $cocStats 'coefficientOfVariation')); p95 $cocP95 ms; max $cocMax ms; rate $((Get-CSXPropertyValue $cocStats 'transitionsPerMinute'))/min.",
        "- COC failures: $cocFailures events in $((Get-CSXPathValue $raw 'assays.coc.failedTransitions' 0)) transitions; Wilson 95% CI [$cocWilsonLower, $cocWilsonUpper].",
        $publicationLine,
        $preparationLine,
        "- Presentation stretch: mean $stretchMeanFrames frames / $stretchMeanMs ms; max $stretchMaxFrames frames / $stretchMaxMs ms; incomplete stereo at stop $((Get-CSXPathValue $raw 'assays.coc.stretch.incompleteStereoCycleAtStop' 'unknown')).",
        "- CS menu: $menuCompleted/25 stable; wall $((Get-CSXPathValue $raw 'assays.menu.wallClockMs')) ms; total $((Get-CSXPropertyValue $menuStats 'total')) ms; min $((Get-CSXPropertyValue $menuStats 'min')) ms; median $menuMedian ms; mean $((Get-CSXPropertyValue $menuStats 'mean')) ms; SD $((Get-CSXPropertyValue $menuStats 'sampleStandardDeviation')) ms; CV $((Get-CSXPropertyValue $menuStats 'coefficientOfVariation')); p95 $menuP95 ms; max $((Get-CSXPropertyValue $menuStats 'max')) ms; rate $((Get-CSXPropertyValue $menuStats 'transitionsPerMinute'))/min.",
        "- DLSS trace: $traceOutcome; $($traceGroups.Count) scoped sessions; $traceSetConstants constants calls; $traceEvaluates evaluate calls; $traceDropped dropped records.",
        "- Visual captures: $visualCompleted/3 complete, $((Get-CSXPathValue $raw 'assays.visual.validatedChildReceipts' 0))/48 child receipts validated; review $reviewState.",
        $visualQualityLine,
        $speedLine,
        "- Evidence: $root", ''
    ) -join [Environment]::NewLine
    if ($status -eq 'LOCAL_PASS') {
        $markdown += "`nThis is a passing local qualification, not a PR qualification. PR use requires -PrMode and an explicitly identified baseline build.`n"
    }
    elseif ($status -ne 'PASS') {
        $markdown += "`nThis is not a passing PR qualification. See run.json errors; protocol revision 4 has no manual review or pending state.`n"
    }
    $summaryName = if ($prMode) { 'pr-summary.md' } else { 'qualification-summary.md' }
    $summaryPath = Write-CSXTextFile -Path (Join-Path $root $summaryName) -Value $markdown
    return [pscustomobject][ordered]@{ report = $report; runPath = $runPath; summaryPath = $summaryPath }
}

Export-ModuleMember -Function Assert-CSXProtocol, Get-CSXQualificationProtocol, Get-CSXFixtureManifest, Write-CSXJsonFile, Write-CSXTextFile, Get-CSXFileSha256,
    Get-CSXPropertyValue, Get-CSXPathValue, Get-CSXLiveGpuFixtureEvidence, ConvertTo-CSXHashtable, Add-CSXExactRuntimeToProfile, Get-CSXFoveationTarget,
    New-CSXCocScenario, New-CSXMenuScenario, New-CSXRecoveryScenario, New-CSXVisualSequenceRequest,
    New-CSXMcpConnection, Invoke-CSXMcpTool, Get-CSXRemainingMilliseconds, Get-CSXBoundedTimeoutSeconds,
    Get-CSXNearestRankPercentile, Get-CSXMedian, Get-CSXMetricSummary, Get-CSXWilsonInterval, Get-CSXQualificationWaitRecords, Get-CSXResourcePublicationSummary,
    Test-CSXFoveationEvidence, Test-CSXDLSSCaptureSummary, Test-CSXDLSSScenarioEvidence, Get-CSXPairedComparison,
    Assert-CSXVisualIndexSet, Resolve-CSXEvidencePath, Assert-CSXEvidencePathNoReparse,
    New-CSXAutomatedVisualPromptText, New-CSXAutomatedVisualReview, Test-CSXAutomatedVisualReviewEvidence,
    Test-CSXVisualReview, Test-CSXFlattenedBaselineVisualReview,
    Test-CSXJsonIdentity, Test-CSXAutomationArtifactInventory, Test-CSXProducerArtifactEvidence, Test-CSXVisualArtifactEvidence,
    Test-CSXFinalizerEnvelope, Update-CSXQualificationReport
