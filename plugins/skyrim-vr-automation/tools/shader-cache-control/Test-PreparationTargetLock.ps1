# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([string]$FixtureRoot, [ValidateSet('','prepare','seed')][string]$Worker='', [string]$RequestPath, [string]$ResultPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$catalogTool=Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheCatalog.ps1'
$transactionTool=Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
if($Worker){
    $arguments=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json -AsHashtable
    $tool=if($Worker -ceq 'prepare'){$catalogTool}else{$transactionTool}
    $result=& $tool @arguments|ConvertFrom-Json -Depth 60
    [IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 60))
    exit 0
}
$root=Join-Path ([IO.Path]::GetFullPath($(if($FixtureRoot){$FixtureRoot}else{[IO.Path]::GetTempPath()}))) ('prepare-lock-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$priorControl=$env:CSX_SHADER_CACHE_CONTROL_ROOT
$passes=[Collections.Generic.List[string]]::new()
$children=[Collections.Generic.List[object]]::new()
function Check([bool]$Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$passes.Add($Name)}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 60))}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash}
function CallCatalog([hashtable]$Parameters){(& $catalogTool @Parameters|Out-String)|ConvertFrom-Json -Depth 60}
function CallTransaction([hashtable]$Parameters){(& $transactionTool @Parameters|Out-String)|ConvertFrom-Json -Depth 60}
function MergeParameters([hashtable]$Base,[hashtable]$Override){$merged=@{}+$Base;foreach($key in $Override.Keys){$merged[$key]=$Override[$key]};return $merged}
function StartChild([string]$Mode,[hashtable]$Parameters,[string]$Label){
    $request=Join-Path $root ($Label+'.request.json');$result=Join-Path $root ($Label+'.result.json')
    WriteJson $request $Parameters
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-NoProfile','-File',$PSCommandPath,'-Worker',$Mode,'-RequestPath',$request,'-ResultPath',$result)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($info);$children.Add($process)
    return @{process=$process;result=$result;label=$Label}
}
function FinishChild($Child,[int]$ExpectedExit=0){
    if(-not $Child.process.WaitForExit(20000)){$Child.process.Kill($true);$Child.process.WaitForExit();throw "Owned fixture child deadline: $($Child.label)"}
    $out=$Child.process.StandardOutput.ReadToEnd();$err=$Child.process.StandardError.ReadToEnd()
    [IO.File]::WriteAllText((Join-Path $root ($Child.label+'.stdout.txt')),$out)
    [IO.File]::WriteAllText((Join-Path $root ($Child.label+'.stderr.txt')),$err)
    Check ($Child.process.ExitCode -eq $ExpectedExit) "$($Child.label): exact owned child exit $ExpectedExit"
    if($ExpectedExit -eq 0){return Get-Content -LiteralPath $Child.result -Raw|ConvertFrom-Json -Depth 60}
}
function WaitReady([string]$Barrier){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not(Test-Path -LiteralPath ($Barrier+'.ready'))){if($timer.ElapsedMilliseconds -ge 15000){throw 'Fixture readiness barrier deadline'};Start-Sleep -Milliseconds 20}
}
try{
    $env:CSX_SHADER_CACHE_CONTROL_ROOT=Join-Path $root 'controls'
    foreach($kind in @('seed','no-seed','overwrite')){
        foreach($boundary in @('before-target-lock','after-readmission','before-publication','no-drift')){
            $label=$kind+'-'+$boundary;$case=Join-Path $root $label
            $cache=Join-Path $case $(if($kind -ceq 'overwrite'){'mo2/overwrite/ShaderCache'}else{'live/ShaderCache'})
            $foreign=Join-Path $case 'foreign/ShaderCache';$seed=Join-Path $case 'seed/ShaderCache'
            foreach($dir in @($cache,$foreign,$seed)){[void][IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'Info.ini'),"[Cache]`nShaderCacheABI=abi-lock")}
            [IO.File]::WriteAllText((Join-Path $cache 'baseline.bin'),'original-A')
            [IO.File]::WriteAllText((Join-Path $foreign 'foreign.bin'),'foreign-B')
            [IO.File]::WriteAllText((Join-Path $seed 'selected.bin'),'selected-S')
            $common=@{CatalogRoot=(Join-Path $case 'catalog');CachePath=$cache;EvidenceDirectory=(Join-Path $case 'task');ShaderCacheAbi='abi-lock';ShaderSourceSha256=('A'*64);BlockingProcessNames=@('FixtureNeverRunningMO2');NoExit=$true;Compact=$true;Confirm=$false}
            $tx=@{CachePath=$cache;BlockingProcessNames=@('FixtureNeverRunningMO2');NoExit=$true;Compact=$true;Confirm=$false}
            if($kind -ceq 'seed'){
                $sourceSnapshot=CallTransaction (MergeParameters $tx @{Command='snapshot';CachePath=$seed;EvidenceDirectory=(Join-Path $case 'seed-proof')})
                Check $sourceSnapshot.ok "${label}: selected source snapshot"
                $capture=CallCatalog ($common+@{Command='capture';SourceCachePath=(Join-Path $case 'seed-proof/cache.before');ExpectedSourceTreeSha256=$sourceSnapshot.data.inventory.treeSha256;SourceReceiptPath=$sourceSnapshot.data.receiptPath;SnapshotStatus='known-working'})
                Check $capture.ok "${label}: selected source captured"
            }
            if($kind -ceq 'overwrite'){
                $mods=Join-Path $case 'mo2/mods';$profile=Join-Path $case 'mo2/profile/modlist.txt';$plugin=Join-Path $mods 'Provider/SKSE/Plugins';$lower=Join-Path $mods 'Provider/ShaderCache'
                foreach($dir in @($plugin,$lower,(Split-Path -Parent $profile))){[void][IO.Directory]::CreateDirectory($dir)}
                [IO.File]::WriteAllText($profile,'+Provider');[IO.File]::WriteAllText((Join-Path $lower 'lower.bin'),'lower-provider')
                $dll=Join-Path $plugin 'CommunityShaders.dll';[IO.File]::WriteAllText($dll,'fixture-plugin')
                WriteJson (Join-Path $plugin 'CSX.BuildManifest.json') @{buildId='fixture-lock-build';artifact=@{sha256=(Hash $dll);sizeBytes=(Get-Item $dll).Length};identity=@{shaderCache=@{abiId='abi-lock'}}}
                $baseline=CallTransaction ($tx+@{Command='inspect'})
                $marker=Join-Path (Split-Path -Parent $cache) '.codex-workspace-output-owner.json'
                WriteJson $marker @{workspaceId='fixture-workspace';ownershipId='fixture-owner';mode='mo2-overwrite-output';overwritePath=(Split-Path -Parent $cache);reconciledCacheBaselineSha256=$baseline.data.treeSha256}
                $common+=@{BindToOverwrite=$true;ProfilePath=$profile;ModsPath=$mods;BuildId='fixture-lock-build';WorkspaceId='fixture-workspace';OwnershipId='fixture-owner';OwnerMarkerPath=$marker;OwnerMarkerSha256=(Hash $marker)}
            }
            $interrupted=StartChild 'prepare' ($common+@{Command='prepare';InternalTestFailurePoint='prepare-interrupt-after-snapshot-plan'}) ($label+'-snapshot')
            $null=FinishChild $interrupted 93
            $plan=Join-Path $common.EvidenceDirectory 'shader-cache-task.plan.json';$receipt=Join-Path $common.EvidenceDirectory 'shader-cache-transaction.receipt.json'
            Check ((Get-Content $plan -Raw|ConvertFrom-Json).state -ceq 'snapshot-preserved') "${label}: interrupted original plan retained"
            $planHash=Hash $plan;$receiptHash=Hash $receipt
            $writerEvidence=Join-Path $case 'writer-proof'
            $writerSnapshot=CallTransaction ($tx+@{Command='snapshot';EvidenceDirectory=$writerEvidence})
            Check $writerSnapshot.ok "${label}: independent writer snapshot authority"
            $foreignHash=(CallTransaction (MergeParameters $tx @{Command='inspect';CachePath=$foreign})).data.treeSha256
            $writerArgs=$tx+@{Command='seed';EvidenceDirectory=$writerEvidence;SourceCachePath=$foreign;ExpectedSourceTreeSha256=$foreignHash;TransactionLockTimeoutMilliseconds=500}
            if($boundary -ceq 'no-drift'){
                $result=CallCatalog ($common+@{Command='prepare'})
            }else{
                $barrier=Join-Path $case 'barrier'
                $preparer=StartChild 'prepare' ($common+@{Command='prepare';InternalTestBarrierPoint=$boundary;InternalTestBarrierPath=$barrier}) ($label+'-prepare')
                WaitReady $barrier
                $writer=StartChild 'seed' $writerArgs ($label+'-writer')
                $written=FinishChild $writer
                if($boundary -ceq 'before-target-lock'){
                    Check $written.ok "${label}: cooperating writer changed target before lock admission"
                }else{
                    Check (-not $written.ok -and ($written.errors -join ' ') -like '*Timed out acquiring shader-cache target lock*') "${label}: separate production seed writer excluded during preparation"
                    Check (@(Get-ChildItem $writerEvidence -Filter 'shader-cache-seed.*.receipt.json').Count -eq 0) "${label}: blocked writer has no mutation receipt"
                }
                [IO.File]::WriteAllText($barrier+'.continue','continue')
                $result=FinishChild $preparer
            }
            if($boundary -ceq 'before-target-lock'){
                Check (-not $result.ok -and ($result.errors -join ' ') -match 'baseline readmission failed|changed after completed-output reconciliation') "${label}: foreign target refused, not rebased"
                Check ((Hash $plan) -ceq $planHash -and (Hash $receipt) -ceq $receiptHash) "${label}: original plan and snapshot remain byte-exact"
                Check ((Test-Path (Join-Path $cache 'foreign.bin')) -and -not(Test-Path (Join-Path $common.EvidenceDirectory 'shader-cache-provider-shadow.receipt.json'))) "${label}: foreign bytes retained without provider consumption"
            }else{
                Check ($result.ok -and $result.state -ceq 'prepared') "${label}: original preparation completes"
                Check (-not(Test-Path (Join-Path $cache 'foreign.bin'))) "${label}: no foreign bytes displaced or consumed"
                $inventory=CallTransaction ($tx+@{Command='inspect'})
                $published=Get-Content $plan -Raw|ConvertFrom-Json -Depth 60
                Check ($published.preparedTreeSha256 -ceq $inventory.data.treeSha256 -and (Hash $receipt) -ceq $receiptHash) "${label}: published exact locked inventory/snapshot"
                if($kind -ceq 'overwrite'){Check (Test-Path (Join-Path $cache 'lower.bin')) "${label}: lower provider materialized under lock"}
            }
            # A new exclusive acquisition after either result proves finally released.
            Import-Module (Join-Path $PSScriptRoot 'ShaderCacheTargetLock.psm1')
            $lease=Enter-CSXCacheTargetLock -CachePath $cache -TimeoutMilliseconds 500
            Exit-CSXCacheTargetLock $lease
            Check $true "${label}: terminal target lock released"
            if($boundary -ceq 'no-drift'){
                $before=(CallTransaction ($tx+@{Command='inspect'})).data.treeSha256
                $refused=CallTransaction ($writerArgs+@{ExpectedTargetTreeSha256=('F'*64)})
                Check (-not $refused.ok -and ($refused.errors -join ' ') -like '*caller-admitted baseline*' -and (CallTransaction ($tx+@{Command='inspect'})).data.treeSha256 -ceq $before) "${label}: explicit expected-target mismatch refuses before seed mutation"
                Check (@(Get-ChildItem $writerEvidence -Filter 'shader-cache-seed.*.receipt.json').Count -eq 0) "${label}: expected-target refusal has no seed receipt"
            }
        }
    }
    @{ok=$true;passed=$passes.Count;passes=@($passes);fixturePath=$root;liveCalls=0;cases=12}|ConvertTo-Json -Depth 6
}finally{
    foreach($child in $children){if(-not $child.HasExited){$child.Kill($true);$child.WaitForExit()};$child.Dispose()}
    $env:CSX_SHADER_CACHE_CONTROL_ROOT=$priorControl
}
