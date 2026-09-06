# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bounded-process-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $fixture = Join-Path $root 'fixture.ps1'
    $state = Join-Path $root 'state.txt'
    @'
param([string]$StatePath)
if (-not (Test-Path -LiteralPath $StatePath)) {
    Set-Content -LiteralPath $StatePath -Value first
    [Console]::Error.WriteLine('compiler output.d.json: Permission denied')
    exit 5
}
Write-Output 'second attempt succeeded'
'@ | Set-Content -LiteralPath $fixture -Encoding utf8
    $tool = Join-Path $PSScriptRoot 'Invoke-BoundedProcess.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $result = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $fixture, '-StatePath', $state) -WorkingDirectory $root -EvidenceDirectory (Join-Path $root 'evidence') -NoExit | ConvertFrom-Json
    if (-not $result.ok -or $result.attemptsRun -ne 2 -or -not $result.retried) { throw 'Expected one classified retry followed by success.' }
    $nonRetry = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 7') -WorkingDirectory $root -MaxAttempts 3 -NoExit | ConvertFrom-Json
    if ($nonRetry.ok -or $nonRetry.attemptsRun -ne 1) { throw 'Unclassified failures must not be retried.' }

    $treeFixture = Join-Path $root 'tree-fixture.ps1'
    $childPidPath = Join-Path $root 'child.pid'
    @'
param([string]$ChildPidPath)
$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -PassThru -WindowStyle Hidden
Set-Content -LiteralPath $ChildPidPath -Value $child.Id
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $treeFixture -Encoding utf8
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $treeFixture, '-ChildPidPath', $childPidPath) -WorkingDirectory $root -TimeoutSeconds 10 -TerminationGraceMilliseconds 500 -StreamDrainGraceMilliseconds 500 -NoExit | ConvertFrom-Json
    $timer.Stop()
    if ($timedOut.ok -or -not $timedOut.attempts[0].timedOut -or -not $timedOut.attempts[0].terminationConfirmed -or $timedOut.attempts[0].unresolvedProcess) { throw 'Timeout did not return a confirmed owned-tree termination.' }
    if ($timer.Elapsed.TotalSeconds -gt 15) { throw "Bounded timeout exceeded its termination and drain allowance: $($timer.Elapsed)." }
    $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw)
    if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) { throw "Descendant process remained alive after job termination: $childPid" }

    $evidenceRoot = Join-Path $root 'unique-evidence'
    $firstEvidence = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -WorkingDirectory $root -EvidenceDirectory $evidenceRoot -NoExit | ConvertFrom-Json
    $secondEvidence = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 0') -WorkingDirectory $root -EvidenceDirectory $evidenceRoot -NoExit | ConvertFrom-Json
    if ($firstEvidence.receiptPath -eq $secondEvidence.receiptPath -or -not (Test-Path -LiteralPath $firstEvidence.receiptPath) -or -not (Test-Path -LiteralPath $secondEvidence.receiptPath)) { throw 'Repeated runs did not preserve unique append-only receipts.' }
    [pscustomobject][ordered]@{ ok = $true; assertions = 6; receipt = $result.attemptsRun } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
