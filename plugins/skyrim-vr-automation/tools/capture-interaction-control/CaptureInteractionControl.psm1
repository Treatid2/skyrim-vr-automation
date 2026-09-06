# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Copy-CaptureInteractionValue($Value) {
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 80 -Compress | ConvertFrom-Json -Depth 80)
}

function Get-CaptureInteractionActionCatalog {
    [CmdletBinding()]
    param([string]$Path = (Join-Path $PSScriptRoot 'actions.v1.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Action catalog does not exist: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30
}

function Get-CaptureInteractionProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Set-CaptureInteractionControllerNeutral($Controller) {
    if (-not $Controller.PSObject.Properties['controller']) {
        $Controller | Add-Member -NotePropertyName controller -NotePropertyValue ([pscustomobject]@{})
    }
    $state = $Controller.controller
    $packet = [uint32](Get-CaptureInteractionProperty $state 'packetNumber' 0)
    foreach ($pair in @(@('packetNumber', [uint32]($packet + 1)), @('pressed', [uint64]0), @('touched', [uint64]0))) {
        if ($state.PSObject.Properties[$pair[0]]) { $state.($pair[0]) = $pair[1] } else { $state | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    $axes = @(@(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0), @(0.0, 0.0))
    if ($state.PSObject.Properties['axes']) { $state.axes = $axes } else { $state | Add-Member -NotePropertyName axes -NotePropertyValue $axes }
}

function New-CaptureInteractionFrames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ObservedFrame,
        [Parameter(Mandatory)][string]$ActionName,
        $ActionArguments = ([pscustomobject]@{}),
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'actions.v1.json')
    )
    $catalog = Get-CaptureInteractionActionCatalog -Path $CatalogPath
    $matches = @($catalog.actions | Where-Object name -eq $ActionName)
    if ($matches.Count -ne 1) { throw "Unknown or ambiguous named action '$ActionName'." }
    $action = $matches[0]
    $values = [ordered]@{}
    foreach ($property in @($action.defaults.PSObject.Properties)) { $values[$property.Name] = $property.Value }
    foreach ($property in @($ActionArguments.PSObject.Properties)) { $values[$property.Name] = $property.Value }
    foreach ($required in @(Get-CaptureInteractionProperty $action 'required' @())) {
        if (-not $values.Contains([string]$required)) { throw "Action '$ActionName' requires '$required'." }
    }

    $neutral = Copy-CaptureInteractionValue $ObservedFrame
    foreach ($role in @('left', 'right')) {
        if (-not $neutral.PSObject.Properties[$role]) { throw "Observed tracked set is missing '$role'." }
        Set-CaptureInteractionControllerNeutral $neutral.$role
    }
    foreach ($required in @('hmd', 'left', 'right')) {
        if (-not $neutral.PSObject.Properties[$required]) { throw "Observed tracked set is missing '$required'." }
    }
    $neutral.tMs = 0
    $neutral.seq = [uint64]1
    $holdValue = if ($values.Contains('holdMs')) { $values.holdMs } else { 50 }
    $holdMs = [int]$holdValue
    if ($holdMs -lt 10 -or $holdMs -gt 10000) { throw 'holdMs must be between 10 and 10000.' }

    if ([string]$action.kind -eq 'tracked-set') { return @($neutral) }
    if ([string]$action.kind -eq 'keyboard') {
        return [pscustomobject][ordered]@{
            device = 'keyboard'; arguments = [pscustomobject][ordered]@{
                action = 'tap'; device = 'keyboard'; key = [string]$values.key; holdMs = $holdMs
            }
        }
    }

    $active = Copy-CaptureInteractionValue $neutral
    $release = Copy-CaptureInteractionValue $neutral
    $active.tMs = 10
    $active.seq = [uint64]2
    $release.tMs = 10 + $holdMs
    $release.seq = [uint64]3
    foreach ($role in @('left', 'right')) {
        $basePacket = [uint32]$neutral.$role.controller.packetNumber
        $active.$role.controller.packetNumber = [uint32]($basePacket + 1)
        $release.$role.controller.packetNumber = [uint32]($basePacket + 2)
    }
    $controller = [string]$values.controller
    if ($controller -notin @('left', 'right')) { throw "Action '$ActionName' controller must be left or right." }
    if ([string]$action.kind -eq 'button-pulse') {
        $mask = [uint64]$values.buttonMask
        $active.$controller.controller.pressed = $mask
        $active.$controller.controller.touched = $mask
    }
    elseif ([string]$action.kind -eq 'axis-pulse') {
        $axis = [int]$values.axis
        $x = [double]$values.x
        $y = [double]$values.y
        if ($axis -lt 0 -or $axis -gt 4) { throw 'axis must be between 0 and 4.' }
        if ($x -lt -1 -or $x -gt 1 -or $y -lt -1 -or $y -gt 1) { throw 'axis x/y must be within [-1,1].' }
        $axes = @($active.$controller.controller.axes)
        $axes[$axis] = @($x, $y)
        $active.$controller.controller.axes = $axes
    }
    else { throw "Action kind '$($action.kind)' is not implemented." }
    return @($neutral, $active, $release)
}

function Find-CaptureInteractionScreenshotReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Value)
    $found = [Collections.Generic.List[object]]::new()
    function Visit($Current) {
        if ($null -eq $Current -or $Current -is [string] -or $Current -is [ValueType]) { return }
        $requestId = $Current.PSObject.Properties['requestId']
        $state = $Current.PSObject.Properties['state']
        if ($requestId -and $state) { $found.Add($Current) }
        if ($Current -is [Collections.IDictionary]) { foreach ($entry in $Current.GetEnumerator()) { Visit $entry.Value }; return }
        if ($Current -is [Collections.IEnumerable] -and $Current -isnot [pscustomobject]) { foreach ($entry in $Current) { Visit $entry }; return }
        foreach ($property in @($Current.PSObject.Properties)) { Visit $property.Value }
    }
    Visit $Value
    return @($found | Sort-Object { if ($_.PSObject.Properties['terminal']) { [int][bool]$_.terminal } else { 0 } } -Descending | Select-Object -First 1)
}

