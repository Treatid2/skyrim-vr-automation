# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$checks=0
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Clone($Object){$Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30}
$fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/native-menu-status.json') -Raw | ConvertFrom-Json -Depth 30
$query=@{action='status';expectedBuildId=$fixture.producer.buildId}
function Read($Payload,$Arguments=$query){Get-DevBenchCallSemanticStatus -ToolName communityshaders.menu -Arguments $Arguments -Content @($Payload)}
function Reject($Payload,[string]$Message,$Arguments=$query){$r=Read $Payload $Arguments;Require (-not $r.ok -and $null -eq $r.qualifiedMenuStatus) $Message}
$before=$fixture | ConvertTo-Json -Depth 30 -Compress
$r=Read $fixture
Require ($r.known -and $r.ok -and $r.completionBasis -ceq 'read-schema-only') 'Real retained native status must qualify without generic ok'
Require (-not $r.qualifiedMenuStatus.status.menuEnabled) 'A closed menu is a valid read, not a failed interaction'
Require (($fixture | ConvertTo-Json -Depth 30 -Compress) -ceq $before -and -not $fixture.PSObject.Properties['ok']) 'Raw receipt changed'
Require (Test-DevBenchReadOnlyRequest -ToolName communityshaders.menu -Arguments $query) 'Exact status not read-only'
foreach($field in @('action','path','delegatedRequest','producer','status')) {$bad=Clone $fixture;$bad.PSObject.Properties.Remove($field);Reject $bad "Missing $field"}
foreach($field in @('menuEnabled','menuSessionOpen','menuLayoutUnlocked','menuRenderTarget','drawDataValid','loadingMenuOpen','screenshotPending')) {
    foreach($value in @('false',1,$null,@($false))) {$bad=Clone $fixture;$bad.status.$field=$value;Reject $bad "Malformed $field"}
}
foreach($field in @('runtimeType','drawCommandLists','drawTotalIndices','drawTotalVertices')) {
    foreach($value in @(-1,1.5,$true,'1',$null)) {$bad=Clone $fixture;$bad.status.$field=$value;Reject $bad "Malformed $field"}
}
foreach($field in @('menuOffsetX','menuOffsetY','menuOffsetZ','menuScale')) {
    foreach($value in @('1',$null,$true,[double]::NaN,[double]::PositiveInfinity)) {$bad=Clone $fixture;$bad.status.$field=$value;Reject $bad "Malformed $field"}
}
foreach($field in @('buildId','shaderCacheAbiId','sourceCommit')) {$bad=Clone $fixture;$bad.producer.$field='foreign';Reject $bad "Foreign producer $field"}
foreach($mode in @('nested-error','negative','delegated','path','mutation','foreign-build','extra-argument')) {
    $bad=Clone $fixture;$argsMap=$query.Clone()
    switch($mode) {
        nested-error {$bad.producer | Add-Member error 'native failure'}
        negative {$bad | Add-Member ok $false}
        delegated {$bad.delegatedRequest=[pscustomobject]@{id='foreign'}}
        path {$bad.path='settings'}
        mutation {$bad | Add-Member applied $true}
        foreign-build {$argsMap.expectedBuildId='f'*64}
        extra-argument {$argsMap.enabled=$true}
    }
    Reject $bad $mode $argsMap
}
foreach($content in @(@($fixture,$fixture),@([pscustomobject]@{ok=$true}),@('scalar'))) {
    $r=Get-DevBenchCallSemanticStatus -ToolName communityshaders.menu -Arguments $query -Content $content
    Require (-not $r.ok -and $null -eq $r.qualifiedMenuStatus) 'Foreign/multiple/scalar receipt accepted'
}
foreach($action in @('set','open','close','save','STATUS',@('status'))) {
    $argsMap=@{action=$action};$r=Read $fixture $argsMap
    Require (-not $r.PSObject.Properties['qualifiedMenuStatus']) 'Mutation gained read qualifier'
    Require (-not (Test-DevBenchReadOnlyRequest -ToolName communityshaders.menu -Arguments $argsMap)) 'Mutation admitted as read-only'
}
[pscustomobject]@{ok=$true;checks=$checks;liveQualification=$false;fixtureSourceSha256='b8f25a05ca433980631d1c48f2732369ef356b360d376867b4df4873ce5856e8'} | ConvertTo-Json -Compress
