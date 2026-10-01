# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passes = [Collections.Generic.List[string]]::new()
function Assert-Semantic([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$parseErrors = $null; $tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
Assert-Semantic (@($parseErrors).Count -eq 0) 'entry point parses without errors'
foreach ($name in @('ConvertTo-CanonicalJsonValue','Get-JsonSemanticSha256','Test-JsonDictionaryContains','Test-JsonValueEquivalent','Get-JsonDifferencePaths','Get-SettingsRestoreValidation','Get-MO2ProviderInventoryEvidence','Assert-MO2NullAdmissionMatchesReceipt')) {
    $node = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
    Invoke-Expression $node.Extent.Text
}
function Clone-Value($Value) { return $Value | ConvertTo-Json -Depth 64 -Compress | ConvertFrom-Json -AsHashtable -Depth 64 }
$inventory = [ordered]@{profile='task';modListPath='C:\fixture\profiles\task\modlist.txt';providers=@([ordered]@{classification='OCU';modName='OCU';modPath='C:\fixture\mods\OCU';lineNumber=85;marker='-';enabled=$false;markers=[ordered]@{rootOpenVrApi=$true;rootOpenCompositeIni=$true;openCompositeInput=$false}});errors=@()}
function New-Admission($Inventory) {
    $proof = Get-MO2ProviderInventoryEvidence $Inventory
    [pscustomobject]@{mode='mo2';runtimeRoute='SteamVRNull';profile='task';leaseId='fixture-lease';providerInventoryContractVersion=1;providerInventory=$proof.inventory;providerInventorySemanticSha256=$proof.semanticSha256;providerInventorySha256='legacy-raw'}
}
$admission = New-Admission $inventory
$receipt = @{mo2Admission=Clone-Value $admission}
$moved = Clone-Value $inventory; $moved.providers[0].lineNumber = 87
$movedAdmission = New-Admission $moved
Assert-MO2NullAdmissionMatchesReceipt $movedAdmission $receipt
Assert-Semantic ($admission.providerInventorySemanticSha256 -ceq $movedAdmission.providerInventorySemanticSha256 -and $movedAdmission.providerInventory.providers[0].lineNumber -eq 87) 'line85 to87 changes only retained provenance, not semantic admission'
$reordered = [ordered]@{errors=@();providers=@([ordered]@{markers=[ordered]@{openCompositeInput=$false;rootOpenCompositeIni=$true;rootOpenVrApi=$true};enabled=$false;marker='-';lineNumber=87;modPath='C:\fixture\mods\OCU';modName='OCU';classification='OCU'});modListPath=$inventory.modListPath;profile='task'}
Assert-MO2NullAdmissionMatchesReceipt (New-Admission $reordered) $receipt
Assert-Semantic ((New-Admission $reordered).providerInventorySemanticSha256 -ceq $admission.providerInventorySemanticSha256) 'object and nested marker property order is canonical'
foreach ($case in @('enabled','path','name','marker','classification','profile','modlist','rootMarker','iniMarker','inputMarker','errors','missingMarkers','unknownField')) {
    $changed = Clone-Value $inventory
    switch ($case) {
        enabled {$changed.providers[0].enabled=$true;$changed.providers[0].marker='+'}
        path {$changed.providers[0].modPath='C:\fixture\mods\other'}
        name {$changed.providers[0].modName='other'}
        marker {$changed.providers[0].marker='+'}
        classification {$changed.providers[0].classification='unclassified-openvr-provider'}
        profile {$changed.profile='other'}
        modlist {$changed.modListPath='C:\fixture\other.txt'}
        rootMarker {$changed.providers[0].markers.rootOpenVrApi=$false}
        iniMarker {$changed.providers[0].markers.rootOpenCompositeIni=$false}
        inputMarker {$changed.providers[0].markers.openCompositeInput=$true}
        errors {$changed.errors=@('read failure')}
        missingMarkers {$changed.providers[0].Remove('markers')}
        unknownField {$changed.providers[0]['newContractField']='different'}
    }
    $rejected=$false
    try { Assert-MO2NullAdmissionMatchesReceipt (New-Admission $changed) $receipt } catch {$rejected=$true}
    Assert-Semantic $rejected "reject actual provider contract change: $case"
}
foreach ($case in @('lease','mode','route','profile','snapshot','digest','version')) {
    $altered = Clone-Value $receipt
    switch ($case) {
        lease {$altered.mo2Admission.leaseId='new-lease'}
        mode {$altered.mo2Admission.mode='standalone'}
        route {$altered.mo2Admission.runtimeRoute='SteamVR'}
        profile {$altered.mo2Admission.profile='other'}
        snapshot {$altered.mo2Admission.providerInventory.providers[0].modPath='C:\tampered'}
        digest {$altered.mo2Admission.providerInventorySemanticSha256='tampered'}
        version {$altered.mo2Admission.providerInventoryContractVersion=$true}
    }
    $rejected=$false;try {Assert-MO2NullAdmissionMatchesReceipt $admission $altered} catch {$rejected=$true}
    Assert-Semantic $rejected "reject inconsistent receipt authority: $case"
}
$legacy=@{mo2Admission=@{mode='mo2';runtimeRoute='SteamVRNull';profile='task';leaseId='fixture-lease';providerInventorySha256='legacy-raw'}}
Assert-MO2NullAdmissionMatchesReceipt $admission $legacy
$legacy.mo2Admission.providerInventorySha256='old-different'
$rejected=$false;try {Assert-MO2NullAdmissionMatchesReceipt $admission $legacy} catch {$rejected=$_.Exception.Message -match 'Legacy receipts are not migrated'}
Assert-Semantic $rejected 'legacy receipts remain exact-hash-bound and are not migrated'

# Pure restore qualification uses fixture files only, never the live controller.
$fixture=Join-Path $FixtureRoot ('null-semantic-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$currentPath=Join-Path $fixture 'current.json'
$expected=[ordered]@{dashboard=[ordered]@{enableDashboard=$false};steamvr=[ordered]@{forcedDriver='null'}}
function Read-JsonHashtable([string]$Path) {Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable}
function Get-HashOrNull([string]$Path) {(Get-FileHash -LiteralPath $Path).Hash}
function Get-NullSettingsExpectation($Receipt,$BackupPath) { [pscustomobject]@{value=$expected;profile=$expected;controlledPaths=@('dashboard.enableDashboard','steamvr.forcedDriver');semanticSha256=Get-JsonSemanticSha256 -Value $expected} }
function Assess-History($Document) {
    $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $currentPath -Encoding utf8NoBOM
    Get-SettingsRestoreValidation -Receipt @{settingsSha256Null='different'} -BackupPath 'fixture-only' -CurrentPath $currentPath
}
$added=Clone-Value $expected;$added.dashboard['lastAccessedExternalOverlayKey']='overlay.one'
Assert-Semantic (Assess-History $added).dashboardHistoryDriftAccepted 'string history addition qualifies'
$expected.dashboard['lastAccessedExternalOverlayKey']='overlay.old'
Assert-Semantic (Assess-History $added).dashboardHistoryDriftAccepted 'string history change qualifies'
$removed=Clone-Value $expected;$removed.dashboard.Remove('lastAccessedExternalOverlayKey')
Assert-Semantic (Assess-History $removed).dashboardHistoryDriftAccepted 'string history removal qualifies'
$added.dashboard.enableDashboard=$true
Assert-Semantic (-not (Assess-History $added).authorized) 'history allowance cannot override enableDashboard change'
$added.dashboard.enableDashboard=$false;$added.dashboard['other']='unclassified'
Assert-Semantic (-not (Assess-History $added).authorized) 'history allowance cannot override other dashboard changes'
$added.dashboard.Remove('other');$added.steamvr.forcedDriver='other'
Assert-Semantic (-not (Assess-History $added).authorized) 'history allowance cannot override other controlled settings'
# Preserve real nested history while attacking the ambiguous display spelling.
$historyKey = 'lastAccessedExternalOverlayKey'
foreach ($case in @('add','remove','change','object','null','boolean','number')) {
    $originalExpected = Clone-Value $expected
    $candidate = Clone-Value $expected
    $literalKey = 'dashboard.lastAccessedExternalOverlayKey'
    switch ($case) {
        add { $candidate[$literalKey] = 'unrelated' }
        remove { $expected[$literalKey] = 'unrelated' }
        change { $expected[$literalKey] = 'old'; $candidate[$literalKey] = 'new' }
        object { $candidate[$literalKey] = [ordered]@{ value = 'unrelated' } }
        null { $candidate[$literalKey] = $null }
        boolean { $candidate[$literalKey] = $true }
        number { $candidate[$literalKey] = 42 }
    }
    $candidate.dashboard[$historyKey] = 'overlay.new'
    $assessment = Assess-History $candidate
    Assert-Semantic (-not $assessment.authorized -and -not $assessment.dashboardHistoryDriftAccepted -and -not $assessment.runtimeManagedStructuralMatch) "literal dotted root-key drift is never history authority: $case"
    $expected = $originalExpected
}
foreach ($value in @($null,$false,42,[ordered]@{ value = 'not-string' })) {
    $candidate = Clone-Value $expected; $candidate.dashboard[$historyKey] = $value
    Assert-Semantic (-not (Assess-History $candidate).authorized) 'non-string actual history leaf remains refused'
}
$candidate = Clone-Value $expected; $candidate['GpuSpeed'] = [ordered]@{ nested = 42 }; $candidate.dashboard[$historyKey] = 'overlay.new'
Assert-Semantic (Assess-History $candidate).authorized 'actual runtime-managed root subtree and actual string history qualify together'
$candidate = Clone-Value $expected; $candidate['GpuSpeed.nested'] = 42
Assert-Semantic (-not (Assess-History $candidate).authorized) 'literal runtime-managed dotted root key does not borrow subtree authority'
[pscustomobject]@{ok=$true;passed=$passes.Count;passes=@($passes);fixture=$fixture;liveMutation=$false} | ConvertTo-Json -Depth 6
