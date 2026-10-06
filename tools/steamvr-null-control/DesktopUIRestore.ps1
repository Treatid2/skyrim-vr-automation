# SPDX-License-Identifier: GPL-3.0-or-later
# Narrow restore selection; no interpretation of the serialized UI strings.
function Test-DesktopUIRestoreValueEquivalent($Expected, $Actual) {
    if ($Expected -is [pscustomobject] -or $Actual -is [pscustomobject]) {
        return $Expected -is [pscustomobject] -and $Actual -is [pscustomobject] -and $Expected.numericIdentity -ceq $Actual.numericIdentity
    }
    if ($null -eq $Expected -or $null -eq $Actual) { return $null -eq $Expected -and $null -eq $Actual }
    if ($Expected -is [Collections.IDictionary] -or $Actual -is [Collections.IDictionary]) {
        if ($Expected -isnot [Collections.IDictionary] -or $Actual -isnot [Collections.IDictionary]) { return $false }
        $keys = @($Expected.Keys | Sort-Object -CaseSensitive)
        $other = @($Actual.Keys | Sort-Object -CaseSensitive)
        if (($keys | ConvertTo-Json -Compress) -cne ($other | ConvertTo-Json -Compress)) { return $false }
        foreach ($key in $keys) { if (-not (Test-DesktopUIRestoreValueEquivalent $Expected[$key] $Actual[$key])) { return $false } }
        return $true
    }
    $ea = $Expected -is [Collections.IEnumerable] -and $Expected -isnot [string]
    $aa = $Actual -is [Collections.IEnumerable] -and $Actual -isnot [string]
    if ($ea -or $aa) {
        if (-not $ea -or -not $aa) { return $false }
        $e = @($Expected); $a = @($Actual)
        if ($e.Count -ne $a.Count) { return $false }
        for ($i = 0; $i -lt $e.Count; $i++) { if (-not (Test-DesktopUIRestoreValueEquivalent $e[$i] $a[$i])) { return $false } }
        return $true
    }
    if ($Expected -is [string] -or $Actual -is [string]) { return $Expected -is [string] -and $Actual -is [string] -and $Expected -ceq $Actual }
    if ($Expected -is [bool] -or $Actual -is [bool]) { return $Expected -is [bool] -and $Actual -is [bool] -and $Expected.Equals($Actual) }
    # Normalize decimal coefficient/exponent without rounding integers through Double.
    $identities = @(foreach ($number in @($Expected, $Actual)) {
        $match = [regex]::Match(($number | ConvertTo-Json -Compress), '\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z')
        if (-not $match.Success) { return $false }
        $digits = ($match.Groups[2].Value + $match.Groups[3].Value).TrimStart('0')
        if ($digits.Length -eq 0) { '0@0'; continue }
        $exponent = if ($match.Groups[4].Success) { [long]::Parse($match.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture) } else { [long]0 }
        $exponent -= $match.Groups[3].Value.Length
        $coefficient = $digits.TrimEnd('0'); $exponent += $digits.Length - $coefficient.Length
        $match.Groups[1].Value + $coefficient + '@' + $exponent.ToString([Globalization.CultureInfo]::InvariantCulture)
    })
    return $identities.Count -eq 2 -and $identities[0] -ceq $identities[1]
}

function Assert-DesktopUIRestoreJsonElement($Element) {
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw "Duplicate JSON key in DesktopUI restore input: $($property.Name)" }
            Assert-DesktopUIRestoreJsonElement $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($child in $Element.EnumerateArray()) { Assert-DesktopUIRestoreJsonElement $child }
    }
}

