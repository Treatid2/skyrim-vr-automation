# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([string]$NativeReceiptRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
function Clone($value){$value|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20}
foreach($command in @('coc QASmoke','coc ThroatoftheWorldExterior','getpos x')) {
    $argsMap=@{action='exec';command=$command;capture=$false}
    $payload=[pscustomobject]@{command=$command;queued=$true;capturing=$false}
    $before=$payload|ConvertTo-Json -Compress
    $good=Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($payload)
    Check ($good.known -and $good.ok -and $good.completionBasis -ceq 'dispatch-only' -and $good.dispatchAccepted -and -not $good.executionCompleted -and -not $good.desiredEffectVerified -and -not $good.outputQualified) 'queue admission is not execution, arrival or output'
    Check (($payload|ConvertTo-Json -Compress) -ceq $before) 'raw receipt unchanged'
    foreach($field in @('queued','capturing')) {
        foreach($value in @([string]$payload.$field,1,0,$null,-not $payload.$field)) {
            $bad=Clone $payload;$bad.$field=$value
            Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) "wrong Boolean $field refuses"
        }
        $bad=Clone $payload;$bad.PSObject.Properties.Remove($field)
        Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) "missing $field refuses"
    }
    foreach($field in @('ok','error','redirected','isError','completed','extra')) {
        $bad=Clone $payload;$bad|Add-Member $field $true
        Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) 'extra fields cannot bypass'
    }
    foreach($value in @('different',$null,1)) {
        $bad=Clone $payload;$bad.command=$value
        Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) 'command mismatch/type refuses'
    }
    Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($payload,$payload)).ok) 'multiple receipts refuse'
    Check (-not (Get-DevBenchConsoleDispatchStatus -Arguments $argsMap -Content @()).ok) 'empty content refuses'
    foreach($value in @('false',$null,0,$true)) {
        $badArgs=$argsMap.Clone();$badArgs.capture=$value
        Check (-not (Get-DevBenchConsoleDispatchStatus -Arguments $badArgs -Content @($payload)).ok) 'wrong request capture refuses'
    }
    $badArgs=$argsMap.Clone();$badArgs.extra=$true
    Check (-not (Get-DevBenchConsoleDispatchStatus -Arguments $badArgs -Content @($payload)).ok) 'unknown request extension refuses'
    $bad=Clone $payload;$bad.PSObject.Properties.Remove('queued');$bad|Add-Member Queued $true
    Check (-not (Get-DevBenchConsoleDispatchStatus -Arguments $argsMap -Content @($bad)).ok) 'case drift refuses'
    Check (-not (Test-DevBenchReadOnlyRequest -ToolName console -Arguments $argsMap)) 'dispatch remains mutation-capable'
}
if($NativeReceiptRoot) {
    foreach($item in @(@('E-mountain-COC-DISPATCH.json','32ae672b8948c01c362a9ae61f70133c4a5b0ca54f7d80103834e9ba9693f2de','coc ThroatoftheWorldExterior'),@('SURVEY-QASMOKE-COC-DISPATCH.json','c97fa4d28986ff1f00c23df2b039ec78758aa33c7cc6724c23216ab6b42c6788','coc QASmoke'))) {
        $path=Join-Path $NativeReceiptRoot $item[0]
        Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $item[1]) 'immutable native input pinned'
        $j=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 80
        $good=Get-DevBenchCallSemanticStatus -ToolName console -Arguments @{action='exec';command=$item[2];capture=$false} -Content @($j.data.content)
        Check ($good.ok -and $good.dispatchAccepted -and -not $good.executionCompleted) 'actual retained native receipt admitted as dispatch only'
        Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $item[1]) 'immutable input remains unchanged'
    }
}
[pscustomobject]@{ok=$true;checks=$checks;scope='offline uncaptured dispatch receipts; no native execution or desired effect claim'}|ConvertTo-Json -Compress
