# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot, [string]$HealthEvidencePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
function Assert-Health([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $passes.Add($Name) }
$health = [pscustomobject]@{ exe = 'SkyrimVR.exe'; frame = 47572L; lastTaskFrame = -1L; pendingTasks = 0L; pid = 43980L; port = 8921L; vr = $true }
Assert-Health (Get-DevBenchHealthSemanticStatus -Content @($health)).ok 'plain supported health does not require an invented ok marker'
Assert-Health (Get-DevBenchHealthSemanticStatus -Content @([pscustomobject]@{ ok = $true; pid = 101L; exe = 'fixture.exe' })).ok 'legacy positive health identity remains valid'
Assert-Health (-not (Get-DevBenchHealthSemanticStatus -Content @([pscustomobject]@{ retryable = $false; pid = 101L; exe = 'fixture.exe' })).ok) 'a retryable false marker does not qualify incomplete health'
foreach ($case in @('negative','retryable','pid-string','pid-zero','pid-too-large','exe-empty','port-string','port-too-large','vr-string','frame-negative','task-invalid','pending-negative','missing-frame','unknown','multiple','scalar')) {
    $h = $health | ConvertTo-Json | ConvertFrom-Json
    $content = @($h)
    switch ($case) {
        negative { $h | Add-Member ok $false }
        retryable { $h | Add-Member ok $false; $h | Add-Member retryable $true; $h | Add-Member error 'main_thread_busy' }
        pid-string { $h.pid = '43980' }
        pid-zero { $h.pid = 0 }
        pid-too-large { $h.pid = 2147483648L }
        exe-empty { $h.exe = '' }
        port-string { $h.port = '8921' }
        port-too-large { $h.port = 65536 }
        vr-string { $h.vr = 'true' }
        frame-negative { $h.frame = -1 }
        task-invalid { $h.lastTaskFrame = -2 }
        pending-negative { $h.pendingTasks = -1 }
        missing-frame { $h.PSObject.Properties.Remove('frame') }
        unknown { $content = @([pscustomobject]@{ pid = 43980L; exe = 'SkyrimVR.exe' }) }
        multiple { $content = @($h,$h) }
        scalar { $content = @('health') }
    }
    $semantic = Get-DevBenchHealthSemanticStatus -Content $content
    Assert-Health (-not $semantic.ok -and $semantic.reasons.Count -gt 0) "reject $case with explicit reasons"
}
if ($HealthEvidencePath) {
    $envelope = Get-Content -LiteralPath $HealthEvidencePath -Raw | ConvertFrom-Json
    Assert-Health (Get-DevBenchHealthSemanticStatus -Content @($envelope.parsedContent)).ok 'captured real health envelope qualifies offline'
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { throw 'Controller parse error.' }
$node = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-RuntimeHealthReply'},$true))[0]
Invoke-Expression $node.Extent.Text
$fixture = Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('health-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:invocationEvidencePath = Join-Path $fixture 'journal.json'
$script:invocationRecord = [ordered]@{ state = 'preparing'; dispatchReached = $false }
function Write-JsonAtomic($Path,$Value) { $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path }
$bad = [pscustomobject]@{ ok = $false; retryable = $true; error = 'main_thread_busy'; pid = 43980L; exe = 'SkyrimVR.exe' }
$reply = [pscustomobject]@{ content = @($bad); rawResult = [pscustomobject]@{ isError = $false; content = @([pscustomobject]@{ type = 'text'; text = ($bad | ConvertTo-Json -Compress) }) } }
$refused = $false
try { Assert-RuntimeHealthReply -Reply $reply | Out-Null } catch { $refused = $_.Exception.Message -match 'Unqualified runtime identity' }
$journal = Get-Content -LiteralPath $script:invocationEvidencePath -Raw | ConvertFrom-Json
Assert-Health ($refused -and -not $journal.identityHealthProbe.qualified -and $journal.identityHealthProbe.rawResult.content[0].text -eq $reply.rawResult.content[0].text -and -not $journal.dispatchReached) 'failed probe journal preserves raw MCP text and negative semantic outcome before dispatch'
$good = Assert-RuntimeHealthReply -Reply ([pscustomobject]@{ content = @($health); rawResult = [pscustomobject]@{ isError = $false; content = @() } })
Assert-Health ($good.pid -eq 43980 -and $script:invocationRecord.identityHealthProbe.qualified) 'supported typed health passes the private controller gate'
[pscustomobject]@{ ok = $true; tests = $passes.Count; passes = @($passes); fixture = $fixture } | ConvertTo-Json -Depth 5
