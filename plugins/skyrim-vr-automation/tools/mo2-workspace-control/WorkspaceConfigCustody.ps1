# SPDX-License-Identifier: GPL-3.0-or-later

function Invoke-WorkspaceConfigPrimitive([string]$Operation, $Plan, [hashtable]$Extra = @{}) {
    $arguments = @{
        CachePath = [string]$Plan.livePath; RelativeCachePath = 'SKSE\Plugins\CommunityShaders'
        EvidenceDirectory = [string]$Plan.snapshotRoot; MaxInventoryFiles = 256
        MaxInventoryBytes = 16777216; MaxInventoryDepth = 8; InventoryTimeoutSeconds = 30
        BlockingProcessNames = @(Get-WorkspaceBlockingProcessNames $config); NoExit = $true; Confirm = $false
    }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    $entry = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $response = & $entry $Operation @arguments | ConvertFrom-Json -Depth 40
    if (-not $response.ok) { throw "CSX configuration $Operation failed: $($response.errors -join '; ')" }
    return $response.data
}

function Assert-WorkspaceConfigOutputOwner($Config, $Workspace) {
    $output = $Workspace.data.runtimeOutput
    $null = Assert-WorkspaceOutputOwnerMarker -Path $output.ownerMarkerPath -ExpectedSha256 $output.ownerMarkerSha256 -WorkspaceId $Workspace.data.workspaceId -OwnershipId $Workspace.data.ownershipId -OverwritePath $output.overwritePath
}

function Copy-WorkspaceConfigTree([string]$Source, [string]$Target) {
    $sourceTree = Get-CSXConfigTree $Source
    $null = Assert-CSXConfigSafePath $Target
    if (Test-Path -LiteralPath $Target) { throw 'Configuration copy target already exists; retained evidence is never replaced.' }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    foreach ($dir in $sourceTree.directories) { New-Item -ItemType Directory -Path (Join-Path $Target $dir) -Force | Out-Null }
    foreach ($entry in $sourceTree.entries) {
        Assert-TreeOperationBudget 'CSX configuration copy'
        Copy-Item -LiteralPath (Join-Path $Source $entry.relativePath) -Destination (Join-Path $Target $entry.relativePath)
    }
    $after = Get-CSXConfigTree $Target
    $sourceAfter = Get-CSXConfigTree $Source
    if ($after.treeSha256 -cne $sourceTree.treeSha256 -or $sourceAfter.treeSha256 -cne $sourceTree.treeSha256) { throw 'CSX configuration copy/source stability verification failed.' }
    return $after
}

function Assert-WorkspaceConfigProviders($Plan) {
    foreach ($provider in $Plan.providers) {
        Assert-TreeOperationBudget 'CSX configuration provider verification'
        $observed = Get-CSXConfigTree $provider.path
        if ($observed.treeSha256 -cne [string]$provider.treeSha256 -or $observed.exists -ne [bool]$provider.exists) { throw "Shared configuration provider changed: $($provider.path)" }
    }
}

function Get-WorkspaceConfigMarkerPath($Config) { return Join-Path ([string]$Config.mo2.overwriteDirectory) '.codex-csx-config-owner.json' }

function Assert-WorkspaceConfigMarker($Config, $Plan) {
    $path = Get-WorkspaceConfigMarkerPath $Config
    $null = Assert-CSXConfigSafePath $path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$Plan.markerSha256) { throw 'CSX configuration custody marker missing or changed; recovery remains required.' }
}

