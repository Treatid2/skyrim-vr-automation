# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('submit', 'amend', 'get', 'list', 'list-mine', 'triage', 'accept', 'duplicate', 'defer', 'decline', 'resolve', 'reopen', 'export')]
    [string]$Command,

    [string]$FeedbackId,

    [ValidateSet('mo2', 'mo2-profile', 'mo2-workspace', 'devbench', 'null-hmd', 'profiler', 'shader-cache', 'process', 'build-test', 'doctor', 'packaging', 'documentation', 'other')]
    [string]$Area,

    [ValidateSet('defect', 'ambiguity', 'safety', 'enhancement', 'time-saver')]
    [string]$Kind,

    [ValidateSet('low', 'normal', 'high', 'critical')]
    [string]$Severity = 'normal',

    [string]$Summary,
    [string]$Observed,
    [string]$Expected,
    [string]$Suggestion,
    [string]$Operation,
    [string]$ParametersJson,
    [switch]$Blocked,

    [ValidateSet('unchanged', 'true', 'false')]
    [string]$BlockedState = 'unchanged',

    [string[]]$EvidencePath,
    [string]$Reporter = 'codex-task',
    [string]$ReporterTaskId,
    [string]$SessionId,
    [string]$ProfilePath,

    [string]$Actor,
    [ValidateSet('reporter', 'maintainer')]
    [string]$ActorRole,
    [string]$Note,
    [string]$DuplicateOf,
    [string]$Resolution,
    [string]$Commit,
    [string]$PullRequest,
    [string]$Release,

    [string[]]$Status,
    [string[]]$AreaFilter,
    [string[]]$KindFilter,
    [string[]]$SeverityFilter,
    [ValidateRange(1, 10000)]
    [int]$Limit = 100,

    [ValidateSet('json', 'markdown')]
    [string]$Format = 'markdown',
    [string]$OutputPath,
    [switch]$IncludeLocalPaths,

    [string]$FeedbackRoot,
    [string]$ConfigPath,
    [ValidateRange(1, 60)]
    [int]$LockTimeoutSeconds = 10,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:TerminalStatuses = @('duplicate', 'declined', 'resolved')

function Require-Value([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "-$Name is required for '$Command'." }
}

function ConvertTo-Hashtable($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) { $result[[string]$key] = ConvertTo-Hashtable $Value[$key] }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-Hashtable $property.Value }
        return $result
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $Value
}

function Resolve-FeedbackStorageRoot {
    if (-not [string]::IsNullOrWhiteSpace($FeedbackRoot)) {
        return [pscustomobject]@{ path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($FeedbackRoot)); source = 'parameter' }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT)) {
        return [pscustomobject]@{ path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT)); source = 'environment' }
    }

    $candidateConfig = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        [IO.Path]::GetFullPath($ConfigPath)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SKYRIM_VR_AUTOMATION_CONFIG)) {
        [IO.Path]::GetFullPath($env:SKYRIM_VR_AUTOMATION_CONFIG)
    }
    else {
        Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\machine.local.json'
    }
    if (Test-Path -LiteralPath $candidateConfig -PathType Leaf) {
        $configuration = Get-Content -LiteralPath $candidateConfig -Raw | ConvertFrom-Json -Depth 30
        $configured = $null
        if ($configuration.PSObject.Properties.Name -contains 'storage' -and $null -ne $configuration.storage -and $configuration.storage.PSObject.Properties.Name -contains 'feedback') {
            $configured = $configuration.storage.feedback
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$configured)) {
            return [pscustomobject]@{ path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$configured)); source = 'machine-config'; configPath = $candidateConfig }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [pscustomobject]@{ path = [IO.Path]::GetFullPath((Join-Path $env:CODEX_HOME 'state\skyrim-vr-automation\feedback')); source = 'codex-home' }
    }
    return [pscustomobject]@{ path = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'SkyrimVRAutomation\feedback')); source = 'local-app-data' }
}

function Initialize-FeedbackStorage([string]$Root) {
    foreach ($directory in @($Root, (Join-Path $Root 'items'), (Join-Path $Root 'events'), (Join-Path $Root 'exports'))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
}

function Write-JsonAtomic([string]$Path, $Value) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 40) + "`n")
    try {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $Path, $false)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-WithFeedbackLock([string]$Root, [scriptblock]$Action) {
    Initialize-FeedbackStorage -Root $Root
    $lockPath = Join-Path $Root '.write.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    $lock = $null
    do {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for feedback queue write lock: $lockPath" }
            Start-Sleep -Milliseconds 50
        }
    } until ($null -ne $lock)
    try { & $Action }
    finally { $lock.Dispose() }
}

