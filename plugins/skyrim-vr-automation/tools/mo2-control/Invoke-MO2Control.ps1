# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'validate', 'prepare', 'open', 'launch', 'status', 'stop-game', 'close', 'recover-close', 'recover-rootbuilder', 'stop', 'terminate', 'release', 'help')]
    [string]$Command = 'help',

    [string]$ConfigPath,

    [string]$Profile,

    [string]$Executable,

    [string]$SessionId,

    [string]$Label = 'automation',

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 90,

    [switch]$WhatIf,

    [switch]$RequireClosed,

    [switch]$StartOnly,

    [switch]$NoExit,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configuration = $null

try {
    Import-Module (Join-Path $PSScriptRoot 'ConfigResolution.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'MO2Control.psm1') -Force -ErrorAction Stop
    $configuration = Resolve-MO2ControlConfigPath -ConfigPath $ConfigPath -PackageRoot $PSScriptRoot
    if (-not $configuration.exists) {
        throw "MO2 configuration was not found at '$($configuration.path)' (source: $($configuration.source)). Run tools/doctor/Invoke-SkyrimVRAutomationDoctor.ps1 init, pass -ConfigPath, or set SKYRIM_VR_AUTOMATION_CONFIG."
    }
    $config = Read-MO2ControlConfig -ConfigPath $configuration.path

    $sessionCommands = @('open', 'launch', 'stop-game', 'close', 'recover-rootbuilder', 'stop', 'terminate', 'release')
    if ($Command -in $sessionCommands -and [string]::IsNullOrWhiteSpace($SessionId)) {
        $result = [pscustomobject][ordered]@{
            contractVersion = '0.5.0'
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
    else { $result = switch ($Command) {
        'inspect' {
            Invoke-MO2Inspect -Config $config -Profile $Profile -Executable $Executable
        }
        'validate' {
            Invoke-MO2Validate -Config $config -Profile $Profile -Executable $Executable -RequireClosed:$RequireClosed
        }
        'prepare' {
            Invoke-MO2Prepare -Config $config -Profile $Profile -Executable $Executable -Label $Label -WhatIf:$WhatIf
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
        'close' {
            Invoke-MO2Close -Config $config -SessionId $SessionId -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
        }
        'recover-close' {
            Invoke-MO2RecoverClose -Config $config -Label $Label -TimeoutSeconds $TimeoutSeconds -WhatIf:$WhatIf
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

    $result.data | Add-Member -NotePropertyName configuration -NotePropertyValue $configuration -Force
}
catch {
    $result = [pscustomobject][ordered]@{
        contractVersion = '0.5.0'
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