function New-WorkspaceConfigStage($Config, $Workspace, [string]$UnmanagedConfigPath, [string]$ScopeNote) {
    Assert-WorkspaceConfigOutputOwner $Config $Workspace
    $markerPath = Get-WorkspaceConfigMarkerPath $Config
    if (Test-Path -LiteralPath $markerPath) { throw 'CSX configuration is already owned; complete the exact existing custody generation first.' }
    if ([string]::IsNullOrWhiteSpace($ScopeNote) -or $ScopeNote.Length -gt 2048) { throw '-ConfigScopeNote must explicitly state archive/unmanaged scope and remaining VFS limitations (maximum 2048 characters).' }
    $unmanaged = Assert-CSXConfigSafePath $UnmanagedConfigPath
    if ([IO.Path]::GetFileName($unmanaged) -cne 'CommunityShaders' -or $unmanaged -notmatch '[\\/]Data[\\/]SKSE[\\/]Plugins[\\/]CommunityShaders$') { throw '-UnmanagedConfigPath must be the exact game Data\SKSE\Plugins\CommunityShaders directory, even if absent.' }
    $unmanagedTree = Get-CSXConfigTree $unmanaged
    if ($unmanagedTree.files -gt 0) { throw 'Unmanaged CSX configuration files require separate VFS qualification; this custody lane refuses them.' }
    $prior = Read-CSXConfigCustodyPlan $Config $Workspace.data
    if ($null -ne $prior -and $prior.data.phase -cne 'completed') { throw 'Existing configuration custody is not completed; bind/complete the retained generation instead of replacing it.' }
    $generation = [guid]::NewGuid().ToString('N')
    $root = Join-Path (Get-WorkspaceControlRoot $Config) ($Workspace.data.workspaceId + '-config-' + $generation)
    $live = Join-Path ([string]$Config.mo2.overwriteDirectory) 'SKSE\Plugins\CommunityShaders'
    $baseline = Get-CSXConfigTree $live
    $plan = [pscustomobject][ordered]@{
        schema = 'csx.config-custody.1'; generation = $generation; phase = 'staging'
        workspaceId = $Workspace.data.workspaceId; ownershipId = $Workspace.data.ownershipId; ownerTaskId = $Workspace.data.ownerTaskId
        evidenceRoot = $root; snapshotRoot = (Join-Path $root 'snapshot'); workingPath = (Join-Path $root 'working'); livePath = $live
        profileSha256 = (Get-FileHash -LiteralPath (Join-Path $Workspace.data.profilePath 'modlist.txt') -Algorithm SHA256).Hash
        baseline = $baseline; snapshot = $null; providers = @($unmanagedTree); markerSha256 = $null; preparedTreeSha256 = $null
        preserved = $null; restore = $null; scopeNote = $ScopeNote; createdUtc = [DateTime]::UtcNow.ToString('o')
        missingParents = @(); retainedNonemptyParents = @(); previousPlanPath = $(if ($null -ne $prior) { $prior.path } else { $null })
    }
    $parent = Split-Path -Parent $live
    while (-not (Test-Path -LiteralPath $parent)) {
        $plan.missingParents += $parent
        $parent = Split-Path -Parent $parent
    }
    $tool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $providerResult = & $tool providers -ProfilePath (Join-Path $Workspace.data.profilePath 'modlist.txt') -ModsPath $Config.mo2.modsDirectory -RelativeCachePath 'SKSE\Plugins\CommunityShaders' -DeepInventory -IncludeInventoryEntries -MaxInventoryFiles 256 -MaxInventoryBytes 16777216 -MaxInventoryDepth 8 -InventoryTimeoutSeconds 30 -NoExit -Confirm:$false | ConvertFrom-Json -Depth 40
    if (-not $providerResult.ok) { throw "Configuration provider inventory failed: $($providerResult.errors -join '; ')" }
    # Retain absent roots too: a previously empty enabled mod must not gain a
    # writable CSX config provider unnoticed after preparation.
    $modsRoot = [IO.Path]::GetFullPath([string]$Config.mo2.modsDirectory).TrimEnd('\')
    foreach ($line in Get-Content -LiteralPath (Join-Path $Workspace.data.profilePath 'modlist.txt')) {
        Assert-TreeOperationBudget 'CSX configuration complete provider scope'
        if (-not $line.StartsWith('+')) { continue }
        $name = $line.Substring(1)
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/]' -or $name -in @('.', '..')) { throw 'Unsafe enabled mod name in configuration provider scope.' }
        $modRoot = [IO.Path]::GetFullPath((Join-Path $modsRoot $name))
        if (-not (Test-WorkspaceSamePath (Split-Path -Parent $modRoot) $modsRoot)) { throw 'Configuration provider root escaped the exact mods directory.' }
        $plan.providers += Get-CSXConfigTree (Join-Path $modRoot 'SKSE\Plugins\CommunityShaders') $script:TreeOperationDeadlineUtc
    }
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    $planPath = Join-Path $root 'config-custody.plan.json'
    Write-WorkspaceJsonAtomic $planPath $plan
    # No shared state is changed by staging. Publish the pointer first so an
    # interrupted stage cannot silently be replaced by another generation.
    $Workspace.data | Add-Member -NotePropertyName configCustody -NotePropertyValue ([pscustomobject]@{ generation = $generation; planPath = $planPath }) -Force
    Write-WorkspaceJsonAtomic $Workspace.path $Workspace.data
    $source = if ($null -ne $prior) { [string]$prior.data.preserved.preservedPath } else { $live }
    if ($null -ne $prior) {
        $retained = Get-CSXConfigTree $source
        if ($retained.treeSha256 -cne [string]$prior.data.preserved.inventory.treeSha256) { throw 'Retained task configuration changed after completion.' }
    }
    $null = Copy-WorkspaceConfigTree $source $plan.workingPath
    $null = Copy-WorkspaceProviderTreeShadow $providerResult $plan.workingPath 'SKSE\Plugins\CommunityShaders' 'Task CSX configuration union'
    $working = Get-CSXConfigTree $plan.workingPath
    foreach ($required in @('SettingsDefault.json', 'SettingsUser.json')) {
        $path = Join-Path $plan.workingPath $required
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "CSX configuration staging lacks '$required'." }
        $null = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
    }
    Assert-WorkspaceConfigProviders $plan
    if ((Get-CSXConfigTree $live).treeSha256 -cne $baseline.treeSha256) { throw 'Shared configuration changed during staging.' }
    $plan.phase = 'staged'; Write-WorkspaceJsonAtomic $planPath $plan
    return [pscustomobject]@{ state = 'config-staged'; planPath = $planPath; workingPath = $plan.workingPath; inventory = $working; scopeNote = $ScopeNote; guidance = 'Edit only the task working copy, then bind-config under the same owned closed-state workspace. Staging does not authorize launch.' }
}

