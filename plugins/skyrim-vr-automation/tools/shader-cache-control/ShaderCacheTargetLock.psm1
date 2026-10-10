# SPDX-License-Identifier: GPL-3.0-or-later
# One canonical OS lock for composed preparation and standalone transactions.
# Re-entry is local to this module/runspace and an actually held exclusive handle;
# callers cannot provide a skip-lock flag or serialize a borrowed lock capability.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ShaderCacheInventory.ps1')
$script:HeldTargets = @{}
$script:Leases = @{}

function Get-CSXCacheTransactionControl([string]$LivePath) {
    $canonical = [IO.Path]::GetFullPath($LivePath).TrimEnd('\')
    $identity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical.ToUpperInvariant())))
    $override = [Environment]::GetEnvironmentVariable('CSX_SHADER_CACHE_CONTROL_ROOT')
    if ([string]::IsNullOrWhiteSpace($override)) {
        $base = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CSX-VR-Automation\ShaderCache\transactions'
    } else {
        $base = [IO.Path]::GetFullPath($override)
        $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $canonical.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase) -or
            -not $base.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'CSX_SHADER_CACHE_CONTROL_ROOT is fixture-only and requires both the cache and control root beneath the OS temporary directory.'
        }
    }
    $root = Join-Path $base $identity
    return [pscustomobject]@{ identity=$identity; root=$root; lock=(Join-Path $root 'target.lock'); journal=(Join-Path $root 'transaction.journal.json') }
}

function Enter-CSXCacheTargetLock {
    param([Parameter(Mandatory)][string]$CachePath, [ValidateRange(1,600000)][int]$TimeoutMilliseconds=10000)
    $control = Get-CSXCacheTransactionControl $CachePath
    $existing = $control.root
    while (-not (Test-Path -LiteralPath $existing)) { $existing = Split-Path -Parent $existing }
    Assert-CSXNoCacheReparsePoint -Path $existing -Purpose 'Shader-cache lock control'
    $key = $control.lock.ToUpperInvariant()
    $runspace = [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
    if ($script:HeldTargets.ContainsKey($key)) {
        $held = $script:HeldTargets[$key]
        if ($held.runspace -ne $runspace -or $held.stream.SafeFileHandle.IsClosed -or $held.stream.SafeFileHandle.IsInvalid) {
            throw 'Shader-cache target lock cannot be borrowed across runspaces or reused after closure.'
        }
    } else {
        New-Item -ItemType Directory -Path $control.root -Force | Out-Null
        Assert-CSXNoCacheReparsePoint -Path $control.root -Purpose 'Shader-cache lock control'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        do {
            try {
                $stream = [IO.File]::Open($control.lock, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                break
            } catch [IO.IOException] {
                if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw "Timed out acquiring shader-cache target lock after $TimeoutMilliseconds ms: $($control.lock)" }
                Start-Sleep -Milliseconds ([Math]::Min(100, [Math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)))
            }
        } while ($true)
        $held = [pscustomobject]@{ stream=$stream; runspace=$runspace; count=0 }
        $script:HeldTargets[$key] = $held
    }
    $token = [guid]::NewGuid().ToString('N')
    $held.count++
    $script:Leases[$token] = $key
    return $token
}

function Exit-CSXCacheTargetLock([string]$Token) {
    if (-not $script:Leases.ContainsKey($Token)) { throw 'Unknown or already released shader-cache lock lease.' }
    $key = $script:Leases[$Token]
    $held = $script:HeldTargets[$key]
    if ($held.runspace -ne [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId) { throw 'Shader-cache lock release belongs to another runspace.' }
    $script:Leases.Remove($Token)
    $held.count--
    if ($held.count -eq 0) { $held.stream.Dispose(); $script:HeldTargets.Remove($key) }
}
Export-ModuleMember -Function Get-CSXCacheTransactionControl,Enter-CSXCacheTargetLock,Exit-CSXCacheTargetLock
