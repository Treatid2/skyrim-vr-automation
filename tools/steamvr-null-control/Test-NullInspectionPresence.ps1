[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('null-inspection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$copied=Join-Path $fixture 'tools/steamvr-null-control'
$poseDir=Join-Path $fixture 'tools/steamvr-head-pose-control'
$null=New-Item -ItemType Directory -Path $copied,$poseDir
foreach($name in @('Invoke-SteamVRNullControl.ps1','StartupLogProof.ps1','DesktopUIRestore.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $copied $name)}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../steamvr-head-pose-control/DriverPackageAuthority.ps1') -Destination $poseDir
$entry=Join-Path $copied 'Invoke-SteamVRNullControl.ps1'
$text=[IO.File]::ReadAllText($entry)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Production parse failure.'}
# Only external observations and transaction lock/recovery are synthetic. The
# copied public inspect branch, classification, input contract and result writer
# remain the production code. No OS inventory, runtime probe or shared state.
$scenarioPath=Join-Path $fixture 'scenario.json'
$quoted=$scenarioPath.Replace("'","''")
$replacements=@{
 'Get-SteamVRProcesses'="function Get-SteamVRProcesses { (Get-Content -LiteralPath '$quoted' -Raw|ConvertFrom-Json -Depth 40).processes }"
 'Get-NullRuntimeEvidence'="function Get-NullRuntimeEvidence { param(`$Processes,`$Profile,`$DeadlineUtc,[switch]`$DiagnosticPhases,[switch]`$DiagnosticFailedRoles) (Get-Content -LiteralPath '$quoted' -Raw|ConvertFrom-Json -Depth 40).runtime }"
 'Get-ExternalDriverInventory'="function Get-ExternalDriverInventory { param(`$Path) (Get-Content -LiteralPath '$quoted' -Raw|ConvertFrom-Json -Depth 40).external }"
 'Get-SteamVRTargetControl'="function Get-SteamVRTargetControl { param(`$Settings,`$OpenVRPaths,`$ControlRoot) @{journalPath='$quoted.never-journal';lockPath='$quoted.never-lock'} }"
 'Enter-SteamVRTargetLock'='function Enter-SteamVRTargetLock { param($Control,$TimeoutMilliseconds) $null }'
 'Resolve-PendingSteamVRJournal'='function Resolve-PendingSteamVRJournal { param($JournalPath) $null }'
}
foreach($node in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $replacements.Keys},$true)|Sort-Object {$_.Extent.StartOffset} -Descending)){
 $text=$text.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset).Insert($node.Extent.StartOffset,$replacements[$node.Name])
}
[IO.File]::WriteAllText($entry,$text,[Text.UTF8Encoding]::new($false))
$profilePath=Join-Path $fixture 'profile.json'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../profiles/steamvr-null.profile.json') -Destination $profilePath
$settingsPath=Join-Path $fixture 'settings.json'
$registration=Join-Path $fixture 'openvrpaths.json'
[IO.File]::WriteAllText($registration,'{}')
$steamRoot=Join-Path $fixture 'SteamVR'
$headRoot=Join-Path $fixture 'head-provider'
$outside=Join-Path $fixture 'unrelated/vrserver.exe'
$cases=@(
 @{name='configured-empty';count=0;expected='null-configured-runtime-stopped'},
 @{name='configured-running-without-proof';count=13;expected='null-runtime-active-unqualified'},
 @{name='helper-only';count=1;expected='null-runtime-active-unqualified'},
 @{name='later-log-rotation';count=13;expected='null-runtime-active-unqualified';rotation=$true},
 @{name='log-ready-pose-not-ready';count=1;active=$true;expected='head-pose-provider-not-ready'},
 @{name='qualified';count=1;active=$true;ready=$true;expected='null-runtime-active-head-pose-ready'},
 @{name='authorization-error';count=13;denied=$true;expected='head-pose-provider-authorization-failed'},
 @{name='inventory-error';count=13;inventoryError=$true;expected='external-driver-inventory-failed'},
 @{name='provider-absent';count=13;providerAbsent=$true;expected='head-pose-provider-unavailable'},
 @{name='redirector-conflict';count=13;conflict=$true;expected='external-driver-conflict'},
 @{name='non-null-config-running';count=1;inactive=$true;expected='null-inactive'},
 @{name='unproven-only';count=0;unproven=$true;expected='null-configured-runtime-stopped'},
 @{name='running-plus-unproven';count=2;unproven=$true;expected='null-runtime-active-unqualified'}
)
$checks=[Collections.Generic.List[string]]::new()
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "Fixture assertion failed: $Name"};$checks.Add($Name)}
$results=@()
foreach($case in $cases){
 $settings=Get-Content -LiteralPath $profilePath -Raw|ConvertFrom-Json -AsHashtable
 if($case['inactive']){$settings.steamvr.forcedDriver='not-null'}
 [IO.File]::WriteAllText($settingsPath,($settings|ConvertTo-Json -Depth 30))
 $processes=@(for($i=0;$i -lt $case.count;$i++){[ordered]@{name=if($case.name -eq 'helper-only'){'vrwebhelper'}elseif($i -eq 0){'vrserver'}else{'vrwebhelper'};id=100+$i;path=Join-Path $steamRoot 'bin/win64/vrserver.exe';startTimeUtc='2026-10-10T19:34:56.4045058Z'}})
 if($case['unproven']){$processes+=@{name='vrserver';id=777;path=$outside;startTimeUtc='2026-10-10T19:00:00Z'}}
 $runtime=@{active=[bool]$case['active'];headPoseReady=[bool]$case['ready'];controllersReady=[bool]$case['ready'];packageAuthority=@{verified=[bool]$case['ready']};headPoseAuthorizationError=if($case['denied']){'fixture-access-denied'}else{$null};applicationHeadPose=@{probeAttempted=$false};startupLogProof=@{terminalFailure=[bool]$case['rotation'];error=if($case['rotation']){'Startup log subsequent rotation/replacement is not supported.'}else{$null}}}
 $external=@{drivers=@(if(-not $case['providerAbsent']){@{name='codex_head_pose';root=$headRoot}});errors=@(if($case['inventoryError']){'fixture-inventory-error'});conflicts=@(if($case['conflict']){'fixture-display-redirector'})}
 [IO.File]::WriteAllText($scenarioPath,(@{processes=$processes;runtime=$runtime;external=$external}|ConvertTo-Json -Depth 40))
 $before=(Get-FileHash -LiteralPath $settingsPath).Hash
 $raw=(& $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamRoot -HeadPoseDriverRoot $headRoot -ServerLogPath (Join-Path $fixture 'never-live.log') -OpenVRPathsPath $registration -NoExit -Compact|Out-String).Trim()
 $r=$raw|ConvertFrom-Json -Depth 60
 Assert ($r.state -ceq $case.expected) ($case.name+':state')
 Assert ($r.ok -eq (-not [bool]$case['denied'])) ($case.name+':original-ok-semantics')
 Assert ($r.data.processPresence.ownedProcessCount -eq $case.count) ($case.name+':owned-count')
 Assert ($r.data.processPresence.unprovenProcessCount -eq [int][bool]$case['unproven']) ($case.name+':unproven-count')
 Assert ($r.data.processPresence.closureVerified -eq ($case.count -eq 0)) ($case.name+':scoped-closure')
 Assert ($r.data.processPresence.state -ceq $(if($case.count){'processes-present'}else{'inventory-empty'})) ($case.name+':presence')
 Assert ($r.data.processPresence.scope -ceq 'configured-SteamVR-root-pre-probe-process-inventory') ($case.name+':scope')
 Assert (-not $r.data.runtime.applicationHeadPose.probeAttempted) ($case.name+':no-extra-probe')
 Assert ($r.data.inputContract.measurementReady -eq ([bool]$case['ready'])) ($case.name+':qualification-unchanged')
 Assert (-not $r.data.inputContract.replayReady) ($case.name+':no-replay-admission')
 Assert ((Get-FileHash -LiteralPath $settingsPath).Hash -ceq $before) ($case.name+':settings-unchanged')
 Assert ($r.data.processes.Count -eq $processes.Count) ($case.name+':full-inventory-retained')
 $results+=@{name=$case.name;state=$r.state;processPresence=$r.data.processPresence;measurementReady=$r.data.inputContract.measurementReady;probeAttempted=$r.data.runtime.applicationHeadPose.probeAttempted}
}
@{ok=$true;checks=$checks.Count;cases=$results;seams=@($replacements.Keys);scope='Copied production public inspect entry; synthetic process/runtime/external inventory and lock/recovery boundaries only';runtimeOperations=0;fixture=$fixture}|ConvertTo-Json -Depth 30 -Compress
