# SPDX-License-Identifier: GPL-3.0-or-later
param([string]$GateName,[string]$EvidenceDirectory,[string]$BoundedProcessPath,[string]$BoundedProcessSha256)
$ErrorActionPreference='Stop'
$gate=[Threading.EventWaitHandle]::OpenExisting($GateName)
try{if(-not $gate.WaitOne(10000)){throw 'Concurrent fixture gate deadline expired'}}finally{$gate.Dispose()}
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-NullHmdGripDiagnostic.ps1') -OfflineCase normal -EvidenceDirectory $EvidenceDirectory -BoundedProcessPath $BoundedProcessPath -BoundedProcessSha256 $BoundedProcessSha256 -SessionBudgetSeconds 40 -CleanupReserveSeconds 10
