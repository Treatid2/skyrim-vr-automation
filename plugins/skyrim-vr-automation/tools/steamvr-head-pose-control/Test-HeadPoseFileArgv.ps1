# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$entry=Join-Path $PSScriptRoot 'Invoke-SteamVRHeadPoseControl.ps1'
$hostPath=[Environment]::ProcessPath
$mapName='Local\CSXVRHeadPose-file-argv-test-'+[guid]::NewGuid().ToString('N')
$mapping=$null;$view=$null;$checks=[Collections.Generic.List[string]]::new()
function Assert-Argv([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$checks.Add($Name)}
try{
    $mapping=[IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($mapName,128)
    $view=$mapping.CreateViewAccessor(0,128,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $view.Write(0,[uint32]0x48505343);$view.Write(4,[uint16]2);$view.Write(6,[uint16]128)
    $view.Write(8,[uint64]2);$view.Write(16,[uint64]2);$view.Write(24,[uint32]1);$view.Write(28,[uint32]1)
    $view.Write(40,[double]1.68);$view.Write(56,[double]1);$view.Write(88,[uint64]101);$view.Write(96,[uint64]101);$view.Write(104,[uint64]202)
    # PID0 is deliberately not a valid runtime creator; no SteamVR process or
    # installed package can acquire authority for this random test mapping.
    $view.Write(112,[uint32]0);$view.Flush()
    $before=[byte[]]::new(128);$null=$view.ReadArray(0,$before,0,128)
    Assert-Argv ((Get-Command $entry).Parameters['Enabled'].ParameterType -eq [Nullable[bool]]) 'real controller retains nullable Boolean contract'
    foreach($argument in @('-Enabled:true','-Enabled:false','-Enabled:$true','-Enabled:$false')){
        $output=& $hostPath -NoProfile -NonInteractive -File $entry inspect -MapName $mapName -InstallRoot $FixtureRoot -OpenVRPathsPath (Join-Path $FixtureRoot 'unused-openvrpaths.json') -SteamVRRoot $FixtureRoot $argument -NoExit -Compact
        $result=$output|ConvertFrom-Json
        Assert-Argv ($LASTEXITCODE -eq 0 -and $result.ok -and $result.command -eq 'inspect' -and $result.data.mapName -ceq $mapName) "single argv $argument passes real file binder"
    }
    foreach($argument in @('-Enabled:true','-Enabled:false')){
        $output=& $hostPath -NoProfile -NonInteractive -File $entry set -MapName $mapName -InstallRoot $FixtureRoot -OpenVRPathsPath (Join-Path $FixtureRoot 'unused-openvrpaths.json') -SteamVRRoot $FixtureRoot $argument -NoWait -NoExit -Compact
        $result=$output|ConvertFrom-Json
        Assert-Argv ($LASTEXITCODE -eq 0 -and -not $result.ok -and $result.command -eq 'set' -and $result.state -eq 'blocked' -and $result.errors[0] -match 'not owned by a live') "set $argument reaches script but cannot bypass creator authority"
        $after=[byte[]]::new(128);$null=$view.ReadArray(0,$after,0,128)
        Assert-Argv ([Convert]::ToHexString($after) -ceq [Convert]::ToHexString($before)) "refused set $argument leaves fixture bytes unchanged"
    }
    $badOutput=& $hostPath -NoProfile -NonInteractive -File $entry inspect -MapName $mapName -Enabled '$true' -NoExit -Compact 2>&1
    Assert-Argv ($LASTEXITCODE -ne 0 -and ($badOutput -join "`n") -match 'Cannot process argument transformation.*Enabled') 'separate literal dollar-true argv fails before script execution'
    [pscustomobject]@{ok=$true;passed=$checks.Count;failed=0;scope='Actual controller file-argv on random non-runtime map; no installed package/runtime mutation';checks=@($checks)}|ConvertTo-Json -Depth 5
}finally{if($view){$view.Dispose()};if($mapping){$mapping.Dispose()}}
