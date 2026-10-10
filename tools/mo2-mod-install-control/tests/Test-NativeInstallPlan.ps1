# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../NativeInstallPlan.psm1') -Force
$root = Join-Path $FixtureRoot ('native-plan-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$utf8 = [Text.UTF8Encoding]::new($false)
$commit = 'a' * 40
$lease = 'lease-20261009T140000Z-1234abcd'
$dll = Join-Path $root 'example.dll'
$pdb = Join-Path $root 'example.pdb'
[IO.File]::WriteAllBytes($dll, [byte[]](1, 2, 3, 4))
[IO.File]::WriteAllBytes($pdb, [byte[]](5, 6, 7))
$receiptPath = Join-Path $root 'receipt.json'
$planPath = Join-Path $root 'plan.json'
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
$cases = [Collections.Generic.List[object]]::new()
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30 -Compress), $utf8) }
function New-Plan {
    $script:receipt = @{ commit=$commit; artifacts=@(
        @{path=$dll; bytes=4; sha256=(Hash $dll)}, @{path=$pdb; bytes=3; sha256=(Hash $pdb)}
    ) }
    Write-Json $receiptPath $receipt
    return @{schema='mo2.native-install-plan.1'; installId=('b'*32); sourceCommit=$commit; profile="Human's Profile";
        leaseId=$lease; modName='Synthetic Native TEST'; buildReceipt=@{path=$receiptPath; sha256=(Hash $receiptPath)};
        files=@(@{sourcePath=$dll; relativePath='SKSE/Plugins/example.dll'; bytes=4; sha256=(Hash $dll)},
                @{sourcePath=$pdb; relativePath='SKSE/Plugins/example.pdb'; bytes=3; sha256=(Hash $pdb)})}
}
function Refresh-Receipt { Write-Json $receiptPath $script:receipt; $script:plan.buildReceipt.sha256 = Hash $receiptPath }
function Check([string]$CaseName, [scriptblock]$Mutation, [bool]$Accept=$false, [string]$ErrorPattern='.') {
    $script:plan = New-Plan
    $script:rawPlan = $null
    $script:rawReceipt = $null
    $script:argsOverride = @{}
    . $Mutation
    if ($null -ne $rawReceipt) { [IO.File]::WriteAllBytes($receiptPath,$rawReceipt); $plan.buildReceipt.sha256 = Hash $receiptPath }
    if ($null -ne $rawPlan) { [IO.File]::WriteAllBytes($planPath,$rawPlan) } else { Write-Json $planPath $plan }
    $invoke = @{PlanPath=$planPath; ExpectedPlanSha256=(Hash $planPath); ExpectedSourceCommit=$commit;
        ExpectedProfile="Human's Profile"; ExpectedLeaseId=$lease; TimeoutSeconds=10}
    foreach ($key in $argsOverride.Keys) { $invoke[$key]=$argsOverride[$key] }
    $before = @{}; foreach ($path in @($dll,$pdb,$planPath,$receiptPath)) { $before[$path] = Hash $path }
    $initialFiles = @(Get-ChildItem -LiteralPath $root -File).Count
    $errorText = $null; $result = $null
    try { $result = Get-VerifiedNativeInstallPlan @invoke } catch { $errorText = $_.Exception.Message }
    $valid = if ($Accept) {
        $null -eq $errorText -and $result.ok -and $result.schema -ceq 'mo2.native-install-plan-validation.1' -and
        -not $result.mutationAuthorized -and -not $result.deploymentPerformed -and -not $result.enablePerformed -and
        $result.requiresFreshDeploymentValidation -and $result.sourceCommit -ceq $commit -and
        $result.profile -ceq "Human's Profile" -and $result.files.Count -eq $plan.files.Count -and
        $result.planSha256 -ceq $invoke.ExpectedPlanSha256
    } else { $null -ne $errorText -and $errorText -match $ErrorPattern }
    foreach ($path in $before.Keys) { if ((Hash $path) -cne $before[$path]) { $valid=$false } }
    if (@(Get-ChildItem -LiteralPath $root -File).Count -ne $initialFiles) { $valid=$false }
    if ($valid) { $script:passed++ } else { $failures.Add($CaseName + ': ' + $errorText) }
    $cases.Add(@{name=$CaseName; passed=[bool]$valid; expectedAccepted=$Accept; actualAccepted=$null -eq $errorText; error=$errorText})
}
Check 'valid native pair, non-authorising snapshot, inputs unchanged' {} $true
Check 'valid DLL alone, array preserved' { $plan.files=@($plan.files[0]) } $true
Check 'receipt extra unselected metadata does not grant authority' { $receipt.note='not a build verdict'; Refresh-Receipt } $true
foreach ($field in @('schema','installId','sourceCommit','profile','leaseId','modName','buildReceipt','files')) {
    Check "missing plan field $field" { $plan.Remove($field) } $false 'missing|unexpected'
}
Check 'unknown plan field' { $plan.privateCapability='never admitted' } $false 'missing|unexpected'
Check 'foreign schema' { $plan.schema='racemenu.install-plan.1' } $false 'identity mismatch'
Check 'schema case' { $plan.schema='MO2.native-install-plan.1' } $false 'identity mismatch'
Check 'candidate mismatch' { $plan.sourceCommit='c'*40 } $false 'identity mismatch'
Check 'profile mismatch' { $plan.profile='Other Profile' } $false 'identity mismatch'
Check 'lease mismatch' { $plan.leaseId='lease-20261009T140000Z-abcd1234' } $false 'identity mismatch'
Check 'invalid correlated lease' { $plan.leaseId='not-a-lease'; $argsOverride.ExpectedLeaseId='not-a-lease' } $false 'identity mismatch'
Check 'install identifier type' { $plan.installId=42 } $false 'identity mismatch'
Check 'plan digest mismatch' { $argsOverride.ExpectedPlanSha256='0'*64 } $false 'digest mismatch'
Check 'uppercase expected digest' { $argsOverride.ExpectedPlanSha256=(Hash $planPath).ToUpperInvariant() } $false 'lowercase|digest mismatch'
Check 'uppercase expected commit' { $argsOverride.ExpectedSourceCommit=$commit.ToUpperInvariant(); $plan.sourceCommit=$commit.ToUpperInvariant() } $false 'lowercase'
foreach ($name in @('..','.', 'CON','nul.dll','COM1','LPT9.txt','Trailing.', ' leading', 'trailing ', 'bad/name','bad:name','bad|name',('a'*121))) {
    Check "unsafe mod name $name" { $plan.modName=$name } $false 'safe exact Windows'
}
Check 'unsafe exact profile' { $plan.profile='CON'; $argsOverride.ExpectedProfile='CON' } $false 'safe exact Windows'
foreach ($prefix in @('COM','LPT')) {
    foreach ($digit in @([char]0xB9,[char]0xB2,[char]0xB3)) {
        foreach ($suffix in @('','.txt')) {
            $name = $prefix.ToLowerInvariant()+$digit+$suffix
            Check "reserved superscript mod $name" { $plan.modName=$name } $false 'safe exact Windows'
            Check "reserved superscript profile $name" { $plan.profile=$name; $argsOverride.ExpectedProfile=$name } $false 'safe exact Windows'
        }
    }
}
Check 'non-reserved superscript directory remains admitted' { $plan.modName='Native '+[char]0xB9+' TEST' } $true
Check 'receipt missing reference field' { $plan.buildReceipt.Remove('sha256') } $false 'missing|unexpected'
Check 'receipt extra reference field' { $plan.buildReceipt.token='refuse' } $false 'missing|unexpected'
Check 'receipt digest drift' { $plan.buildReceipt.sha256='0'*64 } $false 'receipt digest mismatch'
Check 'receipt commit mismatch' { $receipt.commit='d'*40; Refresh-Receipt } $false 'exact candidate'
Check 'receipt lacks commit' { $receipt.Remove('commit'); Refresh-Receipt } $false 'exact candidate'
Check 'receipt lacks inventory' { $receipt.Remove('artifacts'); Refresh-Receipt } $false 'exact candidate'
Check 'receipt inventory not array' { $receipt.artifacts=$receipt.artifacts[0]; Refresh-Receipt } $false 'bounded artifact'
Check 'receipt inventory over budget' { $receipt.artifacts=@(1..129 | ForEach-Object { @{path='unselected'} }); Refresh-Receipt } $false 'bounded artifact'
Check 'no issued artifact match' { $receipt.artifacts=@(); Refresh-Receipt } $false 'uniquely bound'
Check 'ambiguous issued artifact' { $receipt.artifacts+=@($receipt.artifacts[0]); Refresh-Receipt } $false 'uniquely bound'
Check 'issued bytes drift' { $receipt.artifacts[0].bytes=5; Refresh-Receipt } $false 'uniquely bound'
Check 'issued hash drift' { $receipt.artifacts[0].sha256='0'*64; Refresh-Receipt } $false 'uniquely bound'
Check 'issued bytes string' { $receipt.artifacts[0].bytes='4'; Refresh-Receipt } $false 'uniquely bound'
Check 'issued bytes Boolean' { $receipt.artifacts[0].bytes=$true; Refresh-Receipt } $false 'uniquely bound'
Check 'zero files' { $plan.files=@() } $false '1..32'
Check 'file count budget' { $plan.files=@(1..33|ForEach-Object { $plan.files[0] }) } $false '1..32'
Check 'file declaration not array' { $plan.files=$plan.files[0] } $false '1..32'
foreach ($field in @('sourcePath','relativePath','bytes','sha256')) {
    Check "missing file field $field" { $plan.files[0].Remove($field) } $false 'missing|unexpected'
}
Check 'extra file field' { $plan.files[0].enable=$true } $false 'missing|unexpected'
foreach ($size in @($true,'4',4.5,0,-1,268435457)) {
    Check "invalid typed size $size" { $plan.files[0].bytes=$size } $false 'typed, bounded'
}
foreach ($path in @('SKSE/Plugins/example.ini','SKSE/Plugins/example.swf','SKSE/Plugins/example.exe',
    'Data/SKSE/Plugins/example.dll','SKSE/Plugins/../example.dll','SKSE\Plugins\example.dll',
    'SKSE/Plugins/example.DLL','SKSE/Plugins/CON.dll','SKSE/Plugins/example.dll:stream')) {
    Check "refused target $path" { $plan.files[0].relativePath=$path } $false 'native DLL/PDB|safe exact Windows'
}
Check 'target case collision' { $plan.files+=@(@{sourcePath=$dll;relativePath='SKSE/Plugins/EXAMPLE.dll';bytes=4;sha256=(Hash $dll)}) } $false 'case-colliding'
Check 'duplicate source' { $plan.files[1].sourcePath=$dll; $plan.files[1].relativePath='SKSE/Plugins/other.dll' } $false 'Duplicate native source'
Check 'source filename mismatch' { $plan.files[0].relativePath='SKSE/Plugins/other.dll' } $false 'filename does not match'
Check 'PDB only' { $plan.files=@($plan.files[1]) } $false 'contain a DLL'
Check 'orphan PDB' { $orphan=Join-Path $root 'orphan.pdb'; [IO.File]::WriteAllBytes($orphan,[byte[]](8));
    $plan.files[1]=@{sourcePath=$orphan;relativePath='SKSE/Plugins/orphan.pdb';bytes=1;sha256=(Hash $orphan)};
    $receipt.artifacts[1]=@{path=$orphan;bytes=1;sha256=(Hash $orphan)}; Refresh-Receipt } $false 'PDB must accompany'
