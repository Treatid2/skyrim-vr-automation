# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot, [string]$RetainedLogPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checks = 0
function Require([bool]$Condition, [string]$Name) { if (-not $Condition) { throw $Name }; $script:checks++ }
$fixture = Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('startup-proof-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$source = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$tokens = $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
Require (@($errors).Count -eq 0) 'controller parses'
foreach ($name in @('Get-StreamRangeSha256', 'Get-ByteArraySha256', 'Get-Utf8TrailingIncompleteByteCount', 'Get-SharedTextTail', 'Get-LogTimestampUtc', 'Get-NullRuntimeEvidence')) {
    $node = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true))[0]
    Invoke-Expression $node.Extent.Text
}
. (Join-Path $PSScriptRoot 'StartupLogProof.ps1')
$SteamVRRoot = Join-Path $fixture 'SteamVR'
$ServerLogPath = Join-Path $fixture 'vrserver.txt'
$LogTailMaxBytes = 4096
$InternalTestFailurePoint = ''
$script:SharedTextTailState = @{}
$utf8 = [Text.UTF8Encoding]::new($false)
$start = [DateTime]::UtcNow.AddSeconds(-10)
$server = [pscustomobject]@{ name = 'vrserver'; id = 123; path = (Join-Path $SteamVRRoot 'bin/win64/vrserver.exe'); startTimeUtc = $start.ToString('o') }
$profile = @{ driver_null = @{ serialNumber = 'fixture-null' }; headPoseProviderContract = @{}; dashboard = @{ enableDashboard = $false } }
$script:probes = 0
function Get-NullProviderAuthority { param($DeadlineUtc) [pscustomobject]@{ verified = $true } }
function Get-HeadPoseSharedState {
    param($Contract)
    [pscustomobject]@{ qualified = $true; driverCreatorPid = $server.id; creatorAuthority = [pscustomobject]@{ pid = $server.id; executablePath = $server.path; processStartFileTimeUtc = $start.ToFileTimeUtc() } }
}
function Get-ApplicationHeadPose {
    param($Contract, $PreProbePose, $PreProbePackageAuthority, $DeadlineUtc)
    $script:probes++
    [pscustomobject]@{ qualified = $true; controllersQualified = $true; poseAfterProbe = $PreProbePose; packageAuthority = $PreProbePackageAuthority; providerContinuity = @{ verified = $true } }
}
function Reset-Log([string]$Text) {
    $script:NullStartupLogProofState.Clear(); $script:SharedTextTailState.Clear()
    [IO.File]::WriteAllText($ServerLogPath, $Text, $utf8)
}
function Proof-Lines([DateTime]$At, [string]$Serial = 'fixture-null') {
    $stamp = $At.ToLocalTime().ToString('ddd MMM d yyyy HH:mm:ss.fff', [cultureinfo]::InvariantCulture)
    @("$stamp [Info] Loaded server driver null fixture driver_null.dll",
      "$stamp [Info] Active HMD set to null.$Serial",
      "$stamp [Info] Loaded server driver codex_head_pose fixture driver_codex_head_pose.dll",
      "$stamp [Info] codex_head_pose: registered synthetic head-pose device at configured standing pose") -join "`n"
}
function Read-Proof {
    Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
}
$proofText = (Proof-Lines $start.AddSeconds(1)) + "`n"
$noise = ("diagnostic noise`n" * 3000)
Reset-Log ($proofText + $noise)
$runtime = Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Require ($runtime.active -and $runtime.headPoseReady -and $runtime.controllersReady -and $script:probes -eq 1) 'delayed first poll admits four early lines even beyond byte and 2000-line tail limits'
Require ($runtime.serverLogHashOffset -gt 0 -and $runtime.startupLogProof.offset -eq 0 -and $runtime.startupLogProof.length -eq $utf8.GetByteCount($proofText)) 'startup prefix and diagnostic tail have distinct exact offsets'
[IO.File]::AppendAllText($ServerLogPath, $noise, $utf8)
$again = Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Require ($again.headPoseReady -and $again.startupLogProof.retained -and $again.startupLogProof.sha256 -ceq $runtime.startupLogProof.sha256) 'validated pinned prefix survives append and tail rollover across observations'
Require ($again.startupLogProof.bytesRead -eq 0 -and $again.startupLogProof.hashBytesRead -eq 2 * $again.startupLogProof.length) 'retained confirmation examines only two bounded proof spans'
Require ($script:NullStartupLogProofState.Count -eq 1) 'retention has a single current server binding'
$edit = [IO.File]::Open($ServerLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
try { $edit.Position = 30; $edit.WriteByte([byte][char]'X') } finally { $edit.Dispose() }
$bad = Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Require (-not $bad.active -and -not $bad.headPoseReady -and $bad.startupLogProof.error -match 'in place' -and $script:probes -eq 2) 'in-place proof drift outside diagnostic tail refuses probe and readiness'
[IO.File]::WriteAllText($ServerLogPath, $proofText + $noise, $utf8)
Require (-not (Read-Proof).complete) 'same-server invalidation cannot silently reacquire formerly rejected proof'
Reset-Log ($proofText + $noise)
$null = Read-Proof
$rotated = Join-Path $fixture 'rotated.txt'
[IO.File]::Move($ServerLogPath, $rotated)
[IO.File]::WriteAllText($ServerLogPath, $proofText + $noise, $utf8)
[IO.File]::SetCreationTimeUtc($ServerLogPath, [IO.File]::GetCreationTimeUtc($rotated))
Require (-not (Read-Proof).complete) 'replacement with identical content and creation timestamp is rejected by OS file identity'
Reset-Log ($proofText + $noise)
$null = Read-Proof
[IO.File]::WriteAllText($ServerLogPath, $proofText, $utf8)
Require ((Read-Proof).error -match 'truncated') 'truncation rejects retained proof even when its bytes survive'
Reset-Log ($proofText + $noise)
$null = Read-Proof
[IO.File]::Move($ServerLogPath, (Join-Path $fixture 'temporarily-missing.txt'))
$missing = Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
[IO.File]::WriteAllText($ServerLogPath, $proofText + $noise, $utf8)
Require (-not $missing.active -and -not (Read-Proof).complete) 'missing selected path invalidates rather than clearing and reacquiring same-server proof'
Reset-Log (Proof-Lines $start.AddSeconds(-10))
Require (-not (Read-Proof).complete) 'historical pre-server lines never establish readiness'
Reset-Log ((Proof-Lines $start.AddSeconds(1) 'fixture-null-extra') + "`n")
Require (-not (Read-Proof).complete) 'different serial suffix is not an exact HMD match'
Reset-Log ((Proof-Lines $start.AddSeconds(1) 'FIXTURE-NULL') + "`n")
Require (-not (Read-Proof).complete) 'case-changed serial cannot borrow the configured identity'
$split = $proofText.LastIndexOf("`n")
Reset-Log $proofText.Substring(0, $split)
Require (-not (Read-Proof).complete) 'unterminated proof line is not published'
[IO.File]::AppendAllText($ServerLogPath, "`n", $utf8)
Require ((Read-Proof).complete) 'newline completion safely extends the verified prefix'
Reset-Log ($proofText + $noise)
$null = Read-Proof
$server.id++
$start = $start.AddMinutes(1)
$server.startTimeUtc = $start.ToString('o')
Require (-not (Read-Proof).complete -and $script:NullStartupLogProofState.Count -eq 1) 'new PID/start identity discards old proof rather than transferring authority'
$start = $start.AddMinutes(-1); $server.startTimeUtc = $start.ToString('o')
Reset-Log $noise
Require ((Read-Proof).error -match 'byte budget') 'missing proof beyond byte cap fails explicitly without an unbounded scan'
Reset-Log ("n`n" * 10001)
$lineCapped = Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes 65536 -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
Require ($lineCapped.error -match 'line budget') 'many short lines cannot turn the byte cap into unbounded parsing work'
Reset-Log $proofText
$drift = Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -InternalMutationHook { param($path) [IO.File]::WriteAllText($path, 'rewritten') }
Require (-not $drift.stable -and -not $drift.complete) 'between-read and selected-path mutation cannot publish proof'
Reset-Log $proofText
$expired = $false
try { Get-NullStartupLogProof -Path $ServerLogPath -Server $server -SerialNumber 'fixture-null' -MaxBytes $LogTailMaxBytes -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(-1)) | Out-Null } catch [TimeoutException] { $expired = $true }
Require ($expired -and -not @($script:NullStartupLogProofState.Values)[0].complete) 'expired deadline throws and removes admissible cached evidence'
$retainedResult = $null
if ($RetainedLogPath) {
    $logInfo = Get-Item -LiteralPath $RetainedLogPath
    Require ($logInfo.Length -le 2097152) 'retained diagnostic input stays within declared 2MiB scope'
    $ServerLogPath = $RetainedLogPath; $LogTailMaxBytes = 262144
    $server.id = 54956; $start = [DateTimeOffset]::Parse('2026-10-05T10:35:44.5780874Z').UtcDateTime; $server.startTimeUtc = $start.ToString('o')
    $script:NullStartupLogProofState.Clear(); $script:SharedTextTailState.Clear()
    $profile.driver_null.serialNumber = 'CSX Null HMD'
    $retainedResult = Get-NullRuntimeEvidence -Processes @($server) -Profile $profile -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5))
    Require ($retainedResult.startupLogProof.complete -and $retainedResult.startupLogProof.length -eq 14963 -and $retainedResult.serverLogHashOffset -gt 500000) 'exact immutable failed-run log admits prefix proof while moving tail contains none'
    Require ($retainedResult.headPoseReady) 'actual retained log reaches production runtime probe gate with explicit fixture observations only'
}
[pscustomobject]@{ ok = $true; checks = $checks; liveRuntimeChanged = $false; applicationProbe = 'fixture only'; retainedLogProof = $(if ($retainedResult) { $retainedResult.startupLogProof } else { $null }); fixtureRoot = $fixture } | ConvertTo-Json -Depth 8 -Compress
