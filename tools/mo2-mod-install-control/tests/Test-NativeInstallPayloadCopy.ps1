# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# A previously loaded V1 type must not shadow the V2 implementation.
Add-Type 'namespace SkyrimVRAutomation { public sealed class NativePlanPayloadCustodyV1 {} }'
Add-Type 'public sealed class RejectedNativeCopyStream : System.IO.MemoryStream { public override long Length { get { throw new System.Exception("Subclass property must not run"); } } }'
Import-Module (Join-Path $PSScriptRoot '../NativeInstallPlan.psm1') -Force
$root=Join-Path $FixtureRoot ('native-copy-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$dll=Join-Path $root 'sample.dll';$pdb=Join-Path $root 'sample.pdb'
$planPath=Join-Path $root 'plan.json';$receiptPath=Join-Path $root 'receipt.json'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllBytes($dll,[byte[]](1,2,3,4));[IO.File]::WriteAllBytes($pdb,[byte[]](5,6,7))
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12 -Compress),$utf8)}
$commit='a'*40;$lease='lease-20261009T140000Z-1234abcd'
$files=@(@{sourcePath=$dll;relativePath='SKSE/Plugins/sample.dll';bytes=4;sha256=(Hash $dll)},@{sourcePath=$pdb;relativePath='SKSE/Plugins/sample.pdb';bytes=3;sha256=(Hash $pdb)})
Json $receiptPath @{commit=$commit;artifacts=@($files|ForEach-Object{@{path=$_.sourcePath;bytes=$_.bytes;sha256=$_.sha256}})}
Json $planPath @{schema='mo2.native-install-plan.1';installId=('b'*32);sourceCommit=$commit;profile='Synthetic';leaseId=$lease;modName='Synthetic TEST';buildReceipt=@{path=$receiptPath;sha256=(Hash $receiptPath)};files=$files}
function OpenCustody {Open-VerifiedNativeInstallPayloadCustody -PlanPath $planPath -ExpectedPlanSha256 (Hash $planPath) -ExpectedSourceCommit $commit -ExpectedProfile Synthetic -ExpectedLeaseId $lease -TimeoutSeconds 10}
function CanWrite([string]$Path){$s=$null;try{$s=[IO.File]::Open($Path,'Open','Write','None');return $true}catch{return $false}finally{if($s){$s.Dispose()}}}
$passed=0;$failures=[Collections.Generic.List[string]]::new();$cases=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Value){$cases.Add(@{name=$Name;passed=$Value});if($Value){$script:passed++}else{$failures.Add($Name)}}
$before=@{};foreach($path in @($dll,$pdb,$planPath,$receiptPath)){$before[$path]=Hash $path}
$custody=OpenCustody;$a=[IO.MemoryStream]::new();$b=[IO.MemoryStream]::new()
try {
 Check 'new V2 loads with old V1 already present' ($custody.GetType().Name -ceq 'NativePlanPayloadCustodyV2')
 $projection=$custody.ValidationJson|ConvertFrom-Json;$projection.files[0].sha256='0'*64
 $proof=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))|ConvertFrom-Json
 Check 'complete same-handle two-payload copy and readback' ($proof.ok -and $proof.files.Count -eq 2 -and $proof.files[0].bytes -eq 4 -and $proof.files[1].bytes -eq 3 -and $proof.files[0].sha256 -ceq $files[0].sha256 -and $proof.files[1].readbackVerified)
 Check 'copied bytes exact and destinations still open' (($a.ToArray() -join ',') -ceq '1,2,3,4' -and ($b.ToArray() -join ',') -ceq '5,6,7' -and $a.CanWrite -and $b.CanWrite)
 Check 'content receipt not deployment and source custody still held' (-not $proof.publicationPerformed -and -not $proof.deploymentPerformed -and -not (CanWrite $dll) -and -not (CanWrite $pdb))
 $refused=$false;try{$null=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))}catch{$refused=$true}
 Check 'second attempt refuses and closes whole source set without touching copied bytes' ($refused -and $custody.IsDisposed -and (CanWrite $dll) -and (CanWrite $pdb) -and $a.Length -eq 4 -and $b.Length -eq 3)
} finally {$custody.Dispose();$a.Dispose();$b.Dispose()}
foreach($case in @('count','duplicate','nonempty','closed','readonly','expired','too-far','unspecified','custom-stream')) {
 $custody=OpenCustody;$a=[IO.MemoryStream]::new();$b=[IO.MemoryStream]::new();$deadline=[datetime]::UtcNow.AddSeconds(10);$outputs=[IO.Stream[]]@($a,$b)
 switch($case){
  count {$outputs=[IO.Stream[]]@($a)}
  duplicate {$outputs=[IO.Stream[]]@($a,$a)}
  nonempty {$b.WriteByte(99)}
  closed {$b.Dispose()}
  readonly {$b.Dispose();$b=[IO.MemoryStream]::new([byte[]]@(),$false);$outputs=[IO.Stream[]]@($a,$b)}
  expired {$deadline=[datetime]::UtcNow.AddSeconds(-1)}
  too-far {$deadline=[datetime]::UtcNow.AddSeconds(61)}
  unspecified {$deadline=[datetime]::SpecifyKind($deadline,[DateTimeKind]::Unspecified)}
  custom-stream {$b.Dispose();$b=[RejectedNativeCopyStream]::new();$outputs=[IO.Stream[]]@($a,$b)}
 }
 try{
  $refused=$false;try{$null=$custody.CopyToValidatedStreams($outputs,$deadline)}catch{$refused=$true}
  Check ('prewrite refusal all source handles closed '+$case) ($refused -and $custody.IsDisposed -and $a.Length -eq 0 -and (CanWrite $dll) -and (CanWrite $pdb))
 }finally{$custody.Dispose();$a.Dispose();$b.Dispose()}
}
# Exact MemoryStream with fixed zero capacity fails on write, after first copy.
$custody=OpenCustody;$a=[IO.MemoryStream]::new();$b=[IO.MemoryStream]::new([byte[]]@(),0,0,$true,$true)
try{
 $refused=$false;try{$null=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))}catch{$refused=$true}
 Check 'partial write failure preserves destination bytes and closes every source' ($refused -and $custody.IsDisposed -and $a.Length -eq 4 -and $b.Length -eq 0 -and $a.CanWrite -and (CanWrite $dll) -and (CanWrite $pdb))
}finally{$custody.Dispose();$a.Dispose();$b.Dispose()}
# Actual caller-owned file streams, not publication into MO2.
$custody=OpenCustody;$outA=Join-Path $root 'copy.dll';$outB=Join-Path $root 'copy.pdb'
$a=[IO.File]::Open($outA,'CreateNew','ReadWrite','None');$b=[IO.File]::Open($outB,'CreateNew','ReadWrite','None')
try{
 $proof=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))|ConvertFrom-Json
 Check 'actual caller-owned empty file streams qualify' ($proof.ok -and $a.Length -eq 4 -and $b.Length -eq 3 -and $a.CanWrite -and $b.CanWrite)
}finally{$custody.Dispose();$a.Dispose();$b.Dispose()}
Check 'closed copied file hashes exact' ((Hash $outA) -ceq (Hash $dll) -and (Hash $outB) -ceq (Hash $pdb))
$a=[IO.MemoryStream]::new();$b=[IO.MemoryStream]::new();$custody=OpenCustody;$custody.Dispose()
try{
 $refused=$false;try{$null=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))}catch{$refused=$true}
 Check 'disposed custody refuses without destination writes' ($refused -and $a.Length -eq 0 -and $b.Length -eq 0)
}finally{$a.Dispose();$b.Dispose()}
# Two distinct handles to the same physical destination demonstrate why readback
# must happen for the whole set AFTER the last write. Content proof fails closed;
# this helper does not confer physical destination-ownership proof.
$aliasPath=Join-Path $root 'aliased-destination.bin';$custody=OpenCustody
$a=[IO.File]::Open($aliasPath,'CreateNew','ReadWrite','ReadWrite');$b=[IO.File]::Open($aliasPath,'Open','ReadWrite','ReadWrite')
try{
 $refused=$false;try{$null=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))}catch{$refused=$_.Exception.Message -match 'readback hash mismatch'}
 Check 'later aliased write invalidates earlier copy and no proof returns' ($refused -and $custody.IsDisposed -and $a.Length -eq 4 -and $a.CanWrite -and $b.CanWrite -and (CanWrite $dll) -and (CanWrite $pdb))
}finally{$custody.Dispose();$a.Dispose();$b.Dispose()}
# Low-level helper constructor is not an admission/authority token; it still
# refuses a mismatched content expectation and never returns a qualified proof.
$sourceA=[IO.File]::Open($dll,'Open','Read','Read');$sourceB=[IO.File]::Open($pdb,'Open','Read','Read')
$custody=[SkyrimVRAutomation.NativePlanPayloadCustodyV2]::new('{}',[IO.FileStream[]]@($sourceA,$sourceB),[long[]]@(4,3),[string[]]@(('0'*64),$files[1].sha256))
$a=[IO.MemoryStream]::new();$b=[IO.MemoryStream]::new()
try{
 $refused=$false;try{$null=$custody.CopyToValidatedStreams([IO.Stream[]]@($a,$b),[datetime]::UtcNow.AddSeconds(10))}catch{$refused=$_.Exception.Message -match 'hash mismatch'}
 Check 'mismatched pinned content refuses qualified receipt and preserves partial bytes' ($refused -and $custody.IsDisposed -and $a.Length -eq 4 -and $b.Length -eq 0 -and (CanWrite $dll) -and (CanWrite $pdb))
}finally{$custody.Dispose();$a.Dispose();$b.Dispose()}
foreach($path in $before.Keys){Check ('source unchanged '+[IO.Path]::GetFileName($path)) ((Hash $path) -ceq $before[$path])}
# Public acquisition and copy through more than one64KiB chunk.
$largePath=Join-Path $root 'large.dll';$largePlanPath=Join-Path $root 'large-plan.json';$largeReceiptPath=Join-Path $root 'large-receipt.json'
$large=[byte[]]::new(131073);for($index=0;$index -lt $large.Length;$index++){$large[$index]=[byte]($index%251)}
[IO.File]::WriteAllBytes($largePath,$large);$largeHash=Hash $largePath
Json $largeReceiptPath @{commit=$commit;artifacts=@(@{path=$largePath;bytes=$large.Length;sha256=$largeHash})}
Json $largePlanPath @{schema='mo2.native-install-plan.1';installId=('c'*32);sourceCommit=$commit;profile='Synthetic';leaseId=$lease;modName='Large TEST';buildReceipt=@{path=$largeReceiptPath;sha256=(Hash $largeReceiptPath)};files=@(@{sourcePath=$largePath;relativePath='SKSE/Plugins/large.dll';bytes=$large.Length;sha256=$largeHash})}
$custody=Open-VerifiedNativeInstallPayloadCustody -PlanPath $largePlanPath -ExpectedPlanSha256 (Hash $largePlanPath) -ExpectedSourceCommit $commit -ExpectedProfile Synthetic -ExpectedLeaseId $lease -TimeoutSeconds 10
$a=[IO.MemoryStream]::new()
try{
 $proof=$custody.CopyToValidatedStreams([IO.Stream[]]@($a),[datetime]::UtcNow.AddSeconds(10))|ConvertFrom-Json
 $readback=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($a.ToArray())).ToLowerInvariant()
 Check 'public multi-chunk acquisition copy and independent readback match' ($proof.ok -and $proof.files[0].bytes -eq 131073 -and $proof.files[0].sha256 -ceq $largeHash -and $readback -ceq $largeHash)
}finally{$custody.Dispose();$a.Dispose()}
@{ok=$failures.Count -eq 0;passed=$passed;failed=$failures.Count;failures=$failures.ToArray();cases=$cases.ToArray();fixtureRoot=$root;liveRuntimeUsed=$false;realLeaseUsed=$false;publicationImplemented=$false}|ConvertTo-Json -Depth 12
if($failures.Count){exit 1}