function Get-Sha256Text([string]$Text) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function New-FeedbackId {
    return 'AUTO-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'), ([guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant())
}

function Get-ToolkitIdentity {
    $manifestPath = Join-Path $script:RepositoryRoot 'toolset.manifest.json'
    $pluginPath = Join-Path $script:RepositoryRoot '.codex-plugin\plugin.json'
    $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }
    $plugin = if (Test-Path -LiteralPath $pluginPath -PathType Leaf) { Get-Content -LiteralPath $pluginPath -Raw | ConvertFrom-Json } else { $null }
    $commit = $null
    if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot '.git')) {
        try {
            $value = & git -C $script:RepositoryRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0) { $commit = [string]$value }
        }
        catch { $commit = $null }
    }
    return [ordered]@{
        name = 'skyrim-vr-automation'
        version = if ($null -ne $manifest -and $manifest.PSObject.Properties['version']) { [string]$manifest.version } else { $null }
        pluginVersion = if ($null -ne $plugin -and $plugin.PSObject.Properties['version']) { [string]$plugin.version } else { $null }
        sourceCommit = $commit
        powerShellVersion = [string]$PSVersionTable.PSVersion
    }
}

function Get-EvidenceRecord([string]$Path) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $resolved = try { [IO.Path]::GetFullPath($expanded) } catch { $expanded }
    $exists = Test-Path -LiteralPath $resolved
    $item = if ($exists) { Get-Item -LiteralPath $resolved -Force } else { $null }
    $isFile = $null -ne $item -and -not $item.PSIsContainer
    return [ordered]@{
        path = $resolved
        exists = $exists
        kind = if ($null -eq $item) { 'missing' } elseif ($item.PSIsContainer) { 'directory' } else { 'file' }
        length = if ($isFile) { [long]$item.Length } else { $null }
        sha256 = if ($isFile) { (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        capturedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Assert-FeedbackId([string]$Id) {
    Require-Value -Name 'FeedbackId' -Value $Id
    if ($Id -cnotmatch '^AUTO-\d{8}-\d{9}-[A-F0-9]{8}$') {
        throw 'FeedbackId is malformed. Expected AUTO-YYYYMMDD-HHMMSSfff-XXXXXXXX.'
    }
}

function Get-FeedbackItemPath([string]$Root, [string]$Id) {
    Assert-FeedbackId -Id $Id
    $itemsRoot = [IO.Path]::GetFullPath((Join-Path $Root 'items')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $itemsRoot ($Id + '.json')))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($path), $itemsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'FeedbackId did not resolve to a direct item child.'
    }
    return $path
}

function Get-FeedbackEventRoot([string]$Root, [string]$Id) {
    Assert-FeedbackId -Id $Id
    $eventsRoot = [IO.Path]::GetFullPath((Join-Path $Root 'events')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $eventsRoot $Id))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($path), $eventsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'FeedbackId did not resolve to a direct event child.'
    }
    return $path
}

function Read-FeedbackBase([string]$Root, [string]$Id) {
    $path = Get-FeedbackItemPath -Root $Root -Id $Id
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Feedback item does not exist: $Id" }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 40)
}

function Get-FeedbackEvents([string]$Root, [string]$Id) {
    $eventRoot = Get-FeedbackEventRoot -Root $Root -Id $Id
    if (-not (Test-Path -LiteralPath $eventRoot -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $eventRoot -File -Filter '*.json' | Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 40 })
}

