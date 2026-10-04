# SPDX-License-Identifier: GPL-3.0-or-later
# Source-bound native v1 still-request observation; raw receipts are never mutated.
function Get-DevBenchNativeScreenshotRequest {
    param($Payload,[Collections.IDictionary]$Arguments)
    $reasons=[Collections.Generic.List[string]]::new()
    function Field($Node,[string]$Name) { if($Node -isnot [pscustomobject]){return $null}; $p=$Node.PSObject.Properties[$Name]; if($p -and $p.Name -ceq $Name){return ,$p.Value}; return $null }
    function Check([bool]$Good,[string]$Name){if(-not $Good){$reasons.Add("Native screenshot request_get: invalid or missing $Name.")}}
    function UInt($Value,[decimal]$Max=[uint64]::MaxValue,[decimal]$Min=0){return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and [decimal]$Value -ge $Min -and [decimal]$Value -le $Max}
    function Text($Value){return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)}
    function Exact($Value,[string]$Expected){return $Value -is [string] -and $Value -ceq $Expected}
    function Utc($Value){
        if($Value -is [DateTime] -and $Value.Kind -eq [DateTimeKind]::Utc){return [DateTimeOffset]$Value}
        if($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$'){return $null}
        $parsed=[DateTimeOffset]::MinValue
        if([DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed}
        return $null
    }
    Check ($Payload -is [pscustomobject]) 'one structured native payload'
    $contract=Field $Payload 'contract'; $command=Field $Payload 'command'; $server=Field $Payload 'server'; $receipt=Field $Payload 'result'
    Check ((Field $Payload 'ok') -is [bool] -and (Field $Payload 'ok')) 'outer ok Boolean true'
    Check ((Exact (Field $contract 'name') 'csx.screenshot') -and (UInt (Field $contract 'major') 1 1) -and (UInt (Field $contract 'minor') 0) -and (UInt (Field $contract 'schemaRevision') 1 1)) 'csx.screenshot contract1.0/schemaRevision1'
    Check ($receipt -is [pscustomobject]) 'result'
    foreach($name in @('clientId','commandId')){Check ($Arguments.Contains($name) -and (Text $Arguments[$name]) -and (Field $command $name) -is [string] -and (Field $command $name) -ceq $Arguments[$name]) "query command.$name binding"}
    Check ((Exact (Field $command 'action') 'request_get') -and $Arguments.Contains('contractMajor') -and (UInt $Arguments['contractMajor'] 1 1)) 'exact request_get command/major'
    Check ((Exact (Field $server 'component') 'CommunityShaders') -and (Field $server 'buildId') -is [string] -and (Field $server 'buildId') -cmatch '^[a-f0-9]{64}$' -and (Text (Field $server 'serviceSessionId'))) 'server producer/build/service session'
    if($Arguments.Contains('expectedBuildId')){Check ((Exact $Arguments['expectedBuildId'] (Field $server 'buildId'))) 'expected producer build'}
    $requestId=Field $receipt 'requestId'
    Check ($Arguments.Contains('requestId') -and (Text $Arguments['requestId']) -and $requestId -is [string] -and $requestId -ceq $Arguments['requestId']) 'exact requested requestId'
    Check ((Exact (Field $receipt 'kind') 'still')) 'supported native still request kind'
    Check ((Field $receipt 'clientId') -is [string] -and (Field $receipt 'clientId') -ceq $Arguments['clientId']) 'receipt client ownership'
    Check (Text (Field $receipt 'commandId')) 'original capture command identity'
    $requested=Field $receipt 'requested'; $effective=Field $receipt 'effective'; $actual=Field $receipt 'actual'
    Check ($requested -is [pscustomobject] -and $effective -is [pscustomobject] -and $actual -is [pscustomobject]) 'requested/effective/actual sections'
    Check ((Exact (Field $requested 'action') 'capture') -and (Exact (Field $requested 'clientId') (Field $receipt 'clientId')) -and (Exact (Field $requested 'commandId') (Field $receipt 'commandId'))) 'original capture request ownership'
    Check ((UInt (Field $requested 'contractMajor') 1 1)) 'original capture contract major'
    $terminalStates=@('completed','completed_with_warnings','failed','failed_partial','rejected','cancelled','cancelled_partial','stopped','dropped')
    $nonterminalStates=@('accepted','waiting_source','queued','encoding','running','stop_requested','cancel_requested','finalizing')
    $state=Field $receipt 'state'; $terminal=$state -is [string] -and $state -cin $terminalStates
    Check ($state -is [string] -and $state -cin @($terminalStates+$nonterminalStates)) 'source-bound RequestRecord state'
    $accepted=Utc (Field $receipt 'acceptedUtc'); $observed=Utc (Field $Payload 'timestampUtc'); $ended=Utc (Field $receipt 'terminalUtc')
    Check ($null -ne $accepted -and $null -ne $observed -and $accepted -le $observed) 'accepted/observed UTC chronology'
    Check ($receipt -is [pscustomobject] -and $null -ne $receipt.PSObject.Properties['terminalUtc']) 'explicit terminalUtc member'
    if($terminal){Check ($null -ne $ended -and $null -ne $accepted -and $null -ne $observed -and $ended -ge $accepted -and $ended -le $observed) 'terminal UTC chronology'}
    else{Check ($null -eq (Field $receipt 'terminalUtc')) 'nonterminal explicit null terminalUtc'}
    if($receipt -is [pscustomobject] -and $receipt.PSObject.Properties['terminal']){Check ($receipt.terminal -is [bool] -and $receipt.terminal -eq $terminal) 'optional legacy terminal flag consistency'}
    $publication=Field $receipt 'publication'
    Check ((Exact (Field $publication 'state') 'settled') -and $publication -is [pscustomobject] -and $publication.PSObject.Properties['artifactCommitted'] -and $null -eq (Field $publication 'artifactCommitted')) 'settled native publication (unresolved refuses qualification)'
    Check ((Field $receipt 'acknowledged') -is [bool]) 'acknowledged Boolean'
    $progress=Field $receipt 'artifactProgress'; $expected=Field $progress 'expected'; $successful=Field $progress 'successful'; $finished=Field $progress 'terminal'
    foreach($name in @('expected','successful','terminal')){Check (UInt (Field $progress $name) ([uint32]::MaxValue)) "artifactProgress.$name"}
    if((UInt $expected) -and (UInt $successful) -and (UInt $finished)){Check ($successful -le $finished -and $finished -le $expected) 'artifact progress ordering'}
    $outputs=Field $effective 'outputs'; $inputOutputs=Field (Field $requested 'capture') 'outputs'
    Check ($outputs -is [array] -and $inputOutputs -is [array] -and $outputs.Count -gt 0 -and $outputs.Count -eq $expected -and $inputOutputs.Count -eq $expected) 'expected output inventory'
    if($outputs -is [array] -and $inputOutputs -is [array] -and $outputs.Count -eq $inputOutputs.Count){
        for($i=0;$i -lt $outputs.Count;$i++){
            Check ((Exact (Field $inputOutputs[$i] 'view') (Field $outputs[$i] 'view')) -and (Exact (Field (Field $inputOutputs[$i] 'encoding') 'format') (Field (Field $outputs[$i] 'encoding') 'format')) -and (Exact (Field (Field $inputOutputs[$i] 'encoding') 'colourContract') (Field (Field $outputs[$i] 'encoding') 'colourContract'))) 'requested/effective output agreement'
        }
    }
    $artifacts=Field $receipt 'artifacts'; Check ($artifacts -is [array]) 'artifacts array'
    if($artifacts -is [array]){Check ($artifacts.Count -eq $successful) 'committed artifact/progress count'}
    $views=[Collections.Generic.List[string]]::new()
    foreach($output in @($outputs)){
        $view=Field $output 'view'; Check ($view -is [string] -and $view -cin @('left_eye','right_eye','side_by_side','framed_combined','source_native') -and -not $views.Contains($view)) 'unique supported output view'
        if($view -is [string]){$views.Add($view)}
        $encoding=Field $output 'encoding'; Check ((Field $encoding 'format') -is [string] -and (Field $encoding 'format') -cin @('png','bmp') -and (Exact (Field $encoding 'colourContract') 'sdr_srgb')) 'output encoding'
    }
    if($state -cin @('completed','completed_with_warnings')){Check ((UInt $expected ([uint32]::MaxValue) 1) -and $successful -eq $expected -and $finished -eq $expected) 'successful terminal complete progress'}
    foreach($name in @('warnings','errors')){Check ((Field $receipt $name) -is [array]) "$name array"}
    $warnings=Field $receipt 'warnings'
    foreach($warning in @($warnings)){
        Check ($warning -is [pscustomobject] -and (Field $warning 'code') -cin @('source_fallback','artifact_hash_failed') -and (Text (Field $warning 'message')) -and @($warning.PSObject.Properties | Where-Object Name -cnotin @('code','message')).Count -eq 0) 'source-bound typed still-request warning'
    }
    Check ($receipt -is [pscustomobject] -and $receipt.PSObject.Properties['error']) 'explicit request error member'
    $requestErrors=Field $receipt 'errors'; $requestError=Field $receipt 'error'
    $hasRequestErrors=$null -ne $requestError -or ($requestErrors -is [array] -and $requestErrors.Count -gt 0)
    if($hasRequestErrors){Check ($terminal -and $state -cnotin @('completed','completed_with_warnings')) 'historical request errors only on unsuccessful terminal receipt'}
    foreach($errorItem in @($requestErrors)+@($requestError)){if($null -ne $errorItem){
        Check ($errorItem -is [pscustomobject] -and (Text (Field $errorItem 'code')) -and (Text (Field $errorItem 'message')) -and (Field $errorItem 'phase') -cin @('source','encoding') -and @($errorItem.PSObject.Properties|Where-Object Name -cnotin @('code','message','phase','path')).Count -eq 0) 'source-bound typed retained still request error'
        if($errorItem -is [pscustomobject] -and $errorItem.PSObject.Properties['path']){Check ($null -eq (Field $errorItem 'path') -or (Text (Field $errorItem 'path'))) 'typed error path/null'}
    }}
    $acquisition=Field $actual 'acquisition'; $engineFrame=Field $acquisition 'engineFrame'
    if((UInt $successful) -and $successful -gt 0){
        $acquired=Utc (Field $acquisition 'utcTimestamp')
        Check ((UInt $engineFrame ([uint32]::MaxValue) 1) -and (UInt (Field $acquisition 'compositorCycle') ([uint64]::MaxValue) 1) -and $null -ne $acquired -and $null -ne $accepted -and $null -ne $observed -and $acquired -ge $accepted -and $acquired -le $observed) 'artifact acquisition frame/cycle/UTC chronology'
    }
    $paths=[Collections.Generic.List[string]]::new(); $artifactViews=[Collections.Generic.List[string]]::new()
    foreach($artifact in @($artifacts)){
        Check ($artifact -is [pscustomobject] -and (Field $artifact 'committed') -is [bool] -and (Field $artifact 'committed')) 'artifact committed Boolean true'
        $path=Field $artifact 'path'; $a=Field $artifact 'actual'; $view=Field $a 'view'
        Check ((Text $path) -and -not $paths.Contains($path)) 'unique artifact path'
        if($path -is [string]){$paths.Add($path)}
        Check ((Text $view) -and $views.Contains($view) -and -not $artifactViews.Contains($view)) 'unique artifact view in effective output inventory'
        if($view -is [string]){$artifactViews.Add($view)}
        Check ((UInt (Field $artifact 'bytes') ([uint64]::MaxValue) 1) -and (Field $artifact 'sha256') -is [string] -and (Field $artifact 'sha256') -cmatch '^[a-f0-9]{64}$') 'committed artifact byte/hash evidence'
        Check ((Field $a 'format') -is [string] -and (Field $a 'format') -cin @('png','bmp') -and (Exact (Field $a 'colourContract') 'sdr_srgb') -and (UInt (Field $a 'width') ([uint32]::MaxValue) 1) -and (UInt (Field $a 'height') ([uint32]::MaxValue) 1)) 'artifact actual encoding/dimensions'
        $matching=@($outputs | Where-Object { (Field $_ 'view') -ceq $view })
        Check ($matching.Count -eq 1 -and (Field (Field $matching[0] 'encoding') 'format') -ceq (Field $a 'format') -and (Field (Field $matching[0] 'encoding') 'colourContract') -ceq (Field $a 'colourContract')) 'artifact encoding matches its effective output'
    }
    # Request error fields describe this immutable owned capture, not query success.
    # Remove only validated historical error/warning fields from a private classifier copy;
    # all other explicit failures, including outer errors and flags, remain vetoes.
    $projection=$null
    if($reasons.Count -eq 0){
        $classifierCopy=$Payload|ConvertTo-Json -Depth 80|ConvertFrom-Json -Depth 80
        $classifierCopy.result.PSObject.Properties.Remove('error'); $classifierCopy.result.PSObject.Properties.Remove('errors'); $classifierCopy.result.PSObject.Properties.Remove('warnings')
        $generic=Get-DevBenchSemanticStatus -Content @($classifierCopy)
        if(-not $generic.ok){foreach($reason in $generic.reasons){$reasons.Add([string]$reason)}}
    }
    if($reasons.Count -eq 0){
        $projection=$receipt|ConvertTo-Json -Depth 80|ConvertFrom-Json -Depth 80
        $projection|Add-Member terminal ([bool]$terminal) -Force
        $projection|Add-Member terminalBasis 'native-v1-state/UTC/progress/settled-publication' -Force
        $projection|Add-Member requestSucceeded ([bool]($terminal -and $state -cin @('completed','completed_with_warnings'))) -Force
        if($null -ne $engineFrame){$projection|Add-Member engineFrame $engineFrame -Force; $projection|Add-Member timestampUtc ((Utc (Field $acquisition 'utcTimestamp')).ToString('o')) -Force}
        foreach($artifact in $projection.artifacts){foreach($name in @('view','format','width','height','colourContract')){$artifact|Add-Member $name (Field $artifact.actual $name) -Force}}
    }
    return [pscustomobject]@{known=$true;ok=$reasons.Count -eq 0;reasons=@($reasons);projection=$projection;requestSucceeded=($null -ne $projection -and $projection.requestSucceeded);terminal=$terminal}
}
