# SPDX-License-Identifier: GPL-3.0-or-later
# Pure documented native ConsoleHandler captured-exec receipt qualification.
# Fence completion only: neither desired command effect nor output admission.
function Test-DevBenchConsoleInteger {
    param($Value, [decimal]$Minimum = 0, [decimal]$Maximum = [uint64]::MaxValue)
    return ($null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and
        [decimal]$Value -ge $Minimum -and [decimal]$Value -le $Maximum)
}

function Get-DevBenchConsoleReadRequestReasons {
    param([Collections.IDictionary]$Arguments)
    if (@($Arguments.Keys | Where-Object { $_ -cnotin @('action','windowId','maxLines') }).Count -or
        -not $Arguments.Contains('action') -or $Arguments.action -isnot [string] -or $Arguments.action -cne 'read') {
        'Console read requires exact action read and only optional windowId/maxLines.'
    }
    if ($Arguments.Contains('windowId') -and -not (Test-DevBenchConsoleInteger $Arguments.windowId 1)) {
        'Console read windowId must be a positive native uint64 integer.'
    }
    if ($Arguments.Contains('maxLines') -and -not (Test-DevBenchConsoleInteger $Arguments.maxLines 1 20000)) {
        'Console read maxLines must be a native integer in 1..20000.'
    }
}

function Get-DevBenchConsoleExecutionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Arguments,
          [AllowEmptyCollection()][object[]]$Content)
    $reasons=[Collections.Generic.List[string]]::new()
    if($Arguments.Count -ne 3 -or @($Arguments.Keys | Where-Object { $_ -cnotin @('action','command','capture') }).Count -or @('action','command','capture').Where({-not $Arguments.Contains($_)}).Count) {
        $reasons.Add('Captured console execution requires exactly action, command and capture.')
    }
    if(-not $Arguments.Contains('action') -or $Arguments.action -isnot [string] -or $Arguments.action -cne 'exec') {$reasons.Add('Explicit console exec action required.')}
    if(-not $Arguments.Contains('command') -or $Arguments.command -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.command)) {$reasons.Add('Exact nonempty command required.')}
    if(-not $Arguments.Contains('capture') -or $Arguments.capture -isnot [bool] -or -not $Arguments.capture) {$reasons.Add('Boolean capture true required.')}
    $p=if(@($Content).Count -eq 1 -and $Content[0] -is [pscustomobject]){$Content[0]}else{$null}
    if($null -eq $p) {$reasons.Add('Exactly one structured native execution receipt required.')}
    else {
        $names=@($p.PSObject.Properties.Name)
        if(@('command','completed','queued','capturing').Where({$_ -cnotin $names}).Count -or
            @($names | Where-Object { $_ -cnotin @('command','completed','queued','capturing','windowId') }).Count) {
            $reasons.Add('Only the four native captured-exec fields and optional positive windowId are admitted; errors/redirects/extensions refuse.')
        }
        if('windowId' -cin $names -and -not (Test-DevBenchConsoleInteger $p.windowId 1)) {$reasons.Add('Console execution windowId must be a positive native uint64 integer.')}
        $command=$p.PSObject.Properties['command']
        if(-not $command -or $command.Value -isnot [string] -or -not $Arguments.Contains('command') -or $Arguments.command -isnot [string] -or $command.Value -cne $Arguments.command) {$reasons.Add('Receipt command differs from exact requested command.')}
        foreach($item in @(@('completed',$true),@('queued',$false),@('capturing',$true))) {
            $property=$p.PSObject.Properties[$item[0]]
            if(-not $property -or $property.Value -isnot [bool] -or $property.Value -ne $item[1]) {$reasons.Add("Console $($item[0]) has wrong type/value.")}
        }
    }
    $ok=$reasons.Count -eq 0
    return [pscustomobject]@{
        known=$true;ok=$ok;outcome=$(if($ok){'console-captured-execution-completed'}else{'console-captured-execution-refused'})
        guarded=-not $ok;transient=$false;codes=@();states=@();reasons=@($reasons)
        explicitOutcomeEvidence=$(if($ok){@('native-console-captured-exec-typed-receipt')}else{@()})
        completionBasis='execution-only';desiredEffectVerified=$false;outputQualified=$false
        qualifiedExecution=$(if($ok){$p}else{$null})
    }
}
Export-ModuleMember -Function Get-DevBenchConsoleExecutionStatus

