# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'resolve', 'register', 'select')]
    [string]$Command = 'list',

    [string]$Name,
    [string]$ConfigPath,
    [string]$UserRoot,
    [switch]$WhatIf,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'mo2-control\ConfigResolution.psm1') -Force

function Read-ActiveModlist([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $active = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $active.PSObject.Properties['schemaVersion'] -or [int]$active.schemaVersion -ne 1) { throw "Active modlist selection has an unsupported schema: $Path" }
    if (-not $active.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$active.name)) { throw "Active modlist selection has no name: $Path" }
    $active
}

function Read-ModlistSummary([IO.FileInfo]$File, [string]$SelectedName) {
    $suffix = '.machine.local.json'
    $name = $File.Name.Substring(0, $File.Name.Length - $suffix.Length)
    try {
        $config = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
        [pscustomobject][ordered]@{
            name = $name
            selected = $name -ceq $SelectedName
            path = $File.FullName
            validJson = $true
            machine = if ($config.PSObject.Properties['machine']) { [string]$config.machine } else { $null }
            mo2Root = if ($config.PSObject.Properties['mo2'] -and $config.mo2.PSObject.Properties['root']) { [string]$config.mo2.root } else { $null }
            profile = if ($config.PSObject.Properties['defaults'] -and $config.defaults.PSObject.Properties['profile']) { [string]$config.defaults.profile } else { $null }
            executable = if ($config.PSObject.Properties['defaults'] -and $config.defaults.PSObject.Properties['executable']) { [string]$config.defaults.executable } else { $null }
            sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
            error = $null
        }
    }
    catch {
        [pscustomobject][ordered]@{
            name = $name; selected = $name -ceq $SelectedName; path = $File.FullName; validJson = $false
            machine = $null; mo2Root = $null; profile = $null; executable = $null; sha256 = $null; error = $_.Exception.Message
        }
    }
}

function New-ModlistResult([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @()) {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $Ok
        command = $Command
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = $State
        errors = @($Errors | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        data = $Data
    }
}

try {
    $resolvedUserRoot = if ([string]::IsNullOrWhiteSpace($UserRoot)) { Get-MO2ControlUserRoot } else { [IO.Path]::GetFullPath($UserRoot) }
    $modlistsDirectory = Get-MO2ControlModlistsDirectory -UserRoot $resolvedUserRoot
    $activePath = Get-MO2ControlActiveModlistPath -UserRoot $resolvedUserRoot
    $active = Read-ActiveModlist -Path $activePath
    $activeName = if ($null -eq $active) { $null } else { [string]$active.name }

    switch ($Command) {
        'list' {
            $files = if (Test-Path -LiteralPath $modlistsDirectory -PathType Container) {
                @(Get-ChildItem -LiteralPath $modlistsDirectory -Filter '*.machine.local.json' -File | Sort-Object Name)
            }
            else { @() }
            $items = @($files | ForEach-Object { Read-ModlistSummary -File $_ -SelectedName $activeName })
            $selectionValid = [string]::IsNullOrWhiteSpace($activeName) -or @($items | Where-Object { $_.name -ceq $activeName -and $_.validJson }).Count -eq 1
            $result = New-ModlistResult -Ok $selectionValid -State $(if (-not $selectionValid) { 'active-selection-invalid' } elseif ($items.Count -eq 0) { 'empty' } elseif ([string]::IsNullOrWhiteSpace($activeName)) { 'selection-required' } else { 'ready' }) -Data ([pscustomobject][ordered]@{
                userRoot = $resolvedUserRoot
                modlistsDirectory = $modlistsDirectory
                activeModlistPath = $activePath
                active = $active
                modlists = $items
            }) -Errors $(if ($selectionValid) { @() } else { @("Active modlist '$activeName' does not resolve to exactly one valid named configuration.") })
        }
        'resolve' {
            if (-not [string]::IsNullOrWhiteSpace($Name)) {
                $path = Get-MO2ControlNamedConfigPath -Name $Name -UserRoot $resolvedUserRoot
                $source = 'named-argument'
                $resolvedName = $Name
            }
            else {
                $stablePath = Join-Path $resolvedUserRoot 'machine.local.json'
                $resolution = Resolve-MO2ControlConfigPath -PackageRoot (Join-Path $toolRoot 'mo2-control') -UserConfigPath $stablePath
                $path = $resolution.path
                $source = $resolution.source
                $resolvedName = $resolution.modlist
            }
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            $result = New-ModlistResult -Ok $exists -State $(if ($exists) { 'resolved' } else { 'not-found' }) -Data ([pscustomobject][ordered]@{ name = $resolvedName; path = $path; source = $source; exists = $exists }) -Errors $(if ($exists) { @() } else { @("Modlist configuration was not found: $path") })
        }
        'register' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw '-Name is required for register.' }
            if ([string]::IsNullOrWhiteSpace($ConfigPath)) { throw '-ConfigPath is required for register.' }
            $source = [IO.Path]::GetFullPath($ConfigPath)
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Configuration source does not exist: $source" }
            $config = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
            foreach ($required in @('mo2', 'defaults', 'storage', 'limits', 'session')) {
                if (-not $config.PSObject.Properties[$required]) { throw "Configuration is missing required object '$required': $source" }
            }
            $destination = Get-MO2ControlNamedConfigPath -Name $Name -UserRoot $resolvedUserRoot
            if (Test-Path -LiteralPath $destination -PathType Leaf) { throw "Named modlist already exists and was not overwritten: $destination" }
            if (-not $WhatIf) {
                New-Item -ItemType Directory -Path $modlistsDirectory -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination
            }
            $result = New-ModlistResult -Ok $true -State $(if ($WhatIf) { 'dry-run' } else { 'registered' }) -Data ([pscustomobject][ordered]@{
                name = $Name; source = $source; path = $destination; created = -not $WhatIf
                sha256 = if ($WhatIf) { (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash } else { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
            })
        }
        'select' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw '-Name is required for select.' }
            $path = Get-MO2ControlNamedConfigPath -Name $Name -UserRoot $resolvedUserRoot
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Named modlist does not exist: $path" }
            $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if (-not $config.PSObject.Properties['mo2'] -or -not $config.PSObject.Properties['defaults']) { throw "Named modlist configuration is incomplete: $path" }
            $selection = [pscustomobject][ordered]@{
                schemaVersion = 1
                name = $Name
                selectedAtUtc = [DateTime]::UtcNow.ToString('o')
                configSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
            if (-not $WhatIf) {
                New-Item -ItemType Directory -Path $resolvedUserRoot -Force | Out-Null
                $temporary = "$activePath.tmp-$([guid]::NewGuid().ToString('N'))"
                try {
                    $selection | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding utf8
                    Move-Item -LiteralPath $temporary -Destination $activePath -Force
                }
                finally {
                    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
                }
            }
            $result = New-ModlistResult -Ok $true -State $(if ($WhatIf) { 'dry-run' } else { 'selected' }) -Data ([pscustomobject][ordered]@{
                name = $Name; path = $path; activeModlistPath = $activePath; selected = -not $WhatIf; selection = $selection
            })
        }
    }
}
catch {
    $result = New-ModlistResult -Ok $false -State 'tool-error' -Data $null -Errors @($_.Exception.Message)
}

$json = @{ InputObject = $result; Depth = 20 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
