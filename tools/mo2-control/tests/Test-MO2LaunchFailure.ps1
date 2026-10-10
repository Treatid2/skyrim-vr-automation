[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\MO2Control.psm1') -Force
$module = Get-Module MO2Control
$fixture = Join-Path $FixtureRoot ('launch-failure-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $fixture 'logs') -Force
$passes = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $passes.Add($Name)
}
$results = & $module {
    param($root)
    $names = @('Resolve-MO2OwnedProcessTarget','Get-MO2OwnedSession','Invoke-MO2Validate','Get-MO2ProcessRecords','Get-MO2DispatchBoundChildEvidence','Invoke-MO2OwnedSessionMutation','Get-MO2InspectionData','Get-MO2WindowSnapshot')
    if (Get-Command Get-MO2TaskWorkspaceIsolation -ErrorAction SilentlyContinue) { $names += 'Get-MO2TaskWorkspaceIsolation' }
    $originals = @{}
    foreach ($name in $names) { $originals[$name] = (Get-Command $name).ScriptBlock }
    $cfg = [pscustomobject]@{ mo2 = [pscustomobject]@{ root=$root; executable=(Join-Path $root 'ModOrganizer.exe'); processNames=@('FixtureMO2'); gameProcessNames=@('FixtureGame') }; limits=[pscustomobject]@{} }
    $binary = Join-Path $root 'sksevr_loader.exe'
    $validation = [pscustomobject]@{ ok=$true; warnings=@(); errors=@(); data=[pscustomobject]@{ executables=@([pscustomobject]@{title='Fixture SKSE';binary=$binary}); config=[pscustomobject]@{mo2Executable=$cfg.mo2.executable}; processes=[pscustomobject]@{mo2=@();game=@()}; sessionLock=[pscustomobject]@{ownerIdentityMatched=$false} } }
    $logPath = Join-Path $root 'logs\mo_interface.log'
    $argumentLine = '--profile "Fixture Profile" run --executable "Fixture SKSE"'
    $command = '"' + $cfg.mo2.executable + '" ' + $argumentLine
    $dispatch = [DateTime]::UtcNow.AddSeconds(-5)
    $script:FailureOwner = [pscustomobject]@{id=111;name='FixtureMO2';path=$cfg.mo2.executable;startTime=$dispatch.AddMilliseconds(100).ToString('o')}
    $script:FailureResolutionOk = $true
    $owned = [pscustomobject]@{path='fixture-lock';sessionId='fixture';accessId='fixture';data=[pscustomobject]@{status='launching';profile='Fixture Profile';executable='Fixture SKSE';launchAttemptId=[guid]::NewGuid().ToString('D');launchDispatchedUtc=$dispatch.ToString('o')}}
    function Boundary([bool]$Retained=$false) { New-MO2LaunchLogBoundary -Config $cfg -Validation $validation -AttemptId $owned.data.launchAttemptId -Profile $owned.data.profile -Executable $owned.data.executable -ArgumentLine $argumentLine -RetainedOwner $Retained }
    function Probe([object[]]$Games=@(),[object[]]$Owners=@($script:FailureOwner)) { Get-MO2LaunchFailureEvidence -Config $cfg -Owned $owned -MO2Processes $Owners -GameProcesses $Games }
    function Error-Block([string]$Binary=$binary,[DateTime]$Stamp=$dispatch.AddSeconds(1),[int]$Code=5) {
        $time = $Stamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
        "[$time E] Error $Code ERROR_ACCESS_DENIED: Accessisdenied. (0x5)`r`n[$time E]  . binary: '$Binary'`r`n"
    }
    function Fresh-Log([string]$Command=$command,[DateTime]$Stamp=$dispatch.AddMilliseconds(200)) { "[$($Stamp.ToString('yyyy-MM-dd HH:mm:ss.fff')) D] command line: '$Command'`r`n" + (Error-Block) }
    function Write-Log([string]$Text) { [IO.File]::WriteAllText($logPath,$Text,[Text.UTF8Encoding]::new($false)) }
    $out = [ordered]@{}
    try {
        Set-Item Function:script:Resolve-MO2OwnedProcessTarget { [pscustomobject]@{ok=$script:FailureResolutionOk;adopted=$false;targets=@($script:FailureOwner);ownerPid=111} }
        $owned.data | Add-Member launchLogBoundary (Boundary)
        Write-Log (Fresh-Log)
        $out.fresh = Probe
        Write-Log (Fresh-Log -Command 'foreign')
        $out.foreignHeader = Probe
        Write-Log (Fresh-Log -Stamp $dispatch.AddMinutes(-1))
        $out.oldHeader = Probe
        Write-Log (Fresh-Log)
        $out.gamePresent = Probe -Games @([pscustomobject]@{id=222})
        $out.extraOwner = Probe -Owners @($script:FailureOwner,$script:FailureOwner)
        $script:FailureResolutionOk = $false
        $out.changedOwner = Probe
        $script:FailureResolutionOk = $true
        # Retained logs cannot correlate delayed same-command actions to a request.
        Write-Log (Error-Block -Stamp $dispatch.AddMinutes(-1))
        $owned.data.launchLogBoundary = Boundary -Retained $true
        $out.oldOnly = Probe
        [IO.File]::AppendAllText($logPath,(Error-Block),[Text.UTF8Encoding]::new($false))
        $out.retainedBareAppend = Probe
        [IO.File]::AppendAllText($logPath,(Fresh-Log),[Text.UTF8Encoding]::new($false))
        $out.retainedExactHeader = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Error-Block),[Text.UTF8Encoding]::new($false))
        $out.freshBareAppend = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Fresh-Log),[Text.UTF8Encoding]::new($false))
        $out.append = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        # A genuinely fresh log with error before its matching command header.
        Write-Log ((Error-Block) + (Fresh-Log).Split("`r`n")[0] + "`r`n")
        $out.errorBeforeHeader = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        Write-Log ((Fresh-Log) -replace [regex]::Escape($dispatch.AddSeconds(1).ToString('yyyy-MM-dd HH:mm:ss.fff')), $dispatch.AddMilliseconds(150).ToString('yyyy-MM-dd HH:mm:ss.fff'))
        $out.timeBeforeHeader = Probe
        Write-Log ((Fresh-Log) + (Fresh-Log -Command 'foreign'))
        $out.multipleHeaders = Probe
        # Replacement with identical sampled anchors must still fail generation proof.
        Write-Log ('p' * 256 + 'middle' + 't' * 128)
        $owned.data.launchLogBoundary = Boundary
        $oldBytes = [IO.File]::ReadAllBytes($logPath)
        $replacement = $logPath + '.replacement'
        [IO.File]::WriteAllBytes($replacement,$oldBytes)
        [IO.File]::AppendAllText($replacement,"`r`n" + (Fresh-Log),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($replacement,$logPath,$true)
        $out.sameAnchorsReplacement = Probe
        # Restore a stable baseline for the following fresh-truncation positive.
        Write-Log 'old baseline'
        $owned.data.launchLogBoundary = Boundary
        Write-Log (Error-Block)
        $out.retainedRotation = Probe
        Write-Log 'old baseline'
        $owned.data.launchLogBoundary = Boundary
        Write-Log (Fresh-Log)
        $out.freshReplacement = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Fresh-Log).Split("`r`n")[0] + "`r`n" + (Error-Block -Binary (Join-Path $root 'foreign.exe')))
        $out.otherBinary = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Fresh-Log).Split("`r`n")[0] + "`r`n" + (Error-Block -Stamp ([DateTime]::UtcNow.AddMinutes(1))))
        $out.future = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Fresh-Log).Split("`r`n")[0] + "`r`n" + ((Error-Block) -replace "\. binary:",'. other:'))
        $out.partial = Probe
        Write-Log 'baseline'
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,"`r`n" + (Fresh-Log).Split("`r`n")[0] + "`r`n" + (Error-Block -Code 193))
        $out.otherCode = Probe
        $owned.data.launchLogBoundary.attemptId = [guid]::NewGuid().ToString('D')
        $out.otherAttempt = Probe
        Write-Log ('x' * 270000)
        $out.byteBudget = Read-MO2LaunchLogWindow -Path $logPath
        $owned.data.launchLogBoundary = Boundary
        [IO.File]::AppendAllText($logPath,("`r`n" + ('x' * 270000) + "`r`n" + (Error-Block)))
        $out.overBudget = Probe
        # Real public launch/status entry points; mock OS dispatch only, never a live MO2.
        Set-Item Function:script:Get-MO2OwnedSession { $script:FailureOwned }
        Set-Item Function:script:Invoke-MO2Validate { $validation }
        if ($names -contains 'Get-MO2TaskWorkspaceIsolation') { Set-Item Function:script:Get-MO2TaskWorkspaceIsolation { [pscustomobject]@{ok=$true} } }
        $script:FailureGameAppeared = $false
        Set-Item Function:script:Get-MO2ProcessRecords { param($Names) if ($script:FailureDispatched -and $Names -contains 'FixtureMO2') { @($script:FailureOwner) } elseif ($script:FailureGameAppeared -and $Names -contains 'FixtureGame') { @([pscustomobject]@{id=222}) } else { @() } }
        Set-Item Function:script:Get-MO2DispatchBoundChildEvidence { @() }
        Set-Item Function:script:Invoke-MO2OwnedSessionMutation { param($Owned,$Action) $result = & $Action $Owned.data; $Owned.data=$result.sessionData; $Owned.data.generation++; $result.result }
        Set-Item Function:script:Get-MO2InspectionData { [pscustomobject]@{processes=[pscustomobject]@{mo2=@($script:FailureOwner);game=@()};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{exists=$true;status=$script:FailureOwned.data.status}} }
        Set-Item Function:script:Get-MO2WindowSnapshot { @() }
        Set-Item Function:script:Start-Process {
            $now = [DateTime]::UtcNow
            $script:FailureOwner.startTime = $now.ToString('o')
            $script:FailureDispatched = $true
            Write-Log ("[$($now.AddMilliseconds(10).ToString('yyyy-MM-dd HH:mm:ss.fff')) D] command line: '$command'`r`n" + (Error-Block -Stamp $now.AddMilliseconds(20)))
            Start-Sleep -Milliseconds 30
            [pscustomobject]@{Id=111;StartTime=$now;HasExited=$false;ExitCode=$null}
        }
        foreach ($mode in @('sync','startOnly')) {
            $sessionPath = Join-Path $root $mode
            $null = New-Item -ItemType Directory -Path $sessionPath
            $script:FailureDispatched = $false
            $script:FailureOwned = [pscustomobject]@{path='fixture-lock';sessionId=$mode;accessId='fixture';data=[pscustomobject]@{status='prepared';profile='Fixture Profile';executable='Fixture SKSE';sessionPath=$sessionPath;generation=0L;accessId='fixture';gameProcesses=@()}}
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $launch = Invoke-MO2Launch -Config $cfg -SessionId $mode -TimeoutSeconds 10 -StartOnly:($mode -eq 'startOnly')
            $terminal = if ($mode -eq 'startOnly') { Invoke-MO2Status -Config $cfg -SessionId $mode } else { $launch }
            $timer.Stop()
            if (-not $script:FailureOwned.data.PSObject.Properties['launchFailureReceiptPath']) { throw ("Public $mode classification missing: " + ($terminal | ConvertTo-Json -Depth 12 -Compress) + ' boundary=' + ($script:FailureOwned.data | ConvertTo-Json -Depth 12 -Compress)) }
            $out[$mode] = [pscustomobject]@{launch=$launch;terminal=$terminal;seconds=$timer.Elapsed.TotalSeconds;generation=$script:FailureOwned.data.generation;receipt=Get-Content -LiteralPath $script:FailureOwned.data.launchFailureReceiptPath -Raw | ConvertFrom-Json;repeat=Invoke-MO2Status -Config $cfg -SessionId $mode}
        }
        $proof = $out.startOnly.receipt
        $script:FailureOwned.data.status = 'launching'
        $generationBefore = $script:FailureOwned.data.generation
        $oldStart = $script:FailureOwner.startTime
        $script:FailureOwner.startTime = [DateTime]::UtcNow.AddMinutes(1).ToString('o')
        $out.commitOwnerChanged = $false
        try { $null = Set-MO2LaunchFailureEvidence -Config $cfg -Owned $script:FailureOwned -Failure $proof } catch { $out.commitOwnerChanged = $script:FailureOwned.data.generation -eq $generationBefore }
        $script:FailureOwner.startTime = $oldStart
        $script:FailureGameAppeared = $true
        $out.commitGameAppeared = $false
        try { $null = Set-MO2LaunchFailureEvidence -Config $cfg -Owned $script:FailureOwned -Failure $proof } catch { $out.commitGameAppeared = $script:FailureOwned.data.generation -eq $generationBefore }
        $script:FailureGameAppeared = $false
        $script:FailureOwned.data.launchAttemptId = [guid]::NewGuid().ToString('D')
        $out.commitAttemptChanged = $false
        try { $null = Set-MO2LaunchFailureEvidence -Config $cfg -Owned $script:FailureOwned -Failure $proof } catch { $out.commitAttemptChanged = $script:FailureOwned.data.generation -eq $generationBefore }
    }
    finally {
        foreach ($name in $names) { Set-Item "Function:script:$name" -Value $originals[$name] }
        Remove-Item Function:script:Start-Process -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name FailureOwner,FailureResolutionOk,FailureOwned,FailureDispatched,FailureGameAppeared -ErrorAction SilentlyContinue
    }
    [pscustomobject]$out
} $fixture
foreach ($name in @('fresh','append','freshReplacement')) { Assert-Test ($results.$name.win32ErrorCode -eq 5 -and $results.$name.cause -eq 'unassigned' -and $results.$name.windowStableAtVerification) "classify $name exact spawn denial without guessing cause" }
foreach ($name in @('foreignHeader','oldHeader','gamePresent','extraOwner','changedOwner','oldOnly','retainedRotation','retainedBareAppend','retainedExactHeader','freshBareAppend','errorBeforeHeader','timeBeforeHeader','multipleHeaders','sameAnchorsReplacement','otherBinary','future','partial','otherAttempt','overBudget')) { Assert-Test ($null -eq $results.$name) "refuse $name evidence" }
Assert-Test ($results.otherCode.win32ErrorCode -eq 193 -and $results.otherCode.classification -eq 'loader-spawn-failed') 'preserve other Win32 error without calling it access denial'
Assert-Test ($results.byteBudget.bytesRead -eq 262144 -and $results.byteBudget.truncated) 'read budget is 256KiB, no full large-log scan'
foreach ($mode in @('sync','startOnly')) {
    $r = $results.$mode
    Assert-Test (-not $r.terminal.ok -and $r.terminal.state -eq 'launch-failed' -and $r.seconds -lt 5) "$mode public terminal classification precedes ten-second timeout"
    Assert-Test ($r.receipt.win32ErrorCode -eq 5 -and $r.receipt.cause -eq 'unassigned' -and $r.receipt.owner.id -eq 111) "$mode retains exact error/owner receipt"
    Assert-Test (-not $r.repeat.ok -and $r.repeat.state -eq 'launch-failed') "$mode later status retains failure instead of reporting mo2-running"
}
Assert-Test ($results.startOnly.launch.ok -and $results.startOnly.launch.state -eq 'launching') 'StartOnly dispatch remains immediate, status owns later classification'
foreach ($name in @('commitOwnerChanged','commitGameAppeared','commitAttemptChanged')) { Assert-Test $results.$name "serialized commit refuses $name without advancing generation" }
[pscustomobject]@{ok=$true;tests=$passes.Count;passes=@($passes);fixturePath=$fixture} | ConvertTo-Json -Depth 5