function Get-CaptureInteractionLatestFrame {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Receipt,
        [ValidateSet('left_eye', 'right_eye', 'side_by_side', 'framed_combined', 'source_native')]
        [string]$PreferredView = 'left_eye'
    )
    $items = [Collections.Generic.List[object]]::new()
    function VisitArtifact($Current, [int]$Ordinal, [long]$EngineFrame, [string]$TimestampUtc) {
        if ($null -eq $Current -or $Current -is [string] -or $Current -is [ValueType]) { return }
        $nextOrdinal = if ($Current.PSObject.Properties['ordinal']) { [int]$Current.ordinal } else { $Ordinal }
        $nextFrame = if ($Current.PSObject.Properties['scheduledEngineFrame']) { [long]$Current.scheduledEngineFrame } elseif ($Current.PSObject.Properties['engineFrame']) { [long]$Current.engineFrame } else { $EngineFrame }
        $nextTimestamp = if ($Current.PSObject.Properties['timestampUtc']) { [string]$Current.timestampUtc } elseif ($Current.PSObject.Properties['scheduledTimestampUtc']) { [string]$Current.scheduledTimestampUtc } else { $TimestampUtc }
        if ($Current.PSObject.Properties['path']) {
            $state = [string](Get-CaptureInteractionProperty $Current 'state' '')
            $committed = [bool](Get-CaptureInteractionProperty $Current 'committed' ($state -in @('written', 'completed')))
            if ($committed) {
                $items.Add([pscustomobject][ordered]@{
                    path = [string]$Current.path
                    view = [string](Get-CaptureInteractionProperty $Current 'view' '')
                    format = [string](Get-CaptureInteractionProperty $Current 'format' '')
                    sha256 = Get-CaptureInteractionProperty $Current 'sha256' $null
                    bytes = Get-CaptureInteractionProperty $Current 'bytes' $null
                    ordinal = $nextOrdinal
                    engineFrame = $nextFrame
                    timestampUtc = $nextTimestamp
                    committed = $true
                })
            }
        }
        if ($Current -is [Collections.IDictionary]) { foreach ($entry in $Current.GetEnumerator()) { VisitArtifact $entry.Value $nextOrdinal $nextFrame $nextTimestamp }; return }
        if ($Current -is [Collections.IEnumerable] -and $Current -isnot [pscustomobject]) { foreach ($entry in $Current) { VisitArtifact $entry $nextOrdinal $nextFrame $nextTimestamp }; return }
        foreach ($property in @($Current.PSObject.Properties)) { VisitArtifact $property.Value $nextOrdinal $nextFrame $nextTimestamp }
    }
    VisitArtifact $Receipt -1 -1 $null
    $ranked = @($items | Sort-Object @{ Expression = 'ordinal'; Descending = $true }, @{ Expression = 'engineFrame'; Descending = $true }, @{ Expression = { if ($_.view -eq $PreferredView) { 1 } else { 0 } }; Descending = $true })
    if ($ranked.Count -eq 0) { return $null }
    return $ranked[0]
}

function ConvertTo-CaptureInteractionUtcBoundary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles)
    return $parsed.ToUniversalTime()
}

function Get-CaptureInteractionSaveCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][DateTimeOffset]$SinceUtc,
        [string]$NamePattern = '*'
    )
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Save directory does not exist: $resolved" }
    $boundary = $SinceUtc.ToUniversalTime()
    return @(Get-ChildItem -LiteralPath $resolved -File -Filter '*.ess' | Where-Object {
        ([DateTimeOffset]$_.LastWriteTimeUtc) -gt $boundary -and $_.BaseName -like $NamePattern
    } | Sort-Object LastWriteTimeUtc | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.FullName
            name = $_.Name
            baseName = $_.BaseName
            bytes = $_.Length
            lastWriteUtc = ([DateTimeOffset]$_.LastWriteTimeUtc).ToUniversalTime().ToString('o')
        }
    })
}

Export-ModuleMember -Function Get-CaptureInteractionActionCatalog, New-CaptureInteractionFrames, Find-CaptureInteractionScreenshotReceipt, Get-CaptureInteractionLatestFrame, ConvertTo-CaptureInteractionUtcBoundary, Get-CaptureInteractionSaveCandidates
