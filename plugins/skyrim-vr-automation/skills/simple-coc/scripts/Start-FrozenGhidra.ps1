# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedBuildId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedArtifactSha256,
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$ModsPath,
    [Parameter(Mandatory)][string]$CommunityShadersRoot,
    [string]$GhidraInstallDir,
    [string]$GhidraUserExtensionsDir,
    [string]$JavaHome,
    [string]$ProjectDirectory,
    [switch]$UserAuthorized,
    [string]$AuthorizationStatement,
    [switch]$ResolveOnly,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Test-SamePath([string]$Left, [string]$Right) {
    return (Get-FullPath $Left).Equals(
        (Get-FullPath $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Invoke-JsonScript {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $raw = & $Path @Arguments
    return ($raw | ConvertFrom-Json -Depth 30)
}

function Test-GhidraArtifactReceipt($Receipt, [string]$Path, [string]$Sha256) {
    return $Receipt.ok -and
        [bool]$Receipt.programMatchesExpectation -and
        (Test-SamePath ([string]$Receipt.project.programPath) $Path) -and
        ([string]$Receipt.project.programSha256).Equals(
            $Sha256,
            [StringComparison]::OrdinalIgnoreCase
        )
}

function Test-GhidraStartingReceipt($Receipt, [string]$Path, [string]$Sha256) {
    return [bool]$Receipt.ok -and
        [string]$Receipt.state -ceq 'starting' -and
        [bool]$Receipt.managed -and
        (Test-SamePath ([string]$Receipt.project.programPath) $Path) -and
        ([string]$Receipt.project.programSha256).Equals(
            $Sha256,
            [StringComparison]::OrdinalIgnoreCase
        )
}

$result = $null
try {
    if (-not $ResolveOnly -and
        (-not $UserAuthorized -or
            [string]::IsNullOrWhiteSpace($AuthorizationStatement))) {
        throw 'Starting Ghidra requires an explicit user request recorded with -UserAuthorized and -AuthorizationStatement.'
    }

    $pluginRoot = Get-FullPath (Join-Path $PSScriptRoot '..\..\..')
    $providerTool = Join-Path $pluginRoot (
        'tools\shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    )
    if (-not (Test-Path -LiteralPath $providerTool -PathType Leaf)) {
        throw "The bundled physical-provider resolver is missing: $providerTool"
    }

    $provider = Invoke-JsonScript -Path $providerTool -Arguments @{
        Command = 'providers'
        ProfilePath = $ProfilePath
        ModsPath = $ModsPath
        RelativeCachePath = 'SKSE\Plugins\CommunityShaders.dll'
        DeepInventory = $false
        NoExit = $true
        Compact = $true
    }
    if (-not $provider.ok) {
        throw "Physical provider resolution failed: $($provider.errors -join '; ')"
    }
    $winner = $provider.data.effectiveWinnerAmongEnabledMods
    if ($null -eq $winner -or [string]$winner.providerType -cne 'file') {
        throw 'The exact MO2 profile has no winning loose-file CommunityShaders.dll provider.'
    }

    $artifactPath = Get-FullPath ([string]$winner.providerPath)
    $manifestPath = Join-Path (Split-Path -Parent $artifactPath) (
        'CSX.BuildManifest.json'
    )
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The physical provider has no CSX.BuildManifest.json: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw |
        ConvertFrom-Json -Depth 50
    $artifact = Get-Item -LiteralPath $artifactPath
    $artifactSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    if (-not ([string]$manifest.buildId).Equals(
            $ExpectedBuildId,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([string]$manifest.artifact.sha256).Equals(
            $ExpectedArtifactSha256,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not $artifactSha256.Equals(
            $ExpectedArtifactSha256,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [long]$manifest.artifact.sizeBytes -ne [long]$artifact.Length) {
        throw 'The physical provider does not match the expected Build ID, artifact SHA-256, and byte length.'
    }

    $resolvedCsxRoot = Get-FullPath $CommunityShadersRoot
    $provenanceTool = Join-Path $resolvedCsxRoot 'tools\build_provenance.py'
    if (-not (Test-Path -LiteralPath $provenanceTool -PathType Leaf)) {
        throw "The Community Shaders provenance verifier is missing: $provenanceTool"
    }
    $python = Get-Command python -ErrorAction Stop
    $verifyOutput = @(& $python.Source $provenanceTool verify `
            --manifest $manifestPath --artifact $artifactPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Community Shaders provenance verification failed: $($verifyOutput -join ' ')"
    }

    $projectName = 'CSX-{0}-{1}' -f (
        $ExpectedBuildId.Substring(0, 16).ToLowerInvariant()
    ), ($ExpectedArtifactSha256.Substring(0, 16).ToLowerInvariant())
    $pdbPath = [IO.Path]::ChangeExtension($artifactPath, '.pdb')
    $binding = [pscustomobject][ordered]@{
        profilePath = Get-FullPath ([string]$provider.data.profilePath)
        profileSha256 = [string]$provider.data.profileSha256
        modName = [string]$winner.modName
        modRoot = Get-FullPath ([string]$winner.modRoot)
        artifactPath = $artifactPath
        manifestPath = Get-FullPath $manifestPath
        pdbPath = $(if (Test-Path -LiteralPath $pdbPath -PathType Leaf) {
                Get-FullPath $pdbPath
            } else { $null })
        bytes = [long]$artifact.Length
        artifactSha256 = $artifactSha256
        buildId = ([string]$manifest.buildId).ToLowerInvariant()
        projectName = $projectName
    }

    if ($ResolveOnly) {
        $result = [pscustomobject][ordered]@{
            schema = 'csx-frozen-ghidra-v1'
            ok = $true
            state = 'identity-resolved'
            userAuthorized = $false
            authorizationStatement = $null
            binding = $binding
            ghidra = $null
            errors = @()
        }
    }
    else {
        $controller = Join-Path $resolvedCsxRoot 'tools\ghidra-mcp-control.ps1'
        if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) {
            throw "The managed Ghidra controller is missing: $controller"
        }
        $controllerArguments = @{
            Action = 'start'
            ProgramPath = $artifactPath
            ProjectName = $projectName
            NoExit = $true
            Compact = $true
        }
        foreach ($entry in @{
                GhidraInstallDir = $GhidraInstallDir
                GhidraUserExtensionsDir = $GhidraUserExtensionsDir
                JavaHome = $JavaHome
                ProjectDirectory = $ProjectDirectory
            }.GetEnumerator()) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                $controllerArguments[$entry.Key] = [string]$entry.Value
            }
        }
        $ghidra = Invoke-JsonScript -Path $controller -Arguments $controllerArguments
        $projectSwitch = $null
        if ((Test-GhidraArtifactReceipt $ghidra $artifactPath $artifactSha256) -and
            [string]$ghidra.project.name -cne $projectName) {
            $stopped = Invoke-JsonScript -Path $controller -Arguments @{
                Action = 'stop'
                NoExit = $true
                Compact = $true
            }
            if (-not $stopped.ok) {
                throw 'The managed stale Ghidra project could not be stopped cleanly.'
            }
            $projectSwitch = [pscustomobject][ordered]@{
                from = [string]$ghidra.project.name
                to = $projectName
                stop = $stopped
            }
            $ghidra = Invoke-JsonScript -Path $controller -Arguments (
                $controllerArguments
            )
        }
        $matches = ((Test-GhidraArtifactReceipt `
                    $ghidra $artifactPath $artifactSha256) -or
                (Test-GhidraStartingReceipt `
                    $ghidra $artifactPath $artifactSha256)) -and
            [string]$ghidra.project.name -ceq $projectName
        if (-not $matches) {
            throw 'The managed Ghidra receipt does not match the verified physical artifact and build-specific project.'
        }
        $result = [pscustomobject][ordered]@{
            schema = 'csx-frozen-ghidra-v1'
            ok = $true
            state = [string]$ghidra.state
            userAuthorized = $true
            authorizationStatement = $AuthorizationStatement
            binding = $binding
            projectSwitch = $projectSwitch
            ghidra = $ghidra
            errors = @()
        }
    }
}
catch {
    $result = [pscustomobject][ordered]@{
        schema = 'csx-frozen-ghidra-v1'
        ok = $false
        state = 'blocked'
        userAuthorized = [bool]$UserAuthorized
        authorizationStatement = $AuthorizationStatement
        binding = $null
        ghidra = $null
        errors = @($_.Exception.Message)
    }
}

$json = @{ InputObject = $result; Depth = 40 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
