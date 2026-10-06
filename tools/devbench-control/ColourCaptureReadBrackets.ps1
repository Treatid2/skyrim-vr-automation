# SPDX-License-Identifier: GPL-3.0-or-later
# Source-bound read brackets, not an atomic render-frame observation.
Set-StrictMode -Version Latest

function Assert-ColourReadBracketCatalog($Tools) {
    foreach($selection in @(@('camera','action',@('get')),@('inspect','kind',@('scene','lights')))) {
        $matches=@($Tools|Where-Object name -CEQ $selection[0])
        if($matches.Count -ne 1 -or -not $matches[0].PSObject.Properties['inputSchema']){throw "toolSchemaUnresolved: read bracket $($selection[0]) absent or ambiguous."}
        $properties=$matches[0].inputSchema.properties
        if($null -eq $properties -or -not $properties.PSObject.Properties[$selection[1]]){throw 'toolSchemaUnresolved: read bracket selector absent.'}
        $selector=$properties.($selection[1])
        if($selector.type -cne 'string' -or -not $selector.PSObject.Properties['enum'] -or @($selection[2]|Where-Object {$_ -cnotin @($selector.enum)}).Count){throw 'toolSchemaUnresolved: typed read bracket selectors unavailable.'}
        if($selection[0] -ceq 'inspect') {
            if(-not $properties.PSObject.Properties['scope'] -or $properties.scope.type -cne 'string' -or 'scene' -cnotin @($properties.scope.enum) -or -not $properties.PSObject.Properties['limit'] -or $properties.limit.type -cne 'integer'){throw 'toolSchemaUnresolved: bounded scene light read unavailable.'}
            foreach($boundName in @('minimum','maximum')){
                if($properties.limit.PSObject.Properties[$boundName] -and (($boundName -ceq 'minimum' -and $properties.limit.minimum -gt 64) -or ($boundName -ceq 'maximum' -and $properties.limit.maximum -lt 64))){throw 'toolSchemaUnresolved: scene light limit64 outside schema bounds.'}
            }
        }
        if($matches[0].inputSchema.PSObject.Properties['required']){
            $supplied=if($selection[0] -ceq 'camera'){@('action')}else{@('kind')}
            if(@($matches[0].inputSchema.required|Where-Object {$_ -cnotin $supplied}).Count){throw 'toolSchemaUnresolved: read brackets require unsupported arguments.'}
        }
    }
}