foreach ($path in @('relative.dll','\\localhost\share\example.dll','\\?\D:\example.dll',($dll+':ads'),
    ($root+'\..\example.dll'),($root+'\.\example.dll'),($root+'\\example.dll'),($root+'\alias.\example.dll'),'%TEMP%\example.dll','~\example.dll')) {
    Check "refused source $path" { $plan.files[0].sourcePath=$path } $false 'explicit local|ambiguous Windows'
}
Check 'source size drift' { $plan.files[0].bytes=5; $receipt.artifacts[0].bytes=5; Refresh-Receipt } $false 'source size mismatch'
Check 'aggregate size admission before source reads' { $plan.files=@(
    @{sourcePath=$dll;relativePath='SKSE/Plugins/one.dll';bytes=268435456;sha256=(Hash $dll)},
    @{sourcePath=$dll;relativePath='SKSE/Plugins/two.dll';bytes=268435456;sha256=(Hash $dll)},
    @{sourcePath=$dll;relativePath='SKSE/Plugins/three.dll';bytes=268435456;sha256=(Hash $dll)}) } $false 'aggregate'
Check 'integral-looking float declaration' { $rawPlan=$utf8.GetBytes(($plan|ConvertTo-Json -Depth 30 -Compress).Replace('"bytes":4','"bytes":4.0')) } $false 'typed, bounded'
Check 'source hash drift' { $plan.files[0].sha256='0'*64; $receipt.artifacts[0].sha256='0'*64; Refresh-Receipt } $false 'source hash mismatch'
Check 'invalid UTF8 plan' { $rawPlan=[byte[]](0xff,0xfe,0xff) } $false 'Unable to translate|fallback|UTF'
Check 'invalid UTF8 receipt' { $rawReceipt=[byte[]](0xff) } $false 'Unable to translate|fallback|UTF'
Check 'plan metadata size budget' { $rawPlan=$utf8.GetBytes(' '*65537) } $false 'byte limit'
Check 'receipt metadata size budget' { $rawReceipt=$utf8.GetBytes(' '*1048577) } $false 'byte limit'
Check 'duplicate plan key' { $rawPlan=$utf8.GetBytes('{"schema":1,"schema":2}') } $false 'duplicate or case-aliased'
Check 'case-aliased plan key' { $rawPlan=$utf8.GetBytes('{"schema":1,"Schema":2}') } $false 'duplicate or case-aliased'
Check 'nested duplicate receipt key' { $rawReceipt=$utf8.GetBytes('{"nested":{"x":1,"X":2}}') } $false 'duplicate or case-aliased'
Check 'comment JSON' { $rawPlan=$utf8.GetBytes('{/*comment*/"schema":1}') }
Check 'trailing comma JSON' { $rawPlan=$utf8.GetBytes('{"schema":1,}') }
Check 'scalar JSON' { $rawPlan=$utf8.GetBytes('null') } $false 'JSON object'
Check 'depth budget' { $rawPlan=$utf8.GetBytes(('['*13)+'0'+(']'*13)) } $false 'depth|Depth'
Check 'node budget' { $rawReceipt=$utf8.GetBytes('['+((@(1..20001|ForEach-Object {'0'})) -join ',')+']') } $false 'node budget'
$link = Join-Path $root 'linked'
$null = New-Item -ItemType Junction -Path $link -Target $root
Check 'source ancestor reparse' { $plan.files[0].sourcePath=Join-Path $link 'example.dll' } $false 'reparse point'
Check 'metadata ancestor reparse' { $argsOverride.PlanPath=Join-Path $link 'plan.json' } $false 'reparse point'
# Unlink only this fixture junction; never recursively traverse its target.
[IO.Directory]::Delete($link)
# OS-boundary fault injection uses the actual public admission entry point and
# leaves its classification/path/identity checks intact. No drive mappings change.
$module = Get-Module NativeInstallPlan
& $module {
    $script:originalNamespace = ${function:Get-NativePlanNamespaceData}
    $script:originalOpened = ${function:Get-NativePlanOpenedFileData}
}
try {
    foreach ($selected in @($planPath,$receiptPath,$dll)) {
        foreach ($mode in @('remote','unknown','subst','unknown-device','api-failure','opened-drift','after-read-drift')) {
            & $module { param($path,$mode)
                $script:fixtureNamespacePath=$path; $script:fixtureNamespaceMode=$mode; $script:fixtureNamespaceCalls=0
                function script:Get-NativePlanNamespaceData([string]$Path) {
                    if ($Path -ine $script:fixtureNamespacePath) { return & $script:originalNamespace $Path }
                    $script:fixtureNamespaceCalls++
                    switch ($script:fixtureNamespaceMode) {
                        remote { return @{driveType=4;device='\Device\LanmanRedirector'} }
                        unknown { return @{driveType=0;device='\Device\HarddiskVolume1'} }
                        subst { return @{driveType=3;device='\??\C:\fixture'} }
                        unknown-device { return @{driveType=3;device='\Device\UnknownLocal'} }
                        api-failure { throw 'Namespace API unavailable (synthetic).' }
                        opened-drift { if ($script:fixtureNamespaceCalls -ge 2) { return @{driveType=3;device='\Device\HarddiskVolume999999'} } }
                        after-read-drift { if ($script:fixtureNamespaceCalls -ge 3) { return @{driveType=3;device='\Device\HarddiskVolume999999'} } }
                    }
                    return & $script:originalNamespace $Path
                }
            } $selected $mode
            Check "namespace $mode refused for $([IO.Path]::GetFileName($selected))" {} $false 'namespace|Namespace'
        }
    }
    & $module {
        Set-Item Function:script:Get-NativePlanNamespaceData $script:originalNamespace
        function script:Get-NativePlanOpenedFileData([IO.FileStream]$Stream) {
            $data = & $script:originalOpened $Stream
            $data.path += '.alias'
            return $data
        }
    }
    Check 'opened metadata exact-path mismatch' {} $false 'opened-file namespace'
    & $module { Set-Item Function:script:Get-NativePlanOpenedFileData $script:originalOpened }
    $hardLink = Join-Path $root 'same-physical.dll'
    $null = New-Item -ItemType HardLink -Path $hardLink -Target $dll
    Check 'different leaves sharing physical file identity refused' {
        $plan.files+=@(@{sourcePath=$hardLink;relativePath='SKSE/Plugins/same-physical.dll';bytes=4;sha256=(Hash $hardLink)})
        $receipt.artifacts+=@(@{path=$hardLink;bytes=4;sha256=(Hash $hardLink)}); Refresh-Receipt
    } $false 'Duplicate physical native source identity'
    Check 'opened local payload identity retained' {} $true
} finally {
    & $module {
        Set-Item Function:script:Get-NativePlanNamespaceData $script:originalNamespace
        Set-Item Function:script:Get-NativePlanOpenedFileData $script:originalOpened
    }
}
$exports=@(Get-Command -Module NativeInstallPlan | Select-Object -ExpandProperty Name)
if ($exports.Count -eq 1 -and $exports[0] -ceq 'Get-VerifiedNativeInstallPlan') { $passed++ } else { $failures.Add('Unexpected public mutation interface') }
@{ok=$failures.Count -eq 0; passed=$passed; failed=$failures.Count; failures=$failures.ToArray(); cases=$cases.ToArray();
    fixtureRoot=$root; syntheticPayloads=$true; liveRuntimeUsed=$false; realLeaseUsed=$false; moduleExports=$exports} | ConvertTo-Json -Depth 20
if ($failures.Count) { exit 1 }
