# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$parent=if($FixtureRoot){[IO.Path]::GetFullPath($FixtureRoot)}else{[IO.Path]::GetFullPath([IO.Path]::GetTempPath())}
$fixture=Join-Path $parent ('probe-phase-fixture-'+[guid]::NewGuid().ToString('N'))
$passes=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$passes.Add($Message)}
try {
 $entry=Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
 Check (@($errors).Count -eq 0) 'production controller parses'
 Check (@($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -ceq 'ProbeDiagnosticPhases'}).Count -eq 1) 'public diagnostic switch explicit and default-off'
 $function=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-ApplicationHeadPose'},$true))
 Check ($function.Count -eq 1) 'exact production application probe function selected'
 $runtimeCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-NullRuntimeEvidence'},$true))
 Check ($runtimeCalls.Count -eq 3) 'all original runtime evidence call sites retained'
 foreach($call in $runtimeCalls){Check ($call.Extent.Text.Contains('-DiagnosticPhases:$ProbeDiagnosticPhases')) 'runtime call explicitly forwards public opt-in'}
 $appCall=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-ApplicationHeadPose'},$true))
 Check ($appCall.Count -eq 1 -and $appCall[0].Extent.Text.Contains('-DiagnosticPhases:$DiagnosticPhases')) 'creator/package gate explicitly forwards opt-in only to admitted probe'
 foreach($dir in @('tools/steamvr-null-control','tools/process-control','provider/tools')){[IO.Directory]::CreateDirectory((Join-Path $fixture $dir))|Out-Null}
 [IO.File]::WriteAllText((Join-Path $fixture 'provider/tools/csx_openvr_pose_probe.exe'),'Synthetic fixture marker, never executable.')
 $setup=@'
param([string]$Fixture,[switch]$DiagnosticPhases,[switch]$Expired,[switch]$BadAuthority)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$HeadPoseDriverRoot=Join-Path $Fixture 'provider'
function Get-NullProviderAuthority {param($DeadlineUtc) [pscustomobject]@{verified=(-not $BadAuthority);markerSha256='fixture';errors=@('fixture refusal')}}
function New-HeadPoseContinuityIdentity {param($Pose,$PackageAuthority) [pscustomobject]@{fixture='same'}}
function Assert-HeadPoseContinuity {param($Before,$After)}
function Get-HeadPoseCanonicalPath {param($Path) [IO.Path]::GetFullPath($Path)}
'@
 $run=@'
$contract=@{poseProbeRelativePath='tools/csx_openvr_pose_probe.exe'}
$deadline=if($Expired){[datetime]::UtcNow.AddSeconds(-1)}else{[datetime]::UtcNow.AddSeconds(90)}
Get-ApplicationHeadPose -Contract $contract -PreProbePose @{} -PreProbePackageAuthority @{} -DeadlineUtc $deadline -DiagnosticPhases:$DiagnosticPhases|ConvertTo-Json -Depth 60 -Compress
'@
 $harness=Join-Path $fixture 'tools/steamvr-null-control/harness.ps1'
 [IO.File]::WriteAllText($harness,($setup+"`n"+$function[0].Extent.Text+"`n"+$run))
 $fake=@'
param($FilePath,[string[]]$ArgumentList,$WorkingDirectory,$MaxAttempts,$TimeoutSeconds,$TerminationGraceMilliseconds,$StreamDrainGraceMilliseconds,[switch]$NoExit,[switch]$Compact)
$record=@{args=$ArgumentList;file=$FilePath;maxAttempts=$MaxAttempts;timeout=$TimeoutSeconds;terminationGrace=$TerminationGraceMilliseconds;drainGrace=$StreamDrainGraceMilliseconds}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'dispatch.json'),($record|ConvertTo-Json -Compress))
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'case.json') -Raw
'@
 $processRoot=Join-Path $fixture 'tools/process-control'
 [IO.File]::WriteAllText((Join-Path $processRoot 'Invoke-BoundedProcess.ps1'),$fake)
 $stderr="CSX_OPENVR_PROBE_PHASE_V1 seq=1 call=1 phase=VR_Init state=entered sample=-1 hand=-1`n"
 $bounded=@{ok=$false;attempts=@(@{timedOut=$true;stdout='';stderr=$stderr;exitVerified=$true;jobQuiescent=$true;streamDrainComplete=$true;pid=123});errors=@('synthetic10s timeout')}
 [IO.File]::WriteAllText((Join-Path $processRoot 'case.json'),($bounded|ConvertTo-Json -Depth 20 -Compress))
 foreach($enabled in @($false,$true)){
  $result=& $harness -Fixture $fixture -DiagnosticPhases:$enabled|ConvertFrom-Json -Depth 60
  $dispatch=Get-Content -LiteralPath (Join-Path $processRoot 'dispatch.json') -Raw|ConvertFrom-Json
  $expected=if($enabled){@('--require-controllers','--diagnostic-phases')}else{@('--require-controllers')}
  Check (($dispatch.args -join '|') -ceq ($expected -join '|')) "opt-in=$enabled exact admitted native argv"
  Check ($dispatch.maxAttempts -eq 1 -and $dispatch.timeout -eq 10 -and $dispatch.terminationGrace -eq 100 -and $dispatch.drainGrace -eq 100) "opt-in=$enabled retains attempt/budget/cleanup limits"
  Check ($result.timedOut -and $result.terminalFailure -and $result.failureKind -ceq 'timeout' -and -not $result.qualified) "opt-in=$enabled breadcrumbs cannot qualify timeout"
  Check ($result.boundedProcess.attempts[0].stderr -ceq $stderr -and $result.boundedProcess.attempts[0].stdout -ceq '') "opt-in=$enabled exact partial native streams retained"
  Check ($result.boundedProcess.attempts[0].exitVerified -and $result.boundedProcess.attempts[0].jobQuiescent) "opt-in=$enabled exact cleanup evidence retained"
 }
 $dispatchPath=Join-Path $processRoot 'dispatch.json';$before=(Get-FileHash $dispatchPath).Hash
 foreach($case in @('Expired','BadAuthority')){
  $flags=@{Fixture=$fixture;DiagnosticPhases=$true};$flags[$case]=$true
  $result=& $harness @flags|ConvertFrom-Json -Depth 60
  Check (-not $result.probeAttempted -and -not $result.qualified -and $result.terminalFailure) "$case refuses before diagnostic dispatch"
  Check ((Get-FileHash $dispatchPath).Hash -ceq $before) "$case does not dispatch or replay"
 }
 @{ok=$true;passed=$passes.Count;passes=@($passes);liveRuntimeUsed=$false;nativeCompiledOrExecuted=$false;scope='Actual production functions with synthetic bounded adapter; AST public propagation; raw timeout custody, no native or runtime execution'}|ConvertTo-Json -Depth 8 -Compress
}finally{
 $resolved=[IO.Path]::GetFullPath($fixture)
 if(-not $resolved.StartsWith($parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup boundary refused'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

