# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([string]$ResultPath)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ($root.EndsWith('plugins\skyrim-vr-automation',[StringComparison]::OrdinalIgnoreCase)) { throw 'Run aggregate validation from ROOT, not plugin mirror.' }
$watch=[Diagnostics.Stopwatch]::StartNew();$started=[DateTime]::UtcNow
$members=@('ScreenshotSequenceEvidence.psm1','ColourCasRejectionEvidence.psm1','Test-ScreenshotSequenceEvidence.ps1','Test-ColourCasRejectionEvidence.ps1','PR46-PR51-BOUNDED-EVIDENCE.md','Test-BoundedNativeEvidence.ps1')
$hashes=@();$results=@();$checks=0
foreach ($name in $members) {
    $source=Join-Path $PSScriptRoot $name;$mirror=Join-Path $root ('plugins/skyrim-vr-automation/tools/devbench-control/'+$name)
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath $mirror -Algorithm SHA256).Hash -cne $hash) { throw "Source/plugin mismatch: $name" }
    if ($name -match '\.ps(m)?1$') { $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);if($errors.Count){throw "Parse failure: $name"} }
    $hashes+=[pscustomobject]@{path='tools/devbench-control/'+$name;bytes=(Get-Item -LiteralPath $source).Length;sha256=$hash.ToLowerInvariant();pluginParity=$true}
}
foreach ($tree in @('tools/devbench-control','plugins/skyrim-vr-automation/tools/devbench-control')) {
    foreach ($name in @('Test-ScreenshotSequenceEvidence.ps1','Test-ColourCasRejectionEvidence.ps1')) {
        $result=& (Join-Path $root ($tree+'/'+$name))|ConvertFrom-Json -Depth 10
        if (-not $result.ok) { throw "Fixture failure: $tree/$name" }
        $checks+=$result.checks;$results+=[pscustomobject]@{tree=$tree;suite=$name;ok=$result.ok;checks=$result.checks;scope=$result.scope}
    }
}
foreach ($member in $hashes) { if ((Get-FileHash -LiteralPath (Join-Path $root $member.path)).Hash.ToLowerInvariant() -cne $member.sha256) {throw 'Source changed during validation'} }
$watch.Stop()
$receipt=[ordered]@{ok=$true;sourceRoot=$root;sourceHead=(& git -C $root rev-parse HEAD).Trim();startedUtc=$started.ToString('o');completedUtc=[DateTime]::UtcNow.ToString('o');durationMs=$watch.ElapsedMilliseconds;checks=$checks;members=$hashes;results=$results;scope='pure source-bound synthetic schema qualification only; no transport/runtime/worker/artifact-file/deployment/review qualification'}
if ($ResultPath) { if(Test-Path -LiteralPath $ResultPath){throw 'Immutable validation receipt exists'};[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResultPath)))|Out-Null;[IO.File]::WriteAllText($ResultPath,($receipt|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false)) }
$receipt|ConvertTo-Json -Depth 15 -Compress
