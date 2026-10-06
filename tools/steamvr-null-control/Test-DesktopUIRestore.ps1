# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('desktopui-restore-' + [guid]::NewGuid().ToString('N'))
$priorRoot = $env:CSX_STEAMVR_TRANSACTION_ROOT
$passes = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $passes.Add($Name)
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Write-Settings($Value) { [IO.File]::WriteAllText($settings, ($Value | ConvertTo-Json -Depth 64), [Text.UTF8Encoding]::new($false)) }
function Set-NumericLiteral([string]$Json, [string]$Key, [string]$Literal) {
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*)-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    if ([regex]::Matches($Json, $pattern).Count -ne 1) { throw "Numeric fixture must select exactly one leaf: $Key" }
    return [regex]::Replace($Json, $pattern, { param($m) $m.Groups[1].Value + $Literal }.GetNewClosure())
}
function Invoke-Control([string]$Command, [hashtable]$Options = @{}) {
    $lines = & $entry $Command @common @Options -Compact -NoExit
    return ($lines -join [Environment]::NewLine) | ConvertFrom-Json -Depth 64
}
function Assert-Refusal([string]$Name, [hashtable]$Options = @{PreserveDesktopUIWindowState=$true;WhatIf=$true}) {
    $before = Hash $settings; $beforeJournal = Hash $journal
    $result = Invoke-Control restore $Options
    Assert-Test (-not $result.ok -and (Hash $settings) -ceq $before -and (Hash $journal) -ceq $beforeJournal) $Name
}
try {
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    $settings = Join-Path $fixture 'steamvr.vrsettings'
    $openvr = Join-Path $fixture 'openvrpaths.vrpath'
    $evidence = Join-Path $fixture 'evidence'
    $steamroot = Join-Path $fixture 'SteamVR'
    [IO.Directory]::CreateDirectory($evidence) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $steamroot 'bin/win64')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $steamroot 'bin/win64/vrstartup.exe'), [byte[]]@(0))
    [IO.File]::WriteAllText($openvr, '{"version":1,"external_drivers":[]}')
    $profile = Join-Path $fixture 'profile.json'
    $profileValue = Get-Content (Join-Path $PSScriptRoot '../../profiles/steamvr-null.profile.json') -Raw | ConvertFrom-Json -AsHashtable
    $profileValue.headPoseProviderContract.sharedMemoryName = 'Local\\DesktopUI-fixture-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($profile, ($profileValue | ConvertTo-Json -Depth 64))
    $env:CSX_STEAMVR_TRANSACTION_ROOT = Join-Path $fixture 'control'
    $common = @{
        SettingsPath=$settings; OpenVRPathsPath=$openvr; NullProfilePath=$profile
        EvidenceDirectory=$evidence; SteamVRRoot=$steamroot
        HeadPoseDriverRoot=(Join-Path $fixture 'missing-driver'); ServerLogPath=(Join-Path $fixture 'missing-log')
    }
    Write-Settings ([ordered]@{
        steamvr=[ordered]@{enableHomeApp=$true}
        DesktopUI=[ordered]@{pairing='891,465,800,600,0';settings_desktop='1349,529,800,600,1';other='retained'}
        unrelated=[ordered]@{flag=$false;large=9007199254740992L;value=7;unownedFloat=1.68}
    })
    $baselineText=[IO.File]::ReadAllText($settings).Replace('"value": 7','"value": 7, "precise": 1.123456789012345678901234567890')
    [IO.File]::WriteAllText($settings,$baselineText,[Text.UTF8Encoding]::new($false))
    $baselineHash = Hash $settings
    $apply = Invoke-Control apply @{Standalone=$true}
    if (-not $apply.ok) { throw ($apply | ConvertTo-Json -Depth 20) }
    $journal = $apply.data.targetControl.journalPath
    $receipt = $apply.data.receiptPath
    $backup = $apply.data.backupPath
    $originalIdentities = @($receipt,$backup,(Join-Path $evidence 'steamvr-null.profile.applied.json')) | ForEach-Object { @{path=$_;sha256=(Hash $_)} }
    $applied = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable -Depth 64
    $applied.DesktopUI.pairing='891,465,-2147483648,-2147483648,0'
    $applied.DesktopUI.settings_desktop='1349,529,-2147483648,-2147483648,1'
    $applied.GpuSpeed=@{speed=999}
    $applied.LastKnown=@{runtime='updated'}
    $applied.dashboard.lastAccessedExternalOverlayKey='history'
    Write-Settings $applied
    $runtimeJson = Set-NumericLiteral ([IO.File]::ReadAllText($settings)) 'eyeHeightMeters' '1.6799999999999999'
    # Exercise the complete real profile at once, not just the first refusal:
    # SteamVR writes six integral-valued floating leaves as integer spellings.
    foreach ($leaf in @('displayFrequency','positionX','positionZ','yawDegrees','pitchDegrees','rollDegrees')) {
        $literal = if ($leaf -eq 'displayFrequency') { '90' } else { '0' }
        $runtimeJson = Set-NumericLiteral $runtimeJson $leaf $literal
    }
    $controlledCount = 0
    foreach ($section in @('steamvr','dashboard','driver_null','driver_codex_head_pose','TrackingOverrides','power')) {
        $controlledCount += $profileValue[$section].Count
    }
    $runtimeValues = $runtimeJson | ConvertFrom-Json -AsHashtable
    Assert-Test ($controlledCount -eq 29 -and $profileValue.driver_null.displayFrequency -is [double] -and
        $runtimeValues.driver_null.displayFrequency -is [long] -and
        @('positionX','positionZ','yawDegrees','pitchDegrees','rollDegrees').Where({
            $profileValue.driver_codex_head_pose[$_] -is [double] -and $runtimeValues.driver_codex_head_pose[$_] -is [long]
        }).Count -eq 5) 'full29 owned-leaf fixture includes all six realistic integral-number runtime spellings together'
    [IO.File]::WriteAllText($settings, $runtimeJson, [Text.UTF8Encoding]::new($false))
    $profileEye = $profileValue.driver_codex_head_pose.eyeHeightMeters
    $runtimeEye = ($runtimeJson | ConvertFrom-Json -AsHashtable).driver_codex_head_pose.eyeHeightMeters
    Assert-Test ($profileEye -is [double] -and $runtimeEye -is [double] -and
        [BitConverter]::DoubleToInt64Bits($profileEye) -eq [BitConverter]::DoubleToInt64Bits($runtimeEye) -and
        $runtimeJson -match '1\.6799999999999999') 'realistic runtime eye-height serialization retains exact profile binary64 bits'
    $admittedBytes=[IO.File]::ReadAllBytes($settings)
    $admittedHash=Hash $settings
    Assert-Refusal 'default restore continues refusing DesktopUI drift' @{WhatIf=$true}
    $evidenceCount=@(Get-ChildItem -LiteralPath $evidence -File).Count
    $preview=Invoke-Control restore @{PreserveDesktopUIWindowState=$true;WhatIf=$true}
    Assert-Test ($preview.ok -and $preview.state -eq 'dry-run' -and
        $preview.data.settingsRestoreSelection.policy -ceq 'baseline-plus-exact-desktopui-strings' -and
        $preview.data.settingsRestoreSelection.preimageSha256 -ceq $admittedHash -and
        $preview.data.expectedSha256 -cne $baselineHash -and (Hash $settings) -ceq $admittedHash -and
        @(Get-ChildItem -LiteralPath $evidence -File).Count -eq $evidenceCount) 'preservation preview pins selected strings/hash without staging or target writes'
    Assert-Refusal 'commit requires the admitted preview hash' @{PreserveDesktopUIWindowState=$true}
    Assert-Refusal 'stale preview hash refuses before mutation' @{PreserveDesktopUIWindowState=$true;ExpectedCurrentSettingsSha256=('0'*64)}
    $cases=@(
        @{name='missing leaf';edit={param($d) $d.DesktopUI.Remove('pairing')}}
        @{name='absent section';edit={param($d) $d.Remove('DesktopUI')}}
        @{name='wrong root casing';edit={param($d) $d['desktopUI']=$d.DesktopUI;$d.Remove('DesktopUI')}}
        @{name='wrong leaf casing';edit={param($d) $d.DesktopUI['Pairing']=$d.DesktopUI.pairing;$d.DesktopUI.Remove('pairing')}}
        @{name='numeric leaf';edit={param($d) $d.DesktopUI.pairing=42}}
        @{name='null leaf';edit={param($d) $d.DesktopUI.pairing=$null}}
        @{name='array leaf';edit={param($d) $d.DesktopUI.pairing=@('x')}}
        @{name='nonobject section';edit={param($d) $d.DesktopUI='bad'}}
        @{name='other UI drift';edit={param($d) $d.DesktopUI.other='changed'}}
        @{name='literal dotted root';edit={param($d) $d['DesktopUI.pairing']='forged'}}
        @{name='literal dotted child';edit={param($d) $d.DesktopUI['pairing.extra']='forged'}}
        @{name='controlled Boolean numeric alias';edit={param($d) $d.steamvr.requireHmd=0}}
        @{name='controlled value drift';edit={param($d) $d.driver_null.renderWidth=100}}
        @{name='controlled case alias alongside owned leaf';edit={param($d) $d.driver_codex_head_pose['EyeHeightMeters']=$d.driver_codex_head_pose.eyeHeightMeters}}
        @{name='controlled dotted alias alongside owned leaf';edit={param($d) $d.driver_codex_head_pose['eyeHeightMeters.extra']=1.68}}
        @{name='other Boolean numeric alias';edit={param($d) $d.unrelated.flag=0}}
        @{name='large integer drift';edit={param($d) $d.unrelated.large=9007199254740993L}}
        @{name='power numeric kind';edit={param($d) $d.power.turnOffControllersTimeout=0.0}}
        @{name='history nonstring';edit={param($d) $d.dashboard.lastAccessedExternalOverlayKey=4}}
    )
    foreach($case in $cases){
        $d=[Text.Encoding]::UTF8.GetString($admittedBytes)|ConvertFrom-Json -AsHashtable -Depth 64
        & $case.edit $d | Out-Null
        Write-Settings $d
        Assert-Refusal ("refuses "+$case.name)
    }
    $raw=[Text.Encoding]::UTF8.GetString($admittedBytes)
    foreach ($numericCase in @(
        @{key='eyeHeightMeters';literal='1.6800000000000002';name='changed controlled binary64 bits'}
        @{key='eyeHeightMeters';literal='1.68000000000000001';name='noncanonical controlled decimal hidden by Double parsing'}
        @{key='positionX';literal='-0.0';name='controlled signed-zero bit change'}
        @{key='unownedFloat';literal='1.6799999999999999';name='unowned canonical binary64 reserialization'}
        @{key='displayFrequency';literal='"90"';name='controlled JSON number replaced by string'}
        @{key='displayFrequency';literal='false';name='controlled JSON number replaced by Boolean'}
        @{key='displayFrequency';literal='null';name='controlled JSON number replaced by null'}
    )) {
        [IO.File]::WriteAllText($settings, (Set-NumericLiteral $raw $numericCase.key $numericCase.literal))
        Assert-Refusal ('refuses ' + $numericCase.name)
    }
    [IO.File]::WriteAllText($settings,$raw.Replace('"value": 7','"value": 7.00000000000000000001'))
    Assert-Refusal 'refuses decimal drift hidden by PowerShell floating-point parsing'
    $controlledRaw=$raw.Replace('"displayFrequency": 90.0','"displayFrequency": 90.00000000000000000001')
    if($controlledRaw -ceq $raw){$controlledRaw=$raw.Replace('"displayFrequency": 90','"displayFrequency": 90.00000000000000000001')}
    if($controlledRaw -ceq $raw){throw 'Controlled decimal fixture did not change its input'}
    [IO.File]::WriteAllText($settings,$controlledRaw)
    Assert-Refusal 'refuses controlled decimal drift hidden by floating-point parsing'
    [IO.File]::WriteAllText($settings,'{"DesktopUI":{"pairing":"x","pairing":"y","settings_desktop":"z"}}')
    Assert-Refusal 'refuses duplicate exact JSON key'
    [IO.File]::WriteAllText($settings,'{"DesktopUI":')
    Assert-Refusal 'refuses malformed JSON'
    [IO.File]::WriteAllBytes($settings,$admittedBytes)
    $drift=Invoke-Control restore @{PreserveDesktopUIWindowState=$true;ExpectedCurrentSettingsSha256=$admittedHash;InternalTestFailurePoint='restore-source-drift-after-stage'}
    Assert-Test (-not $drift.ok -and $drift.errors[0] -match 'changed after staging' -and
        (Hash $settings) -cne $admittedHash -and
        (Get-Content $journal -Raw|ConvertFrom-Json).operation -eq 'apply') 'dispatch-time current hash drift refuses without overwriting newer bytes or replacing apply journal'
    [IO.File]::WriteAllBytes($settings,$admittedBytes)
    $failed=Invoke-Control restore @{PreserveDesktopUIWindowState=$true;ExpectedCurrentSettingsSha256=$admittedHash;InternalTestFailurePoint='restore-after-settings'}
    $rollbackJournal=Get-Content $journal -Raw|ConvertFrom-Json -AsHashtable
    Assert-Test (-not $failed.ok -and (Hash $settings) -ceq $admittedHash -and $rollbackJournal.phase -eq 'rolled-back' -and $rollbackJournal.rollback.verified) 'post-settings failure restores exact accepted preimage including the current UI strings'
    # Emulate interruption with the real prepared journal/targets and selected result.
    [IO.File]::WriteAllBytes($settings,[IO.File]::ReadAllBytes($rollbackJournal.settingsRestoreSelection.resultPath))
    $rollbackJournal.phase='settings-restored-uncommitted'
    [IO.File]::WriteAllText($journal,($rollbackJournal|ConvertTo-Json -Depth 64))
    $recovered=Invoke-Control inspect
    Assert-Test ($recovered.ok -and $recovered.data.recoveredTransaction.phase -eq 'recovered' -and (Hash $settings) -ceq $admittedHash) 'next public command recovers interrupted restore to exact accepted preimage'
    $restored=Invoke-Control restore @{PreserveDesktopUIWindowState=$true;ExpectedCurrentSettingsSha256=$admittedHash}
    if(-not $restored.ok){throw ($restored|ConvertTo-Json -Depth 30)}
    $result=Get-Content $settings -Raw|ConvertFrom-Json -AsHashtable
    $restoreReceipt=Get-Content $restored.data.restoreReceiptPath -Raw|ConvertFrom-Json -AsHashtable
    $rawResult=[Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($settings))
    try { Assert-Test ($rawResult.RootElement.GetProperty('unrelated').GetProperty('precise').GetRawText() -ceq '1.123456789012345678901234567890') 'preserves full-precision raw baseline numbers outside the two selected strings' }
    finally { $rawResult.Dispose() }
    Assert-Test ($restored.state -eq 'restored' -and $result.DesktopUI.pairing -ceq $applied.DesktopUI.pairing -and
        $result.DesktopUI.settings_desktop -ceq $applied.DesktopUI.settings_desktop -and
        $result.steamvr.enableHomeApp -eq $true -and -not $result.Contains('GpuSpeed') -and
        -not $result.Contains('LastKnown') -and -not $result.Contains('driver_null') -and
        $result.DesktopUI.other -ceq 'retained') 'committed result restores baseline everywhere except exactly two approved leaves'
    Assert-Test ($restoreReceipt.settingsRestoreSelection.preimageSha256 -ceq $admittedHash -and
        $restoreReceipt.settingsRestoreSelection.resultSha256 -ceq (Hash $settings) -and
        $restoreReceipt.settingsRestoreSelection.baselineSha256 -ceq $baselineHash -and
        $restoreReceipt.settingsRestoreSelection.applyReceiptSha256 -ceq (Hash $receipt)) 'new receipt honestly binds baseline, immutable apply receipt, selected values, preimage and result'
    $argv=@('-NoProfile','-NonInteractive','-File',$entry,'restore','-Compact','-NoExit')
    foreach($key in $common.Keys){$argv+=@(('-'+$key),[string]$common[$key])}
    $repeated=(& (Join-Path $PSHOME 'pwsh.exe') @argv) -join [Environment]::NewLine | ConvertFrom-Json -Depth 64
    Assert-Test ($repeated.ok -and $repeated.state -eq 'already-restored' -and $repeated.data.restoredSha256 -ceq (Hash $settings) -and
        $repeated.data.settingsRestoreSelection.policy -ceq 'baseline-plus-exact-desktopui-strings') 'fresh process recognizes exact committed selected result without another restore or opt-in'
    $selectionPath=$restoreReceipt.settingsRestoreSelection.resultPath
    $selectedBytes=[IO.File]::ReadAllBytes($selectionPath)
    [IO.File]::AppendAllText($selectionPath,' ')
    Assert-Refusal 'restart refuses changed selected-result evidence' @{}
    [IO.File]::WriteAllBytes($selectionPath,$selectedBytes)
    $committed=Get-Content $journal -Raw|ConvertFrom-Json -AsHashtable
    $committed.settingsRestoreSelection.preservedStrings.pairing='forged'
    [IO.File]::WriteAllText($journal,($committed|ConvertTo-Json -Depth 64))
    Assert-Refusal 'restart refuses forged selected strings rather than treating journal values as authority' @{}
    foreach($identity in $originalIdentities){Assert-Test ((Hash $identity.path) -ceq $identity.sha256) ("original retained identity unchanged: "+[IO.Path]::GetFileName($identity.path))}
    $wrongCommand=Invoke-Control apply @{PreserveDesktopUIWindowState=$true;Standalone=$true}
    Assert-Test (-not $wrongCommand.ok -and $wrongCommand.errors[0] -match 'restore-only') 'preservation option cannot be applied to other commands'
    [pscustomobject]@{ok=$true;passed=$passes.Count;failed=0;cases=@($passes);scope='temporary public-entry fixtures only; no SteamVR/MO2 runtime mutation'}|ConvertTo-Json -Depth 8
}
finally {
    $env:CSX_STEAMVR_TRANSACTION_ROOT=$priorRoot
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($fixture)
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped temporary root'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