function Bind-WorkspaceConfig($Config, $Workspace) {
    Assert-WorkspaceConfigOutputOwner $Config $Workspace
    $record = Read-CSXConfigCustodyPlan $Config $Workspace.data
    if ($null -eq $record -or $record.data.phase -cne 'staged') { throw 'bind-config requires the exact completed stage-config operation.' }
    $plan = $record.data
    if ((Get-FileHash -LiteralPath (Join-Path $Workspace.data.profilePath 'modlist.txt') -Algorithm SHA256).Hash -cne [string]$plan.profileSha256) { throw 'Task profile changed after configuration staging; no shared files were bound.' }
    Assert-WorkspaceConfigProviders $plan
    $live = Get-CSXConfigTree $plan.livePath
    if ($live.treeSha256 -cne [string]$plan.baseline.treeSha256 -or $live.exists -ne [bool]$plan.baseline.exists) { throw 'Shared CSX configuration drifted after staging; nothing was bound.' }
    $working = Get-CSXConfigTree $plan.workingPath
    foreach ($required in @('SettingsDefault.json', 'SettingsUser.json')) { $null = Get-Content -LiteralPath (Join-Path $plan.workingPath $required) -Raw | ConvertFrom-Json -Depth 100 }
    $workingPaths = @($working.entries.relativePath)
    foreach ($provider in $plan.providers) { foreach ($entry in $provider.entries) { if ([string]$entry.relativePath -notin $workingPaths) { throw "Task configuration lacks provider shadow '$($entry.relativePath)'." } } }
    $markerPath = Get-WorkspaceConfigMarkerPath $Config
    if (Test-Path -LiteralPath $markerPath) { throw 'Another CSX configuration transaction owns Overwrite.' }
    $marker = [pscustomobject]@{ schema = 'csx.config-owner.1'; workspaceId = $plan.workspaceId; generation = $plan.generation }
    $payload = New-WorkspaceOutputOwnerMarkerPayload $marker
    $plan.markerSha256 = $payload.sha256; $plan.preparedTreeSha256 = $working.treeSha256
    $plan.phase = 'binding'; Write-WorkspaceJsonAtomic $record.path $plan
    $null = New-WorkspaceOutputOwnerMarker -Path $markerPath -Value $marker -Payload $payload
    if (-not $plan.baseline.exists) { New-Item -ItemType Directory -Path $plan.livePath -Force | Out-Null }
    $plan.snapshot = Invoke-WorkspaceConfigPrimitive 'snapshot' $plan
    Write-WorkspaceJsonAtomic $record.path $plan
    if ([string]$plan.snapshot.inventory.treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'Configuration snapshot differs from its exact staged baseline; binding refused.' }
    $null = Invoke-WorkspaceConfigPrimitive 'seed' $plan @{ SourceCachePath = $plan.workingPath; ExpectedSourceTreeSha256 = $working.treeSha256 }
    if ($InternalTestFailurePoint -eq 'config-bind-after-seed') { throw 'Injected interrupted configuration bind after seed.' }
    if ((Get-CSXConfigTree $plan.livePath).treeSha256 -cne $working.treeSha256) { throw 'Bound CSX configuration postcondition failed; complete-config must restore the baseline.' }
    $plan.phase = 'bound'; Write-WorkspaceJsonAtomic $record.path $plan
    Assert-CSXConfigCustodyIsolation $Config $Workspace.data
    return [pscustomobject]@{ state = 'config-bound'; planPath = $record.path; preparedTreeSha256 = $working.treeSha256; scopeNote = $plan.scopeNote }
}

