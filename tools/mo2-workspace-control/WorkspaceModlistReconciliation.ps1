# SPDX-License-Identifier: GPL-3.0-or-later
# Private existing-workspace recovery; plans and workspace bytes stay immutable.
function Invoke-WorkspaceProfileReconciliation($Config, [string]$ProfilePath, [string]$Operation, [string]$ExpectedHash, [string]$PinnedHash, [string]$Evidence, [switch]$Preview) {
    $arguments = @{ ProfilePath = $ProfilePath; ModName = 'disabled-inventory-reconciliation'; ModsDirectory = [string]$Config.mo2.modsDirectory
        ExpectedCurrentSha256 = $ExpectedHash; EvidenceDirectory = $Evidence; BlockingProcessNames = @(Get-WorkspaceBlockingProcessNames $Config); NoExit = $true; Compact = $true }
    if ($PinnedHash) { $arguments.PinnedProfileSha256 = $PinnedHash }
    if ($Preview) { $arguments.WhatIf = $true } else { $arguments.Confirm = $false }
    $answer = & (Join-Path $toolRoot 'mo2-profile-control\Invoke-MO2ProfileControl.ps1') $Operation @arguments | ConvertFrom-Json -Depth 20
    if (-not $answer.ok) { throw 'Profile disabled inventory reconciliation failed.' }
    return $answer
}

function Assert-WorkspaceModlistConfigCompleted($Config, $Workspace) {
    if (Test-Path -LiteralPath (Get-WorkspaceConfigMarkerPath $Config)) { throw 'Complete configuration custody before disabled inventory reconciliation.' }
    $configPlan = Read-CSXConfigCustodyPlan $Config $Workspace.data
    if ($configPlan) {
        if ([string]$configPlan.data.phase -cne 'completed') { throw 'Complete configuration custody before disabled inventory reconciliation.' }
        if ((Get-CSXConfigTree $configPlan.data.preserved.preservedPath).treeSha256 -cne [string]$configPlan.data.preserved.inventory.treeSha256) { throw 'Completed configuration evidence changed.' }
    }
    return $configPlan
}

function Invoke-WorkspaceModlistReconciliation($Config, $Workspace, [string]$Operation, [string]$ExpectedHash, [switch]$Preview) {
    $modlist = Join-Path $Workspace.data.profilePath 'modlist.txt'
    Assert-NoWorkspaceReparsePoint -Path $modlist -Purpose 'Disabled inventory owned profile'
    if ((Get-FileHash -LiteralPath $modlist).Hash -cne $ExpectedHash.ToUpperInvariant()) { throw 'Disabled inventory current-hash CAS mismatch.' }
    $configPlan = Assert-WorkspaceModlistConfigCompleted $Config $Workspace
    $pinned = $null
    $planProofs = @()
    if ($Operation -eq 'recover-disabled-append') {
        # Reuse the exact owner/paths/prepared-plan/snapshot admission; it is
        # read-only and deliberately resolves the current, not presumed, build.
        $admission = Get-WorkspaceRequalificationAdmission $Config $Workspace
        $pinned = [string]$Workspace.data.runtimeOutput.communityShadersPlugin.profileSha256
        if ($pinned -notmatch '^[A-F0-9]{64}$') { throw 'Original workspace lacks its exact pinned profile hash.' }
        foreach ($item in $admission.items) {
            $plan = Get-Content -LiteralPath $item.planPath -Raw | ConvertFrom-Json -Depth 80
            $binding = if ($item.kind -eq 'cache') { $plan.cacheBinding } else { $plan }
            if ([string]$binding.profileSha256 -cne $pinned) { throw 'Original cache and backup plans disagree on pinned profile bytes.' }
            $planProofs += @{ path = $item.planPath; sha256 = $item.planSha256 }
        }
        if ($configPlan -and [string]$configPlan.data.profileSha256 -cne $pinned) { throw 'Completed configuration belongs to different profile bytes.' }
        $originalBuild = $Workspace.data.runtimeOutput.communityShadersPlugin
        foreach ($field in @('mode', 'modName', 'pluginPath', 'manifestPath', 'manifestSha256', 'buildId', 'artifactSha256', 'artifactBytes', 'shaderCacheAbi')) {
            if ([string]$admission.currentBuild.$field -cne [string]$originalBuild.$field) { throw "Disabled suffix recovery refuses changed CSX build: $field" }
        }
    }
    else {
        $classification = Get-WorkspaceResumeClassification $Config $Workspace.data $Workspace.path
        if (-not $classification.resumable -or $classification.resumeDisposition -cne 'rearm-completed-output') { throw 'Installed inventory normalization requires fully completed output; never modify active pinned bindings.' }
    }
    $manifestHash = (Get-FileHash -LiteralPath $Workspace.path).Hash
    if ($configPlan) { $planProofs += @{ path = $configPlan.path; sha256 = (Get-FileHash -LiteralPath $configPlan.path).Hash } }
    foreach ($proof in $planProofs) { if ((Get-FileHash -LiteralPath $proof.path).Hash -cne $proof.sha256) { throw 'Pinned plan changed during disabled inventory admission.' } }
    $evidence = Join-Path (Get-WorkspaceControlRoot $Config) ($Workspace.data.workspaceId + '-disabled-inventory-' + [guid]::NewGuid().ToString('N'))
    $answer = Invoke-WorkspaceProfileReconciliation -Config $Config -ProfilePath $modlist -Operation $Operation -ExpectedHash $ExpectedHash -PinnedHash $pinned -Evidence $evidence -Preview:$Preview
    foreach ($proof in $planProofs) { if ((Get-FileHash -LiteralPath $proof.path).Hash -cne $proof.sha256) { throw 'Pinned plan changed across disabled inventory reconciliation; retain its committed profile receipt for recovery.' } }
    if ((Get-FileHash -LiteralPath $Workspace.path).Hash -cne $manifestHash) { throw 'Workspace manifest changed across disabled inventory reconciliation.' }
    return [pscustomobject]@{ ok = $true; command = $Operation; state = $(if ($Preview) { 'dry-run' } elseif ($Operation -eq 'recover-disabled-append') { 'pinned-profile-restored-completion-required' } else { 'disabled-inventory-normalized-resume-required' }); data = @{ workspaceId = $Workspace.data.workspaceId; profile = $answer; immutablePlans = $planProofs; manifestSha256 = $manifestHash; runtimeQualified = $false } }
}
