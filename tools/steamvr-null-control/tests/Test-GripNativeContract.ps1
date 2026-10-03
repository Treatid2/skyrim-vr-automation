# SPDX-License-Identifier: GPL-3.0-or-later
param(
    [Parameter(Mandatory)][string]$TestIndexPath,
    [Parameter(Mandatory)][string]$TestIndexSha256,
    [Parameter(Mandatory)][string]$FixturePath,
    [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'GripLifecycle.Common.ps1')
Assert-GripFile @{path=$TestIndexPath;sha256=$TestIndexSha256}
$index=Read-GripJson $TestIndexPath
if($index.productionRuntimeAccess -ne $false -or $index.DLLConstructorsDenied -ne $true -or $index.results.Count -lt 1 -or $index.results.Count -gt 64){throw 'A bounded injected native result index is required'}
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New contract-test evidence root required'}
$rows=[Collections.Generic.List[object]]::new()
foreach($record in $index.results){
    Assert-GripFile $record
    if((Get-Item -LiteralPath $record.path).Length -ne $record.bytes){throw 'Native result size changed'}
    $body=Read-GripJson $record.path
    $binding=@{creatorPid=$body.expectedInstance.pid;creatorFileTime=$body.expectedInstance.creationFileTime;driverNonce=$body.expectedInstance.driverNonce}
    $accepted=$true
    try{Assert-GripNativeResult $body $body.mode $binding (Convert-GripUInt64 $body.workerCeilingTickMs) $true}catch{$accepted=$false}
    if($accepted -ne ($record.exitCode -eq 0)){throw ('Native injected result disagrees with coordinator guard: '+$record.test)}
    $liveRejected=$false
    try{Assert-GripNativeResult $body $body.mode $binding (Convert-GripUInt64 $body.workerCeilingTickMs) $false}catch{$liveRejected=$true}
    if(-not $liveRejected){throw 'Injected evidence admitted as a live native result'}
    $rows.Add(@{test=$record.test;sha256=$record.sha256;injectedAccepted=$accepted;liveRejected=$liveRejected})
}
$valid=Join-Path (Join-Path (Split-Path -Parent $FixturePath) 'evidence') ('contract-root-'+[guid]::NewGuid().ToString('N'))
Assert-GripEvidenceRoot $valid $FixturePath
$escaped=Join-Path (Split-Path -Parent $FixturePath) ('escaped-'+[guid]::NewGuid().ToString('N'))
$rootRejected=$false
try{Assert-GripEvidenceRoot $escaped $FixturePath}catch{$rootRejected=$true}
if(-not $rootRejected -or (Test-Path -LiteralPath $escaped)){throw 'Invalid evidence-root placement was not a nonmutating rejection'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$result=@{ok=$true;scope='Immutable native injected result replay against Main coordinator guards; no OpenVR/DLL execution';count=$rows.Count;results=$rows.ToArray();liveQualified=$false;evidenceRootEscapeRejected=$rootRejected;testIndex=@{path=$TestIndexPath;sha256=$TestIndexSha256}}
$path=Join-Path $EvidenceDirectory 'test-receipt.json'
Write-GripJson $path $result ((Get-GripTick)+[uint64]10000)
@{ok=$true;count=$rows.Count;receipt=$path;liveQualified=$false} | ConvertTo-Json -Compress