function Complete-WorkspaceConfig($Config, $Workspace) {
    $record = Read-CSXConfigCustodyPlan $Config $Workspace.data
    if ($null -eq $record) { return $null }
    $plan = $record.data
    if ($plan.phase -in @('staging', 'staged')) {
        # Explicit cancellation of a stage retains task files but has no shared
        # baseline to restore: stage-config never changed shared Overwrite.
        $plan.preserved = Preserve-WorkspaceRuntimeOutput -Source $plan.workingPath -EvidenceRoot (Join-Path $plan.evidenceRoot 'completion') -WorkspaceId $plan.workspaceId
        $plan.phase = 'completed'; Write-WorkspaceJsonAtomic $record.path $plan
        return [pscustomobject]@{ state = 'config-stage-retained'; planPath = $record.path; preserved = $plan.preserved; sharedConfigChanged = $false }
    }
    if ($plan.phase -eq 'completed') {
        $preserved = Get-CSXConfigTree $plan.preserved.preservedPath
        if ($preserved.treeSha256 -cne [string]$plan.preserved.inventory.treeSha256) { throw 'Completed task configuration evidence changed.' }
        if (Test-Path -LiteralPath (Get-WorkspaceConfigMarkerPath $Config)) {
            Assert-WorkspaceConfigOutputOwner $Config $Workspace
            Assert-WorkspaceConfigMarker $Config $plan
            $live = Get-CSXConfigTree $plan.livePath
            if ($live.treeSha256 -cne [string]$plan.baseline.treeSha256 -or $live.exists -ne [bool]$plan.baseline.exists) { throw 'Restored configuration drifted before marker-release recovery.' }
            Remove-Item -LiteralPath (Get-WorkspaceConfigMarkerPath $Config) -Force
        }
        return [pscustomobject]@{ state = 'config-completed'; planPath = $record.path; preserved = $plan.preserved }
    }
    Assert-WorkspaceConfigOutputOwner $Config $Workspace
    if ($plan.phase -eq 'binding' -and $null -eq $plan.snapshot -and -not (Test-Path -LiteralPath (Get-WorkspaceConfigMarkerPath $Config))) {
        $unmutated = Get-CSXConfigTree $plan.livePath
        if ($unmutated.treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'Interrupted marker claim cannot prove unchanged baseline.' }
        $marker = [pscustomobject]@{ schema = 'csx.config-owner.1'; workspaceId = $plan.workspaceId; generation = $plan.generation }
        $payload = New-WorkspaceOutputOwnerMarkerPayload $marker
        if ($payload.sha256 -cne [string]$plan.markerSha256) { throw 'Interrupted marker claim has different expected bytes.' }
        $null = New-WorkspaceOutputOwnerMarker -Path (Get-WorkspaceConfigMarkerPath $Config) -Value $marker -Payload $payload
    }
    Assert-WorkspaceConfigMarker $Config $plan
    Assert-WorkspaceConfigProviders $plan
    if ($plan.phase -notin @('binding', 'bound', 'completing', 'restored')) { throw 'Unknown configuration custody phase; recovery required.' }
    if ($null -eq $plan.snapshot) {
        # An interrupted snapshot is reconciled by its existing owner primitive.
        # Snapshot never changes the live tree, and its immutable receipt is
        # accepted only when it still binds the original staging inventory.
        $receiptPath = Join-Path $plan.snapshotRoot 'shader-cache-transaction.receipt.json'
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            if ([string]$receipt.operation -cne 'snapshot' -or -not (Test-WorkspaceSamePath $receipt.cachePath $plan.livePath) -or
                -not (Test-WorkspaceSamePath $receipt.backupPath (Join-Path $plan.snapshotRoot 'cache.before')) -or
                [string]$receipt.beforeTreeSha256 -cne [string]$plan.baseline.treeSha256 -or
                (Get-CSXConfigTree $receipt.backupPath).treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'Interrupted snapshot receipt is not this exact baseline.' }
            $plan.snapshot = [pscustomobject]@{ receiptPath = $receiptPath; inventory = $plan.baseline }
        }
        else {
            if ((Get-CSXConfigTree $plan.livePath).treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'No committed snapshot exists and live configuration changed; recovery refused.' }
            $partial = Join-Path $plan.snapshotRoot 'cache.before'
            if (Test-Path -LiteralPath $partial) {
                $null = Assert-CSXConfigSafePath $partial
                Move-Item -LiteralPath $partial -Destination (Join-Path $plan.snapshotRoot ('incomplete-snapshot-' + [guid]::NewGuid().ToString('N')))
            }
            $plan.snapshot = Invoke-WorkspaceConfigPrimitive 'snapshot' $plan
        }
        if ([string]$plan.snapshot.inventory.treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'Interrupted configuration snapshot does not match the exact baseline.' }
        Write-WorkspaceJsonAtomic $record.path $plan
    }
    if ($null -eq $plan.preserved) {
        $plan.preserved = Preserve-WorkspaceRuntimeOutput -Source $plan.livePath -EvidenceRoot (Join-Path $plan.evidenceRoot 'completion') -WorkspaceId $plan.workspaceId
        $plan.phase = 'completing'; Write-WorkspaceJsonAtomic $record.path $plan
    }
    $snapshotReceipt = Get-Content -LiteralPath (Join-Path $plan.snapshotRoot 'shader-cache-transaction.receipt.json') -Raw | ConvertFrom-Json
    if ([string]$snapshotReceipt.operation -cne 'snapshot' -or [string]$snapshotReceipt.beforeTreeSha256 -cne [string]$plan.baseline.treeSha256 -or
        -not (Test-WorkspaceSamePath $snapshotReceipt.cachePath $plan.livePath) -or
        -not (Test-WorkspaceSamePath $snapshotReceipt.backupPath (Join-Path $plan.snapshotRoot 'cache.before'))) { throw 'Configuration snapshot receipt changed or has foreign ownership.' }
    $transactionTool = Join-Path $toolRoot 'shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1'
    $proofArgs = @{
        EvidenceRoot = $plan.snapshotRoot; CachePath = $plan.livePath; BaselineTreeSha256 = $plan.baseline.treeSha256
        WorkingTreeSha256 = $plan.preserved.inventory.treeSha256; SnapshotTransactionId = $snapshotReceipt.transactionId
        TransactionTool = $transactionTool; RelativePath = 'SKSE\Plugins\CommunityShaders'
        AllowAbsentBaseline = -not [bool]$plan.baseline.exists
    }
    if ($plan.phase -cne 'restored') {
        # A restore may have committed before its response was recorded. Accept
        # only its existing exact receipt/journal/preserved/live proof, rather
        # than restoring again and changing the working-tree lineage.
        $receipts = @(Get-ChildItem -LiteralPath $plan.snapshotRoot -Filter 'shader-cache-restore.*.receipt.json' -File)
        if ($receipts.Count -gt 64) { throw 'Configuration restore receipt budget exceeded.' }
        $matched = @()
        foreach ($candidate in $receipts) {
            $receipt = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json
            if ([string]$receipt.snapshotTransactionId -ceq [string]$snapshotReceipt.transactionId -and
                [string]$receipt.displacedTreeSha256 -ceq [string]$plan.preserved.inventory.treeSha256) { $matched += $candidate.FullName }
        }
        if ($matched.Count -gt 1) { throw 'Conflicting configuration completion restores; recovery required.' }
        if ($matched.Count -eq 1) {
            $proof = Get-WorkspaceCommittedRestoreProof -ReceiptPath $matched[0] @proofArgs
            $plan.restore = $proof.data
        }
        else { $plan.restore = Invoke-WorkspaceConfigPrimitive 'restore' $plan }
        $live = Get-CSXConfigTree $plan.livePath
        if ($live.treeSha256 -cne [string]$plan.baseline.treeSha256) { throw 'Shared CSX configuration restoration did not match its baseline.' }
        $plan.phase = 'restored'; Write-WorkspaceJsonAtomic $record.path $plan
        if ($InternalTestFailurePoint -eq 'config-complete-after-restore') { throw 'Injected interrupted configuration completion after restore.' }
    }
    $null = Get-WorkspaceCommittedRestoreProof -ReceiptPath $plan.restore.restoreReceiptPath @proofArgs
    $baseline = Get-CSXConfigTree (Join-Path $plan.snapshotRoot 'cache.before')
    $preserved = Get-CSXConfigTree $plan.preserved.preservedPath
    $live = Get-CSXConfigTree $plan.livePath
    if ($baseline.treeSha256 -cne [string]$plan.baseline.treeSha256 -or $live.treeSha256 -cne $baseline.treeSha256 -or $preserved.treeSha256 -cne [string]$plan.preserved.inventory.treeSha256) { throw 'Configuration baseline/live/preserved proof failed; owner retained.' }
    if (($live.directories -join '|') -cne ($plan.baseline.directories -join '|')) { throw 'Restored configuration directory inventory differs from the original baseline.' }
    # Exact directory-existence restoration removes only validated empty paths.
    if (-not $plan.baseline.exists -and $live.exists) {
        if (@(Get-ChildItem -LiteralPath $plan.livePath -Force).Count -gt 0) { throw 'Originally absent CSX configuration root is not empty after restore.' }
        Remove-Item -LiteralPath $plan.livePath -Force
    }
    foreach ($parent in $plan.missingParents) {
        $resolved = Assert-CSXConfigSafePath $parent
        $overwrite = [IO.Path]::GetFullPath([string]$Config.mo2.overwriteDirectory).TrimEnd('\')
        if (-not $resolved.StartsWith($overwrite + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Configuration parent cleanup escaped Overwrite.' }
        if (Test-Path -LiteralPath $resolved) {
            if (@(Get-ChildItem -LiteralPath $resolved -Force).Count -gt 0) {
                # Other plugin output is outside this transaction's authority.
                # Retain it and report the ancestor-existence difference.
                $plan.retainedNonemptyParents = @($plan.retainedNonemptyParents) + $resolved
            }
            else { Remove-Item -LiteralPath $resolved -Force }
        }
    }
    # Persist restored state before marker release; this is recoverable after
    # interruption without claiming a second transaction or losing task files.
    Assert-WorkspaceConfigMarker $Config $plan
    $plan.phase = 'completed'; Write-WorkspaceJsonAtomic $record.path $plan
    if ($InternalTestFailurePoint -eq 'config-complete-after-terminal') { throw 'Injected interrupted configuration completion before marker release.' }
    Remove-Item -LiteralPath (Get-WorkspaceConfigMarkerPath $Config) -Force
    return [pscustomobject]@{ state = 'config-completed'; planPath = $record.path; preserved = $plan.preserved; baseline = $plan.baseline; retainedNonemptyParents = @($plan.retainedNonemptyParents) }
}
