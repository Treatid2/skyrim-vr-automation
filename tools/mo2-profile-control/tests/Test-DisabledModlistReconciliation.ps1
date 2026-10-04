# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2ProfileControl.ps1'
$root = Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('disabled-profile-' + [guid]::NewGuid().ToString('N'))
$prior = $env:CSX_MO2_PROFILE_CONTROL_ROOT
$env:CSX_MO2_PROFILE_CONTROL_ROOT = Join-Path $root 'transactions'
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:checks++ }
function Hash([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
function Invoke-Case([string]$Operation, [hashtable]$Extra=@{}) {
    $argsMap = @{ ProfilePath=$profile; ModName='inventory'; ModsDirectory=$mods; EvidenceDirectory=(Join-Path $root ([guid]::NewGuid().ToString('N'))); ExpectedCurrentSha256=(Get-FileHash -LiteralPath $profile).Hash; PinnedProfileSha256=$pinned; BlockingProcessNames=@('MO2DisabledImpossibleFixtureProcess'); NoExit=$true; Confirm=$false; Compact=$true }
    foreach ($key in $Extra.Keys) { $argsMap[$key]=$Extra[$key] }
    return & $entry $Operation @argsMap | ConvertFrom-Json
}
function Refuse([byte[]]$Bytes, [string]$Message, [hashtable]$Extra=@{}) {
    [IO.File]::WriteAllBytes($profile,$Bytes)
    $failed=$false
    try { $null=Invoke-Case recover-disabled-append $Extra } catch { $failed=$true }
    Check ($failed -and (Get-FileHash -LiteralPath $profile).Hash -ceq (Hash $Bytes)) $Message
}
try {
    $mods=Join-Path $root 'mods'; $profile=Join-Path $root 'modlist.txt'
    foreach ($name in @('Existing','Old disabled','New α','New two')) { [void][IO.Directory]::CreateDirectory((Join-Path $mods $name)) }
    $utf8=[Text.UTF8Encoding]::new($false)
    foreach ($newline in @("`r`n","`n")) {
        foreach ($bom in @($false,$true)) {
            $original=$utf8.GetBytes("+Existing${newline}-Old disabled${newline}")
            if ($bom) { $original=[Text.UTF8Encoding]::new($true).GetPreamble()+$original }
            $pinned=Hash $original
            $drift=$original+$utf8.GetBytes("-New α${newline}-New two${newline}")
            [IO.File]::WriteAllBytes($profile,$drift)
            $preview=Invoke-Case recover-disabled-append @{WhatIf=$true}
            Check ($preview.ok -and -not (Test-Path -LiteralPath $preview.receiptPath) -and (Get-FileHash -LiteralPath $profile).Hash -ceq (Hash $drift)) 'Preview mutated bytes/evidence.'
            $recovered=Invoke-Case recover-disabled-append
            Check ($recovered.ok -and $recovered.state -eq 'committed' -and $recovered.sha256 -ceq $pinned) 'BOM/Unicode/newline exact recovery failed.'
            Check ((Get-FileHash -LiteralPath $recovered.backupPath).Hash -ceq (Hash $drift)) 'Original drift backup was not retained.'
            $noop=Invoke-Case recover-disabled-append
            Check ($noop.ok -and -not $noop.operationResult.changed -and -not (Test-Path -LiteralPath $noop.receiptPath)) 'Repeated exact recovery wrote a new transaction.'
            $normalized=Invoke-Case normalize-installed
            $normalizedBytes=[IO.File]::ReadAllBytes($profile)
            Check ($normalized.ok -and $normalized.operationResult.changed -and $utf8.GetString($normalizedBytes).StartsWith($utf8.GetString($original),[StringComparison]::Ordinal)) 'Normalization changed original byte prefix.'
            $normNoop=Invoke-Case normalize-installed
            Check ($normNoop.ok -and -not $normNoop.operationResult.changed) 'Normalization was not idempotent.'
        }
    }
    $original=$utf8.GetBytes("+Existing`r`n-Old disabled`r`n"); $pinned=Hash $original
    Refuse ($original+$utf8.GetBytes("+New two`r`n")) 'Enabled suffix was accepted.'
    Refuse ($utf8.GetBytes("-Existing`r`n-Old disabled`r`n-New two`r`n")) 'Existing enable-state drift was accepted.'
    Refuse ($utf8.GetBytes("-Old disabled`r`n+Existing`r`n-New two`r`n")) 'Existing order drift was accepted.'
    Refuse ($original+$utf8.GetBytes("-Nonexistent`r`n")) 'Unknown installed name was accepted.'
    Refuse ($original+$utf8.GetBytes("-Old disabled`r`n")) 'Duplicate original marker was accepted.'
    Refuse ($original+$utf8.GetBytes("-New two`r`n-New two`r`n")) 'Duplicate appended marker was accepted.'
    Refuse ($original+$utf8.GetBytes("-New two`r`n#comment`r`n")) 'Non-disabled suffix was accepted.'
    Refuse ($original+$utf8.GetBytes("-New two`r`n")) 'Wrong current-hash CAS accepted.' @{ExpectedCurrentSha256=[string]::new([char]'0',64)}
    Refuse ($original+$utf8.GetBytes("-../New two`r`n")) 'Escaping mod name was accepted.'
    Refuse ($original+[byte[]]@(255,254)) 'Invalid UTF8 was accepted.'
    Refuse ([byte[]]::new(16777217)) 'Modlist byte limit ignored.'
    $link=Join-Path $mods 'Linked'; $outside=Join-Path $root 'outside'
    [void][IO.Directory]::CreateDirectory($outside)
    New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
    Refuse ($original+$utf8.GetBytes("-Linked`r`n")) 'Reparse installed mod was accepted.'
    Remove-Item -LiteralPath $link -Force
    $tooMany=$original
    for ($i=0;$i -lt 65;$i++) { $name="Late$i"; [void][IO.Directory]::CreateDirectory((Join-Path $mods $name)); $tooMany+=$utf8.GetBytes("-$name`r`n") }
    Refuse $tooMany 'Disabled suffix line budget ignored.'
    $drift=$original+$utf8.GetBytes("-New two`r`n")
    [IO.File]::WriteAllBytes($profile,$drift)
    $badEvidence=Join-Path $root 'receipt-failure'
    [void][IO.Directory]::CreateDirectory((Join-Path $badEvidence 'modlist-control.receipt.json'))
    $failed=$false
    try { $null=Invoke-Case recover-disabled-append @{EvidenceDirectory=$badEvidence} } catch { $failed=$_.Exception.Message -match 'exact preimage restored' }
    Check ($failed -and (Get-FileHash -LiteralPath $profile).Hash -ceq (Hash $drift)) 'Receipt failure did not roll back exact drift bytes.'
    [pscustomobject]@{ok=$true;checks=$checks;mode='disabled-profile-only';runtimeQualified=$false} | ConvertTo-Json -Compress
}
finally {
    $env:CSX_MO2_PROFILE_CONTROL_ROOT=$prior
    # Only this generated direct child of caller-owned managed scratch.
    if ((Split-Path -Parent $root) -cne [IO.Path]::GetFullPath($FixtureRoot)) { throw 'Unsafe fixture cleanup target.' }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