function Get-CurrentFeedback([string]$Root, [string]$Id) {
    $base = ConvertTo-Hashtable (Read-FeedbackBase -Root $Root -Id $Id)
    $base.status = 'new'
    $base.updatedUtc = $base.createdUtc
    $base.history = @()
    foreach ($event in @(Get-FeedbackEvents -Root $Root -Id $Id)) {
        $eventTable = ConvertTo-Hashtable $event
        if ($eventTable.type -eq 'amend') {
            foreach ($key in $eventTable.patch.Keys) { $base[$key] = $eventTable.patch[$key] }
        }
        elseif ($eventTable.type -eq 'status') {
            $base.status = $eventTable.status
            if ($eventTable.Contains('duplicateOf')) { $base.duplicateOf = $eventTable.duplicateOf }
            if ($eventTable.Contains('resolution')) { $base.resolution = $eventTable.resolution }
            if ($eventTable.Contains('links')) { $base.resolutionLinks = $eventTable.links }
        }
        $base.updatedUtc = $eventTable.timestampUtc
        $base.history += ,$eventTable
    }
    return [pscustomobject]$base
}

function Get-AllCurrentFeedback([string]$Root) {
    $itemsRoot = Join-Path $Root 'items'
    if (-not (Test-Path -LiteralPath $itemsRoot -PathType Container)) { return @() }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $itemsRoot -File -Filter 'AUTO-*.json')) {
        try { $records.Add((Get-CurrentFeedback -Root $Root -Id $file.BaseName)) }
        catch { throw "Feedback queue contains an unreadable item '$($file.FullName)': $($_.Exception.Message)" }
    }
    $sorted = @($records.ToArray() | Sort-Object createdUtc -Descending)
    return $sorted
}

function Write-FeedbackEvent([string]$Root, [string]$Id, [hashtable]$Event) {
    $eventRoot = Get-FeedbackEventRoot -Root $Root -Id $Id
    $name = '{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'), ([guid]::NewGuid().ToString('N'))
    Write-JsonAtomic -Path (Join-Path $eventRoot $name) -Value $Event
    return (Get-CurrentFeedback -Root $Root -Id $Id)
}

function Test-Transition([string]$Current, [string]$Target) {
    if ($Target -eq 'reopened') { return $Current -in $script:TerminalStatuses -or $Current -eq 'deferred' }
    if ($Current -in $script:TerminalStatuses) { return $false }
    return $Target -in @('triaged', 'accepted', 'duplicate', 'deferred', 'declined', 'resolved')
}

function Protect-PublicText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $protected = [regex]::Replace($Text, '(?i)\b[A-Z]:\\[^\r\n]*', '<local-path>')
    $protected = [regex]::Replace($protected, '(?i)\\\\[^\s\\]+\\[^\r\n]*', '<network-path>')
    return $protected
}

function Protect-PublicValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-PublicText $Value }
    if ($Value -is [Collections.IDictionary]) {
        $protected = [ordered]@{}
        foreach ($key in $Value.Keys) { $protected[[string]$key] = Protect-PublicValue $Value[$key] }
        return $protected
    }
    if ($Value -is [pscustomobject]) {
        $protected = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $protected[$property.Name] = Protect-PublicValue $property.Value }
        return [pscustomobject]$protected
    }
    if ($Value -is [Collections.IEnumerable]) { return @($Value | ForEach-Object { Protect-PublicValue $_ }) }
    return $Value
}

function ConvertTo-PublicFeedback($Item, [bool]$IncludePaths) {
    $evidence = @($Item.evidence | ForEach-Object {
        [ordered]@{
            path = if ($IncludePaths) { $_.path } else { $null }
            fileName = if ([string]::IsNullOrWhiteSpace([string]$_.path)) { $null } else { [IO.Path]::GetFileName([string]$_.path) }
            exists = $_.exists; kind = $_.kind; length = $_.length; sha256 = $_.sha256; capturedUtc = $_.capturedUtc
        }
    })
    return [ordered]@{
        schemaVersion = 1
        feedbackId = $Item.feedbackId
        createdUtc = $Item.createdUtc
        updatedUtc = $Item.updatedUtc
        status = $Item.status
        area = $Item.area
        kind = $Item.kind
        severity = $Item.severity
        blocked = $Item.blocked
        summary = if ($IncludePaths) { $Item.summary } else { Protect-PublicText ([string]$Item.summary) }
        observed = if ($IncludePaths) { $Item.observed } else { Protect-PublicText ([string]$Item.observed) }
        expected = if ($IncludePaths) { $Item.expected } else { Protect-PublicText ([string]$Item.expected) }
        suggestion = if ($IncludePaths) { $Item.suggestion } else { Protect-PublicText ([string]$Item.suggestion) }
        operation = if ($IncludePaths) { $Item.operation } else { Protect-PublicValue $Item.operation }
        toolkit = $Item.toolkit
        evidence = $evidence
        duplicateOf = if ($Item.PSObject.Properties.Name -contains 'duplicateOf') { $Item.duplicateOf } else { $null }
        resolution = if ($Item.PSObject.Properties.Name -contains 'resolution') { if ($IncludePaths) { $Item.resolution } else { Protect-PublicValue $Item.resolution } } else { $null }
        resolutionLinks = if ($Item.PSObject.Properties.Name -contains 'resolutionLinks') { if ($IncludePaths) { $Item.resolutionLinks } else { Protect-PublicValue $Item.resolutionLinks } } else { $null }
        reviewRequired = 'Review this export before sharing. Free-text fields can contain identifying or private information.'
    }
}

