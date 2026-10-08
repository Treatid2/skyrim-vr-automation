# SPDX-License-Identifier: GPL-3.0-or-later
# Bounded scene-only schema from DevBench16dac; membership never proves illumination.
function Test-DevBenchSceneLightRequest {
    param([Collections.IDictionary]$Arguments)
    $fields=@('kind','scope','limit')
    return $null -ne $Arguments -and $Arguments.Count -eq 3 -and
        @($Arguments.Keys|Where-Object {$_ -cnotin $fields}).Count -eq 0 -and
        $Arguments.Contains('kind') -and $Arguments.kind -is [string] -and $Arguments.kind -ceq 'lights' -and
        $Arguments.Contains('scope') -and $Arguments.scope -is [string] -and $Arguments.scope -ceq 'scene' -and
        $Arguments.Contains('limit') -and $null -ne $Arguments.limit -and $Arguments.limit.GetType() -in @([int],[long],[uint32],[uint64]) -and $Arguments.limit -ge 1 -and $Arguments.limit -le 64
}
function Get-DevBenchSceneLightStatus {
    [CmdletBinding()]param([Collections.IDictionary]$Arguments,[AllowEmptyCollection()][object[]]$Content)
    $reasons=[Collections.Generic.List[string]]::new()
    function Require($ok,$path){if(-not $ok){$reasons.Add("Scene-light read: $path malformed, missing, contradictory or unsupported.")}}
    function Member($n,$key){if($n -is [pscustomobject]){$p=$n.PSObject.Properties[$key];if($p -and $p.Name -ceq $key){return ,$p.Value}};return $null}
    function Shape($n,[string[]]$required,[string[]]$optional=@()){
        if($n -isnot [pscustomobject]){return $false}
        $names=@($n.PSObject.Properties.Name)
        return @($required|Where-Object {$_ -cnotin $names}).Count -eq 0 -and @($names|Where-Object {$_ -cnotin @($required+$optional)}).Count -eq 0
    }
    function UInt($n,$max=[uint64]::MaxValue){return $null -ne $n -and $n.GetType() -in @([int],[long],[uint32],[uint64]) -and [decimal]$n -ge 0 -and [decimal]$n -le $max}
    function Finite($n){return $null -ne $n -and $n.GetType() -in @([int],[long],[single],[double],[decimal],[uint32],[uint64]) -and [double]::IsFinite([double]$n)}
    function Vector($n){return $n -is [array] -and $n.Count -eq 3 -and @($n|Where-Object {-not (Finite $_)}).Count -eq 0}
    function Strings($n){return $n -is [array] -and @($n|Where-Object {$_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)}).Count -eq 0}
    function Literal($n,$key,$value){$v=Member $n $key;return $v -is [string] -and $v -ceq $value}
    function Form($n,$path,[bool]$Owner=$false){
        if($null -eq $n){return}
        $extra=if($Owner){@('base','model','position','rotation','cell','bounds','actor')}else{@()}
        Require (Shape $n @('formId','formType') (@('name','editorId')+$extra)) "$path exact fields"
        Require ((Member $n 'formId') -is [string] -and (Member $n 'formId') -cmatch '^0x[0-9A-F]{8}$') "$path.formId"
        Require ((Member $n 'formType') -is [string] -and -not [string]::IsNullOrWhiteSpace((Member $n 'formType'))) "$path.formType"
        foreach($key in @('name','editorId','model')){if($n -is [pscustomobject] -and $n.PSObject.Properties[$key]){Require ((Member $n $key) -is [string]) "$path.$key"}}
        if($Owner){
            foreach($key in @('position','rotation')){Require (Vector (Member $n $key)) "$path.$key"}
            foreach($key in @('base','cell')){if($n -is [pscustomobject] -and $n.PSObject.Properties[$key]){Form (Member $n $key) "$path.$key"}}
            $b=Member $n 'bounds';if($null -ne $b){Require (Shape $b @('min','max')) "$path.bounds";Require ((Vector (Member $b 'min')) -and (Vector (Member $b 'max'))) "$path.bounds vectors"}
            $a=Member $n 'actor';if($null -ne $a){
                Require (Shape $a @('level','playerTeammate') @('health','healthMax','hostileToPlayer')) "$path.actor fields"
                Require (UInt (Member $a 'level')) "$path.actor.level"
                Require ((Member $a 'playerTeammate') -is [bool]) "$path.actor.playerTeammate"
                foreach($key in @('health','healthMax')){if($a.PSObject.Properties[$key]){Require (Finite (Member $a $key)) "$path.actor.$key"}}
                if($a.PSObject.Properties['hostileToPlayer']){Require ((Member $a 'hostileToPlayer') -is [bool]) "$path.actor.hostileToPlayer"}
            }
        }
    }
    Require (Test-DevBenchSceneLightRequest $Arguments) 'exact kind:lights scope:scene limit:1..64 arguments'
    $p=if(@($Content).Count -eq 1 -and $Content[0] -is [pscustomobject]){$Content[0]}else{$null}
    Require (Shape $p @('scope','count','returned','truncated','countScope','playerPositionAvailable','ordering','lightObservation','lights')) 'exact native payload'
    Require ((Literal $p 'scope' 'scene') -and (Literal $p 'countScope' 'filtered-observed-subset-before-limit') -and (Literal $p 'ordering' 'distance-ownerFormId-path-name-type-pointer; pointer tie-break is process-local')) 'literal scope/count/ordering'
    foreach($key in @('truncated','playerPositionAvailable')){Require ((Member $p $key) -is [bool]) $key}
    $count=Member $p 'count';$returned=Member $p 'returned';$lights=Member $p 'lights'
    Require ((UInt $count 512) -and (UInt $returned 64) -and $lights -is [array]) 'bounded count/returned/array'
    if((UInt $count 512) -and (UInt $returned 64) -and $lights -is [array] -and (Test-DevBenchSceneLightRequest $Arguments)){Require ($returned -eq $lights.Count -and $returned -eq [Math]::Min($count,$Arguments.limit)) 'count/array/request correlation'}
    $ob=Member $p 'lightObservation';Require (Shape $ob @('source','budget')) 'lightObservation fields'
    $source=Member $ob 'source';Require (Shape $source @('source','index','lists','available','complete','observedUniqueLights','visibleIlluminationProven')) 'source fields'
    Require ((Literal $source 'source' 'BSShaderManager.shadowSceneNode[0]') -and (UInt (Member $source 'index') 0)) 'exact source identity'
    $lists=Member $source 'lists';Require ($lists -is [array] -and $lists.Count -eq 2 -and $lists[0] -is [string] -and $lists[1] -is [string] -and $lists[0] -ceq 'activeShadowLights' -and $lists[1] -ceq 'activeLights') 'source list identity'
    foreach($key in @('available','complete','visibleIlluminationProven')){Require ((Member $source $key) -is [bool]) "source.$key"}
    Require ((Member $source 'visibleIlluminationProven') -is [bool] -and -not (Member $source 'visibleIlluminationProven')) 'membership is not illumination'
    Require (UInt (Member $source 'observedUniqueLights') 512) 'observed unique lights'
    if((Member $source 'complete') -eq $true){Require ((Member $source 'available') -eq $true) 'complete source must be available'}
    $budget=Member $ob 'budget';Require (Shape $budget @('complete','reasons','used','limits')) 'budget fields'
    $br=Member $budget 'reasons';Require ((Member $budget 'complete') -is [bool] -and (Strings $br)) 'budget completeness/reasons'
    if($br -is [array]){Require ((Member $budget 'complete') -eq ($br.Count -eq 0)) 'budget completeness consistency'}
    $limits=Member $budget 'limits';$used=Member $budget 'used'
    $caps=@{nodes=4096;edges=16384;parents=32768;rendererEntries=4096;uniqueLights=512;outputs=512;depth=256;ancestors=64}
    Require (Shape $limits @($caps.Keys)) 'exact native budget limits'
    Require (Shape $used @('nodes','edges','parents','rendererEntries','uniqueLights','outputs')) 'exact budget used'
    foreach($key in $caps.Keys){Require ((UInt (Member $limits $key) $caps[$key]) -and (Member $limits $key) -eq $caps[$key]) "limits.$key"}
    foreach($key in @('nodes','edges','parents','rendererEntries','uniqueLights','outputs')){Require (UInt (Member $used $key) $caps[$key]) "used.$key"}
    Require ((UInt $count 512) -and $count -eq (Member $used 'outputs') -and $count -le (Member $source 'observedUniqueLights')) 'observed subset/output count'
    if((Member $p 'truncated') -is [bool] -and $br -is [array]){Require ((Member $p 'truncated') -eq ($count -gt $returned -or $br.Count -gt 0 -or -not (Member $source 'available') -or -not (Member $source 'complete'))) 'truncation consistency'}
    if($lights -is [array]){
        if($lights.Count -gt 64){$reasons.Add('Scene-light array exceeds admitted bound.')}
        else{foreach($l in $lights){
            Require (Shape $l @('name','type','path','lineageCoverage','diffuse','radius','fade','fadeAmount','appCulled','inScene','position','distance','owner')) 'light fields'
            foreach($key in @('name','type','path')){Require ((Member $l $key) -is [string]) "light.$key"}
            foreach($key in @('diffuse','position')){Require (Vector (Member $l $key)) "light.$key"}
            foreach($key in @('radius','fade','fadeAmount')){Require (Finite (Member $l $key)) "light.$key"}
            Require ((Member $l 'appCulled') -is [bool] -and (Member $l 'inScene') -is [string] -and (Member $l 'inScene') -cin @('active','shadow')) 'typed scene membership'
            $distance=Member $l 'distance';Require (($null -eq $distance -and (Member $p 'playerPositionAvailable') -eq $false) -or ((Member $p 'playerPositionAvailable') -eq $true -and (Finite $distance) -and $distance -ge 0)) 'distance nullable/finite'
            $lc=Member $l 'lineageCoverage';Require (Shape $lc @('available','complete','stoppedAfterMatch','visitedNodes','examinedEdges','repeatedPointers','reasons')) 'lineage fields'
            foreach($key in @('available','complete','stoppedAfterMatch')){Require ((Member $lc $key) -is [bool]) "lineage.$key"}
            foreach($key in @('visitedNodes','examinedEdges','repeatedPointers')){Require (UInt (Member $lc $key) 32768) "lineage.$key"}
            Require (Strings (Member $lc 'reasons')) 'lineage reasons'
            $lr=Member $lc 'reasons';if($lr -is [array]){Require ((Member $lc 'complete') -eq ((Member $lc 'available') -eq $true -and $lr.Count -eq 0)) 'lineage completeness consistency'}
            Require ((UInt (Member $lc 'visitedNodes') 64) -and (UInt (Member $lc 'examinedEdges') 0) -and (UInt (Member $lc 'repeatedPointers') 0)) 'scene parent-lineage bounds'
            Form (Member $l 'owner') 'light.owner' $true
        }}
    }
    $ok=$reasons.Count -eq 0
    return [pscustomobject]@{
        known=$true;ok=$ok;outcome=$(if($ok){'scene-light-read-contract-satisfied'}else{'scene-light-read-contract-failed'})
        guarded=-not $ok;transient=$false;codes=@();states=@();reasons=@($reasons)
        completionBasis='bounded-read-only';visibleIlluminationProven=$false;wholeSceneCoverageProven=$false
        observedSubsetComplete=($ok -and -not (Member $p 'truncated'))
        qualifiedSceneLights=$(if($ok){$p}else{$null})
        explicitOutcomeEvidence=$(if($ok){@('native16dac-bounded-scene-light-observation')}else{@()})
    }
}
Export-ModuleMember -Function Get-DevBenchSceneLightStatus,Test-DevBenchSceneLightRequest
