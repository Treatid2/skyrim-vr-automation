# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
function Clone($value){$value|ConvertTo-Json -Depth 20|ConvertFrom-Json -Depth 20}
foreach($command in @('getini "fVrScale:VR"','setini "fVrScale:VR" 79.06','getpos x')) {
    $argsMap=@{action='exec';command=$command;capture=$true}
    $payload=[pscustomobject]@{command=$command;completed=$true;queued=$false;capturing=$true}
    $before=$payload|ConvertTo-Json -Compress
    $good=Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($payload)
    Check ($good.known -and $good.ok -and $good.completionBasis -ceq 'execution-only' -and -not $good.desiredEffectVerified -and -not $good.outputQualified) 'typed native execution-only completion'
    Check (($payload|ConvertTo-Json -Compress) -ceq $before) 'raw receipt unchanged'
    foreach($field in @('completed','queued','capturing')) {
        foreach($value in @([string]$payload.$field,1,0,$null,-not $payload.$field)) {
            $bad=Clone $payload;$bad.$field=$value
            Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) "wrong Boolean $field refuses"
        }
        $bad=Clone $payload;$bad.PSObject.Properties.Remove($field)
        Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) "missing $field refuses"
    }
    foreach($field in @('ok','error','redirected','isError')) {
        $bad=Clone $payload;$bad|Add-Member $field $(if($field -ceq 'ok'){$true}else{'failure'})
        Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) 'extra failure/affirmative/redirect cannot bypass'
    }
    $bad=Clone $payload;$bad.command='different'
    Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($bad)).ok) 'command mismatch'
    Check (-not (Get-DevBenchCallSemanticStatus -ToolName console -Arguments $argsMap -Content @($payload,$payload)).ok) 'multiple receipts refuse'
    $badArgs=$argsMap.Clone();$badArgs.capture='true'
    Check (-not (Get-DevBenchConsoleExecutionStatus -Arguments $badArgs -Content @($payload)).ok) 'string request capture refuses'
    $badArgs=$argsMap.Clone();$badArgs.extra=$true
    Check (-not (Get-DevBenchConsoleExecutionStatus -Arguments $badArgs -Content @($payload)).ok) 'unknown request extension refuses'
}
[pscustomobject]@{ok=$true;checks=$checks;scope='offline documented captured-console receipt; no native execution or desired effect claim'}|ConvertTo-Json -Compress
