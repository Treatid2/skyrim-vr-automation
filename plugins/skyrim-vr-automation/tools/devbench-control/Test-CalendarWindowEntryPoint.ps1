# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param([Parameter(Mandatory)][string]$FixtureRoot,[string]$PythonEntry=$env:CODEX_PYTHON)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($PythonEntry) -or -not(Test-Path -LiteralPath $PythonEntry -PathType Leaf)){throw 'An explicit stable PythonEntry or CODEX_PYTHON is required.'}
$checks=0
function Require([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
$root=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('calendar-entry-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$cases=@('healthy','failed-observation','generation','release-failed','cell-recovered','cell-foreign-rate','cell-new-globals','cell-unavailable','cell-no-transition','cell-lease-id','scene-status','scene-release','scene-release-restored-false','scene-release-ok-false','scene-release-lease-id','scene-release-binding','scene-generation','scene-globals','scene-session','scene-unavailable','scene-rate','scene-transition-missing','scene-transition-reason','scene-transition-ok-false','scene-transition-restored-false','scene-unknown-reason')
foreach($case in $cases) {
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
        $hold=@($events|Where-Object {$_.method -eq 'tools/call' -and $_.arguments.name -eq 'calendar' -and $_.arguments.arguments.action -eq 'hold'})[0].arguments.arguments
        $release=@($events|Where-Object {$_.method -eq 'tools/call' -and $_.arguments.name -eq 'calendar' -and $_.arguments.arguments.action -eq 'release'})[0].arguments.arguments
        Require (($release.binding|ConvertTo-Json -Depth 10 -Compress) -ceq ($hold.binding|ConvertTo-Json -Depth 10 -Compress) -and $release.leaseId -ceq 'fixture-lease' -and $release.owner -ceq $hold.owner -and $release.commandId -cne $hold.commandId) "$case lost original release custody"
        Require ($events[-1].method -eq 'DELETE' -and $response.sessionCleanup.ok) "$case closed session before terminal calendar work"
        Require ($response.data.restorationVerified -eq ($case -in @('healthy','failed-observation','cell-recovered','scene-status','scene-release'))) "$case incorrect restoration claim"
        if($case.StartsWith('cell-')) {
            Require (-not $response.data.continuityVerified -and -not $response.ok) "$case turned cell drift into a successful observation"
            Require ($response.data.indeterminate -eq ($case -ne 'cell-recovered')) "$case confused positively verified cleanup and uncertainty"
            Require (@($events|Where-Object {$_.method -eq 'tools/call' -and $_.arguments.name -eq 'inspect' -and $_.arguments.arguments.kind -eq 'state'}).Count -eq 0) "$case dispatched observation after cell drift"
        }
        if($case.StartsWith('scene-')) {
            $positive=$case -cin @('scene-status','scene-release')
            Require (-not $response.data.continuityVerified -and -not $response.ok) "$case promoted scene loss into scientific success"
            Require ($response.data.indeterminate -ne $positive) "$case confused positive native cleanup and uncertainty"
            $automatic=@($events|Where-Object method -eq 'native-auto-restore')
            Require ($automatic.Count -eq 1 -and $automatic[0].arguments.reason -ceq 'scene_lost' -and $automatic[0].arguments.writes -eq 1) "$case omitted or replayed native automatic restoration"
            $observationIndexes=@(for($i=0;$i -lt $events.Count;$i++){if($events[$i].method -eq 'tools/call' -and $events[$i].arguments.name -eq 'inspect' -and $events[$i].arguments.arguments.kind -eq 'state'){$i}})
            if($case -ceq 'scene-release') {
                $changeIndex=@(for($i=0;$i -lt $events.Count;$i++){if($events[$i].method -eq 'native-scene-change'){$i}})
                Require ($observationIndexes.Count -eq 1 -and $changeIndex.Count -eq 1 -and $observationIndexes[0] -lt $changeIndex[0]) "$case dispatched observation after drift"
            } else {Require ($observationIndexes.Count -eq 0) "$case dispatched observation after automatic scene cleanup"}
        }
        $journal=Get-Content -LiteralPath $response.invocationEvidencePath -Raw | ConvertFrom-Json -Depth 50
        Require ($journal.calendarDispatchArguments.action -eq 'release' -and $journal.sessionCleanup.ok) "$case lost dispatch/cleanup custody"
    } finally {if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit(5000)|Out-Null};$worker.Dispose()}
}
[pscustomobject]@{ok=$true;checks=$checks;cases=$cases.Count;root=$root;nativeLiveQualification=$false}|ConvertTo-Json -Compress

