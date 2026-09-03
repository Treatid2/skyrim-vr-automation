# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'validate', 'validate-closed', 'request-access', 'access-status', 'renew-access', 'release-access', 'recover-access', 'prepare', 'open', 'launch', 'status', 'stop-game', 'terminate-game', 'close', 'recover-close', 'recover-rootbuilder', 'stop', 'terminate', 'release', 'help')]
    [string]$Command = 'help',

    [string]$ConfigPath,

    [string]$Profile,

    [string]$Executable,

    [string]$SessionId,

    [string]$AccessId,

    [Alias('ReporterTaskId')]
    [string]$TaskId,

    [string]$Label = 'automation',

    [ValidateSet('OCU', 'SteamVR', 'SteamVRNull')]
    [string]$RuntimeRoute,

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 90,

    [Nullable[int]]$EstimatedMinutes,

    [ValidateRange(0, 600)]
    [int]$WaitSeconds = 0,

    [switch]$WhatIf,

    [switch]$RequireClosed,

    [switch]$RequireSKSE,

    [switch]$StartOnly,

    [switch]$NoExit,

    [switch]$ConfirmAbandoned,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configuration = $null

function New-MO2ApprovalMetadata {
    param([Parameter(Mandatory)][string]$Subcommand)
    $hostExecutable = [string][Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($hostExecutable)) {
        $hostExecutable = [string](Get-Process -Id $PID -ErrorAction Stop).Path
    }
    $entryPoint = [IO.Path]::GetFullPath($PSCommandPath)
    $oneShotCommands = @('recover-access', 'terminate-game', 'terminate')
    $readOnlyCommands = @('inspect', 'validate', 'validate-closed', 'access-status', 'status', 'help')
    return [pscustomobject][ordered]@{
        hostExecutable = $hostExecutable
        entryPoint = $entryPoint
        subcommand = $Subcommand
        reusablePrefix = @($hostExecutable, '-NoProfile', '-NonInteractive', '-File', $entryPoint, $Subcommand)
        reusableApprovalEligible = $Subcommand -notin $oneShotCommands
        escalationUsuallyRequired = $Subcommand -notin $readOnlyCommands
        oneShotReason = if ($Subcommand -in $oneShotCommands) { 'Recovery ownership transfer or forced process termination must remain a one-shot approval.' } else { $null }
        invocationRule = 'Use the literal host, entry-point, and subcommand shown here. Put changing IDs and paths afterward; do not wrap the call in -Command, variables, pipelines, or a command string.'
    }
}

function Set-MO2ResultDataValue {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )
    if ($null -eq $Result.data) {
        $Result.data = [ordered]@{}
    }
    if ($Result.data -is [Collections.IDictionary]) {
        $Result.data[$Name] = $Value
        return
    }
    $Result.data | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$sessionLocalConfig = Join-Path $PSScriptRoot 'config\machine.local.json'
if ([string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $sessionLocalConfig -PathType Leaf)) {
    # A prepare/recover-created controller bundle is self-contained. Prefer its
    # exact captured configuration over any newer per-user/plugin installation.
    $ConfigPath = $sessionLocalConfig
}

