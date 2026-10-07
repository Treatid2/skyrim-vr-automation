# SPDX-License-Identifier: GPL-3.0-or-later
# Pure documented native ConsoleHandler captured-exec receipt qualification.
# Fence completion only: neither desired command effect nor output admission.
function Get-DevBenchConsoleExecutionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Arguments,
          [AllowEmptyCollection()][object[]]$Content)
    $reasons=[Collections.Generic.List[string]]::new()
    if($Arguments.Count -ne 3 -or @('action','command','capture').Where({-not $Arguments.Contains($_)}).Count) {
        $reasons.Add('Captured console execution requires exactly action, command and capture.')
    }
    if(-not $Arguments.Contains('action') -or $Arguments.action -isnot [string] -or $Arguments.action -cne 'exec') {$reasons.Add('Explicit console exec action required.')}
    if(-not $Arguments.Contains('command') -or $Arguments.command -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments.command)) {$reasons.Add('Exact nonempty command required.')}
    if(-not $Arguments.Contains('capture') -or $Arguments.capture -isnot [bool] -or -not $Arguments.capture) {$reasons.Add('Boolean capture true required.')}
    $p=if(@($Content).Count -eq 1 -and $Content[0] -is [pscustomobject]){$Content[0]}else{$null}
    if($null -eq $p) {$reasons.Add('Exactly one structured native execution receipt required.')}
    else {
        $names=@($p.PSObject.Properties.Name)
        if($names.Count -ne 4 -or @('command','completed','queued','capturing').Where({$_ -cnotin $names}).Count) {$reasons.Add('Only the four native captured-exec fields are admitted; errors/redirects/extensions refuse.')}
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