function ConvertTo-FeedbackMarkdown($Item) {
    $lines = @(
        "# Automation feedback: $($Item.feedbackId)",
        '',
        "- Status: $($Item.status)",
        "- Area: $($Item.area)",
        "- Kind: $($Item.kind)",
        "- Severity: $($Item.severity)",
        "- Blocked: $($Item.blocked)",
        "- Toolkit: $($Item.toolkit.version)",
        '',
        '## Summary', '', [string]$Item.summary,
        '', '## Observed', '', [string]$Item.observed,
        '', '## Expected', '', [string]$Item.expected
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.suggestion)) { $lines += @('', '## Suggested improvement', '', [string]$Item.suggestion) }
    if (@($Item.evidence).Count -gt 0) {
        $lines += @('', '## Evidence', '')
        foreach ($record in @($Item.evidence)) {
            $label = if ([string]::IsNullOrWhiteSpace([string]$record.fileName)) { $record.kind } else { $record.fileName }
            $lines += "- $label — $($record.kind), $($record.length) bytes, SHA-256 $($record.sha256)"
        }
    }
    $lines += @('', '> Review this export before sharing. Free-text fields can contain identifying or private information.', '')
    return $lines -join "`n"
}

function New-Result([bool]$Ok, [string]$State, $Data, [string[]]$Warnings = @(), [string[]]$Errors = @()) {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        ok = $Ok
        command = $Command
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        state = $State
        warnings = @($Warnings | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        errors = @($Errors | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        data = $Data
    }
}

try {
    $storage = Resolve-FeedbackStorageRoot
    $root = $storage.path

    if ($Command -eq 'submit') {
        Require-Value 'Area' $Area; Require-Value 'Kind' $Kind; Require-Value 'Summary' $Summary; Require-Value 'Observed' $Observed; Require-Value 'Expected' $Expected
        $parameters = if ([string]::IsNullOrWhiteSpace($ParametersJson)) { $null } else { $ParametersJson | ConvertFrom-Json -Depth 30 }
        $taskId = if (-not [string]::IsNullOrWhiteSpace($ReporterTaskId)) { $ReporterTaskId } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_TASK_ID)) { $env:CODEX_TASK_ID } else { $null }
        $fingerprint = Get-Sha256Text (($Area.Trim().ToLowerInvariant(), $Kind.Trim().ToLowerInvariant(), $Summary.Trim().ToLowerInvariant(), $Expected.Trim().ToLowerInvariant()) -join "`n")
        $created = Invoke-WithFeedbackLock -Root $root -Action {
            $matches = @(Get-AllCurrentFeedback -Root $root | Where-Object { $_.fingerprint -eq $fingerprint -and $_.status -notin $script:TerminalStatuses } | Select-Object -ExpandProperty feedbackId)
            $id = New-FeedbackId
            $now = [DateTime]::UtcNow.ToString('o')
            $item = [ordered]@{
                schemaVersion = 1
                feedbackId = $id
                createdUtc = $now
                area = $Area
                kind = $Kind
                severity = $Severity
                blocked = [bool]$Blocked
                summary = $Summary.Trim()
                observed = $Observed.Trim()
                expected = $Expected.Trim()
                suggestion = if ([string]::IsNullOrWhiteSpace($Suggestion)) { $null } else { $Suggestion.Trim() }
                operation = if ([string]::IsNullOrWhiteSpace($Operation)) { $null } else { $Operation.Trim() }
                parameters = $parameters
                reporter = [ordered]@{ name = $Reporter; taskId = $taskId }
                context = [ordered]@{ sessionId = $SessionId; profilePath = $ProfilePath }
                toolkit = Get-ToolkitIdentity
                evidence = @(@($EvidencePath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-EvidenceRecord $_ })
                fingerprint = $fingerprint
            }
            Write-JsonAtomic -Path (Get-FeedbackItemPath -Root $root -Id $id) -Value $item
            $persisted = Get-Content -LiteralPath (Get-FeedbackItemPath -Root $root -Id $id) -Raw | ConvertFrom-Json -Depth 40
            if ($persisted.feedbackId -ne $id) { throw 'The feedback receipt did not survive its durability check.' }
            [pscustomobject][ordered]@{ receipt = $id; feedback = (Get-CurrentFeedback -Root $root -Id $id); possibleDuplicates = $matches }
        }
        $result = New-Result $true 'recorded' $created $(if (@($created.possibleDuplicates).Count -gt 0) { @('Possible unresolved duplicates were found; the report was retained as a separate occurrence.') } else { @() })
    }
    elseif ($Command -eq 'get') {
        $result = New-Result $true 'found' ([pscustomobject]@{ feedback = Get-CurrentFeedback -Root $root -Id $FeedbackId })
    }
    elseif ($Command -in @('list', 'list-mine')) {
        $scanned = if (Test-Path -LiteralPath (Join-Path $root 'items') -PathType Container) { @(Get-ChildItem -LiteralPath (Join-Path $root 'items') -File -Filter 'AUTO-*.json').Count } else { 0 }
        $items = @(Get-AllCurrentFeedback -Root $root)
        $statusValues = @($Status | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $areaValues = @($AreaFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $kindValues = @($KindFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $severityValues = @($SeverityFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($statusValues.Count -gt 0) { $items = @($items | Where-Object { $_.status -in $statusValues }) }
        if ($areaValues.Count -gt 0) { $items = @($items | Where-Object { $_.area -in $areaValues }) }
        if ($kindValues.Count -gt 0) { $items = @($items | Where-Object { $_.kind -in $kindValues }) }
        if ($severityValues.Count -gt 0) { $items = @($items | Where-Object { $_.severity -in $severityValues }) }
        if ($Command -eq 'list-mine') {
            $mine = if (-not [string]::IsNullOrWhiteSpace($ReporterTaskId)) { $ReporterTaskId } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $env:CODEX_THREAD_ID } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_TASK_ID)) { $env:CODEX_TASK_ID } else { $null }
            Require-Value 'ReporterTaskId' $mine
            $items = @($items | Where-Object { $_.reporter.taskId -eq $mine })
        }
        $total = $items.Count
        $items = @($items | Select-Object -First $Limit)
        $result = New-Result $true 'listed' ([pscustomobject]@{ scanned = $scanned; total = $total; returned = $items.Count; feedback = $items })
    }
    elseif ($Command -eq 'amend') {
        Require-Value 'FeedbackId' $FeedbackId; Require-Value 'Actor' $Actor; Require-Value 'ActorRole' $ActorRole
        $updated = Invoke-WithFeedbackLock -Root $root -Action {
            $current = Get-CurrentFeedback -Root $root -Id $FeedbackId
            if ($current.status -in $script:TerminalStatuses) { throw "Closed feedback '$FeedbackId' must be reopened before amendment." }
            $patch = [ordered]@{}
            foreach ($entry in @(
                @{ key = 'summary'; value = $Summary }, @{ key = 'observed'; value = $Observed }, @{ key = 'expected'; value = $Expected },
                @{ key = 'suggestion'; value = $Suggestion }, @{ key = 'operation'; value = $Operation }
            )) { if (-not [string]::IsNullOrWhiteSpace([string]$entry.value)) { $patch[$entry.key] = ([string]$entry.value).Trim() } }
            if ($PSBoundParameters.ContainsKey('Severity')) { $patch.severity = $Severity }
            if ($BlockedState -ne 'unchanged') { $patch.blocked = $BlockedState -eq 'true' }
            if (-not [string]::IsNullOrWhiteSpace($ParametersJson)) { $patch.parameters = $ParametersJson | ConvertFrom-Json -Depth 30 }
            $evidenceValues = @($EvidencePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($evidenceValues.Count -gt 0) { $patch.evidence = @($current.evidence) + @($evidenceValues | ForEach-Object { Get-EvidenceRecord $_ }) }
            if ($patch.Count -eq 0) { throw 'Amend requires at least one changed field or evidence path.' }
            $event = [ordered]@{ schemaVersion = 1; type = 'amend'; timestampUtc = [DateTime]::UtcNow.ToString('o'); actor = $Actor; actorRole = $ActorRole; note = $Note; patch = $patch }
            Write-FeedbackEvent -Root $root -Id $FeedbackId -Event $event
        }
        $result = New-Result $true 'amended' ([pscustomobject]@{ receipt = $FeedbackId; feedback = $updated })
    }
    elseif ($Command -in @('triage', 'accept', 'duplicate', 'defer', 'decline', 'resolve', 'reopen')) {
        Require-Value 'FeedbackId' $FeedbackId; Require-Value 'Actor' $Actor; Require-Value 'ActorRole' $ActorRole
        if ($ActorRole -ne 'maintainer') { throw "-$Command requires -ActorRole maintainer." }
        $targetStatus = if ($Command -eq 'triage') { 'triaged' } elseif ($Command -eq 'accept') { 'accepted' } elseif ($Command -eq 'reopen') { 'reopened' } else { $Command + 'd' }
        if ($Command -eq 'duplicate') { $targetStatus = 'duplicate' }
        if ($Command -eq 'defer') { $targetStatus = 'deferred' }
        if ($Command -eq 'decline') { $targetStatus = 'declined' }
        if ($Command -eq 'resolve') { $targetStatus = 'resolved' }
        $updated = Invoke-WithFeedbackLock -Root $root -Action {
            $current = Get-CurrentFeedback -Root $root -Id $FeedbackId
            if (-not (Test-Transition -Current $current.status -Target $targetStatus)) { throw "Invalid feedback transition: $($current.status) -> $targetStatus." }
            if ($Command -eq 'duplicate') {
                Require-Value 'DuplicateOf' $DuplicateOf
                if ($DuplicateOf -eq $FeedbackId) { throw 'Feedback cannot duplicate itself.' }
                $null = Read-FeedbackBase -Root $root -Id $DuplicateOf
            }
            if ($Command -eq 'resolve') { Require-Value 'Resolution' $Resolution }
            $event = [ordered]@{
                schemaVersion = 1; type = 'status'; timestampUtc = [DateTime]::UtcNow.ToString('o'); actor = $Actor; actorRole = $ActorRole
                status = $targetStatus; note = $Note
            }
            if ($Command -eq 'duplicate') { $event.duplicateOf = $DuplicateOf }
            if ($Command -eq 'resolve') {
                $event.resolution = $Resolution
                $event.links = [ordered]@{ commit = $Commit; pullRequest = $PullRequest; release = $Release }
            }
            Write-FeedbackEvent -Root $root -Id $FeedbackId -Event $event
        }
        $result = New-Result $true $targetStatus ([pscustomobject]@{ receipt = $FeedbackId; feedback = $updated })
    }
    elseif ($Command -eq 'export') {
        Require-Value 'FeedbackId' $FeedbackId; Require-Value 'OutputPath' $OutputPath
        $current = Get-CurrentFeedback -Root $root -Id $FeedbackId
        $public = ConvertTo-PublicFeedback -Item $current -IncludePaths ([bool]$IncludeLocalPaths)
        $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
        $content = if ($Format -eq 'json') { $public | ConvertTo-Json -Depth 30 } else { ConvertTo-FeedbackMarkdown ([pscustomobject]$public) }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content + "`n")
        $directory = Split-Path -Parent $resolvedOutput
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        [IO.File]::WriteAllBytes($resolvedOutput, $bytes)
        $result = New-Result $true 'exported' ([pscustomobject]@{ feedbackId = $FeedbackId; format = $Format; outputPath = $resolvedOutput; sha256 = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant(); includesLocalPaths = [bool]$IncludeLocalPaths; reviewRequired = $true })
    }

    $result.data | Add-Member -NotePropertyName storage -NotePropertyValue ([pscustomobject]$storage) -Force
}
catch {
    $result = New-Result $false 'tool-error' $null @() @($_.Exception.Message)
}

$json = @{ InputObject = $result; Depth = 50 }
if ($Compact) { $json.Compress = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
