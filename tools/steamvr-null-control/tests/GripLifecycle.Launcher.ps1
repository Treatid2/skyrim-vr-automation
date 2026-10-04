# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
$pwsh=(Get-Process -Id $PID).Path
$child=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-File',(Join-Path $PSScriptRoot 'GripLifecycle.Child.ps1')) -WindowStyle Hidden -PassThru
$identity=@{id=$child.Id;path=$pwsh;name='fixture-runtime';startTimeUtc=$child.StartTime.ToUniversalTime().ToString('o');creationFileTime=$child.StartTime.ToUniversalTime().ToFileTimeUtc().ToString();launcherPid=$PID}
[IO.File]::WriteAllText((Join-Path $Root 'fixture-child.json'),($identity | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
# The startup parent exits; the child stays within the session owner's job.
@{launcherExited=$true;child=$identity} | ConvertTo-Json -Depth 3 -Compress
