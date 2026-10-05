# SPDX-License-Identifier: GPL-3.0-or-later
# Pure expected-negative observation. Never changes the failed call into success.
Set-StrictMode -Version Latest
function Test-DevBenchColourCasRejectionEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$BeforeStatus,[Parameter(Mandatory)]$RejectedPayload,
        [Parameter(Mandatory)]$AfterStatus,[Parameter(Mandatory)][Collections.IDictionary]$RejectedArguments,
        [Parameter(Mandatory)][string]$ExpectedBuildId)
    function Need([bool]$Good,[string]$Message) { if (-not $Good) { throw "Colour CAS rejection evidence: $Message" } }
    function Field($Node,[string]$Name) { if ($Node -is [pscustomobject]) { $p=$Node.PSObject.Properties[$Name]; if ($p -and $p.Name -ceq $Name) { return ,$p.Value } }; return $null }
    function UInt($Value) { return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and [decimal]$Value -ge 0 }
    function Eq($Left,$Right) { return $Left -is [string] -and $Right -is [string] -and $Left -ceq $Right }
    try {
        Need ($ExpectedBuildId -cmatch '^[a-f0-9]{64}$') 'exact admitted producer build required.'
        Need ($RejectedArguments.Count -eq 5 -and (Eq $RejectedArguments.action 'set') -and (Eq $RejectedArguments.expectedBuildId $ExpectedBuildId) -and (UInt $RejectedArguments.expectedRevision)) 'exact typed set arguments required.'
        foreach ($node in @($BeforeStatus,$RejectedPayload,$AfterStatus)) {
            Need ($node -is [pscustomobject]) 'one native payload per observation required.'
            $names=@('producer','requested','hostContext','runtimeContext','lastSuccessfulDispatch','lastSuccessfulEyeDispatches','sourceColorContractChanged')
            if ([object]::ReferenceEquals($node,$RejectedPayload)) { $names+=@('accepted','resultingRevision','error') }
            Need (@($node.PSObject.Properties).Count -eq $names.Count) 'unknown/missing native payload fields.'
            foreach ($name in $names) { Need ($null -ne $node.PSObject.Properties[$name]) "missing $name." }
            $p=$node.producer
            Need ((Eq (Field $p 'component') 'CommunityShaders') -and (Eq (Field $p 'buildId') $ExpectedBuildId) -and (Field $p 'sourceCommit') -is [string] -and (Field $p 'sourceCommit') -cmatch '^[a-f0-9]{40}$' -and (Field $p 'shaderCacheAbiId') -is [string] -and (Field $p 'shaderCacheAbiId') -cmatch '^[a-f0-9]{64}$' -and (Field $p 'sourceDirty') -is [bool]) 'typed source/producer identity required.'
            $requested=$node.requested
            Need ($requested -is [pscustomobject] -and @($requested.PSObject.Properties).Count -eq 3 -and (UInt (Field $requested 'revision'))) 'typed requested revision required.'
            foreach ($name in @('highDynamicRangeInput','autoExposure')) { Need ((Field $requested $name) -is [bool]) "requested.$name must be Boolean." }
            foreach ($name in @('hostContext','runtimeContext')) {
                $context=$node.$name
                Need ($context -is [pscustomobject] -and @($context.PSObject.Properties).Count -eq 4 -and (UInt (Field $context 'generation'))) 'typed context/generation required.'
                foreach ($flag in @('valid','highDynamicRangeInput','autoExposure')) { Need ((Field $context $flag) -is [bool]) "context.$flag must be Boolean." }
                if ($context.valid) { Need ($context.generation -gt 0) 'valid context needs positive generation.' }
            }
            Need ($node.sourceColorContractChanged -is [bool] -and -not $node.sourceColorContractChanged -and $node.lastSuccessfulDispatch -is [pscustomobject] -and $node.lastSuccessfulEyeDispatches -is [array] -and $node.lastSuccessfulEyeDispatches.Count -eq 2) 'native status sections required; literal transfer annotation is not a dynamic gate.'
        }
        Need ($RejectedPayload.accepted -is [bool] -and -not $RejectedPayload.accepted -and (UInt $RejectedPayload.resultingRevision) -and (Eq $RejectedPayload.error 'expectedRevision did not match the current request')) 'exact uncoded native CAS rejection required.'
        Need ($RejectedArguments.expectedRevision -ne $BeforeStatus.requested.revision -and $RejectedPayload.resultingRevision -eq $BeforeStatus.requested.revision) 'expected revision must actually be stale; resulting revision must stay current.'
        foreach ($flag in @('highDynamicRangeInput','autoExposure')) { Need ($RejectedArguments[$flag] -is [bool] -and $RejectedArguments[$flag] -eq $BeforeStatus.requested.$flag) 'negative test must submit same-value typed flags.' }
        foreach ($later in @($RejectedPayload,$AfterStatus)) {
            foreach ($field in @('revision','highDynamicRangeInput','autoExposure')) { Need ($later.requested.$field -eq $BeforeStatus.requested.$field) 'requested revision/flags changed.' }
            foreach ($context in @('hostContext','runtimeContext')) { foreach ($field in @('valid','generation','highDynamicRangeInput','autoExposure')) { Need ($later.$context.$field -eq $BeforeStatus.$context.$field) 'effective context/generation changed.' } }
            foreach ($field in @('buildId','sourceCommit','shaderCacheAbiId','sourceDirty')) { Need ($later.producer.$field -ceq $BeforeStatus.producer.$field) 'producer lineage changed.' }
        }
        return [pscustomobject]@{ok=$true;expectedNegativeObserved=$true;nativeSetAccepted=$false;unchangedRequestedAndContexts=$true;before=$BeforeStatus;rejected=$RejectedPayload;after=$AfterStatus;basis='source-bound uncoded CAS rejection plus unchanged-state snapshots; caller retains transport/process/session/dispatch evidence';errors=@()}
    } catch { return [pscustomobject]@{ok=$false;expectedNegativeObserved=$false;nativeSetAccepted=$false;unchangedRequestedAndContexts=$false;before=$BeforeStatus;rejected=$RejectedPayload;after=$AfterStatus;errors=@($_.Exception.Message)} }
}
Export-ModuleMember -Function Test-DevBenchColourCasRejectionEvidence
