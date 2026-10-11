# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $FixtureRoot ('provider-metadata-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$priorControl=$env:CSX_SHADER_CACHE_CONTROL_ROOT; $priorTemp=$env:TEMP; $priorTmp=$env:TMP
$env:TEMP=$FixtureRoot; $env:TMP=$FixtureRoot; $env:CSX_SHADER_CACHE_CONTROL_ROOT=Join-Path $root 'controls'
$catalog=Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheCatalog.ps1'; $transaction=Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
$checks=[Collections.Generic.List[string]]::new()
function Assert-Check([bool]$Value,[string]$Name){if(-not $Value){throw ('FAIL '+$Name)}; $checks.Add($Name)}
function Put([string]$Path,[string]$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Call-Catalog([hashtable]$Parameters){return (& $catalog @Parameters|ConvertFrom-Json -Depth 50)}
function Inventory([string]$Path){return (& $transaction inspect -CachePath $Path -NoExit -Compact|ConvertFrom-Json -Depth 30).data}
function New-Fixture([string]$Label) {
    $dir=Join-Path $root $Label; $mods=Join-Path $dir 'mods'; $cache=Join-Path $dir 'overwrite/ShaderCache'; $provider=Join-Path $mods 'Cache/ShaderCache'; $plugin=Join-Path $mods 'CSX/SKSE/Plugins'
    $null=[IO.Directory]::CreateDirectory($cache); $null=[IO.Directory]::CreateDirectory($provider)
    $profile=Join-Path $dir 'profiles/Task/modlist.txt'; Put $profile "+Cache`n+CSX`n"
    Put (Join-Path $plugin 'CommunityShaders.dll') 'not-a-runtime-fixture'
    $dll=Get-Item -LiteralPath (Join-Path $plugin 'CommunityShaders.dll')
    Put (Join-Path $plugin 'CSX.BuildManifest.json') (@{buildId='build-fixture';artifact=@{fileName='CommunityShaders.dll';sha256=(Get-FileHash -LiteralPath $dll.FullName).Hash;sizeBytes=$dll.Length};identity=@{shaderCache=@{abiId='abi-current'}}}|ConvertTo-Json -Depth 8)
    $marker=Join-Path $dir 'overwrite/.codex-workspace-output-owner.json'
    Put $marker (@{workspaceId='workspace-fixture';ownershipId='owner-fixture';mode='mo2-overwrite-output';overwritePath=(Split-Path -Parent $cache)}|ConvertTo-Json)
    Put (Join-Path $cache 'useful.bin') ('same-task-'+$Label); Put (Join-Path $provider 'provider.bin') 'provider-fixture'
    $catalogArgs=@{Command='prepare';CatalogRoot=(Join-Path $dir 'catalog');CachePath=$cache;ProfilePath=$profile;ModsPath=$mods;BindToOverwrite=$true;
        EvidenceDirectory=(Join-Path $dir 'prepare');ShaderCacheAbi='abi-current';ShaderSourceSha256=('A'*64);BuildId='build-fixture';WorkspaceId='workspace-fixture';OwnershipId='owner-fixture';
        OwnerMarkerPath=$marker;OwnerMarkerSha256=(Get-FileHash -LiteralPath $marker).Hash;BlockingProcessNames=@('fixture-no-process');NoExit=$true;Compact=$true;Confirm=$false}
    return @{dir=$dir;cache=$cache;provider=$provider;args=$catalogArgs}
}
try {
    foreach($case in @('compatible','foreign-abi','target-conflict','missing-provider','ambiguous-abi','oversize','malformed-utf8','feature-conflict','fully-shadowed','absent-no-import')) {
        $f=New-Fixture $case; $info="[Cache]`nShaderCacheABI = abi-current`n[Feature]`nEnabled = true`n"
        if($case -ne 'missing-provider' -and $case -ne 'absent-no-import'){Put (Join-Path $f.provider 'Info.ini') $info}
        switch($case) {
            'foreign-abi'{Put (Join-Path $f.provider 'Info.ini') ($info.Replace('abi-current','abi-foreign'))}
            'target-conflict'{Put (Join-Path $f.cache 'Info.ini') ($info.Replace('abi-current','abi-foreign'))}
            'ambiguous-abi'{Put (Join-Path $f.provider 'Info.ini') "[Cache]`nShaderCacheABI=abi-current`nShaderCacheABI=abi-current`n"}
            'oversize'{Put (Join-Path $f.provider 'Info.ini') ($info+(';'*262144))}
            'malformed-utf8'{[IO.File]::WriteAllBytes((Join-Path $f.provider 'Info.ini'),[byte[]](0xff,0xfe,0xff))}
            'feature-conflict'{Put (Join-Path $f.cache 'Info.ini') ($info.Replace('Enabled = true','Enabled = false'))}
            'fully-shadowed'{Put (Join-Path $f.cache 'Info.ini') $info; Put (Join-Path $f.cache 'provider.bin') 'overwrite-winner';Put (Join-Path $f.provider 'Info.ini') ($info.Replace('abi-current','abi-foreign'))}
            'absent-no-import'{Put (Join-Path $f.cache 'provider.bin') 'overwrite-winner'}
        }
        $before=Inventory $f.cache; $providerHash=(Inventory $f.provider).treeSha256
        $r=Call-Catalog $f.args
        if($case -in @('compatible','fully-shadowed','absent-no-import')) {
            Assert-Check $r.ok ($case+' public preparation admitted')
            $receipt=Get-Content -LiteralPath $r.data.task.providerShadow.receiptPath -Raw|ConvertFrom-Json -Depth 40
            Assert-Check ($null -ne $receipt.metadataAdmission -and $receipt.preparedInventory.treeSha256 -ceq (Inventory $f.cache).treeSha256) ($case+' metadata and exact shadow proof retained')
            $readmitted=Call-Catalog $f.args
            Assert-Check ($readmitted.ok -and $readmitted.data.task.state -ceq 'already-prepared') ($case+' existing prepared generation readmitted without replaying seed')
            if($case -eq 'absent-no-import'){Assert-Check (-not (Test-Path -LiteralPath (Join-Path $f.cache 'Info.ini')) -and $receipt.metadataAdmission.state -ceq 'metadata-absent-no-provider-import') 'no metadata fabricated for proven existing files'}
            $done=@{Command='complete';CatalogRoot=$f.args.CatalogRoot;CachePath=$f.cache;EvidenceDirectory=$f.args.EvidenceDirectory;WorkingSetStatus='unverified';BlockingProcessNames=@('fixture-no-process');NoExit=$true;Compact=$true;Confirm=$false}
            $closed=Call-Catalog $done
            Assert-Check ($closed.ok -and (Inventory $f.cache).treeSha256 -ceq $before.treeSha256) ($case+' exact original baseline restored')
        } else {
            Assert-Check (-not $r.ok) ($case+' metadata refuses public preparation')
            Assert-Check ((Inventory $f.cache).treeSha256 -ceq $before.treeSha256 -and -not (Test-Path -LiteralPath (Join-Path $f.args.EvidenceDirectory 'shader-cache-task.plan.json')) -and -not (Test-Path -LiteralPath (Join-Path $f.args.EvidenceDirectory 'shader-cache-provider-shadow.receipt.json'))) ($case+' refusal precedes snapshot/seed/shadow/plan mutation')
        }
        Assert-Check ((Inventory $f.provider).treeSha256 -ceq $providerHash) ($case+' source provider unchanged')
    }
    # Valid historical same-workspace completion with useful bytes but no Info.ini.
    # Current provider changes are not allowed to fill foreign metadata into it.
    $f=New-Fixture 'same-task-missing-info'; $info="[Cache]`nShaderCacheABI = abi-current`n"
    Put (Join-Path $f.provider 'Info.ini') $info
    $r=Call-Catalog $f.args; Assert-Check $r.ok 'same-task fixture initially admitted compatible metadata'
    Remove-Item -LiteralPath (Join-Path $f.cache 'Info.ini')
    Put (Join-Path $f.cache 'generated.bin') 'useful-native-output-fixture'
    $closed=Call-Catalog @{Command='complete';CatalogRoot=$f.args.CatalogRoot;CachePath=$f.cache;EvidenceDirectory=$f.args.EvidenceDirectory;WorkingSetStatus='unverified';BlockingProcessNames=@('fixture-no-process');NoExit=$true;Compact=$true;Confirm=$false}
    Assert-Check $closed.ok 'same-task missing-metadata working cache preserved by normal completion'
    $working=$closed.data.task.workingTree.preservedPath; $workingHash=(Inventory $working).treeSha256
    $resume=@{}+$f.args; $resume.EvidenceDirectory=Join-Path $f.dir 'resume-refused'; $resume.ResumeCompletionPath=$closed.data.task.completionPath; $resume.ExpectedResumeCompletionSha256=(Get-FileHash -LiteralPath $resume.ResumeCompletionPath).Hash
    Put (Join-Path $f.provider 'Info.ini') ($info.Replace('abi-current','abi-foreign'))
    $before=Inventory $f.cache; $oldCompletionHash=(Get-FileHash -LiteralPath $resume.ResumeCompletionPath).Hash
    $refused=Call-Catalog $resume
    Assert-Check (-not $refused.ok -and $refused.errors[0] -match 'metadata ABI mismatch') 'exact resume proof cannot admit foreign metadata into metadata-less working cache'
    Assert-Check ((Inventory $f.cache).treeSha256 -ceq $before.treeSha256 -and (Inventory $working).treeSha256 -ceq $workingHash -and (Get-FileHash -LiteralPath $resume.ResumeCompletionPath).Hash -ceq $oldCompletionHash -and -not (Test-Path -LiteralPath (Join-Path $resume.EvidenceDirectory 'shader-cache-task.plan.json'))) 'resume mismatch preserves live baseline, useful working tree and original completion before seed'
    Put (Join-Path $f.provider 'Info.ini') $info
    $resume.EvidenceDirectory=Join-Path $f.dir 'resume-compatible'
    $admitted=Call-Catalog $resume
    Assert-Check ($admitted.ok -and $admitted.data.task.action -ceq 'seed-same-task-unverified' -and (Test-Path -LiteralPath (Join-Path $f.cache 'generated.bin'))) 'metadata-less same-task resume may use original ABI-compatible provider metadata without fabricating bytes'
    Assert-Check ((Get-FileHash -LiteralPath (Join-Path $f.cache 'Info.ini')).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $f.provider 'Info.ini')).Hash) 'compatible resume metadata is exact original provider bytes'
    $closed2=Call-Catalog @{Command='complete';CatalogRoot=$f.args.CatalogRoot;CachePath=$f.cache;EvidenceDirectory=$resume.EvidenceDirectory;WorkingSetStatus='unverified';BlockingProcessNames=@('fixture-no-process');NoExit=$true;Compact=$true;Confirm=$false}
    Assert-Check ($closed2.ok -and (Inventory $f.cache).treeSha256 -ceq $before.treeSha256) 'compatible resumed generation restores its independent original baseline'
    # Model the immutable shape of a historical prepared plan, not a live cache:
    # exact matching tree hash cannot make a foreign metadata ABI compatible.
    $f=New-Fixture 'historical-prepared'; Put (Join-Path $f.provider 'Info.ini') $info
    $prepared=Call-Catalog $f.args; Assert-Check $prepared.ok 'historical prepared fixture starts with original compatible metadata'
    Put (Join-Path $f.cache 'Info.ini') ($info.Replace('abi-current','abi-foreign'))
    $planPath=Join-Path $f.args.EvidenceDirectory 'shader-cache-task.plan.json'
    $plan=Get-Content -LiteralPath $planPath -Raw|ConvertFrom-Json -Depth 40
    $plan.preparedTreeSha256=(Inventory $f.cache).treeSha256
    Put $planPath ($plan|ConvertTo-Json -Depth 40)
    $planHash=(Get-FileHash -LiteralPath $planPath).Hash; $treeHash=(Inventory $f.cache).treeSha256
    $historicalRefused=Call-Catalog $f.args
    Assert-Check (-not $historicalRefused.ok -and $historicalRefused.errors[0] -match 'metadata ABI mismatch') 'historical prepared matching-tree plan cannot bypass actual metadata ABI admission'
    Assert-Check ((Get-FileHash -LiteralPath $planPath).Hash -ceq $planHash -and (Inventory $f.cache).treeSha256 -ceq $treeHash) 'historical prepared refusal preserves original plan and actual cache bytes'
    @{ok=$true;checks=$checks.Count;scope='Production prepare/complete entry, isolated synthetic providers/plugin/owner/resume proofs; no live MO2/cache/runtime';liveQualified=$false}|ConvertTo-Json -Compress
} finally {$env:CSX_SHADER_CACHE_CONTROL_ROOT=$priorControl; $env:TEMP=$priorTemp; $env:TMP=$priorTmp}