try {
    Import-Module (Join-Path $PSScriptRoot 'ConfigResolution.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'MO2Control.psm1') -Force -ErrorAction Stop
    $configuration = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot $PSScriptRoot
    if (-not $configuration.exists) {
        throw "MO2 configuration was not found at '$($configuration.path)' (source: $($configuration.source)). Run tools/doctor/Invoke-SkyrimVRAutomationDoctor.ps1 init, pass -ConfigPath, or set SKYRIM_VR_AUTOMATION_CONFIG."
    }
    $config = Read-MO2ControlConfig -ConfigPath $configuration.path

    $sessionCommands = @('open', 'launch', 'stop-game', 'terminate-game', 'close', 'recover-rootbuilder', 'stop', 'terminate', 'release')
    if ($Command -in $sessionCommands -and [string]::IsNullOrWhiteSpace($SessionId)) {
        $result = [pscustomobject][ordered]@{
            contractVersion = '0.9.0'
            command = $Command
            ok = $false
            state = 'missing-session-id'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            checks = @()
            warnings = @()
            errors = @("Command '$Command' requires a non-empty -SessionId returned by prepare or recover-close.")
            data = [pscustomobject]@{ requiredParameter = 'SessionId'; supplied = $false }
        }
    }
    elseif ($Command -eq 'request-access' -and [string]::IsNullOrWhiteSpace($RuntimeRoute)) {
        $result = [pscustomobject][ordered]@{
            contractVersion = '0.9.0'
            command = $Command
            ok = $false
            state = 'missing-runtime-route'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            checks = @()
            warnings = @()
            errors = @("Command '$Command' requires exactly one -RuntimeRoute: OCU, SteamVR, or SteamVRNull.")
            data = [pscustomobject]@{ requiredParameter = 'RuntimeRoute'; allowedValues = @('OCU', 'SteamVR', 'SteamVRNull'); supplied = $false }
        }
    }
    elseif ($Command -in @('renew-access', 'release-access', 'recover-access') -and [string]::IsNullOrWhiteSpace($AccessId)) {
        $result = [pscustomobject][ordered]@{
            contractVersion = '0.9.0'
            command = $Command
            ok = $false
            state = 'missing-access-id'
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            checks = @()
            warnings = @()
            errors = @("Command '$Command' requires a non-empty -AccessId returned by request-access.")
            data = [pscustomobject]@{ requiredParameter = 'AccessId'; supplied = $false }
        }
    }
    else { $result = switch ($Command) {
        'inspect' {
            Invoke-MO2Inspect -Config $config -Profile $Profile -Executable $Executable
        }
        'validate' {
            Invoke-MO2Validate -Config $config -Profile $Profile -Executable $Executable -RequireSKSE:$RequireSKSE -RequireClosed:$RequireClosed -OwnedAccessId $AccessId
        }
        'validate-closed' {
            $validated = Invoke-MO2Validate -Config $config -Profile $Profile -Executable $Executable -RequireClosed -OwnedAccessId $AccessId
            $validated.command = 'validate-closed'
            $validated
        }
        'request-access' {
            Invoke-MO2RequestAccess -Config $config -Label $Label -TaskId $TaskId -RuntimeRoute $RuntimeRoute -EstimatedMinutes $EstimatedMinutes -WaitSeconds $WaitSeconds -WhatIf:$WhatIf
        }
        'access-status' {
            Invoke-MO2AccessStatus -Config $config -AccessId $AccessId
        }
        'renew-access' {
            Invoke-MO2RenewAccess -Config $config -AccessId $AccessId -EstimatedMinutes $EstimatedMinutes -WhatIf:$WhatIf
        }
        'release-access' {
            Invoke-MO2ReleaseAccess -Config $config -AccessId $AccessId -WhatIf:$WhatIf
        }
        'recover-access' {
            Invoke-MO2RecoverAccess -Config $config -AccessId $AccessId -Label $Label -ConfirmAbandoned:$ConfirmAbandoned -WhatIf:$WhatIf
        }
        'prepare' {
            Invoke-MO2Prepare -Config $config -Profile $Profile -Executable $Executable -RequireSKSE:$RequireSKSE -Label $Label -AccessId $AccessId -WhatIf:$WhatIf
        }
        'open' {
            Invoke-MO2Open -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -StartOnly:$StartOnly -WhatIf:$WhatIf
        }
        'launch' {
            Invoke-MO2Launch -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -StartOnly:$StartOnly -WhatIf:$WhatIf
        }
        'status' {
            Invoke-MO2Status -Config $config -SessionId $SessionId
        }
        'stop-game' {
            Invoke-MO2StopGame -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'terminate-game' {
            Invoke-MO2TerminateGame -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'close' {
            Invoke-MO2Close -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'recover-close' {
            Invoke-MO2RecoverClose -Config $config -AccessId $AccessId -Label $Label -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'recover-rootbuilder' {
            Invoke-MO2RecoverRootBuilder -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -StartOnly:$StartOnly -WhatIf:$WhatIf
        }
        'stop' {
            Invoke-MO2Stop -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'terminate' {
            Invoke-MO2Terminate -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'release' {
            Invoke-MO2Release -Config $config -SessionId $SessionId -WhatIf:$WhatIf
        }
        'help' {
            Get-MO2ControlHelp -Config $config
        }
    } }

    Set-MO2ResultDataValue -Result $result -Name configuration -Value $configuration
    Set-MO2ResultDataValue -Result $result -Name approval -Value (New-MO2ApprovalMetadata -Subcommand $Command)
}
catch {
    $result = [pscustomobject][ordered]@{
        contractVersion = '0.9.0'
        command = $Command
        ok = $false
        state = 'tool-error'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        checks = @()
        warnings = @()
        errors = @($_.Exception.Message)
        data = [pscustomobject]@{
            exceptionType = $_.Exception.GetType().FullName
            configuration = $configuration
            requestedConfigPath = $ConfigPath
            approval = New-MO2ApprovalMetadata -Subcommand $Command
        }
    }
}

$jsonParameters = @{
    InputObject = $result
    Depth = 16
}
if ($Compact) {
    $jsonParameters['Compress'] = $true
}

ConvertTo-Json @jsonParameters

if (-not $result.ok -and -not $NoExit) {
    exit 2
}
