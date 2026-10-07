[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $FixtureRoot ('catalog-completion-args-'+[guid]::NewGuid().ToString('N'))
$cache=Join-Path $root 'live/ShaderCache';$catalog=Join-Path $root 'catalog-original';$foreign=Join-Path $root 'catalog-other-host';$evidence=Join-Path $root 'evidence'
[IO.Directory]::CreateDirectory($cache)|Out-Null
[IO.File]::WriteAllText((Join-Path $cache 'Info.ini'),"[Cache]`nShaderCacheABI=fixture-args")
[IO.File]::WriteAllText((Join-Path $cache 'human-baseline.bin'),'human-before')
$tool=Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheCatalog.ps1'
$priorCatalog=$env:CSX_SHADER_CACHE_CATALOG_ROOT;$priorControl=$env:CSX_SHADER_CACHE_CONTROL_ROOT
$passes=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$passes.Add($Name)}
function Call([hashtable]$Parameters){$Parameters.NoExit=$true;$Parameters.Compact=$true; $Parameters.Confirm=$false;$Parameters.BlockingProcessNames=@('FixtureNeverRunningMO2');(& $tool @Parameters|Out-String)|ConvertFrom-Json -Depth 80}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash}
try{
 $env:CSX_SHADER_CACHE_CONTROL_ROOT=Join-Path $root 'controls'
 $env:CSX_SHADER_CACHE_CATALOG_ROOT=$catalog
 $prepareParameters=@{Command='prepare';CachePath=$cache;EvidenceDirectory=$evidence;ShaderCacheAbi='fixture-args';ShaderSourceSha256=('A'*64)}
 $dry=Call ($prepareParameters+@{WhatIf=$true})
 Check ($dry.ok -and $dry.state -ceq 'dry-run' -and -not $dry.data.task.PSObject.Properties['completionArguments']) 'dry-run does not provide a prepared completion object'
 $fresh=Call $prepareParameters
 Check ($fresh.ok -and $fresh.state -ceq 'prepared') 'actual fresh fixture preparation admitted'
 $arguments=$fresh.data.task.completionArguments
 Check (@($arguments.PSObject.Properties).Count -eq 4) 'completion arguments have exactly four bounded fields'
 Check ($arguments.Command -ceq 'complete' -and $arguments.CatalogRoot -ceq $catalog -and $arguments.CachePath -ceq $cache -and $arguments.EvidenceDirectory -ceq $evidence) 'fresh arguments pin all exact identities'
 Check ($fresh.data.storage.source -ceq 'environment' -and $fresh.data.storage.path -ceq $catalog) 'initial catalog provenance remains truthful'
 $planPath=$fresh.data.task.planPath;$planBefore=Hash $planPath
 $plan=Get-Content -LiteralPath $planPath -Raw|ConvertFrom-Json -Depth 60
 Check ($plan.catalog.path -ceq $arguments.CatalogRoot -and $plan.cachePath -ceq $arguments.CachePath -and $plan.evidenceDirectory -ceq $arguments.EvidenceDirectory) 'returned identities bind actual immutable plan'
 $env:CSX_SHADER_CACHE_CATALOG_ROOT=$foreign
 $again=Call ($prepareParameters+@{CatalogRoot=$arguments.CatalogRoot})
 Check ($again.ok -and $again.state -ceq 'already-prepared') 'host default drift does not alter explicit already-prepared selection'
 Check (($again.data.task.completionArguments|ConvertTo-Json -Compress) -ceq ($arguments|ConvertTo-Json -Compress) -and (Hash $planPath) -ceq $planBefore) 'already-prepared argument object stable without plan rewriting'
 $detailed=Call ($prepareParameters+@{CatalogRoot=$arguments.CatalogRoot;IncludeInventoryEntries=$true})
 Check ($detailed.ok -and ($detailed.data.task.completionArguments|ConvertTo-Json -Compress) -ceq ($arguments|ConvertTo-Json -Compress)) 'bounded and detailed output preserve identical parameter object'
 [IO.File]::WriteAllText((Join-Path $cache 'task-output.bin'),'unverified-task-output')
 $baselineBefore=Hash (Join-Path $cache 'human-baseline.bin');$outputBefore=Hash (Join-Path $cache 'task-output.bin')
 $snapshotBefore=Hash $plan.transactionReceiptPath
 $wrong=Call @{Command='complete';CatalogRoot=$foreign;CachePath=$cache;EvidenceDirectory=$evidence}
 Check (-not $wrong.ok -and $wrong.state -ceq 'tool-error' -and $wrong.errors[0] -like '*different catalog root*') 'explicit wrong host catalog still refused'
 Check ((Hash $planPath) -ceq $planBefore -and (Hash $plan.transactionReceiptPath) -ceq $snapshotBefore -and (Hash (Join-Path $cache 'human-baseline.bin')) -ceq $baselineBefore -and (Hash (Join-Path $cache 'task-output.bin')) -ceq $outputBefore -and -not (Test-Path (Join-Path $evidence 'shader-cache-task.completion.json'))) 'wrong-root refusal precedes plan/snapshot/cache/completion mutation'
 $forward=@{};foreach($property in $arguments.PSObject.Properties){$forward[$property.Name]=$property.Value}
 $forward.WorkingSetStatus='unverified'
 $complete=Call $forward
 Check ($complete.ok -and $complete.state -ceq 'complete' -and $complete.data.storage.path -ceq $catalog) 'pinned completion succeeds despite changed execution-host default'
 Check ((Hash (Join-Path $cache 'human-baseline.bin')) -ceq $baselineBefore -and -not (Test-Path (Join-Path $cache 'task-output.bin'))) 'normal restoration retains exact human baseline'
 Check ((Hash (Join-Path $complete.data.task.workingTree.preservedPath 'task-output.bin')) -ceq $outputBefore -and $null -eq $complete.data.task.promoted) 'task output retained unverified without promotion'
 $terminalHash=Hash $complete.data.task.completionPath
 $repeat=Call $forward
 Check ($repeat.ok -and $repeat.state -ceq 'already-complete' -and (Hash $complete.data.task.completionPath) -ceq $terminalHash) 'forwarded completion retains existing idempotent completion'
}finally{$env:CSX_SHADER_CACHE_CATALOG_ROOT=$priorCatalog;$env:CSX_SHADER_CACHE_CONTROL_ROOT=$priorControl}
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);fixturePath=$root;liveCalls=0}|ConvertTo-Json -Depth 6