function Get-ColourReadBracketPayload($Reply,[string]$Tool,[hashtable]$Arguments,[uint32]$Cell) {
    if($null -eq $Reply -or -not $Reply.PSObject.Properties['content'] -or @($Reply.content).Count -ne 1 -or $Reply.content[0] -isnot [pscustomobject]){throw 'Read bracket requires exactly one native payload.'}
    if($Reply.PSObject.Properties['rawResult'] -and $Reply.rawResult.PSObject.Properties['isError'] -and ($Reply.rawResult.isError -isnot [bool] -or $Reply.rawResult.isError)){throw 'Read bracket MCP error; raw receipt retained.'}
    $p=$Reply.content[0]
    $semantic=Get-DevBenchCallSemanticStatus -ToolName $Tool -Arguments $Arguments -Content @($p)
    # Existing generic inspect admission intentionally does not include lights.
    # Qualify ONLY this exact bounded scene-light read below; do not broaden it.
    if(($semantic.known -and -not $semantic.ok) -or (-not $semantic.known -and ($Tool -ceq 'camera' -or $Arguments.kind -ceq 'scene'))){throw ('Read bracket native semantic failure: '+($semantic.reasons -join ';'))}
    function Finite($v){return $null -ne $v -and $v.GetType() -in @([byte],[sbyte],[int16],[uint16],[int],[uint32],[long],[uint64],[single],[double],[decimal]) -and [double]::IsFinite([double]$v)}
    function CountValue($v){return $null -ne $v -and $v.GetType() -in @([byte],[int16],[uint16],[int],[uint32],[long],[uint64]) -and [decimal]$v -ge 0 -and [decimal]$v -le [uint64]::MaxValue}
    if($Tool -ceq 'camera'){return [pscustomobject]@{payload=$p;availability=[pscustomobject]@{worldCameraTransform=$true;atomicRenderFrame=$false}}}
    if($Arguments.kind -ceq 'scene'){
        if(-not $p.PSObject.Properties['playerLoaded'] -or $p.playerLoaded -isnot [bool] -or -not $p.playerLoaded -or -not $p.PSObject.Properties['cell'] -or $p.cell -isnot [pscustomobject] -or $p.cell.formId -isnot [string] -or $p.cell.formId -cnotmatch '^0x[0-9a-fA-F]{8}$' -or [Convert]::ToUInt32($p.cell.formId.Substring(2),16) -ne $Cell){throw 'Read bracket scene lost or differs from admitted cell.'}
        if(-not $p.PSObject.Properties['position'] -or @($p.position).Count -ne 3 -or @($p.position|Where-Object {-not (Finite $_)}).Count){throw 'Read bracket scene position malformed.'}
        foreach($field in @('gameHour','daysPassed')){if($p.PSObject.Properties[$field] -and -not (Finite $p.$field)){throw "Read bracket scene $field malformed."}}
        return [pscustomobject]@{payload=$p;availability=[pscustomobject]@{sceneTime=([bool]$p.PSObject.Properties['gameHour'] -and [bool]$p.PSObject.Properties['daysPassed']);weather=([bool]$p.PSObject.Properties['weather'] -and $null -ne $p.weather);atomicRenderFrame=$false}}
    }
    foreach($field in @('scope','count','returned','truncated','countScope','lightObservation','lights')){if(-not $p.PSObject.Properties[$field]){throw "Read bracket light $field missing."}}
    if($p.scope -cne 'scene' -or $p.countScope -cne 'filtered-observed-subset-before-limit' -or -not (CountValue $p.count) -or -not (CountValue $p.returned) -or $p.returned -gt 64 -or $p.returned -gt $p.count -or $p.truncated -isnot [bool] -or $null -eq $p.lights -or @($p.lights).Count -ne $p.returned -or $p.lightObservation -isnot [pscustomobject]){throw 'Read bracket bounded scene light inventory malformed.'}
    $source=$p.lightObservation.source
    if($source -isnot [pscustomobject] -or $source.source -cne 'BSShaderManager.shadowSceneNode[0]' -or -not (CountValue $source.index) -or $source.index -ne 0 -or $source.available -isnot [bool] -or $source.complete -isnot [bool] -or $source.visibleIlluminationProven -isnot [bool] -or $source.visibleIlluminationProven -or @($source.lists).Count -ne 2 -or $source.lists[0] -cne 'activeShadowLights' -or $source.lists[1] -cne 'activeLights'){throw 'Read bracket renderer-list source/coverage malformed.'}
    if((-not $source.available -and ($source.complete -or $p.returned -ne 0)) -or (($p.returned -lt $p.count -or -not $source.available -or -not $source.complete) -and -not $p.truncated)){throw 'Read bracket light availability/coverage contradicts inventory.'}
    foreach($light in $p.lights){
        foreach($vector in @('position','diffuse')){if($light -isnot [pscustomobject] -or -not $light.PSObject.Properties[$vector] -or @($light.$vector).Count -ne 3 -or @($light.$vector|Where-Object {-not (Finite $_)}).Count){throw 'Read bracket light vector malformed.'}}
        foreach($field in @('radius','fade','fadeAmount')){if(-not $light.PSObject.Properties[$field] -or -not (Finite $light.$field)){throw 'Read bracket light numeric state malformed.'}}
        if($light.appCulled -isnot [bool] -or ($null -ne $light.inScene -and $light.inScene -isnot [bool] -and $light.inScene -cnotin @('active','shadow'))){throw 'Read bracket light cull/membership malformed.'}
        if($light.inScene -is [bool] -and $light.inScene){throw 'Read bracket true cannot replace named light membership.'}
    }
    return [pscustomobject]@{payload=$p;availability=[pscustomobject]@{rendererLists=$source.available;boundedCoverageComplete=($source.complete -and -not $p.truncated);visibleIlluminationProven=$false;atomicRenderFrame=$false}}
}

