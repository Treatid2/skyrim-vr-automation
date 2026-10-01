[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\MO2Control.psm1') -Force
$module = Get-Module MO2Control
$root = Join-Path $FixtureRoot ('run-button-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$result = & $module {
    param($root)
    $null = Initialize-MO2UiAutomation
    $cfg = [pscustomobject]@{mo2=[pscustomobject]@{root=$root;executable=(Join-Path $root 'FixtureMO2.exe');processNames=@('FixtureMO2');gameProcessNames=@('FixtureGame')};limits=[pscustomobject]@{}}
    $script:RunOwner = [pscustomobject]@{id=111;name='FixtureMO2';path=$cfg.mo2.executable;startTime=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')}
    $script:RunWindow = [pscustomobject]@{Current=[pscustomobject]@{NativeWindowHandle=123;IsEnabled=$true}}
    $script:RunControls = @{}
    foreach ($id in @('profileBox','executablesListBox','startButton')) {
        $script:RunControls[$id] = [pscustomobject]@{Current=[pscustomobject]@{AutomationId=$id;ProcessId=111;IsEnabled=$true;IsOffscreen=$false;Name=$(if ($id -eq 'startButton') {'Run'} else {'unused'});ControlType=$(if ($id -eq 'startButton') {[System.Windows.Automation.ControlType]::Button} else {[System.Windows.Automation.ControlType]::ComboBox})};FixtureId=$id}
    }
    $script:RunProfile='Fixture Profile'; $script:RunExecutable='Fixture SKSE'
    $script:RunVisible = @([pscustomobject]@{visible=$true;automationAvailable=$true;automationId='MainWindow';handle=123})
    $binding = [pscustomobject]@{Id=111;ProcessName='FixtureMO2';Path=$cfg.mo2.executable;StartTime=[DateTimeOffset]::Parse($script:RunOwner.startTime).UtcDateTime;HasExited=$false;SafeHandle=[pscustomobject]@{IsInvalid=$false;IsClosed=$false}}
    $binding | Add-Member ScriptMethod Refresh {} | Out-Null
    $binding | Add-Member ScriptMethod Dispose {} | Out-Null
    $script:RunBinding=$binding
    $entry=[pscustomobject]@{title='Fixture SKSE';binary=(Join-Path $root 'sksevr_loader.exe');arguments='';workingDirectory=$root}
    $script:RunValidation=[pscustomobject]@{ok=$true;warnings=@();errors=@();data=[pscustomobject]@{config=[pscustomobject]@{mo2Executable=$cfg.mo2.executable};executables=@($entry);processes=[pscustomobject]@{mo2=@($script:RunOwner);game=@()};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{ownerIdentityMatched=$true}}}
    function Reset-Fixture {
        $script:RunOwned=[pscustomobject]@{path='fixture-lock';sessionId='fixture';accessId='private-fixture';data=[pscustomobject]@{generation=1;accessId='private-fixture';status='mo2-open';profile='Fixture Profile';executable='Fixture SKSE';sessionPath=$root;requirements=[pscustomobject]@{skseLoader=$true};ownerPid=111}}
        $script:RunInvokes=0; $script:RunDesktop=$true; $script:RunThrow=$false; $script:RunStale=$false; $script:RunGame=$false; $script:RunObserveAfterUI=$false
    }
    Set-Item Function:script:Get-MO2OwnedSession { $script:RunOwned }
    Set-Item Function:script:Test-MO2InteractiveDesktop { $script:RunDesktop }
    Set-Item Function:script:Invoke-MO2Validate { $script:RunValidation }
    Set-Item Function:script:Resolve-MO2OwnedProcessTarget { [pscustomobject]@{ok=$true;targets=@($script:RunOwner);adopted=$false;ownerPid=111;reason='exact-fixture-owner'} }
    Set-Item Function:script:Get-MO2ProcessRecords { param($Names) if ($Names -contains 'FixtureMO2') {@($script:RunOwner)} elseif ($script:RunGame) {@([pscustomobject]@{id=222;name='FixtureGame'})} else {@()} }
    Set-Item Function:script:Get-Process { $script:RunBinding }
    Set-Item Function:script:Get-MO2WindowSnapshot { @($script:RunVisible) }
    Set-Item Function:script:Get-MO2AutomationWindows { @($script:RunWindow) }
    Set-Item Function:script:Invoke-MO2UiAutomationFindAll { param($Window,$Scope,$Condition) if ($script:RunControls.ContainsKey([string]$Condition.Value)) {@($script:RunControls[[string]$Condition.Value])} else {@()} }
    Set-Item Function:script:Get-MO2RunSelectionValue { param($Element) if ($Element.FixtureId -eq 'profileBox') {$script:RunProfile} else {$script:RunExecutable} }
    Set-Item Function:script:Start-Process { throw 'Unexpected CLI process dispatch in RunButton test.' }
    Set-Item Function:script:Invoke-MO2OwnedSessionMutation { param($Owned,$Action) $changed=& $Action $Owned.data; $Owned.data=$changed.sessionData; $Owned.data.generation++; $changed.result }
    Set-Item Function:script:Invoke-MO2OwnedProcessAction { param($Config,$Owned,$Process,$Action,$ArgumentList) if ($script:RunStale) {throw 'stale generation'}; if ($Owned.data.status -ne 'launching') {throw 'invocation before durable pending commit'}; & $Action @ArgumentList }
    Set-Item Function:script:Invoke-MO2AutomationButton { $script:RunInvokes++; if ($script:RunThrow) {throw 'uncertain UI dispatch'}; if ($script:RunObserveAfterUI) {$script:RunGame=$true}; $true }
    Set-Item Function:script:Get-MO2InspectionData { [pscustomobject]@{processes=[pscustomobject]@{mo2=@($script:RunOwner);game=@(if ($script:RunGame) {[pscustomobject]@{id=222;name='FixtureGame'}})};rootBuilder=[pscustomobject]@{active=@()};sessionLock=[pscustomobject]@{exists=$true}} }
    Set-Item Function:script:Get-MO2ObservedGameProcessAdoption { [pscustomobject]@{eligible=$true;records=@([pscustomobject]@{id=222;name='FixtureGame'});reasons=@()} }
    Set-Item Function:script:Set-MO2OwnedSessionGameProcesses { param($Owned,$Processes) $script:RunOwned.data.status='running'; $script:RunOwned.data | Add-Member NoteProperty gameProcesses @($Processes) -Force }
    Set-Item Function:script:Resolve-MO2RecordedGameProcessTargets { [pscustomobject]@{ok=$true;targets=@([pscustomobject]@{id=222;name='FixtureGame'});reasons=@()} }
    if (Get-Command Get-MO2TaskWorkspaceIsolation -ErrorAction SilentlyContinue) { Set-Item Function:script:Get-MO2TaskWorkspaceIsolation { [pscustomobject]@{ok=$true} } }
    $passes = [Collections.Generic.List[string]]::new()
    function Check($Condition,[string]$Name) { if (-not $Condition) {throw "FAIL: $Name"};$passes.Add($Name) }
    function Refused([scriptblock]$Action,[string]$Name) { $caught=$false;try {& $Action | Out-Null} catch {$caught=$true};Check $caught $Name }
    Reset-Fixture
    $preview=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -WhatIf
    Check ($preview.ok -and $preview.state -eq 'dry-run' -and $script:RunInvokes -eq 0 -and $script:RunOwned.data.status -eq 'mo2-open') 'preview verifies exact controls without dispatch or lifecycle change'
    $casePreview=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod runbutton -WhatIf
    Check ($casePreview.ok -and $casePreview.data.launchMethod -ceq 'RunButton' -and $script:RunInvokes -eq 0) 'case-insensitive valid method never silently falls back to CLI'
    $script:RunProfile='Foreign Profile'
    Refused {Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -WhatIf} 'foreign visible profile refused without changing selection'
    $script:RunProfile='Fixture Profile';$script:RunExecutable='Foreign EXE'
    Refused {Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -WhatIf} 'foreign visible executable refused'
    $script:RunExecutable='Fixture SKSE'
    $script:RunVisible += [pscustomobject]@{visible=$true;automationAvailable=$false;automationId='unknown';handle=456}
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'unknown visible modal refused'
    $script:RunVisible=@($script:RunVisible[0])
    $script:RunControls.startButton.Current.IsEnabled=$false
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'disabled Run refused'
    $script:RunControls.startButton.Current.IsEnabled=$true;$script:RunControls.startButton.Current.ProcessId=222
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'foreign process control refused'
    $script:RunControls.startButton.Current.ProcessId=111
    $script:RunControls.startButton.Current.Name='Not Run'
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'unrecognised button name refused'
    $script:RunControls.startButton.Current.Name='Run'
    $savedControl=$script:RunControls.profileBox
    $script:RunControls.profileBox=@($savedControl,$savedControl)
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'duplicate exact selector refused'
    $script:RunControls.profileBox=$savedControl
    $qualified=@{
        profileBox='MainWindow.centralWidget.categoriesSplitter.splitter.layoutWidget.profileBox'
        executablesListBox='MainWindow.centralWidget.categoriesSplitter.splitter.layoutWidget_2.startGroup.executablesListBox'
        startButton='MainWindow.centralWidget.categoriesSplitter.splitter.layoutWidget_2.startGroup.startButton'
    }
    foreach($id in @('profileBox','executablesListBox','startButton')) {
        $control=$script:RunControls[$id];$script:RunControls.Remove($id)
        $control.Current.AutomationId=$qualified[$id];$script:RunControls[$qualified[$id]]=$control
    }
    $native=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -WhatIf
    Check ($native.ok -and $script:RunInvokes -eq 0 -and $script:RunOwned.data.status -eq 'mo2-open') 'exact Qt parent-qualified IDs verify preview without selection or dispatch'
    $nativeProof=Get-MO2RunButtonProof $script:RunOwner
    Check ($nativeProof.controlIds.startButton -ceq $qualified.startButton -and $nativeProof.controlIds.profileBox -ceq $qualified.profileBox) 'proof retains actual full Qt control identities'
    $script:RunControls['profileBox']=$script:RunControls[$qualified.profileBox]
    Refused {Get-MO2RunButtonProof $script:RunOwner} 'bare and qualified selector ambiguity refuses rather than preferring one'
    $script:RunControls.Remove('profileBox')
    $qProfile=$script:RunControls[$qualified.profileBox];$script:RunControls.Remove($qualified.profileBox)
    $script:RunControls['ForeignWindow.profileBox']=$qProfile
    $diagnostic=$null
    try {Get-MO2RunButtonProof $script:RunOwner|Out-Null} catch {$diagnostic=$_.Exception.Data['MO2RunControlDiscovery']}
    Check ($null -ne $diagnostic -and @($diagnostic.queries).Count -eq 2 -and @($diagnostic.queries|Where-Object matches -ne 0).Count -eq 0 -and $diagnostic.maxQueries -eq 6 -and -not $diagnostic.nativeRpcDeadlineEnforced -and $script:RunInvokes -eq 0) 'foreign prefix rejected with finite selector counts and honest native RPC deadline limitation'
    $script:RunControls.Remove('ForeignWindow.profileBox');$script:RunControls[$qualified.profileBox]=$qProfile
    Reset-Fixture
    $qualifiedLaunch=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    $qualifiedReceipt=Get-Content -LiteralPath (Join-Path $root 'mo2-launch-started.json') -Raw|ConvertFrom-Json
    Check ($qualifiedLaunch.ok -and $script:RunInvokes -eq 1 -and $qualifiedReceipt.runButtonProof.automationId -ceq $qualified.startButton) 'one protected qualified Run invocation receipts actual identity'
    foreach($id in @('profileBox','executablesListBox','startButton')) {
        $control=$script:RunControls[$qualified[$id]];$script:RunControls.Remove($qualified[$id])
        $control.Current.AutomationId=$id;$script:RunControls[$id]=$control
    }
    Reset-Fixture;$script:RunDesktop=$false
    $desktop=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    Check ($desktop.state -eq 'interactive-desktop-required' -and $script:RunInvokes -eq 0) 'noninteractive route refuses before dispatch'
    Reset-Fixture;$script:RunOwned.data.status='prepared'
    $closed=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    Check ($closed.state -eq 'blocked' -and $script:RunInvokes -eq 0) 'Run never opens or adopts MO2 implicitly'
    Reset-Fixture
    $launch=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    $receipt=Get-Content -LiteralPath (Join-Path $root 'mo2-launch-started.json') -Raw | ConvertFrom-Json
    Check ($launch.ok -and $launch.state -eq 'launching' -and $script:RunInvokes -eq 1 -and $script:RunOwned.data.status -eq 'launching') 'exact Run invoked once only after pending attempt commit'
    Check ($receipt.launchMethod -eq 'RunButton' -and $receipt.runButtonProof.invocationState -eq 'invoked' -and $receipt.requestedPid -eq 111 -and @($receipt.arguments).Count -eq 0) 'receipt binds method, selection, control and original owner without helper or fictitious CLI arguments'
    $repeat=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    Check ($repeat.state -eq 'blocked' -and $script:RunInvokes -eq 1) 'pending attempt blocks replay'
    Reset-Fixture;$script:RunObserveAfterUI=$true
    try { $sync=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -TimeoutSeconds 2 }
    catch { throw "$($_.Exception.Message)`n$($_.ScriptStackTrace)" }
    Check ($sync.ok -and $sync.state -eq 'game-running' -and $script:RunInvokes -eq 1 -and $script:RunOwned.data.status -eq 'running') 'synchronous Run uses normal exact game adoption after one UI invocation'
    Reset-Fixture;$script:RunObserveAfterUI=$true
    $start=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    $status=Invoke-MO2Status -Config $cfg -SessionId fixture
    Check ($start.state -eq 'launching' -and $status.ok -and $script:RunOwned.data.status -eq 'running' -and $script:RunInvokes -eq 1) 'StartOnly status adopts game without replaying Run'
    Reset-Fixture;$script:RunThrow=$true
    $uncertain=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    Check ($uncertain.state -eq 'launch-dispatch-uncertain' -and $script:RunOwned.data.status -eq 'launching' -and $script:RunInvokes -eq 1) 'UI exception retains pending authority without automatic retry'
    Reset-Fixture;$script:RunStale=$true
    $stale=Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly
    Check ($stale.state -eq 'launch-dispatch-uncertain' -and $script:RunInvokes -eq 0) 'stale protected-action authority refuses invocation'
    Reset-Fixture;$script:RunGame=$true
    Refused {Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly} 'game appearing during admission refuses Run'
    Reset-Fixture;$script:RunBinding.HasExited=$true
    Refused {Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly} 'ended process handle refuses Run'
    $script:RunBinding.HasExited=$false
    Reset-Fixture
    $script:RunValidation.data.rootBuilder.active=@([pscustomobject]@{path=(Join-Path $root 'BuildData.json')})
    Refused {Invoke-MO2Launch -Config $cfg -SessionId fixture -LaunchMethod RunButton -StartOnly} 'active RootBuilder deployment refuses before Run'
    $passes.ToArray()
} $root
[pscustomobject]@{ok=$true;passed=@($result).Count;passes=@($result)} | ConvertTo-Json -Depth 4
