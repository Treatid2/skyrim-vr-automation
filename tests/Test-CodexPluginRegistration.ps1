# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$subjectPath = Join-Path $repositoryRoot 'scripts\Install-CodexMarketplacePlugin.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-plugin-registration-' + [guid]::NewGuid().ToString('N'))
$priorStatePath = $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE
$passedCases = [Collections.Generic.List[string]]::new()

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-MarketplaceManifest {
    param([string]$SourceKind = 'local', [string]$SourcePath = './plugins/skyrim-vr-automation')
    [pscustomobject][ordered]@{
        name = 'skyrim-vr-tools'
        plugins = @([pscustomobject][ordered]@{
                name = 'skyrim-vr-automation'
                source = [pscustomobject][ordered]@{ source = $SourceKind; path = $SourcePath }
            })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $marketplaceManifestPath -Encoding utf8NoBOM
}

function Reset-SourceTree {
    param([string]$ManifestName = 'skyrim-vr-automation')
    if (Test-Path -LiteralPath $pluginRoot) { Remove-Item -LiteralPath $pluginRoot -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $pluginRoot '.codex-plugin'), (Join-Path $pluginRoot 'skills\coc-stability') -Force | Out-Null
    Write-Utf8File (Join-Path $pluginRoot '.codex-plugin\plugin.json') ("{`"name`":`"$ManifestName`",`"version`":`"0.8.0+codex.current`"}")
    Write-Utf8File (Join-Path $pluginRoot 'skills\coc-stability\SKILL.md') 'current'
    $hiddenPath = Join-Path $pluginRoot '.hidden.ps1'
    Write-Utf8File $hiddenPath 'hidden-current'
    (Get-Item -LiteralPath $hiddenPath -Force).Attributes = [IO.FileAttributes]::Hidden
    Write-MarketplaceManifest
}

function Write-State {
    param([hashtable]$Overrides = @{})
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
    $state = [ordered]@{
        marketplaceMode = 'exact'; afterMarketplaceAddMode = 'exact'
        marketplaceRoot = [IO.Path]::GetFullPath($marketplaceRoot)
        wrongMarketplaceRoot = [IO.Path]::GetFullPath((Join-Path $fixture 'wrong-marketplace'))
        pluginInstalled = $false; omitInstalledEntry = $false; omitInstalledEntryAfterMarketplaceAdd = $false
        stale = $false; remainStaleAfterMarketplaceAdd = $false
        staleVersion = '0.8.0+codex.stale'; expectedVersion = '0.8.0+codex.current'
        sourcePluginRoot = [IO.Path]::GetFullPath($pluginRoot); installedRoot = [IO.Path]::GetFullPath($installRoot)
        installMode = 'exact'; pluginAddCount = 0; pluginRemoveCount = 0
        marketplaceAddCount = 0; marketplaceRemoveCount = 0; marketplaceListCount = 0; commandCount = 0
    }
    foreach ($key in $Overrides.Keys) { $state[$key] = $Overrides[$key] }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM
}

function Invoke-Subject {
    param([switch]$WithoutConfirmation)
    $arguments = @{
        MarketplaceRoot = $marketplaceRoot; CodexCommand = $powerShell
        CodexPrefixArguments = @('-NoProfile', '-File', $mockPath)
    }
    if (-not $WithoutConfirmation) { $arguments.ConfirmSafeCacheRotation = $true }
    & $subjectPath @arguments
}

function Assert-Failure {
    param([string]$Name, [scriptblock]$Action, [string]$MessageLike)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    if ($null -eq $failure) { throw "[$Name] Expected failure, but the operation succeeded." }
    if ($failure.Exception.Message -notlike $MessageLike) { throw "[$Name] Unexpected failure: $($failure.Exception.Message)" }
    $passedCases.Add($Name)
}

function Assert-Count {
    param([string]$Name, [object]$Actual, [object]$Expected)
    if ($Actual -ne $Expected) { throw "[$Name] Expected '$Expected', got '$Actual'." }
}

try {
    $marketplaceRoot = Join-Path $fixture 'marketplace'
    $pluginRoot = Join-Path $marketplaceRoot 'plugins\skyrim-vr-automation'
    $marketplaceManifestPath = Join-Path $marketplaceRoot '.agents\plugins\marketplace.json'
    $installRoot = Join-Path $fixture 'cache\skyrim-vr-tools\skyrim-vr-automation\0.8.0+codex.current'
    $statePath = Join-Path $fixture 'state.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $marketplaceManifestPath), (Join-Path $fixture 'wrong-marketplace') -Force | Out-Null
    Reset-SourceTree
    $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE = $statePath

    $mockPath = Join-Path $fixture 'codex-mock.ps1'
    Write-Utf8File $mockPath @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$statePath = $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$command = @($args)
function Save-State { $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding utf8NoBOM }
function Assert-Arguments {
    param([string[]]$Expected)
    if ($command.Count -ne $Expected.Count) { throw "Unexpected mock command: $($command -join ' ')" }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($command[$index] -cne $Expected[$index]) { throw "Unexpected mock command: $($command -join ' ')" }
    }
}
$state.commandCount++
if ($command.Count -ge 3 -and ($command[0..2] -join ' ') -eq 'plugin marketplace list') {
    Assert-Arguments @('plugin', 'marketplace', 'list', '--json')
    $state.marketplaceListCount++
    $items = switch ($state.marketplaceMode) {
        'absent' { @() }
        'exact' { @([pscustomobject]@{ name = 'skyrim-vr-tools'; root = $state.marketplaceRoot }) }
        'wrong' { @([pscustomobject]@{ name = 'skyrim-vr-tools'; root = $state.wrongMarketplaceRoot }) }
        'duplicate' { @([pscustomobject]@{ name = 'skyrim-vr-tools'; root = $state.marketplaceRoot }, [pscustomobject]@{ name = 'skyrim-vr-tools'; root = $state.marketplaceRoot }) }
        default { throw "Unknown marketplace mode '$($state.marketplaceMode)'." }
    }
    Save-State
    [pscustomobject]@{ marketplaces = $items } | ConvertTo-Json -Depth 5
    return
}
if ($command.Count -ge 2 -and ($command[0..1] -join ' ') -eq 'plugin list') {
    Assert-Arguments @('plugin', 'list', '--marketplace', 'skyrim-vr-tools', '--json')
    $items = if ($state.pluginInstalled -and -not $state.omitInstalledEntry) {
        @([pscustomobject]@{ pluginId = 'skyrim-vr-automation@skyrim-vr-tools'; name = 'skyrim-vr-automation'; marketplaceName = 'skyrim-vr-tools'; version = $(if ($state.stale) { $state.staleVersion } else { $state.expectedVersion }); installed = $true; enabled = $true })
    } else { @() }
    Save-State
    [pscustomobject]@{ installed = $items; available = @() } | ConvertTo-Json -Depth 5
    return
}
if ($command.Count -ge 2 -and ($command[0..1] -join ' ') -eq 'plugin add') {
    Assert-Arguments @('plugin', 'add', 'skyrim-vr-automation@skyrim-vr-tools', '--json')
    if (Test-Path -LiteralPath $state.installedRoot) { Remove-Item -LiteralPath $state.installedRoot -Recurse -Force }
    if ($state.installMode -ne 'missingRoot') {
        New-Item -ItemType Directory -Path (Split-Path -Parent $state.installedRoot) -Force | Out-Null
        Copy-Item -LiteralPath $state.sourcePluginRoot -Destination $state.installedRoot -Recurse -Force
        switch ($state.installMode) {
            'extraVisible' { [IO.File]::WriteAllText((Join-Path $state.installedRoot 'extra.ps1'), 'extra') }
            'extraHidden' { $path = Join-Path $state.installedRoot 'extra-hidden.ps1'; [IO.File]::WriteAllText($path, 'extra-hidden'); (Get-Item -LiteralPath $path -Force).Attributes = [IO.FileAttributes]::Hidden }
            'missingHidden' { Remove-Item -LiteralPath (Join-Path $state.installedRoot '.hidden.ps1') -Force }
            'corruptVisible' { [IO.File]::WriteAllText((Join-Path $state.installedRoot 'skills\coc-stability\SKILL.md'), 'corrupt') }
            'corruptHidden' {
                $path = Join-Path $state.installedRoot '.hidden.ps1'
                (Get-Item -LiteralPath $path -Force).Attributes = [IO.FileAttributes]::Normal
                [IO.File]::WriteAllText($path, 'corrupt-hidden')
                (Get-Item -LiteralPath $path -Force).Attributes = [IO.FileAttributes]::Hidden
            }
        }
    }
    $state.pluginInstalled = $true; $state.pluginAddCount++; Save-State
    $reportedVersion = if ($state.installMode -eq 'wrongAddVersion') { $state.staleVersion } else { $state.expectedVersion }
    [pscustomobject]@{ pluginId = 'skyrim-vr-automation@skyrim-vr-tools'; version = $reportedVersion; installedPath = $state.installedRoot } | ConvertTo-Json
    return
}
if ($command.Count -ge 2 -and ($command[0..1] -join ' ') -eq 'plugin remove') {
    Assert-Arguments @('plugin', 'remove', 'skyrim-vr-automation@skyrim-vr-tools', '--json')
    $state.pluginInstalled = $false; $state.pluginRemoveCount++; Save-State
    [pscustomobject]@{ pluginId = 'skyrim-vr-automation@skyrim-vr-tools' } | ConvertTo-Json
    return
}
if ($command.Count -ge 3 -and ($command[0..2] -join ' ') -eq 'plugin marketplace remove') {
    Assert-Arguments @('plugin', 'marketplace', 'remove', 'skyrim-vr-tools', '--json')
    $state.marketplaceMode = 'absent'; $state.marketplaceRemoveCount++; Save-State
    [pscustomobject]@{ marketplaceName = 'skyrim-vr-tools' } | ConvertTo-Json
    return
}
if ($command.Count -ge 3 -and ($command[0..2] -join ' ') -eq 'plugin marketplace add') {
    Assert-Arguments @('plugin', 'marketplace', 'add', $state.marketplaceRoot, '--json')
    $state.marketplaceMode = $state.afterMarketplaceAddMode
    if (-not $state.remainStaleAfterMarketplaceAdd) { $state.stale = $false }
    if ($state.omitInstalledEntryAfterMarketplaceAdd) { $state.omitInstalledEntry = $true }
    $state.marketplaceAddCount++; Save-State
    [pscustomobject]@{ marketplaceName = 'skyrim-vr-tools'; installedRoot = $state.marketplaceRoot } | ConvertTo-Json
    return
}
throw "Unexpected mock command: $($command -join ' ')"
'@
    $powerShell = (Get-Process -Id $PID).Path

    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($subjectPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw "Installer parse failed: $($parseErrors[0].Message)" }
    $normalizerAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-NormalizedPath' }, $true)
    Invoke-Expression $normalizerAst.Extent.Text
    $extendedDrive = '\\?\' + [IO.Path]::GetFullPath($marketplaceRoot)
    if ((Resolve-NormalizedPath $extendedDrive) -cne [IO.Path]::GetFullPath($marketplaceRoot)) { throw 'Extended drive path normalization failed.' }
    if ((Resolve-NormalizedPath '\\?\UNC\server\share\repo\') -cne '\\server\share\repo') { throw 'Extended UNC path normalization failed.' }
    $passedCases.Add('extended path normalization')

    Write-State
    Assert-Failure 'cache rotation confirmation guard' { Invoke-Subject -WithoutConfirmation } '*-ConfirmSafeCacheRotation*'
    Assert-Count 'guard command count' (Get-Content $statePath -Raw | ConvertFrom-Json).commandCount 0

    Reset-SourceTree; Write-State
    $result = Invoke-Subject | ConvertFrom-Json; $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if (-not $result.ok -or -not $result.sourceAndInstalledMatch -or $result.verifiedFiles -ne 3) { throw 'Existing exact registration did not pass complete parity.' }
    Assert-Count 'existing exact plugin add count' $state.pluginAddCount 1
    Assert-Count 'existing exact marketplace add count' $state.marketplaceAddCount 0
    $passedCases.Add('existing exact registration')

    Reset-SourceTree; Write-State @{ marketplaceMode = 'absent' }
    $result = Invoke-Subject | ConvertFrom-Json; $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if (-not $result.registrationRefreshed) { throw 'Initially absent registration was not classified as refreshed.' }
    Assert-Count 'initial add marketplace list count' $state.marketplaceListCount 2
    Assert-Count 'initial add marketplace add count' $state.marketplaceAddCount 1
    $passedCases.Add('initially absent registration is rebound')

    Reset-SourceTree; Write-State @{ pluginInstalled = $true; stale = $true }
    $result = Invoke-Subject | ConvertFrom-Json; $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if ($result.staleReportedVersion -ne '0.8.0+codex.stale') { throw 'Stale version was not retained in the receipt.' }
    Assert-Count 'repair plugin add count' $state.pluginAddCount 2
    Assert-Count 'repair plugin remove count' $state.pluginRemoveCount 1
    Assert-Count 'repair marketplace add count' $state.marketplaceAddCount 1
    Assert-Count 'repair marketplace remove count' $state.marketplaceRemoveCount 1
    $passedCases.Add('single bounded stale repair')

    foreach ($case in @(
            @{ Name = 'duplicate existing registration'; State = @{ marketplaceMode = 'duplicate' }; Like = '*duplicate*' },
            @{ Name = 'wrong existing registration root'; State = @{ marketplaceMode = 'wrong' }; Like = '*points to*' },
            @{ Name = 'duplicate registration after initial add'; State = @{ marketplaceMode = 'absent'; afterMarketplaceAddMode = 'duplicate' }; Like = '*exactly one*' },
            @{ Name = 'wrong registration root after initial add'; State = @{ marketplaceMode = 'absent'; afterMarketplaceAddMode = 'wrong' }; Like = '*points to*' },
            @{ Name = 'wrong registration root after stale repair'; State = @{ pluginInstalled = $true; stale = $true; afterMarketplaceAddMode = 'wrong' }; Like = '*points to*' },
            @{ Name = 'stale after the one repair'; State = @{ pluginInstalled = $true; stale = $true; remainStaleAfterMarketplaceAdd = $true }; Like = '*stale after one scoped refresh*' },
            @{ Name = 'installed entry absent after repair'; State = @{ pluginInstalled = $true; stale = $true; omitInstalledEntryAfterMarketplaceAdd = $true }; Like = '*stale after one scoped refresh*' },
            @{ Name = 'missing installed root'; State = @{ installMode = 'missingRoot' }; Like = '*missing installed path*' },
            @{ Name = 'plugin add reports wrong version'; State = @{ installMode = 'wrongAddVersion' }; Like = '*instead of*' },
            @{ Name = 'extra visible installed file'; State = @{ installMode = 'extraVisible' }; Like = '*file set*' },
            @{ Name = 'extra hidden installed file'; State = @{ installMode = 'extraHidden' }; Like = '*file set*' },
            @{ Name = 'missing hidden installed file'; State = @{ installMode = 'missingHidden' }; Like = '*file set*' },
            @{ Name = 'visible content hash drift'; State = @{ installMode = 'corruptVisible' }; Like = '*content differs*' },
            @{ Name = 'hidden content hash drift'; State = @{ installMode = 'corruptHidden' }; Like = '*content differs*' }
        )) {
        Reset-SourceTree; Write-State $case.State
        Assert-Failure $case.Name { Invoke-Subject } $case.Like
    }

    Reset-SourceTree; Write-State; Write-MarketplaceManifest -SourceKind 'git'
    Assert-Failure 'non-local marketplace source' { Invoke-Subject } "*source kind 'local'*"
    Assert-Count 'non-local command count' (Get-Content $statePath -Raw | ConvertFrom-Json).commandCount 0

    Reset-SourceTree; Write-State; Write-MarketplaceManifest -SourcePath $pluginRoot
    Assert-Failure 'rooted marketplace source path' { Invoke-Subject } '*must be relative*'
    Assert-Count 'rooted source command count' (Get-Content $statePath -Raw | ConvertFrom-Json).commandCount 0

    $externalPlugin = Join-Path $fixture 'external-plugin'
    New-Item -ItemType Directory -Path (Join-Path $externalPlugin '.codex-plugin') -Force | Out-Null
    Write-Utf8File (Join-Path $externalPlugin '.codex-plugin\plugin.json') '{"name":"skyrim-vr-automation","version":"0.8.0+codex.current"}'
    Reset-SourceTree; Write-State; Write-MarketplaceManifest -SourcePath '..\external-plugin'
    Assert-Failure 'traversing marketplace source path' { Invoke-Subject } '*must not traverse*'

    Reset-SourceTree -ManifestName 'different-plugin'; Write-State
    Assert-Failure 'source manifest name mismatch' { Invoke-Subject } '*does not match*'

    Reset-SourceTree
    $junctionTarget = Join-Path $fixture 'junction-target'
    Copy-Item -LiteralPath $pluginRoot -Destination $junctionTarget -Recurse -Force
    $junctionPath = Join-Path $marketplaceRoot 'linked-plugin'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    Write-State; Write-MarketplaceManifest -SourcePath './linked-plugin'
    Assert-Failure 'reparse-point source traversal' { Invoke-Subject } '*reparse point*'

    [pscustomobject][ordered]@{
        ok = $true; casesPassed = $passedCases.Count; cases = @($passedCases)
        exactCommandTargetsAsserted = $true; hiddenAndSystemEnumerationExercised = $true
        boundedRepairExercised = $true; requiresCodexHostReload = $true
    } | ConvertTo-Json -Depth 5
}
finally {
    $env:SKYRIM_AUTOMATION_PLUGIN_REGISTRATION_STATE = $priorStatePath
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
