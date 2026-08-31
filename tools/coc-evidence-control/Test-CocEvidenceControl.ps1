# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocEvidenceControl.ps1'
$script = Get-Content -LiteralPath $scriptPath -Raw

foreach ($requiredText in @(
    "[ValidateSet('inspect', 'arm', 'status', 'capture-hang', 'stop')]",
    "'-ma'",
    "'-e'",
    "'-n', '2'",
    "'-r', '1'",
    "'-a'",
    '@(''-w'', $TargetName)',
    "'-cancel'",
    'csx-coc-evidence-state-v1',
    'MinimumFreeGiB = 100',
    'CSX_COC_EVIDENCE_ROOT',
    'Test-DumpRootWriteAccess',
    "name = 'dump-write'",
    "code = 'evidence-output-not-writable'",
    '[IO.File]::WriteAllText',
    '[IO.File]::Delete',
    'DateTimeOffset]::Parse',
    'InvariantCulture',
    "triggerPolicy = 'unhandled-exception'",
    "trigger = 'operator-confirmed-hang'",
    'Stop-OwnedProcDumpMonitor',
    'cdb'
)) {
    if (-not $script.Contains($requiredText, [StringComparison]::Ordinal)) {
        throw "COC evidence controller is missing: $requiredText"
    }
}

foreach ($forbiddenText in @(
    "'-t'",
    "'-e', '1'",
    "'-h'",
    'Stop-Process',
    'GhidraMcpUrl',
    'GhidraInstallRoot',
    'PyGhidraPath'
)) {
    if ($script.Contains($forbiddenText, [StringComparison]::Ordinal)) {
        throw "COC evidence controller contains unsafe behavior: $forbiddenText"
    }
}

[pscustomobject][ordered]@{
    ok = $true
    fullUnhandledCrashDump = $true
    automaticHangDump = $false
    explicitHangDump = $true
    normalExitDump = $false
    firstChanceDump = $false
    boundedDumpCount = 2
    officialCancellation = $true
} | ConvertTo-Json
