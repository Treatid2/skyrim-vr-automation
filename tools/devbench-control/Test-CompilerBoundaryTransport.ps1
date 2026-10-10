# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Controller parse failed'}
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in @('Get-HttpFailureEvidenceSnapshot','Retain-HttpFailureEvidence','Invoke-McpRequest','Invoke-RestRequest','Invoke-ToolRpc','Test-CaptureBracketRpcRequest')){
    $node=@($nodes|Where-Object Name -CEQ $name)
    if($node.Count){Invoke-Expression $node[0].Extent.Text}
}
$guard=@($nodes|Where-Object Name -CEQ 'Get-ShaderCompilerGuard')[0].Extent.Text
if($guard -notmatch 'Invoke-ToolRpc[^\r\n]+-SingleAttempt'){throw 'Compiler guard must explicitly select first-boundary policy'}
$Command='call';$MaxTransientRetries=4;$PollMilliseconds=50;$MaxPollMilliseconds=500
$finalizationReserveMilliseconds=0;$endpoint='http://127.0.0.1:1/not-called';$script:baseEndpoint=$endpoint
$script:operationDeadlineUtc=[DateTime]::UtcNow.AddMinutes(1)
$transportRetries=[Collections.Generic.List[object]]::new()
function Get-RequestTimeoutSeconds {1}
function Set-ServerWaitBudgetAtDispatch {param($Arguments)}
function Start-OperationDelay {param($RequestedMilliseconds)}
function Invoke-WebRequest {
    param([switch]$UseBasicParsing,$Method,$Uri,$Headers,$Body,$TimeoutSec,$ContentType)
    $script:calls++
    if($script:calls -eq 1){throw [TimeoutException]::new('Synthetic boundary timed out')}
    $content=if($script:transport -ceq 'rest'){'{"ok":true}'}else{'{"jsonrpc":"2.0","id":1,"result":{"isError":false,"content":[{"type":"text","text":"{\"ok\":true}"}]}}'}
    [pscustomobject]@{Content=$content}
}
$passes=[Collections.Generic.List[string]]::new()
foreach($lane in @('mcp','rest')){
    if($lane -ceq 'rest' -and -not @($nodes|Where-Object Name -CEQ 'Invoke-RestRequest').Count){continue}
    $script:transport=$lane
    foreach($single in @($true,$false)){
        $script:calls=0;$transportRetries.Clear();$failure=$null;$reply=$null
        try{$reply=Invoke-ToolRpc -Name 'communityshaders.shader_api' -Arguments @{action='snapshot'} -Headers @{} -SingleAttempt:$single}
        catch{$failure=$_.Exception}
        if($single){
            if($script:calls -ne 1 -or $null -eq $failure -or $failure.Data['DevBenchBoundaryReadFailure'].transport -cne $lane -or $transportRetries.Count -ne 1){throw "$lane first boundary must stop with original failure"}
            $passes.Add("$lane first boundary: one attempt and retained failure")
        }else{
            if($script:calls -ne 2 -or $null -ne $failure -or $null -eq $reply -or $transportRetries.Count -ne 1){throw "$lane ordinary read retry compatibility failed"}
            $passes.Add("$lane ordinary read: transient retry preserved")
        }
    }
}
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);scope='Exact production transport/tool AST with deterministic command doubles; no socket or public REST-entry/live qualification'}|ConvertTo-Json -Depth 5
