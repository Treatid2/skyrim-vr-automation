# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[string]$PythonEntry=$env:CODEX_PYTHON)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($PythonEntry) -or -not(Test-Path -LiteralPath $PythonEntry -PathType Leaf)){throw 'An explicit stable PythonEntry or CODEX_PYTHON is required.'}
$checks=0
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('calendar-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
foreach($case in @('healthy','failed-observation','generation','release-failed')) {
    $fixture=Join-Path $root $case;New-Item -ItemType Directory -Path $fixture | Out-Null
    $start=[Diagnostics.ProcessStartInfo]::new()
    # The stable entry point is a cmd shim on Windows; invoke its selected
    # deterministic Python via its documented -- executable argument output.
    $python=(& $PythonEntry -c 'import sys; print(sys.executable)').Trim()
    $start.FileName=$python; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    foreach($arg in @('-B',(Join-Path $PSScriptRoot 'fixtures/calendar_mcp_server.py'),$fixture,(Join-Path $PSScriptRoot 'fixtures/native-calendar-schema.json'),$case)){$start.ArgumentList.Add($arg)}
    $worker=[Diagnostics.Process]::Start($start)
    try {
        $runtime=Join-Path $fixture 'runtime.json';$readyDeadline=[datetime]::UtcNow.AddSeconds(5)
        while(-not(Test-Path -LiteralPath $runtime) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $readyDeadline){Start-Sleep -Milliseconds 50}
        Require (Test-Path -LiteralPath $runtime) "$case fixture did not start"
        $response=& (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') calendar-window -CalendarOwner fixture-owner -CalendarObservationsJson '[{"tool":"inspect","arguments":{"kind":"state"}}]' -RuntimePath $runtime -ArtifactPath (Join-Path $PSScriptRoot 'fixtures/calendar_mcp_server.py') -ExpectedBuildId calendar-fixture-build -MaxTransientRetries 0 -TimeoutSeconds 30 -EvidenceDirectory $fixture -Compact -NoExit | ConvertFrom-Json -Depth 50
        Require ($response.ok -eq ($case -eq 'healthy')) "$case incorrect public outcome: $($response.errors -join ';')"
        Require $response.runtimeIdentity.complete "$case did not exercise complete real identity admission"
        $events=Get-Content -LiteralPath (Join-Path $fixture 'events.json') -Raw | ConvertFrom-Json -Depth 30
        Require (@($events | Where-Object method -eq initialize).Count -eq 1) "$case rebound MCP"
        Require (@($events | Where-Object {$_.method -eq 'tools/call' -and $_.arguments.name -eq 'calendar' -and $_.arguments.arguments.action -eq 'hold'}).Count -eq 1) "$case replayed hold"
        Require (@($events | Where-Object {$_.method -eq 'tools/call' -and $_.arguments.name -eq 'calendar' -and $_.arguments.arguments.action -eq 'release'}).Count -eq 1) "$case omitted or replayed exact release"
        Require (@($events | Where-Object {$_.method -eq 'tools/call' -and $_.session -cne 'calendar-test-session'}).Count -eq 0) "$case changed actual session"
        Require ($events[-1].method -eq 'DELETE' -and $response.sessionCleanup.ok) "$case closed session before terminal calendar work"
        Require ($response.data.restorationVerified -eq ($case -in @('healthy','failed-observation'))) "$case incorrect restoration claim"
        $journal=Get-Content -LiteralPath $response.invocationEvidencePath -Raw | ConvertFrom-Json -Depth 50
        Require ($journal.calendarDispatchArguments.action -eq 'release' -and $journal.sessionCleanup.ok) "$case lost dispatch/cleanup custody"
    } finally {if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit(5000)|Out-Null};$worker.Dispose()}
}
[pscustomobject]@{ok=$true;checks=$checks;cases=4;root=$root;nativeLiveQualification=$false}|ConvertTo-Json -Compress