function Get-DesktopUIRestoreExactValue($Element) {
    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $value = [ordered]@{}
            foreach ($property in $Element.EnumerateObject()) { $value[$property.Name] = Get-DesktopUIRestoreExactValue $property.Value }
            return $value
        }
        ([Text.Json.JsonValueKind]::Array) { return ,@(foreach ($child in $Element.EnumerateArray()) { Get-DesktopUIRestoreExactValue $child }) }
        ([Text.Json.JsonValueKind]::String) { return $Element.GetString() }
        ([Text.Json.JsonValueKind]::True) { return $true }
        ([Text.Json.JsonValueKind]::False) { return $false }
        ([Text.Json.JsonValueKind]::Null) { return $null }
        ([Text.Json.JsonValueKind]::Number) {
            $match = [regex]::Match($Element.GetRawText(), '\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z')
            if (-not $match.Success) { throw 'Malformed JSON number.' }
            $digits = ($match.Groups[2].Value + $match.Groups[3].Value).TrimStart('0')
            if ($digits.Length -eq 0) { return [pscustomobject]@{numericIdentity='0@0'} }
            $exponent = if ($match.Groups[4].Success) { [long]::Parse($match.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture) } else { [long]0 }
            $exponent -= $match.Groups[3].Value.Length
            $coefficient = $digits.TrimEnd('0'); $exponent += $digits.Length - $coefficient.Length
            return [pscustomobject]@{numericIdentity=($match.Groups[1].Value + $coefficient + '@' + $exponent.ToString([Globalization.CultureInfo]::InvariantCulture))}
        }
        default { throw 'Unsupported JSON kind.' }
    }
}