# Immutable latest-window output admission, never a new capture or desired-effect proof.
function Get-DevBenchConsoleReadStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Arguments,
          [AllowEmptyCollection()][object[]]$Content)
    $reasons=[Collections.Generic.List[string]]::new()
    foreach($reason in @(Get-DevBenchConsoleReadRequestReasons $Arguments)) {$reasons.Add($reason)}
    $limit=if($Arguments.Contains('maxLines') -and (Test-DevBenchConsoleInteger $Arguments.maxLines 1 20000)) {$Arguments.maxLines} else {200}
    $p=if(@($Content).Count -eq 1 -and $Content[0] -is [pscustomobject]) {$Content[0]} else {$null}
    $windowMatched=$false
    if($null -eq $p) {$reasons.Add('Exactly one structured native console read required.')}
    else {
        $names=@($p.PSObject.Properties.Name)
        $required=@('markersFound','sawBegin','sawEnd','count','lines','source','lossPossible','diag')
        if(@($required | Where-Object { $_ -cnotin $names }).Count -or
            @($names | Where-Object { $_ -cnotin ($required + 'windowId') }).Count) {
            $reasons.Add('Console read has missing native fields or unknown/error/redirect extensions.')
        }
        $modern='windowId' -cin $names
        if(-not $modern) {
            # Fences and lossPossible do not expose ReadFenced's final maxLines
            # tail trim. Retain the raw response, but never qualify its completeness.
            $reasons.Add('Legacy windowless read lacks total-line completeness telemetry.')
        }
        if($modern -and -not (Test-DevBenchConsoleInteger $p.windowId 1)) {$reasons.Add('Read windowId must be a positive native uint64 integer.')}
        if($Arguments.Contains('windowId')) {
            $windowMatched=$modern -and (Test-DevBenchConsoleInteger $p.windowId 1) -and
                (Test-DevBenchConsoleInteger $Arguments.windowId 1) -and [decimal]$p.windowId -eq [decimal]$Arguments.windowId
            if(-not $windowMatched) {$reasons.Add('Read windowId does not match the exact requested capture generation.')}
        }
        foreach($item in @(@('markersFound',$true),@('sawBegin',$true),@('sawEnd',$true),@('lossPossible',$false))) {
            $property=$p.PSObject.Properties[$item[0]]
            if(-not $property -or $property.Value -isnot [bool] -or $property.Value -ne $item[1]) {$reasons.Add("Console $($item[0]) has wrong type/value.")}
        }
        $lines=$p.PSObject.Properties['lines'];$count=$p.PSObject.Properties['count'];$source=$p.PSObject.Properties['source']
        if(-not $lines -or $lines.Value -isnot [array] -or @($lines.Value | Where-Object { $_ -isnot [string] }).Count) {$reasons.Add('Console lines must be a string array.')}
        if(-not $count -or -not (Test-DevBenchConsoleInteger $count.Value 0 $limit) -or -not $lines -or $count.Value -ne @($lines.Value).Count) {$reasons.Add('Console count must match the requested bounded string array.')}
        if(-not $source -or $source.Value -isnot [string] -or $source.Value -cnotin @('print','buffer')) {$reasons.Add('Unsupported or lossy console output source.')}
        $diag=$p.PSObject.Properties['diag']
        if(-not $diag -or $diag.Value -isnot [pscustomobject]) {$reasons.Add('Structured console diagnostics required.')}
        else {
            $d=$diag.Value
            $booleans=@('consoleLogNull','bufferEmpty','bufferHasBegin','lastMessageHasBegin','consoleMenuExists','consoleMenuOpen','consoleMode','printHooked','timedOut')
            $counters=@('bufferLen','printLines','printDropped','printPayloadLines','printPayloadBytes','ringLines','samples','ticks','engineFrames')
            $allowed=$booleans+$counters+@('lastMessage','printLoss')
            $dn=@($d.PSObject.Properties.Name)
            if(@($dn | Where-Object { $_ -cnotin $allowed }).Count -or ($modern -and @($allowed | Where-Object { $_ -cnotin $dn }).Count)) {$reasons.Add('Console diagnostics have missing modern fields or unknown/error extensions.')}
            foreach($name in $booleans) {
                $property=$d.PSObject.Properties[$name]
                if($property -and $property.Value -isnot [bool]) {$reasons.Add("Console diag.$name must be Boolean.")}
            }
            foreach($name in $counters) {
                $property=$d.PSObject.Properties[$name]
                if($property -and -not (Test-DevBenchConsoleInteger $property.Value)) {$reasons.Add("Console diag.$name must be native uint64 telemetry.")}
            }
            $message=$d.PSObject.Properties['lastMessage']
            if($message -and $message.Value -isnot [string]) {$reasons.Add('Console lastMessage must remain a string diagnostic.')}
            $timeout=$d.PSObject.Properties['timedOut']
            if(-not $timeout -or $timeout.Value -isnot [bool] -or $timeout.Value) {$reasons.Add('Console timeout not proven false.')}
            $dropped=$d.PSObject.Properties['printDropped']
            if($modern -or ($source -and $source.Value -ceq 'print')) {
                if(-not $dropped -or -not (Test-DevBenchConsoleInteger $dropped.Value 0 0)) {$reasons.Add('Console print loss not proven zero.')}
            }
            if($source -and $source.Value -ceq 'print') {
                $hook=$d.PSObject.Properties['printHooked']
                if(-not $hook -or $hook.Value -isnot [bool] -or -not $hook.Value) {$reasons.Add('Console print hook not proven active.')}
                $payloadLines=$d.PSObject.Properties['printPayloadLines']
                if($modern -and (-not $payloadLines -or -not $count -or
                    -not (Test-DevBenchConsoleInteger $payloadLines.Value) -or $payloadLines.Value -ne $count.Value)) {
                    $reasons.Add('Console print payload is truncated or inconsistent with the returned lines.')
                }
            }
            elseif($modern -and $source -and $source.Value -ceq 'buffer' -and $limit -ne 20000) {
                # Native ReadFenced removes older lines without marking lossPossible.
                $reasons.Add('Modern buffer read needs maxLines 20000 to exclude intentional tail truncation.')
            }
            $loss=$d.PSObject.Properties['printLoss']
            if($loss) {
                $lossNames=@('lineLimit','byteLimit','format','allocation','oversize')
                if($loss.Value -isnot [pscustomobject]) {$reasons.Add('Console printLoss must be structured.')}
                else {
                    $ln=@($loss.Value.PSObject.Properties.Name)
                    if($ln.Count -ne 5 -or @($lossNames | Where-Object { $_ -cnotin $ln }).Count) {$reasons.Add('Console printLoss has missing or unknown fields.')}
                    foreach($name in $lossNames) {
                        $property=$loss.Value.PSObject.Properties[$name]
                        if(-not $property -or -not (Test-DevBenchConsoleInteger $property.Value 0 0)) {$reasons.Add("Console printLoss.$name not proven zero.")}
                    }
                }
            }
        }
    }
    $ok=$reasons.Count -eq 0
    return [pscustomobject]@{
        known=$true;ok=$ok;outcome=$(if($ok){'console-fenced-output-qualified'}else{'console-capture-contract-failed'})
        guarded=-not $ok;transient=$false;codes=@();states=@();reasons=@($reasons)
        explicitOutcomeEvidence=$(if($ok){@('native-console-fenced-read-typed-receipt')}else{@()})
        completionBasis='output-capture-only';desiredEffectVerified=$false;outputQualified=$ok
        windowMatched=($ok -and $windowMatched);qualifiedConsoleOutput=$(if($ok){$p}else{$null})
    }
}
Export-ModuleMember -Function Get-DevBenchConsoleReadStatus

