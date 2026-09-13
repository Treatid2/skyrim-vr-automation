# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Get-MO2ControlUserRoot {
    [CmdletBinding()]
    param()

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Windows LocalApplicationData could not be resolved.'
    }
    Join-Path $localAppData 'SkyrimVRAutomation'
}

function Get-MO2ControlUserConfigPath {
    [CmdletBinding()]
    param()

    Join-Path (Get-MO2ControlUserRoot) 'machine.local.json'
}

function Get-MO2ControlModlistsDirectory {
    [CmdletBinding()]
    param([string]$UserRoot)

    $root = if ([string]::IsNullOrWhiteSpace($UserRoot)) { Get-MO2ControlUserRoot } else { [IO.Path]::GetFullPath($UserRoot) }
    Join-Path $root 'modlists'
}

function Get-MO2ControlActiveModlistPath {
    [CmdletBinding()]
    param([string]$UserRoot)

    $root = if ([string]::IsNullOrWhiteSpace($UserRoot)) { Get-MO2ControlUserRoot } else { [IO.Path]::GetFullPath($UserRoot) }
    Join-Path $root 'active-modlist.json'
}

function Assert-MO2ControlModlistName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ($Name -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
        throw "Invalid modlist name '$Name'. Use 1-64 lowercase letters, digits, dots, underscores, or hyphens."
    }
}

function Get-MO2ControlNamedConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$UserRoot
    )

    Assert-MO2ControlModlistName -Name $Name
    Join-Path (Get-MO2ControlModlistsDirectory -UserRoot $UserRoot) "$Name.machine.local.json"
}

function Resolve-MO2ControlConfigPath {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$PackageRoot = $PSScriptRoot,
        [string]$UserConfigPath
    )

    $stablePath = if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { Get-MO2ControlUserConfigPath } else { [IO.Path]::GetFullPath($UserConfigPath) }
    $userRoot = [IO.Path]::GetFullPath((Split-Path -Parent $stablePath))
    $modlistsDirectory = Get-MO2ControlModlistsDirectory -UserRoot $userRoot
    $activeModlistPath = Get-MO2ControlActiveModlistPath -UserRoot $userRoot
    $candidates = [System.Collections.Generic.List[object]]::new()
    $selectedSource = $null
    $selectedPath = $null
    $selectedName = $null

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $selectedSource = 'explicit'
        $selectedPath = [IO.Path]::GetFullPath($ConfigPath)
        $candidates.Add([pscustomobject]@{ source = $selectedSource; path = $selectedPath })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_CONFIG)) {
        $selectedSource = 'environment'
        $selectedPath = [IO.Path]::GetFullPath($env:SKYRIM_VR_AUTOMATION_CONFIG)
        $candidates.Add([pscustomobject]@{ source = $selectedSource; path = $selectedPath })
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_MODLIST)) {
        $selectedName = [string]$env:SKYRIM_VR_AUTOMATION_MODLIST
        $selectedSource = 'environment-modlist'
        $selectedPath = Get-MO2ControlNamedConfigPath -Name $selectedName -UserRoot $userRoot
        $candidates.Add([pscustomobject]@{ source = $selectedSource; name = $selectedName; path = $selectedPath })
    }
    elseif (Test-Path -LiteralPath $activeModlistPath -PathType Leaf) {
        try {
            $active = Get-Content -LiteralPath $activeModlistPath -Raw | ConvertFrom-Json
            if (-not $active.PSObject.Properties['schemaVersion'] -or [int]$active.schemaVersion -ne 1) { throw 'schemaVersion must be 1' }
            if (-not $active.PSObject.Properties['name']) { throw 'name is required' }
            $selectedName = [string]$active.name
            $selectedSource = 'active-modlist'
            $selectedPath = Get-MO2ControlNamedConfigPath -Name $selectedName -UserRoot $userRoot
            $candidates.Add([pscustomobject]@{ source = $selectedSource; name = $selectedName; path = $selectedPath; selectionPath = $activeModlistPath })
        }
        catch {
            $selectedSource = 'active-modlist-invalid'
            $selectedPath = $activeModlistPath
            $candidates.Add([pscustomobject]@{ source = $selectedSource; path = $selectedPath; error = $_.Exception.Message })
        }
    }
    else {
        $namedConfigs = if (Test-Path -LiteralPath $modlistsDirectory -PathType Container) {
            @(Get-ChildItem -LiteralPath $modlistsDirectory -Filter '*.machine.local.json' -File | Sort-Object Name)
        }
        else { @() }

        if ($namedConfigs.Count -gt 0) {
            $selectedSource = 'named-selection-required'
            $selectedPath = $activeModlistPath
            foreach ($namedConfig in $namedConfigs) {
                $name = $namedConfig.Name.Substring(0, $namedConfig.Name.Length - '.machine.local.json'.Length)
                $candidates.Add([pscustomobject]@{ source = 'named-modlist'; name = $name; path = $namedConfig.FullName })
            }
        }
        else {
            $candidates.Add([pscustomobject]@{ source = 'user'; path = $stablePath })
            $candidates.Add([pscustomobject]@{ source = 'legacy-package-local'; path = [IO.Path]::GetFullPath((Join-Path $PackageRoot 'config\machine.local.json')) })
            $selected = @($candidates | Where-Object { Test-Path -LiteralPath $_.path -PathType Leaf } | Select-Object -First 1)
            if ($selected.Count -eq 0) { $selected = @($candidates[0]) }
            $selectedSource = [string]$selected[0].source
            $selectedPath = [string]$selected[0].path
        }
    }

    [pscustomobject][ordered]@{
        path = [string]$selectedPath
        source = [string]$selectedSource
        exists = -not [string]::IsNullOrWhiteSpace($selectedPath) -and (Test-Path -LiteralPath $selectedPath -PathType Leaf) -and $selectedSource -notin @('active-modlist-invalid', 'named-selection-required')
        modlist = $selectedName
        modlistsDirectory = $modlistsDirectory
        activeModlistPath = $activeModlistPath
        candidates = @($candidates)
    }
}

Export-ModuleMember -Function Get-MO2ControlUserRoot, Get-MO2ControlUserConfigPath, Get-MO2ControlModlistsDirectory, Get-MO2ControlActiveModlistPath, Get-MO2ControlNamedConfigPath, Resolve-MO2ControlConfigPath