function Read-DesktopUIRestoreInput([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'DesktopUI restore input exceeds the 1 MiB bound.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 1048576) { throw 'DesktopUI restore input exceeds the 1 MiB bound.' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xfeff)
    $parsed = [Text.Json.JsonDocument]::Parse($text)
    try {
        if ($parsed.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'DesktopUI restore input must be a JSON object.' }
        Assert-DesktopUIRestoreJsonElement $parsed.RootElement
        $exactValue = Get-DesktopUIRestoreExactValue $parsed.RootElement
    }
    finally { $parsed.Dispose() }
    return [pscustomobject]@{
        value = $text | ConvertFrom-Json -AsHashtable -Depth 64
        jsonText = $text; exactValue = $exactValue
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

function Test-DesktopUIRestoreControlledValueEquivalent($Expected, $Actual, $ExpectedExact, $ActualExact) {
    # Only a profile-owned floating leaf may use a runtime's canonical G17
    # binary64 spelling. This is not a tolerance or generic decimal coercion:
    # arbitrary extra precision (even hidden by Double parsing) still refuses.
    if ($Expected -is [double] -or $Actual -is [double]) {
        if ($Expected -isnot [double] -or $Actual -isnot [double] -or
            -not [double]::IsFinite($Expected) -or -not [double]::IsFinite($Actual) -or
            [BitConverter]::DoubleToInt64Bits($Expected) -ne [BitConverter]::DoubleToInt64Bits($Actual)) { return $false }
        if (Test-DesktopUIRestoreValueEquivalent $ExpectedExact $ActualExact) { return $true }
        $canonical = [Text.Json.JsonDocument]::Parse($Expected.ToString('G17', [Globalization.CultureInfo]::InvariantCulture))
        try { return Test-DesktopUIRestoreValueEquivalent (Get-DesktopUIRestoreExactValue $canonical.RootElement) $ActualExact }
        finally { $canonical.Dispose() }
    }
    return (Test-DesktopUIRestoreValueEquivalent $Expected $Actual) -and
        (Test-DesktopUIRestoreValueEquivalent $ExpectedExact $ActualExact)
}

function Get-DesktopUIRestoreStrings($Document) {
    if ($Document -isnot [Collections.IDictionary] -or 'DesktopUI' -cnotin @($Document.Keys) -or $Document['DesktopUI'] -isnot [Collections.IDictionary]) {
        throw 'DesktopUI preservation requires an actual exact-case DesktopUI JSON object.'
    }
    $strings = [ordered]@{}
    foreach ($key in @('pairing', 'settings_desktop')) {
        if ($key -cnotin @($Document['DesktopUI'].Keys) -or $Document['DesktopUI'][$key] -isnot [string]) {
            throw "DesktopUI preservation requires the present actual exact-case string leaf DesktopUI.$key."
        }
        $strings[$key] = $Document['DesktopUI'][$key]
    }
    return $strings
}

function Get-DesktopUIRestoreProjection($Document) {
    $copy = [ordered]@{}
    foreach ($key in $Document.Keys) {
        if ($key -cin @('GpuSpeed', 'LastKnown')) { continue }
        if ($key -ceq 'DesktopUI') {
            $ui = [ordered]@{}
            foreach ($leaf in $Document[$key].Keys) {
                if ($leaf -cnotin @('pairing', 'settings_desktop')) { $ui[$leaf] = $Document[$key][$leaf] }
            }
            $copy[$key] = $ui
        }
        elseif ($key -ceq 'dashboard' -and $Document[$key] -is [Collections.IDictionary]) {
            $dashboard = [ordered]@{}
            foreach ($leaf in $Document[$key].Keys) {
                if ($leaf -ceq 'lastAccessedExternalOverlayKey') {
                    if ($Document[$key][$leaf] -isnot [string]) { throw 'DesktopUI restore refuses malformed dashboard history.' }
                }
                else { $dashboard[$leaf] = $Document[$key][$leaf] }
            }
            $copy[$key] = $dashboard
        }
        else { $copy[$key] = $Document[$key] }
    }
    return $copy
}

function Get-DesktopUIRestoreResultBytes([string]$BaselineJson, $Strings) {
    # Copy untouched baseline values as raw JSON, including full-precision
    # numbers. A PowerShell deserialize/serialize roundtrip may round decimals.
    $document = [Text.Json.JsonDocument]::Parse($BaselineJson)
    $stream = [IO.MemoryStream]::new()
    $writer = [Text.Json.Utf8JsonWriter]::new($stream)
    try {
        $writer.WriteStartObject()
        foreach ($property in $document.RootElement.EnumerateObject()) {
            $writer.WritePropertyName($property.Name)
            if ($property.Name -ceq 'DesktopUI') {
                $writer.WriteStartObject()
                foreach ($leaf in $property.Value.EnumerateObject()) {
                    if ($leaf.Name -cin @('pairing', 'settings_desktop')) { $writer.WriteString($leaf.Name, [string]$Strings[$leaf.Name]) }
                    else { $writer.WritePropertyName($leaf.Name); $writer.WriteRawValue($leaf.Value.GetRawText(), $false) }
                }
                $writer.WriteEndObject()
            }
            else { $writer.WriteRawValue($property.Value.GetRawText(), $false) }
        }
        $writer.WriteEndObject(); $writer.Flush()
        return ,$stream.ToArray()
    }
    finally { $writer.Dispose(); $stream.Dispose(); $document.Dispose() }
}

function Get-DesktopUISettingsRestorePlan($Receipt, [string]$BackupPath, [string]$CurrentPath) {
    $baseline = Read-DesktopUIRestoreInput $BackupPath
    if ($baseline.sha256 -cne [string]$Receipt['settingsSha256Before']) { throw 'DesktopUI restore baseline hash differs from apply receipt.' }
    $nullExpectation = Get-NullSettingsExpectation -Receipt $Receipt -BackupPath $BackupPath
    $profileInput = Read-DesktopUIRestoreInput $nullExpectation.profilePath
    if ($profileInput.sha256 -cne [string]$Receipt['profileSha256']) { throw 'DesktopUI restore profile hash differs from apply receipt.' }
    $current = Read-DesktopUIRestoreInput $CurrentPath
    $nullStrings = Get-DesktopUIRestoreStrings $nullExpectation.value
    $baselineStrings = Get-DesktopUIRestoreStrings $baseline.value
    $strings = Get-DesktopUIRestoreStrings $current.value
    # Profile-owned leaves are never excepted, even if future profiles grow.
    foreach ($path in @($nullExpectation.controlledPaths)) {
        $section, $key = $path -split '[.]', 2
        if ($section -cnotin @($current.value.Keys) -or $current.value[$section] -isnot [Collections.IDictionary] -or
            $key -cnotin @($current.value[$section].Keys) -or
            -not (Test-DesktopUIRestoreControlledValueEquivalent $profileInput.value[$section][$key] $current.value[$section][$key] $profileInput.exactValue[$section][$key] $current.exactValue[$section][$key])) {
            throw "DesktopUI restore refuses controlled-key drift: $path"
        }
        if ($path -ceq 'power.turnOffControllersTimeout' -and
            (($current.value[$section][$key] -isnot [int] -and $current.value[$section][$key] -isnot [long]) -or $current.value[$section][$key] -lt 0 -or $current.value[$section][$key] -gt [int]::MaxValue)) {
            throw 'DesktopUI restore refuses malformed controlled power timeout.'
        }
    }
    $expectedDocument = [Text.Json.JsonDocument]::Parse(($nullExpectation.value | ConvertTo-Json -Depth 64 -Compress))
    try { $expectedExactValue = Get-DesktopUIRestoreExactValue $expectedDocument.RootElement }
    finally { $expectedDocument.Dispose() }
    # Reconcile only already-admitted exact owned leaves with the whole-document
    # projection. Never discard the containing section: its aliases/extra keys
    # and every unowned raw numeric identity remain part of the strict check.
    foreach ($path in @($nullExpectation.controlledPaths)) {
        $section, $key = $path -split '[.]', 2
        $current.exactValue[$section][$key] = $expectedExactValue[$section][$key]
    }
    if (-not (Test-DesktopUIRestoreValueEquivalent (Get-DesktopUIRestoreProjection $expectedExactValue) (Get-DesktopUIRestoreProjection $current.exactValue))) {
        throw 'DesktopUI restore refuses other unclassified drift (including dotted-key or case aliases).'
    }
    $bytes = Get-DesktopUIRestoreResultBytes $baseline.jsonText $strings
    return [pscustomobject]@{
        bytes = $bytes
        selection = [ordered]@{
            schemaVersion = 1; policy = 'baseline-plus-exact-desktopui-strings'
            applyTransactionId = [string]$Receipt['transactionId']; baselineSha256 = $baseline.sha256
            preimageSha256 = $current.sha256; preservedStrings = $strings
            resultSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        }
        validation = [ordered]@{
            authorized = $true; authorizationRoute = 'controlled-contract-plus-exact-desktopui-preservation'
            currentSha256 = $current.sha256; controlledContractMatch = $true
            preservedPaths = @('DesktopUI.pairing', 'DesktopUI.settings_desktop')
            unclassifiedDifferencePaths = @()
        }
    }
}

function Assert-CommittedDesktopUIRestoreSelection($Selection, $Receipt, [string]$BackupPath, [string]$PreimagePath) {
    if ($Selection -isnot [Collections.IDictionary] -or $Selection['schemaVersion'] -ne 1 -or
        $Selection['policy'] -cne 'baseline-plus-exact-desktopui-strings' -or
        $Selection['applyTransactionId'] -cne [string]$Receipt['transactionId']) { throw 'Invalid committed DesktopUI restore lineage.' }
    $plan = Get-DesktopUISettingsRestorePlan $Receipt $BackupPath $PreimagePath
    foreach ($key in @('baselineSha256', 'preimageSha256', 'resultSha256')) {
        if ($Selection[$key] -cne $plan.selection[$key]) { throw "Committed DesktopUI restore selection differs at $key." }
    }
    if (-not (Test-DesktopUIRestoreValueEquivalent $Selection['preservedStrings'] $plan.selection['preservedStrings'])) { throw 'Committed DesktopUI restore selected strings differ from exact preimage.' }
    if ((Get-HashOrNull ([string]$Selection['resultPath'])) -cne [string]$Selection['resultSha256']) { throw 'Committed DesktopUI restore selected result is missing or changed.' }
}

