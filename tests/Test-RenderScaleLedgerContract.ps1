# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Content, [string]$Token, [string]$Message) {
    $normalizedContent = [regex]::Replace($Content, '\s+', ' ')
    $normalizedToken = [regex]::Replace($Token, '\s+', ' ')
    Assert-True $normalizedContent.Contains(
        $normalizedToken,
        [StringComparison]::Ordinal
    ) $Message
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$protocols = [ordered]@{}

foreach ($variant in @('renderscale-tuning-nvidia', 'renderscale-tuning-amd')) {
    $relative = "skills\$variant\references\protocol.md"
    $sourcePath = Join-Path $repositoryRoot $relative
    $pluginPath = Join-Path $repositoryRoot "plugins\skyrim-vr-automation\$relative"

    Assert-True (Test-Path -LiteralPath $sourcePath -PathType Leaf) "Missing source protocol: $sourcePath"
    Assert-True (Test-Path -LiteralPath $pluginPath -PathType Leaf) "Missing packaged protocol: $pluginPath"
    Assert-True (
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $pluginPath -Algorithm SHA256).Hash
    ) "$variant source/package protocol parity failed."

    $protocol = Get-Content -LiteralPath $sourcePath -Raw
    foreach ($token in @(
        'Ledger append transaction',
        'before any ledger write',
        'same ordered metric rows and row count',
        'exactly one additional rightmost column',
        'zero changed pre-existing parsed cell values',
        '`runtime_device_loss_failures`',
        '`runtime_oom_failures`',
        '`runtime_producer_terminal_failures`',
        '`vendor_native_qualification_failures`',
        '`credible_liveness_timeouts`',
        '`ledger_failure_schema_outdated`',
        '`memory_confirmation_passes`',
        '`memory_process_private_mib_pass1_pass2_ratio`',
        '`memory_system_commit_mib_pass1_pass2_ratio`',
        '`memory_dxgi_usage_mib_pass1_pass2_ratio`',
        '`memory_live_textures_pass1_cooldown_pass2`',
        '`memory_live_texture_mib_pass1_cooldown_pass2`',
        '`memory_pressure_pass1_cooldown_pass2`',
        '`memory_confirmation_verdict`',
        'never collapse the memory classification into the render verdict',
        'never from the number of transitions classified `FAIL`',
        '`n/a; legacy aggregate disabled`',
        'Never sum qualification or liveness results into a runtime-hard metric',
        'single in-place `Update File` operation',
        'Never combine `Delete File` and `Add File` operations',
        '`ledger_append_unrepresentable`',
        '`ledger_append_validation_failed`'
    )) {
        Assert-Contains $protocol $token (
            "$variant ledger transaction is missing: $token"
        )
    }
    Assert-True (-not $protocol.Contains(
        'using the Simple COC ledger mechanics',
        [StringComparison]::Ordinal
    )) "$variant ledger finalization still depends on an unloaded protocol."

    $protocols[$variant] = $protocol
}

$sectionPattern = '(?ms)^### Ledger append transaction\r?\n(?<body>.*?)(?=^### Result tables\r?$)'
$nvidiaSection = [regex]::Match($protocols['renderscale-tuning-nvidia'], $sectionPattern)
$amdSection = [regex]::Match($protocols['renderscale-tuning-amd'], $sectionPattern)
Assert-True $nvidiaSection.Success 'NVIDIA ledger transaction section is missing.'
Assert-True $amdSection.Success 'AMD ledger transaction section is missing.'
Assert-True (
    $nvidiaSection.Groups['body'].Value -ceq
    $amdSection.Groups['body'].Value
) 'NVIDIA and AMD ledger transaction contracts differ.'

[pscustomobject][ordered]@{
    ok = $true
    protocols = @($protocols.Keys)
    sourceAndPluginMatch = $true
    ledgerContractsMatch = $true
} | ConvertTo-Json -Depth 4
