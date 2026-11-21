# SPDX-License-Identifier: GPL-3.0-or-later
# Disposable selection-boundary fixture, NOT a production process-custody owner.
param([string]$FilePath,[string[]]$ArgumentList,[string]$WorkingDirectory,[int]$TimeoutSeconds,[int]$MaxAttempts,[string[]]$RetryPatterns,[int]$TerminationGraceMilliseconds,[int]$StreamDrainGraceMilliseconds,[switch]$NoExit,[switch]$Compact)
$ErrorActionPreference='Stop'
$stage=$ArgumentList[[Array]::IndexOf($ArgumentList,'-Stage')+1]
$root=$ArgumentList[[Array]::IndexOf($ArgumentList,'-Root')+1]
$manifest=Get-Content -LiteralPath (Join-Path $root 'selected-inputs.json') -Raw | ConvertFrom-Json -AsHashtable
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'selection-fixture.json') -Raw | ConvertFrom-Json -AsHashtable
$checks=[Collections.Generic.List[object]]::new()
foreach($path in @($config.proposal,$manifest.plan.path,$manifest.worker.path,$manifest.common.path,$config.coordinator,$manifest.boundedProcess.path,$manifest.python.path)){
    $bytes=[IO.File]::ReadAllBytes($path)
    $denied=$false
    try{[IO.File]::WriteAllBytes($path,$bytes)}catch [IO.IOException]{$denied=$true}
    if(-not $denied){throw "Selected input was writable at $stage boundary: $path"}
    $renameDenied=$false
    try{[IO.File]::Move($path,$path+'.replacement')}catch [IO.IOException]{$renameDenied=$true}
    if(-not $renameDenied){throw "Selected input was replaceable at $stage boundary: $path"}
    $checks.Add(@{path=$path;writeDenied=$true;replacementDenied=$true})
}
# The replacement plan is independently self-consistent but changes targets.
# A real worker presented with those bytes and the original expected hash must
# reject BEFORE Common, ownership reads, lifecycle error publication or cleanup.
$badArgs=[string[]]$ArgumentList.Clone()
$badArgs[[Array]::IndexOf($badArgs,'-PlanPath')+1]=$config.alternatePlan
$badOutput=& $FilePath @badArgs 2>&1 | Out-String
$badExit=$LASTEXITCODE
if($badExit -eq 0 -or $badOutput -notlike '*Selected worker/plan/Common hash changed before admission*'){throw 'A real worker admitted substituted plan bytes'}
if(Test-Path -LiteralPath (Join-Path $root 'ownership.json')){throw 'Substitution reached session ownership'}
if(Test-Path -LiteralPath (Join-Path $root 'first-failure.json')){throw 'Rejected worker entered lifecycle publication/cleanup'}
if(Test-Path -LiteralPath $config.controlMarker){throw 'An alternate controller was invoked'}
# Native stage admission uses the same guard, independently of session nesting.
$nativeArgs=[string[]]$badArgs.Clone();$nativeArgs[[Array]::IndexOf($nativeArgs,'-Stage')+1]='native-A'
$nativeOutput=& $FilePath @nativeArgs 2>&1 | Out-String
if($LASTEXITCODE -eq 0 -or $nativeOutput -notlike '*Selected worker/plan/Common hash changed before admission*'){throw 'Native worker admitted substituted plan bytes'}
$evidence=@{stage=$stage;checks=$checks.ToArray();workerRefusedChangedPlan=$true;nativeWorkerRefusedChangedPlan=$true;workerHashArgumentsPropagated=($ArgumentList -contains '-ExpectedWorkerSha256' -and $ArgumentList -contains '-ExpectedCommonSha256');runtimeResponsesSimulated=$true;processCustodySimulated=$true}
[IO.File]::WriteAllText((Join-Path $root ('selection-boundary-'+$stage+'.json')),($evidence | ConvertTo-Json -Depth 6))
# Deliberately unqualified stage: no clean handoff, successful process receipt
# or native/product qualification may be inferred from this boundary fixture.
@{ok=$false;attempts=@();fixtureOnly=$true} | ConvertTo-Json -Compress
