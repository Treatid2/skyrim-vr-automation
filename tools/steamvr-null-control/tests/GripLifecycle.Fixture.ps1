# SPDX-License-Identifier: GPL-3.0-or-later
# Fixed in-process injection for the real session entry point. No DLL/map/runtime.
function Assert-GripFixtureOwner($Record){
    $live=Get-Process -Id ([int]$Record.id) -ErrorAction SilentlyContinue
    if($null -eq $live){return}
    if($live.Path -cne $Record.path -or $live.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -cne $Record.creationFileTime){throw 'Disposable fixture child identity changed'}
}
function Get-GripFixtureInventory {
    $path=Join-Path $Root 'fixture-child.json'
    if(-not (Test-Path -LiteralPath $path)){return @()}
    $record=Read-GripJson $path
    Assert-GripFixtureOwner $record
    if($null -eq (Get-Process -Id ([int]$record.id) -ErrorAction SilentlyContinue)){return @()}
    return @($record)
}
function Invoke-GripFixture([string]$Name,[string]$Command,[hashtable]$Options){
    $settings=Join-Path $Root 'fixture-settings.txt'
    $registration=Join-Path $Root 'fixture-registration.txt'
    if(-not (Test-Path -LiteralPath $settings)){[IO.File]::WriteAllText($settings,'original-fixture-settings');[IO.File]::WriteAllText($registration,'original-fixture-registration')}
    if($Name -eq 'nullControl'){
        switch($Command){
            inspect {
                $inventory=@(Get-GripFixtureInventory)
                $effective=[IO.File]::ReadAllText($settings) -ceq 'applied-fixture-settings'
                return @{ok=$true;state=if($effective){'null-configured-runtime-stopped'}else{'null-inactive'};data=@{runtime=@{steamVrProcesses=$inventory};effective=@{active=$effective};settingsSha256=(Get-FileHash $settings).Hash;externalDrivers=@{sha256=(Get-FileHash $registration).Hash}}}
            }
            apply {
                if($Options.ContainsKey('WhatIf')){return @{ok=$true;state='dry-run'}}
                [IO.File]::WriteAllText($settings,'applied-fixture-settings')
                return @{ok=$true;state='null-applied'}
            }
            start {
                $pwsh=(Get-Process -Id $PID).Path
                $launch=& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'GripLifecycle.Launcher.ps1') -Root $Root | ConvertFrom-Json -AsHashtable
                if($LASTEXITCODE -ne 0){throw 'Fixture launcher failed'}
                $inventory=@(Get-GripFixtureInventory)
                if($inventory.Count -ne 1){throw 'Persistent child did not survive startup parent exit'}
                Save 'startup-child-custody' @{launcherExited=$launch.launcherExited;childAliveAfterLauncherExit=$true;child=$inventory[0]}
                if($OfflineCase -eq 'startup-stall'){Start-Sleep -Seconds 3600}
                return @{ok=$true;state='null-runtime-started-head-pose-ready';data=@{runtimeReceiptPersisted=$true;runtime=@{serverProcess=$inventory[0]}}}
            }
            stop {
                $inventory=@(Get-GripFixtureInventory)
                if($OfflineCase -in @('cleanup-unknown','baseline-cleanup-unknown')){return @{ok=$false;data=@{remaining=$inventory}}}
                foreach($record in $inventory){Assert-GripFixtureOwner $record;Stop-Process -Id ([int]$record.id) -Force -ErrorAction Stop}
                return @{ok=$true;data=@{remaining=@()}}
            }
            restore {
                $content=if($OfflineCase -eq 'restore-drift'){'corrupted-fixture-restoration'}else{'original-fixture-settings'}
                [IO.File]::WriteAllText($settings,$content)
                return @{ok=$true;state='restored'}
            }
        }
    }
    if($Name -eq 'headControl'){
        $counter=Join-Path $Root 'fixture-neutral-count.txt'
        $count=if(Test-Path -LiteralPath $counter){[int][IO.File]::ReadAllText($counter)}else{0}
        [IO.File]::WriteAllText($counter,($count+1).ToString())
        return @{ok=($count -eq 0);state='fixture-neutral';data=@{controllers=@{valid=($count -eq 0)};applicationPose=@{boundedRun=@{attempts=@(@{launched=$true;exitVerified=$true;processTreeOwned=$true;jobQuiescent=$true;jobClosed=$true;streamDrainComplete=$true;deadlineSatisfied=$true;timedOut=$false;terminationRequested=$false;unresolvedProcess=$false})}}}}
    }
    if($Name -eq 'controllerControl'){
        $child=Read-GripJson (Join-Path $Root 'fixture-child.json')
        $boundPid=if($OfflineCase -eq 'binding-mismatch'){[int]$child.id+1}else{[int]$child.id}
        $afterA=Test-Path -LiteralPath (Join-Path $Root 'injected-assay-A.json')
        $neutral=@{pressed='0';touched='0';trackpad=@(0.0,0.0);stick=@(0.0,0.0);trigger=0.0;grip=0.0}
        $pair=@{left=$neutral.Clone();right=$neutral.Clone()}
        $provider=@{inputHealthy=$true;activeOwner='0';deadlineTickMs='0';pair=$pair}
        $binding=@{creatorPid=$boundPid;creatorFileTime=$child.creationFileTime;driverNonce='12345'}
        if($afterA){switch($OfflineCase){
            'owner-busy' {$provider.activeOwner='7'}
            'deadline-active' {$provider.deadlineTickMs='7'}
            'pair-active' {$provider.pair.right.grip=0.1}
            'health-unknown' {$provider.inputHealthy=$null}
            'runtime-changed' {$binding.driverNonce='12346'}
        }}
        return @{ok=$true;data=@{provider=$provider;binding=$binding}}
    }
    throw 'Unknown injected owner operation'
}
function Invoke-GripFixtureAssay([string]$Mode){
    if($Mode -eq 'A' -and $OfflineCase -eq 'assay-stall'){Start-Sleep -Seconds 3600}
    if($Mode -eq 'A' -and $OfflineCase -eq 'abnormal-assay-exit'){exit 17}
    $tick=(Get-GripTick).ToString()
    $body=@{schemaVersion=1;injectedFixture=$true;expectedInstance=@{pid=$script:binding.creatorPid;creationFileTime=$script:binding.creatorFileTime;driverNonce=$script:binding.driverNonce};workerCeilingTickMs=$PositiveDeadlineTickMs.ToString();localRunEndTickMs=$PositiveDeadlineTickMs.ToString();outcome='diagnostic-complete';exitCode=0;partialEvidence=$null;postErrors=@();controlProtocolValid=$true;firstControlFailure=$null;baselineNeutralEstablished=($OfflineCase -notin @('baseline-failure','baseline-cleanup-unknown'));applicationClose=@{attempted=$true;completed=($OfflineCase -ne 'close-unknown');externalUnregistrationVerified=$false;state=if($OfflineCase -eq 'close-unknown'){'unknown'}else{'completed-return'}};closeBoundary=@{start=@{state='known';tickMs=$tick};end=@{state='known';tickMs=$tick};workerCeilingExceeded=$false;localRunCeilingExceeded=$false};semanticMismatches=if($OfflineCase -eq 'semantic-mismatch'){@(@{case='10';leftGripMissing=$true})}else{@()};mode=$Mode}
    $body.clockDomains=@{tick='GetTickCount64 milliseconds, same Windows boot'}
    if($Mode -eq 'A'){switch($OfflineCase){
        'result-injected' {$body.injectedFixture=$false}
        'result-instance' {$body.expectedInstance.driverNonce='12346'}
        'result-ceiling' {$body.workerCeilingTickMs=($PositiveDeadlineTickMs+[uint64]1).ToString()}
        'close-errors' {$body.postErrors=@(@{reason='injected close failure'})}
        'close-state' {$body.applicationClose.state='unknown'}
        'close-clock-unknown' {$body.closeBoundary.end.state='unknown';$body.closeBoundary.end.tickMs=$null}
        'result-partial' {$body.partialEvidence=@{reason='incomplete'}}
    }}
    Save ('injected-assay-'+$Mode) $body
    return $body
}