# Uncaptured execution acknowledges queue admission only, never execution/arrival.
function Get-DevBenchConsoleDispatchStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Arguments,
          [AllowEmptyCollection()][object[]]$Content)
    $reasons=[Collections.Generic.List[string]]::new()
    $fields=@('action','command','capture')
    if($Arguments.Count -ne 3 -or @($Arguments.Keys|Where-Object {$_ -cnotin $fields}).Count -or @($fields|Where-Object {-not $Arguments.Contains($_)}).Count) {$reasons.Add('Uncaptured dispatch requires exactly action, command and capture.')}
    if(-not $Arguments.Contains('action') -or $Arguments.action -isnot [string] -or $Arguments.action -cne 'exec') {$reasons.Add('Explicit console exec action required.')}
    if(-not $Arguments.Contains('command') -or $Arguments.command -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.command)) {$reasons.Add('Exact nonempty command required.')}
    if(-not $Arguments.Contains('capture') -or $Arguments.capture -isnot [bool] -or $Arguments.capture) {$reasons.Add('Boolean capture false required.')}
    $p=if(@($Content).Count -eq 1 -and $Content[0] -is [pscustomobject]){$Content[0]}else{$null}
    if($null -eq $p) {$reasons.Add('Exactly one structured native dispatch receipt required.')}
    else {
        $names=@($p.PSObject.Properties.Name)
        if($names.Count -ne 3 -or @('command','queued','capturing').Where({$_ -cnotin $names}).Count) {$reasons.Add('Only the three native uncaptured-exec fields are admitted; errors/redirects/extensions refuse.')}
        $command=$p.PSObject.Properties['command']
        if(-not $command -or $command.Value -isnot [string] -or -not $Arguments.Contains('command') -or $Arguments.command -isnot [string] -or $command.Value -cne $Arguments.command) {$reasons.Add('Receipt command differs from exact requested command.')}
        foreach($item in @(@('queued',$true),@('capturing',$false))) {
            $property=$p.PSObject.Properties[$item[0]]
            if(-not $property -or $property.Value -isnot [bool] -or $property.Value -ne $item[1]) {$reasons.Add("Console $($item[0]) has wrong type/value.")}
        }
    }
    $ok=$reasons.Count -eq 0
    return [pscustomobject]@{
        known=$true;ok=$ok;outcome=$(if($ok){'console-uncaptured-dispatch-queued'}else{'console-uncaptured-dispatch-refused'})
        guarded=-not $ok;transient=$false;codes=@();states=@();reasons=@($reasons)
        explicitOutcomeEvidence=$(if($ok){@('native-console-uncaptured-exec-typed-receipt')}else{@()})
        completionBasis='dispatch-only';dispatchAccepted=$ok;executionCompleted=$false;desiredEffectVerified=$false;outputQualified=$false
        qualifiedDispatch=$(if($ok){$p}else{$null})
    }
}
Export-ModuleMember -Function Get-DevBenchConsoleDispatchStatus
