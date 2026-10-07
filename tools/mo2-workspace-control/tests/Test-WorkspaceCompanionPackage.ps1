# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$relative='tools/mo2-workspace-control/WorkspaceOutputRequalification.ps1'
$root=Join-Path $repository $relative
$bundled=Join-Path $repository ('plugins/skyrim-vr-automation/'+$relative)
if (-not (Test-Path -LiteralPath $root -PathType Leaf) -or -not (Test-Path -LiteralPath $bundled -PathType Leaf)) { throw 'Supported companion missing from root or bundle' }
$rootHash=(Get-FileHash -LiteralPath $root).Hash
$bundleHash=(Get-FileHash -LiteralPath $bundled).Hash
if ($rootHash -cne $bundleHash -or $rootHash -cne '8112ECA906D84EB6F4E1AD861BB6A8A868C7091A89792ACA9A4972D1F3F3756E') { throw 'Bundled companion is not the exact pinned existing curated source' }
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($bundled,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors|Out-String) }
$names=@($ast.EndBlock.Statements | Where-Object {$_ -is [System.Management.Automation.Language.FunctionDefinitionAst]} | ForEach-Object Name)
if ($names -notcontains 'Assert-WorkspaceRequalificationBoundary') { throw 'Existing requalification boundary missing' }
[pscustomobject]@{ok=$true;assertions=4;rootSha256=$rootHash;bundleSha256=$bundleHash;scope='Static exact reviewed companion availability/parser/function checks; integrated public command qualification retained separately';liveCalls=0}|ConvertTo-Json
