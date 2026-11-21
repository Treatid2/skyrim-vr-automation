# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
if(-not ('SkyrimVRAutomation.GripSessionClock' -as [type])){
    Add-Type -TypeDefinition 'namespace SkyrimVRAutomation { public static class GripSessionClock { [System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern ulong GetTickCount64(); } }'
}
function Get-GripTick { [SkyrimVRAutomation.GripSessionClock]::GetTickCount64() }
function Read-GripJson([string]$Path){
    $item=Get-Item -LiteralPath $Path
    if($item.PSIsContainer -or $item.Length -gt 8388608){throw 'JSON input exceeds the eight MiB boundary'}
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
}
function Write-GripJson([string]$Path,$Value,[uint64]$Deadline){
    if((Get-GripTick) -ge $Deadline){throw 'Common deadline expired before publication staging'}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30))
    if($bytes.Length -gt 8388608){throw 'JSON output exceeds the eight MiB boundary'}
    $stage=$Path+'.stage-'+[guid]::NewGuid().ToString('N')
    # This function runs inside a supervised worker, never in the coordinator.
    $stream=[IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    if((Get-GripTick) -ge $Deadline){throw 'Common deadline expired before atomic publication; stage is nonauthoritative'}
    [IO.File]::Move($stage,$Path,$false)
}
function Assert-GripDeadline([uint64]$Deadline){if((Get-GripTick) -ge $Deadline){throw 'Inherited absolute deadline expired'}}
function Get-GripOuterIdentity([string]$Root,[string]$Nonce,[int]$CreatorPid,[string]$CreatorFileTime){
    return @{schemaVersion='null-grip-outer-session.1';evidenceRoot=[IO.Path]::GetFullPath($Root);nonce=$Nonce;creatorPid=$CreatorPid;creatorFileTime=$CreatorFileTime}
}
function Assert-GripOuterSession($Expected){
    $claimPath=$Expected.evidenceRoot+'.outer-session.json'
    $item=Get-Item -LiteralPath $claimPath
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Outer session claim must be an ordinary file'}
    $actual=Read-GripJson $claimPath
    foreach($key in @('schemaVersion','evidenceRoot','nonce','creatorPid','creatorFileTime')){
        if($actual[$key] -cne $Expected[$key]){throw 'Outer session claim does not match this exact creator and nonce'}
    }
    if($actual.nonce -cnotmatch '^[0-9a-f]{32}$' -or $actual.creatorPid -isnot [long] -and $actual.creatorPid -isnot [int]){throw 'Malformed outer session identity'}
    $creator=Get-Process -Id ([int]$actual.creatorPid) -ErrorAction Stop
    try{if($creator.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne $actual.creatorFileTime){throw 'Outer coordinator creation identity changed'}}finally{$creator.Dispose()}
    $directory=Get-Item -LiteralPath $Expected.evidenceRoot
    if(-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Outer session evidence root changed'}
}
function Assert-GripOuterRecord($Record,$Expected){
    if($Record -isnot [Collections.IDictionary] -or -not $Record.Contains('outerSession') -or $Record.outerSession -isnot [Collections.IDictionary]){throw 'Lifecycle record is missing its exact outer session identity'}
    foreach($key in @('schemaVersion','evidenceRoot','nonce','creatorPid','creatorFileTime')){
        if($Record.outerSession[$key] -cne $Expected[$key]){throw 'Lifecycle record belongs to a different outer session'}
    }
}
function Convert-GripUInt64($Value){
    [uint64]$number=0
    if($Value -isnot [string] -or $Value -cnotmatch '^(0|[1-9][0-9]*)$' -or -not [uint64]::TryParse($Value,[ref]$number)){throw 'Canonical uint64 decimal string required'}
    return $number
}
function Assert-GripNativeResult($Body,[string]$Mode,$Binding,[uint64]$Ceiling,[bool]$Injected){
    if($Body.schemaVersion -isnot [int] -and $Body.schemaVersion -isnot [long]){throw 'Native result schema version must be an integer'}
    if($Body.schemaVersion -ne 1 -or $Body.mode -cne $Mode -or $Body.injectedFixture -isnot [bool] -or $Body.injectedFixture -ne $Injected){throw 'Wrong, injected or incomplete native diagnostic result'}
    if($Body.clockDomains.tick -cne 'GetTickCount64 milliseconds, same Windows boot'){throw 'Native result uses an unqualified clock domain'}
    if($Body.expectedInstance.pid -ne $Binding.creatorPid -or $Body.expectedInstance.creationFileTime -cne $Binding.creatorFileTime -or $Body.expectedInstance.driverNonce -cne $Binding.driverNonce){throw 'Native diagnostic instance differs from admitted binding'}
    if((Convert-GripUInt64 $Body.workerCeilingTickMs) -ne $Ceiling -or (Convert-GripUInt64 $Body.localRunEndTickMs) -gt $Ceiling){throw 'Native diagnostic renewed or changed its worker ceiling'}
    if($Body.outcome -cne 'diagnostic-complete' -or $Body.exitCode -ne 0 -or $null -ne $Body.partialEvidence -or $Body.postErrors -isnot [array] -or $Body.postErrors.Count -ne 0){throw 'Native diagnostic is partial or has post/close errors'}
    if($Body.controlProtocolValid -isnot [bool] -or -not $Body.controlProtocolValid -or $null -ne $Body.firstControlFailure){throw 'Native diagnostic controller protocol is unverified'}
    if($Body.baselineNeutralEstablished -isnot [bool] -or -not $Body.baselineNeutralEstablished){throw 'Native independent neutral baseline failed'}
    $closeStates=if($Injected){@('completed-return','injected-completed')}else{@('completed-return')}
    if($Body.applicationClose.attempted -isnot [bool] -or -not $Body.applicationClose.attempted -or $Body.applicationClose.completed -isnot [bool] -or -not $Body.applicationClose.completed -or $Body.applicationClose.state -cnotin $closeStates){throw 'Native shutdown did not reach recorded completed-return'}
    # This experiment does not assert external SteamVR client removal.
    if($Body.applicationClose -isnot [Collections.IDictionary] -or -not $Body.applicationClose.Contains('externalUnregistrationVerified') -or $Body.applicationClose.externalUnregistrationVerified -isnot [bool] -or $Body.applicationClose.externalUnregistrationVerified){throw 'Native close must explicitly record Boolean false externalUnregistrationVerified'}
    foreach($key in @('workerCeilingExceeded','localRunCeilingExceeded')){if($Body.closeBoundary[$key] -isnot [bool] -or $Body.closeBoundary[$key]){throw 'Unknown or exceeded native close ceiling'}}
    foreach($key in @('start','end')){if($Body.closeBoundary[$key].state -cne 'known'){throw 'Native close clock is unknown'};[void](Convert-GripUInt64 $Body.closeBoundary[$key].tickMs)}
    if([uint64]$Body.closeBoundary.start.tickMs -gt [uint64]$Body.closeBoundary.end.tickMs -or [uint64]$Body.closeBoundary.end.tickMs -ge $Ceiling){throw 'Native close interval is invalid or late'}
}
function Assert-GripEvidenceRoot([string]$Root,[string]$FixturePath){
    $prefix=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $FixturePath) 'evidence')).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($Root).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Native live evidence must be beneath the selected fixture evidence directory'}
    # Reject parent reparse traversal as well as a textual path-prefix escape.
    $ancestor=Get-Item -LiteralPath (Split-Path -Parent $Root)
    while($null -ne $ancestor){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Evidence ancestors must not be reparse points'};$ancestor=$ancestor.Parent}
}
function Assert-GripFile($Record){
    if($Record.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Record.path) -or $Record.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'An exact absolute artifact path and lowercase SHA256 are required'}
    $item=Get-Item -LiteralPath $Record.path
    if($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Artifact must be an ordinary file'}
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $Record.path).Hash.ToLowerInvariant() -cne $Record.sha256){throw 'Pinned artifact hash changed'}
}
function Open-GripPinnedInput($Record,$Handles){
    # Hash the held handle, never a second mutable pathname read. Concurrent
    # writers/deleters are refused by the OS before this pin can be admitted.
    if($Record.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Record.path) -or $Record.sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Exact selected input required'}
    $item=Get-Item -LiteralPath $Record.path
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Selected input must be an ordinary file'}
    $handle=[IO.File]::Open($Record.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $Handles.Add($handle)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($handle)).ToLowerInvariant();$handle.Position=0
    if($hash -cne $Record.sha256){throw 'Pinned artifact hash changed'}
    return $handle
}
function Protect-GripPlanInputs($Plan,[string]$LifecycleRoot,$Handles){
    foreach($name in @('Invoke-NullHmdGripDiagnostic.ps1','GripLifecycle.Worker.ps1','GripLifecycle.Common.ps1')){
        $path=[IO.Path]::GetFullPath((Join-Path $LifecycleRoot $name))
        $pins=@($Plan.fixtureDependencies | Where-Object {[string]::Equals([IO.Path]::GetFullPath($_.path),$path,[StringComparison]::OrdinalIgnoreCase)})
        if($pins.Count -ne 1){throw 'Every lifecycle script must have exactly one selected pin'}
    }
    foreach($key in @('nullControl','headControl','controllerControl','fixture','atomics','python','provider','openvr','poseProbe','nullProfile','boundedProcess')){[void](Open-GripPinnedInput $Plan[$key] $Handles)}
    foreach($pin in $Plan.fixtureDependencies){[void](Open-GripPinnedInput $pin $Handles)}
}
function Assert-GripPlan($Plan){
    if($Plan.schemaVersion -cne 'null-grip-session.1' -or $Plan.diagnostic -cne 'fixed-grip-neutral-A-B' -or $Plan.standalone -isnot [bool] -or -not $Plan.standalone){throw 'Only the explicitly selected standalone grip diagnostic is supported'}
    foreach($key in @('nullControl','headControl','controllerControl','fixture','atomics','python','provider','openvr','poseProbe','nullProfile')){Assert-GripFile $Plan[$key]}
    if($Plan.fixtureDependencies -isnot [array] -or $Plan.fixtureDependencies.Count -lt 2 -or $Plan.fixtureDependencies.Count -gt 32){throw 'A finite complete fixture-dependency pin set is required'}
    foreach($record in $Plan.fixtureDependencies){Assert-GripFile $record}
    Assert-GripFile $Plan.boundedProcess
    if(-not [IO.Path]::IsPathFullyQualified([string]$Plan.toolkitRoot)){throw 'An exact toolkit root is required'}
    $toolPaths=@{nullControl='tools/steamvr-null-control/Invoke-SteamVRNullControl.ps1';headControl='tools/steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1';controllerControl='tools/steamvr-controller-control/Invoke-SteamVRControllerControl.ps1';boundedProcess='tools/process-control/Invoke-BoundedProcess.ps1';nullProfile='profiles/steamvr-null.profile.json'}
    foreach($key in $toolPaths.Keys){if(-not [string]::Equals([IO.Path]::GetFullPath($Plan[$key].path),[IO.Path]::GetFullPath((Join-Path $Plan.toolkitRoot $toolPaths[$key])),[StringComparison]::OrdinalIgnoreCase)){throw 'Controller pins must address the supported toolkit entry points'}}
    if([string]::IsNullOrWhiteSpace($env:CODEX_PYTHON)){throw 'CODEX_PYTHON is missing from this process environment; explicitly propagate the selected configured stable Python binding before invoking the coordinator'}
    if(-not [string]::Equals([IO.Path]::GetFullPath($Plan.python.path),[IO.Path]::GetFullPath($env:CODEX_PYTHON),[StringComparison]::OrdinalIgnoreCase)){throw 'Use the configured stable Python entry point'}
    foreach($key in @('settingsPath','openVRPathsPath','steamVRRoot','serverLogPath','driverRoot')){if(-not [IO.Path]::IsPathFullyQualified([string]$Plan[$key])){throw 'Runtime paths must be explicit and absolute'}}
    if($Plan.fixture.path -notlike '*\grip_neutral_ab.py'){throw 'The fixed A/B fixture is required'}
    $installedProvider=Join-Path $Plan.driverRoot 'bin/win64/driver_codex_head_pose.dll'
    if([IO.Path]::GetFullPath($Plan.provider.path) -cne [IO.Path]::GetFullPath($installedProvider)){throw 'Provider pin must address the installed runtime DLL'}
}
