# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$PlanSha256,[Parameter(Mandatory)][string]$EvidenceDirectory,[Parameter(Mandatory)][string]$ReceiptPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'GripLifecycle.Common.ps1')
$plan=Read-GripJson $PlanPath
$wrapper=Join-Path $root 'Invoke-NullHmdGripSelectedRun.ps1'
$options=@{PlanPath=$PlanPath;PlanSha256=$PlanSha256;ConfiguredPythonPath=$plan.python.path;ConfiguredPythonSha256=$plan.python.sha256;EvidenceDirectory=$EvidenceDirectory;ValidateOnly=$true}
$prior=[Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process')
$checks=[Collections.Generic.List[string]]::new()
function Refuse([scriptblock]$Action,[string]$Expected){
    $caught=$null
    try {& $Action | Out-Null}catch{$caught=$_.Exception.Message}
    if($null -eq $caught -or $caught -notlike ('*'+$Expected+'*')){throw ('Expected refusal: '+$Expected+'; observed: '+$caught)}
    $checks.Add($Expected)
}
try {
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$null,'Process')
    Refuse {Assert-GripPlan $plan} 'CODEX_PYTHON is missing'
    $result=& $wrapper @options | ConvertFrom-Json -AsHashtable
    if(-not $result.ok -or -not $result.pythonBindingVerified -or $result.runtimeInvoked -or $result.evidenceRootCreated){throw 'Empty-env envelope validation failed'}
    if(-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process'))){throw 'Wrapper leaked its process binding'}
    $checks.Add('empty service environment validated; original absence restored')
    $bad=@{};foreach($key in $options.Keys){$bad[$key]=$options[$key]};$bad.PlanSha256='0'*64
    Refuse {& $wrapper @bad} 'Pinned artifact hash changed'
    $bad.PlanSha256=$PlanSha256;$bad.ConfiguredPythonSha256='0'*64
    Refuse {& $wrapper @bad} 'Pinned artifact hash changed'
    $bad.ConfiguredPythonPath=$plan.provider.path;$bad.ConfiguredPythonSha256=$plan.provider.sha256
    Refuse {& $wrapper @bad} 'Explicit configured Python binding differs'
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$plan.provider.path,'Process')
    Refuse {& $wrapper @options} 'Existing process Python configuration conflicts'
    if([Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process') -cne $plan.provider.path){throw 'Conflict refusal changed caller configuration'}
    [Environment]::SetEnvironmentVariable('CODEX_PYTHON',$plan.python.path,'Process')
    [void](& $wrapper @options)
    if([Environment]::GetEnvironmentVariable('CODEX_PYTHON','Process') -cne $plan.python.path){throw 'Existing matching configuration not preserved'}
    $checks.Add('matching process binding preserved')
    if(Test-Path -LiteralPath $EvidenceDirectory){throw 'Validation created the runtime evidence root'}
    $checks.Add('no runtime evidence root created')
    $receipt=@{ok=$true;checks=$checks.ToArray();count=$checks.Count;runtimeInvoked=$false;scope='Actual selected envelope ValidateOnly, no runtime controls';planSha256=$PlanSha256;wrapperSha256=(Get-FileHash -LiteralPath $wrapper).Hash.ToLowerInvariant()}
    if(Test-Path -LiteralPath $ReceiptPath){throw 'New receipt path required'}
    [IO.File]::WriteAllText($ReceiptPath,($receipt | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $receipt | ConvertTo-Json -Depth 5 -Compress
} finally {[Environment]::SetEnvironmentVariable('CODEX_PYTHON',$prior,'Process')}
