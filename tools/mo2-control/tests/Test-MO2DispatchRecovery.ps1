# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($FixtureRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Pass an acquired fixture root.' }
$fixture = Join-Path $root ('dispatch-recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MO2Control.psm1') -Force
$module = Get-Module MO2Control
$passes = [Collections.Generic.List[string]]::new()
function Assert-Fixture([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name)
}
$shapes = & $module {
    $results = @()
    foreach ($shape in @('missing','empty','singleton','multiple')) {
        $data = [pscustomobject]@{ status = 'prepared' }
        if ($shape -ne 'missing') {
            [object[]]$records = @()
            if ($shape -eq 'singleton') { $records = @([pscustomobject]@{ id = 1 }) }
            if ($shape -eq 'multiple') { $records = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 }) }
            $data | Add-Member -NotePropertyName gameProcesses -NotePropertyValue $records
        }
        Reset-MO2GameProcessStateForLaunch -Data $data -LaunchAttemptId 'new-attempt' -LaunchDispatchedUtc ([DateTime]::UtcNow.ToString('o')) -PreLaunchGameProcesses @()
        $results += [pscustomobject]@{ shape = $shape; empty = @($data.gameProcesses).Count -eq 0; historyCount = if ($data.PSObject.Properties['gameProcessHistory']) { @($data.gameProcessHistory[0].processes).Count } else { 0 } }
    }
    $results
}
foreach ($shape in $shapes) {
    $count = switch ($shape.shape) { singleton { 1 }; multiple { 2 }; default { 0 } }
    Assert-Fixture ($shape.empty -and $shape.historyCount -eq $count) "reset preserves $($shape.shape) array shape/history"
}
$dialog = & $module {
    [pscustomobject]@{
        known = Get-MO2KnownDialogKind -Title 'Cannot launch program' -Texts @('Cannot start sksevr_loader.exe')
        unknown = Get-MO2KnownDialogKind -Title 'Unrelated program' -Texts @('Cannot start sksevr_loader.exe')
        incomplete = Get-MO2KnownDialogKind -Title 'Cannot launch program' -Texts @('Generic antivirus suggestion')
    }
}
Assert-Fixture ($dialog.known -eq 'failed-to-run' -and $null -eq $dialog.unknown -and $null -eq $dialog.incomplete) 'classify exact launch-error title/text, leave unknown dialogs untouched'
$exe = Join-Path $fixture 'DispatchRecoveryFixture.exe'
Copy-Item -LiteralPath $env:ComSpec -Destination $exe
$sessionPath = Join-Path $fixture 'session'
New-Item -ItemType Directory -Path $sessionPath | Out-Null
$lockPath = Join-Path $fixture 'lock.json'
$cfg = [pscustomobject]@{
    contractVersion = '1.0.0'; machine = 'fixture'
    mo2 = [pscustomobject]@{ executable = $exe; processNames = @('DispatchRecoveryFixture'); gameProcessNames = @('DispatchRecoveryAbsentGame') }
    defaults = [pscustomobject]@{}; storage = [pscustomobject]@{}; limits = [pscustomobject]@{}
    session = [pscustomobject]@{ lockFile = $lockPath }
}
$freshDispatch = & $module {
    param($c,$fixturePath)
    $names = @('Get-MO2OwnedSession','Invoke-MO2Validate','Get-MO2ProcessRecords','Write-MO2JsonAtomic','Get-MO2DispatchBoundChildEvidence','Invoke-MO2OwnedSessionMutation')
    if (Get-Command Get-MO2TaskWorkspaceIsolation -ErrorAction SilentlyContinue) { $names += 'Get-MO2TaskWorkspaceIsolation' }
    $originals = @{}
    foreach ($name in $names) { $originals[$name] = (Get-Command $name).ScriptBlock }
    $script:FreshOwned = [pscustomobject]@{ path = 'fixture-lock'; sessionId = 'fresh-fixture'; accessId = 'fixture'; data = [pscustomobject]@{ status = 'prepared'; profile = 'Fixture'; executable = 'Fixture'; sessionPath = $fixturePath; generation = 2L; leaseId = 'fixture'; accessId = 'fixture' } }
    $script:FreshWrites = [Collections.Generic.List[object]]::new()
    try {
        Set-Item Function:script:Get-MO2OwnedSession { $script:FreshOwned }
        Set-Item Function:script:Invoke-MO2Validate { [pscustomobject]@{ ok = $true; warnings = @(); errors = @(); data = [pscustomobject]@{ config = [pscustomobject]@{ mo2Executable = $c.mo2.executable }; processes = [pscustomobject]@{ mo2 = @(); game = @() }; sessionLock = [pscustomobject]@{ ownerIdentityMatched = $false } } } }
        if ($names -contains 'Get-MO2TaskWorkspaceIsolation') { Set-Item Function:script:Get-MO2TaskWorkspaceIsolation { [pscustomobject]@{ ok = $true; errors = @() } } }
        Set-Item Function:script:Get-MO2ProcessRecords { @() }
        Set-Item Function:script:Write-MO2JsonAtomic { param($Path,$Value) $script:FreshWrites.Add(($Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -DateKind String)) }
        Set-Item Function:script:Get-MO2DispatchBoundChildEvidence { throw 'injected child inventory failure' }
        Set-Item Function:script:Start-Process { [pscustomobject]@{ Id = 123; StartTime = [DateTime]::UtcNow } }
        Set-Item Function:script:Invoke-MO2OwnedSessionMutation { param($Owned,$Action) $outcome = & $Action $Owned.data; $Owned.data = $outcome.sessionData; $Owned.data.generation++; $outcome.result }
        $result = Invoke-MO2Launch -Config $c -SessionId 'fresh-fixture' -StartOnly
        [pscustomobject]@{ result = $result; data = $script:FreshOwned.data; writes = @($script:FreshWrites) }
    }
    finally {
        foreach ($name in $names) { Set-Item "Function:script:$name" -Value $originals[$name] }
        Remove-Item Function:script:Start-Process
        Remove-Variable -Scope Script -Name FreshOwned,FreshWrites
    }
} $cfg $fixture
Assert-Fixture ($freshDispatch.result.ok -and $freshDispatch.result.state -eq 'launching' -and @($freshDispatch.data.gameProcesses).Count -eq 0 -and $freshDispatch.data.ownerPid -eq 123) 'fresh public StartOnly launch commits owner without prior gameProcesses'
Assert-Fixture ($freshDispatch.writes[-2].requestedPid -eq 123 -and $freshDispatch.writes[-1].childProbeError -eq 'injected child inventory failure' -and $freshDispatch.data.ownerTransition.requestedPid -eq 123) 'record dispatched lifetime before child probe and commit owner despite probe failure'
$controller = & $module { param($c,$p) New-MO2DurableSessionController -Config $c -SessionPath $p } $cfg $sessionPath
$deepSession = Join-Path $fixture ('deep-' + ('x' * 120))
$deepController = & $module { param($c,$p) New-MO2DurableSessionController -Config $c -SessionPath $p } $cfg $deepSession
Assert-Fixture ($deepController.controllerPath.Length -gt 260 -and $deepController.binding.receiptPhysicalIdentity -and @($deepController.binding.files).Count -eq @($deepController.files).Count) 'producer binds deep retained controller members beyond native MAX_PATH'
$attempt = [guid]::NewGuid().ToString('D')
$access = [guid]::NewGuid().ToString('D')
$data = [pscustomobject]@{
    contractVersion = '1.0.0'; sessionId = 'fixture-dispatch'; accessId = $access; leaseId = 'fixture-lease'
    generation = 2L; status = 'prepared'; ownerTaskId = 'fixture-task'; ownerPid = $PID
    sessionPath = $sessionPath; controllerPath = $controller.controllerPath
    controllerConfigPath = $controller.configPath; controllerReceiptPath = $controller.receiptPath
    controllerBundleBinding = $controller.binding
    profile = 'Fixture Profile'; executable = 'Fixture SKSE'; createdUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
}
$data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $lockPath
$manifestPath = Join-Path $sessionPath 'session.json'
$data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath
$dispatch = [DateTime]::UtcNow.ToString('o')
$process = Start-Process -FilePath $exe -ArgumentList '/c ping -n 120 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
try {
    $receiptPath = Join-Path $sessionPath 'mo2-launch-started.json'
    $receipt = [pscustomobject]@{
        sessionId = $data.sessionId; mo2Path = $exe; arguments = @('--profile','Fixture Profile','run','--executable','Fixture SKSE')
        argumentLine = '--profile "Fixture Profile" run --executable "Fixture SKSE"'
        attemptId = $attempt; launchAttemptId = $attempt; requestedPid = $process.Id
        requestedProcessStartTime = $process.StartTime.ToUniversalTime().ToString('o'); startedUtc = $dispatch; dispatchStartedUtc = $dispatch
        preDispatchProcesses = @(); preLaunchGameProcesses = @(); rootBuilderRecovery = $false; dispatchBoundChildren = @()
    }
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    $candidate = [pscustomobject]@{ id = $process.Id; name = $process.ProcessName; path = $exe; startTime = $receipt.requestedProcessStartTime }
    $owned = [pscustomobject]@{ path = $lockPath; sessionId = $data.sessionId; accessId = $access; data = $data }
    $proofArgs = @($cfg,$owned,$attempt,$candidate)
    $matrix = & $module {
        param($c,$o,$a,$p)
        function Test-Proof($oo = $o,$pp = @($p),$games = @(),$task = 'fixture-task',$attemptId = $a,$generation = 2L) {
            Get-MO2UncommittedDispatchProof -Config $c -Owned $oo -TaskId $task -AttemptId $attemptId -ExpectedGeneration $generation -MO2Processes @($pp) -GameProcesses @($games)
        }
        $result = [ordered]@{ exact = Test-Proof }
        $result.wrongTask = Test-Proof -task other
        $result.wrongAttempt = Test-Proof -attemptId ([guid]::NewGuid().ToString('D'))
        $result.stale = Test-Proof -generation 1L
        $result.extraMO2 = Test-Proof -pp @($p,$p)
        $result.game = Test-Proof -games @([pscustomobject]@{ id = 999 })
        $replacement = $p | ConvertTo-Json | ConvertFrom-Json
        $replacement.startTime = [DateTime]::UtcNow.AddMinutes(1).ToString('o')
        $result.reusedPid = Test-Proof -pp @($replacement)
        $replacement.path = Join-Path $c.mo2.executable '..\foreign.exe'
        $result.foreignPath = Test-Proof -pp @($replacement)
        [pscustomobject]$result
    } @proofArgs
    Assert-Fixture $matrix.exact.ok 'legacy prepared receipt proves exact dispatched lifetime'
    foreach ($name in @('wrongTask','wrongAttempt','stale','extraMO2','game','reusedPid','foreignPath')) { Assert-Fixture (-not $matrix.$name.ok) "refuse $name without ownership mutation" }
    $proofCall = { & $module { param($c,$o,$a,$p) Get-MO2UncommittedDispatchProof -Config $c -Owned $o -TaskId 'fixture-task' -AttemptId $a -ExpectedGeneration 2 -MO2Processes @($p) -GameProcesses @() } $cfg $owned $attempt $candidate }
    $receipt.arguments[1] = 'Wrong Profile'
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    Assert-Fixture (-not (& $proofCall).ok) 'reject changed profile arguments'
    $receipt.arguments[1] = 'Fixture Profile'
    $receipt | Add-Member -NotePropertyName generation -NotePropertyValue 99L
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    Assert-Fixture (-not (& $proofCall).ok) 'reject newer receipt generation'
    $receipt.PSObject.Properties.Remove('generation')
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    $receipt | Add-Member -NotePropertyName leaseId -NotePropertyValue $data.leaseId
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    Assert-Fixture (-not (& $proofCall).ok) 'reject lease-only receipt metadata'
    $receipt.PSObject.Properties.Remove('leaseId')
    $receipt | Add-Member -NotePropertyName generation -NotePropertyValue 2L
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    Assert-Fixture (-not (& $proofCall).ok) 'reject generation-only receipt metadata'
    $receipt | Add-Member -NotePropertyName leaseId -NotePropertyValue $data.leaseId
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    $modern = & $proofCall
    Assert-Fixture ($modern.ok -and -not $modern.legacyReceipt) 'both exact modern receipt fields accepted without legacy classification'
    foreach ($wrong in @('2',$true,2.5)) {
        $receipt.generation = $wrong
        $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
        Assert-Fixture (-not (& $proofCall).ok) "reject wrong-typed generation $wrong"
    }
    $receipt.PSObject.Properties.Remove('generation')
    $receipt.PSObject.Properties.Remove('leaseId')
    $receipt | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receiptPath
    $bundleBytes = [IO.File]::ReadAllBytes($controller.receiptPath)
    $bundleOriginal = Get-Content -LiteralPath $controller.receiptPath -Raw
    $authorityHash = (Get-FileHash -LiteralPath $lockPath).Hash
    foreach ($member in @($controller.files)) {
        $bad = $bundleOriginal | ConvertFrom-Json
        $bad.files = @($bad.files | Where-Object name -cne $member.name)
        $bad | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $controller.receiptPath
        Assert-Fixture (-not (& $proofCall).ok) "reject omission of prepared member $($member.name)"
        [IO.File]::WriteAllBytes($controller.receiptPath,$bundleBytes)
    }
    foreach ($attack in @('duplicate','aliased-path','entry-path','config-path','version','receipt-rewrite')) {
        $bad = $bundleOriginal | ConvertFrom-Json
        switch ($attack) {
            'duplicate' { $bad.files = @($bad.files)+@($bad.files[0]) }
            'aliased-path' { $bad.files[0].path = Join-Path (Split-Path $controller.controllerPath) '.\Invoke-MO2Control.ps1' }
            'entry-path' { $bad.controllerPath = $controller.configPath }
            'config-path' { $bad.configPath = $controller.controllerPath }
            'version' { $bad.contractVersion = '999.0.0' }
            'receipt-rewrite' { $bad.purpose = 'rewritten receipt with same inventory' }
        }
        $bad | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $controller.receiptPath
        Assert-Fixture (-not (& $proofCall).ok) "reject bundle $attack without external binding update"
        [IO.File]::WriteAllBytes($controller.receiptPath,$bundleBytes)
    }
    $memberPath = $controller.controllerPath
    $memberBytes = [IO.File]::ReadAllBytes($memberPath)
    try {
        [IO.File]::AppendAllText($memberPath,"`n# fixture corruption")
        $bad = $bundleOriginal | ConvertFrom-Json
        $bad.files[0].sha256 = (Get-FileHash -LiteralPath $memberPath).Hash
        $bad | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $controller.receiptPath
        Assert-Fixture (-not (& $proofCall).ok) 'reject altered member with rewritten self-declared hash'
        [IO.File]::WriteAllBytes($controller.receiptPath,$bundleBytes)
        Assert-Fixture (-not (& $proofCall).ok) 'reject altered member under original receipt'
    } finally { [IO.File]::WriteAllBytes($memberPath,$memberBytes); [IO.File]::WriteAllBytes($controller.receiptPath,$bundleBytes) }
    foreach ($replacedPath in @($memberPath,$controller.receiptPath)) {
        $backupPath = $replacedPath + '.fixture-original'
        if (-not [IO.Path]::GetFullPath($replacedPath).StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Replacement fixture escaped its owned root.' }
        $originalBytes = [IO.File]::ReadAllBytes($replacedPath)
        Move-Item -LiteralPath $replacedPath -Destination $backupPath
        try {
            [IO.File]::WriteAllBytes($replacedPath,$originalBytes)
            Assert-Fixture (-not (& $proofCall).ok) "reject same-byte physical substitution $([IO.Path]::GetFileName($replacedPath))"
        } finally {
            Remove-Item -LiteralPath $replacedPath -Force
            Move-Item -LiteralPath $backupPath -Destination $replacedPath
        }
    }
    $configDirectory = Split-Path -Parent $controller.configPath
    $configBackup = $configDirectory + '.fixture-original'
    if (-not [IO.Path]::GetFullPath($configDirectory).StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Junction fixture escaped its owned root.' }
    Move-Item -LiteralPath $configDirectory -Destination $configBackup
    try {
        New-Item -ItemType Junction -Path $configDirectory -Target $configBackup | Out-Null
        Assert-Fixture (-not (& $proofCall).ok) 'reject junction substitution despite identical member bytes and physical file identity'
    } finally {
        if (Test-Path -LiteralPath $configDirectory) { [IO.Directory]::Delete($configDirectory) }
        Move-Item -LiteralPath $configBackup -Destination $configDirectory
    }
    foreach ($property in @('controllerPath','controllerConfigPath','controllerReceiptPath')) {
        $originalValue = $data.$property
        $data.$property = Join-Path $sessionPath 'foreign'
        Assert-Fixture (-not (& $proofCall).ok) "reject lock/manifest $property mismatch"
        $data.$property = $originalValue
    }
    $binding = $data.controllerBundleBinding
    $data.PSObject.Properties.Remove('controllerBundleBinding')
    Assert-Fixture (-not (& $proofCall).ok) 'reject historical prepared session without independent controller binding'
    $data | Add-Member -NotePropertyName controllerBundleBinding -NotePropertyValue $binding
    Assert-Fixture ((Get-FileHash -LiteralPath $lockPath).Hash -ceq $authorityHash) 'adverse provenance matrix never commits a recovery generation'
    $data | Add-Member -NotePropertyName ownerProcessPath -NotePropertyValue $exe
    Assert-Fixture (-not (& $proofCall).ok) 'reject existing owner tuple even when receipt PID matches'
    $data.PSObject.Properties.Remove('ownerProcessPath')
    $drift = $data | ConvertTo-Json -Depth 30 | ConvertFrom-Json -DateKind String
    $drift.generation = 1
    $drift | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath
    Assert-Fixture (-not (& $proofCall).ok) 'reject lock/manifest generation drift'
    $data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $manifestPath
    $cfg.machine = 'changed'
    Assert-Fixture (-not (& $proofCall).ok) 'reject configuration drift from captured controller'
    $cfg.machine = 'fixture'
    Assert-Fixture ((& $proofCall).ok) 'restored fixture evidence proves exact dispatch again'
    $beforeLock = (Get-FileHash -LiteralPath $lockPath).Hash
    $beforeReceipt = (Get-FileHash -LiteralPath $receiptPath).Hash
    $beforeController = (Get-FileHash -LiteralPath $controller.controllerPath).Hash
    $preview = Invoke-MO2RecoverDispatch -Config $cfg -SessionId $data.sessionId -AccessId $access -TaskId 'fixture-task' -AttemptId $attempt -ExpectedGeneration 2 -WhatIf
    Assert-Fixture ($preview.ok -and $preview.state -eq 'dry-run' -and (Get-FileHash -LiteralPath $lockPath).Hash -eq $beforeLock) 'preview leaves lock and original controller unchanged'
    $wrongCredential = $false
    try { Invoke-MO2RecoverDispatch -Config $cfg -SessionId $data.sessionId -AccessId 'wrong' -TaskId 'fixture-task' -AttemptId $attempt -ExpectedGeneration 2 -WhatIf | Out-Null } catch { $wrongCredential = $true }
    Assert-Fixture $wrongCredential 'foreign credential refused before recovery'
    $result = Invoke-MO2RecoverDispatch -Config $cfg -SessionId $data.sessionId -AccessId $access -TaskId 'fixture-task' -AttemptId $attempt -ExpectedGeneration 2
    Assert-Fixture ($result.ok -and $result.state -eq 'dispatch-owner-recovered' -and -not $result.data.launched -and $result.data.leaseRetained) 'recover ownership only, no launch or release'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -DateKind String
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -DateKind String
    $startProperty = if ($manifest.PSObject.Properties['ownerProcessStartTime']) { 'ownerProcessStartTime' } else { 'processStartTime' }
    Assert-Fixture ($lock.generation -eq 3 -and $manifest.generation -eq 3 -and $lock.ownerPid -eq $process.Id -and $manifest.$startProperty -eq $receipt.requestedProcessStartTime -and $lock.status -eq 'launch-failed') 'commit exact identity to coherent lock and manifest generation'
    Assert-Fixture ((Get-FileHash -LiteralPath $receiptPath).Hash -eq $beforeReceipt -and (Get-FileHash -LiteralPath $controller.controllerPath).Hash -eq $beforeController -and $result.data.controllerPath -ne $controller.controllerPath -and (Test-Path -LiteralPath $result.data.controllerPath)) 'retain original receipt/controller and return new durable bundle'
    $again = Invoke-MO2RecoverDispatch -Config $cfg -SessionId $data.sessionId -AccessId $access -TaskId 'fixture-task' -AttemptId $attempt -ExpectedGeneration 3
    Assert-Fixture (-not $again.ok -and $again.state -eq 'blocked' -and (Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json).generation -eq 3) 'recovery is single use, no second generation commit'
    $boundOwner = & $module { param($c,$sid) $o = Get-MO2OwnedSession -Config $c -SessionId $sid; Resolve-MO2OwnedProcessTarget -Config $c -Owned $o -Processes @(Get-MO2ProcessRecords -Names @($c.mo2.processNames)) } $cfg $data.sessionId
    Assert-Fixture ($boundOwner.ok -and $boundOwner.reason -eq 'recorded-owner') 'normal lifecycle accepts recovered exact owner'
    [pscustomobject]@{ ok = $true; tests = $passes.Count; passes = @($passes); fixturePath = $fixture } | ConvertTo-Json -Depth 5
}
finally {
    # Only the test-created fixture process and its children are targets.
    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null }
    $process.Dispose()
}
