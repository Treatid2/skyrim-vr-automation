# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'AutomatedVisualReviewProvider.psm1'
Import-Module $modulePath -Force

function Assert-ProviderTest {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)

    if (-not $Condition) { throw $Message }
}

function New-ProviderCommandResult {
    param(
        [int]$ExitCode,
        [AllowEmptyString()][string]$Stdout,
        [AllowEmptyString()][string]$Stderr,
        [bool]$TimedOut = $false
    )

    return [pscustomobject][ordered]@{
        launched = $true; processId = 4101; exitCode = $ExitCode; stdout = $Stdout; stderr = $Stderr; timedOut = $TimedOut
        setupError = $null; exitVerified = -not $TimedOut; terminationRequested = $TimedOut; terminationConfirmed = $TimedOut
        unresolvedProcess = $false; streamDrainComplete = $true; inputCompleted = $true; terminationErrors = @()
    }
}

function New-ProviderTestPasses {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string[]]$Images,
        [Parameter(Mandatory)][string]$PromptSuffix
    )

    $passes = [Collections.Generic.List[object]]::new()
    foreach ($presentationPass in 1..2) {
        $batches = [Collections.Generic.List[object]]::new()
        foreach ($replicate in 1..3) {
            $batches.Add([pscustomobject][ordered]@{
                replicate = $replicate
                promptText = "pass=$presentationPass replicate=$replicate $PromptSuffix"
                images = @($Images)
                outputSchemaPath = $SchemaPath
                responsePath = Join-Path $Root "pass-$presentationPass-replicate-$replicate.response.json"
                eventsPath = Join-Path $Root "pass-$presentationPass-replicate-$replicate.events.jsonl"
            })
        }
        $passes.Add([pscustomobject][ordered]@{
            presentationPass = $presentationPass
            batches = @($batches)
        })
    }
    return @($passes)
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "csx-provider-test-$([guid]::NewGuid().ToString('N'))"
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$testTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $temporaryRoot.StartsWith($testTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a test fixture outside the temporary directory: $temporaryRoot"
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $fakeWorkingDirectory = Join-Path $temporaryRoot 'provider path [quoted] & safe'
    New-Item -ItemType Directory -Path $fakeWorkingDirectory | Out-Null
    $schemaPath = Join-Path $fakeWorkingDirectory 'output schema.json'
    $imageOne = Join-Path $fakeWorkingDirectory 'frame 1 left & detail.png'
    $imageTwo = Join-Path $fakeWorkingDirectory 'frame 8 right [detail].png'
    [IO.File]::WriteAllText($schemaPath, '{"type":"object"}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($imageOne, [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes($imageTwo, [byte[]](5, 6, 7, 8))

    $fakeHelp = @'
Run Codex non-interactively
--ephemeral
--ignore-user-config
--skip-git-repo-check
--sandbox
--ask-for-approval
--json
--output-schema
--output-last-message
--image
--model
'@
    $fakeCommandAdapter = {
        param([string]$ExecutablePath, [string[]]$CommandArguments, [int]$TimeoutMilliseconds)

        if (($CommandArguments -join '|') -eq '--version') {
            return New-ProviderCommandResult -ExitCode 0 -Stdout "codex-cli 9.8.7-test`n" -Stderr ''
        }
        if (($CommandArguments -join '|') -in @('--help', 'exec|--help')) {
            return New-ProviderCommandResult -ExitCode 0 -Stdout $fakeHelp -Stderr ''
        }
        if ('--model' -in $CommandArguments) {
            return New-ProviderCommandResult -ExitCode 0 -Stdout '{"type":"turn.completed"}' -Stderr ''
        }
        throw "Unexpected preflight arguments: $($CommandArguments -join ' ')"
    }
    $pwshPath = [IO.Path]::GetFullPath([string](Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    $preflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $fakeCommandAdapter
    Assert-ProviderTest $preflight.ok "The fake preflight did not pass: $($preflight.errors -join ' | ')"
    Assert-ProviderTest ($preflight.version -eq '9.8.7-test') 'The preflight did not preserve the Codex version.'
    Assert-ProviderTest (@($preflight.missingFeatures).Count -eq 0) 'The preflight reported missing required CLI features.'
    Assert-ProviderTest ($preflight.model -eq 'gpt-5.6-sol' -and $preflight.modelProbe.ok) 'The preflight did not prove the selected model before qualification.'

    $missingFeatureAdapter = {
        param([string]$ExecutablePath, [string[]]$CommandArguments, [int]$TimeoutMilliseconds)

        if (($CommandArguments -join '|') -eq '--version') {
            return New-ProviderCommandResult -ExitCode 0 -Stdout "codex-cli 9.8.7-test`n" -Stderr ''
        }
        return New-ProviderCommandResult -ExitCode 0 -Stdout '--ephemeral' -Stderr ''
    }
    $failedPreflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $missingFeatureAdapter
    Assert-ProviderTest (-not $failedPreflight.ok) 'A preflight with missing CLI features passed.'
    Assert-ProviderTest (@($failedPreflight.missingFeatures).Count -gt 0) 'Missing CLI features were not reported.'

    $stderrAdapter = {
        param([string]$ExecutablePath, [string[]]$CommandArguments, [int]$TimeoutMilliseconds)

        return New-ProviderCommandResult -ExitCode 9 -Stdout '' -Stderr "  diagnostic detail  `r`n"
    }
    $stderrPreflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $stderrAdapter
    Assert-ProviderTest (-not $stderrPreflight.ok) 'A failed CLI preflight passed.'
    foreach ($label in @('Codex --version failed', 'Codex --help failed', 'Codex exec --help failed')) {
        Assert-ProviderTest ($label + ': diagnostic detail' -in @($stderrPreflight.errors)) "$label did not preserve trimmed stderr."
    }
    Assert-ProviderTest (-not (@($stderrPreflight.errors) -join ' | ').Contains('.Trim()')) 'Preflight failure evidence contains a literal Trim call.'

    $modelFailureAdapter = {
        param([string]$ExecutablePath, [string[]]$CommandArguments, [int]$TimeoutMilliseconds)

        if (($CommandArguments -join '|') -eq '--version') {
            return New-ProviderCommandResult -ExitCode 0 -Stdout "codex-cli 9.8.7-test`n" -Stderr ''
        }
        if (($CommandArguments -join '|') -in @('--help', 'exec|--help')) {
            return New-ProviderCommandResult -ExitCode 0 -Stdout $fakeHelp -Stderr ''
        }
        return New-ProviderCommandResult -ExitCode 2 -Stdout '' -Stderr "  model unavailable  `n"
    }
    $modelFailurePreflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $modelFailureAdapter
    Assert-ProviderTest (-not $modelFailurePreflight.ok -and -not $modelFailurePreflight.modelProbe.ok) 'An unavailable visual-review model passed preflight.'
    Assert-ProviderTest ("Codex model capability probe failed for 'gpt-5.6-sol': model unavailable" -in @($modelFailurePreflight.errors)) 'Model capability failure was not reported with trimmed evidence.'

    $builderResponsePath = Join-Path $fakeWorkingDirectory 'builder response.json'
    $startInfo = New-CSXCodexVisualReviewProcessStartInfo -CodexExecutablePath $pwshPath `
        -WorkingDirectory $fakeWorkingDirectory -PromptText 'safe stdin prompt' `
        -Images @($imageOne, $imageTwo) -OutputSchemaPath $schemaPath -ResponsePath $builderResponsePath
    $argumentVector = [string[]]@($startInfo.CSXArguments)
    Assert-ProviderTest (-not $startInfo.UseShellExecute -and $startInfo.CreateNoWindow) 'The provider process could open a shell or window.'
    Assert-ProviderTest ($startInfo.RedirectStandardInput -and $startInfo.RedirectStandardOutput -and $startInfo.RedirectStandardError) 'Provider standard streams are not redirected.'
    Assert-ProviderTest ([string]::IsNullOrEmpty($startInfo.Arguments)) 'The provider used a joined command line instead of ArgumentList.'
    Assert-ProviderTest (($argumentVector[0..2] -join '|') -eq '--ask-for-approval|never|exec' -and $argumentVector[-1] -eq '-') 'The Codex global/exec/stdin argument envelope is invalid.'
    Assert-ProviderTest (@($argumentVector | Where-Object { $_ -eq '-i' }).Count -eq 2) 'Images were not supplied as repeated -i arguments.'
    Assert-ProviderTest (($argumentVector -join '|') -match '\|--model\|gpt-5\.6-sol\|') 'The provider did not pin gpt-5.6-sol.'
    foreach ($required in @('--ephemeral', '--ignore-user-config', '--skip-git-repo-check', '--sandbox', 'read-only', '--ask-for-approval', 'never', '--json', '--output-schema', '--output-last-message')) {
        Assert-ProviderTest ($required -in $argumentVector) "The process argument vector omitted $required."
    }
    Assert-ProviderTest ($imageOne -in $argumentVector -and $imageTwo -in $argumentVector) 'A safely quoted image path changed in the argument vector.'

    $fakeExecPath = Join-Path $fakeWorkingDirectory 'fake codex exec.ps1'
    $fakeExec = @'
param(
    [Parameter(Mandatory)][string]$EncodedArguments,
    [Parameter(Mandatory)][string]$BarrierRoot,
    [Parameter(Mandatory)][int]$PresentationPass,
    [Parameter(Mandatory)][int]$Replicate
)
$ErrorActionPreference = 'Stop'
$argumentsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArguments))
$RemainingArguments = [string[]]@($argumentsJson | ConvertFrom-Json -Depth 20)
$responseIndex = [Array]::IndexOf($RemainingArguments, '--output-last-message')
if ($responseIndex -lt 0 -or $responseIndex + 1 -ge $RemainingArguments.Count) { throw 'missing response path' }
$responsePath = $RemainingArguments[$responseIndex + 1]
$imageCount = @($RemainingArguments | Where-Object { $_ -eq '-i' }).Count
$promptText = [Console]::In.ReadToEnd()
$delay = if ($promptText -match 'delay=(?<delay>[0-9]+)') { [int]$Matches.delay } else { 500 }
New-Item -ItemType Directory -Path $BarrierRoot -Force | Out-Null
$readyPath = Join-Path $BarrierRoot "pass-$PresentationPass-replicate-$Replicate.ready"
[IO.File]::WriteAllText($readyPath, '', [Text.UTF8Encoding]::new($false))
$barrierDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
while (@(Get-ChildItem -LiteralPath $BarrierRoot -Filter "pass-$PresentationPass-replicate-*.ready" -File).Count -lt 3) {
    if ([DateTimeOffset]::UtcNow -ge $barrierDeadline) { throw 'replicate barrier timed out' }
    [Threading.Thread]::Sleep(20)
}
[Threading.Thread]::Sleep($delay)
$event = [ordered]@{
    type = 'fake.completed'
    imageCount = $imageCount
    promptLength = $promptText.Length
    arguments = @($RemainingArguments)
} | ConvertTo-Json -Depth 10 -Compress
[Console]::Out.WriteLine($event)
$response = [ordered]@{ fake = $true; imageCount = $imageCount; prompt = $promptText } | ConvertTo-Json -Depth 10 -Compress
[IO.File]::WriteAllText($responsePath, $response, [Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText($fakeExecPath, $fakeExec, [Text.UTF8Encoding]::new($false))
    $fakeProcessAdapter = {
        param(
            [Diagnostics.ProcessStartInfo]$OriginalStartInfo,
            [int]$PresentationPass,
            [int]$Replicate
        )

        $replacement = [Diagnostics.ProcessStartInfo]::new()
        $replacement.FileName = $pwshPath
        $replacement.WorkingDirectory = $OriginalStartInfo.WorkingDirectory
        $replacement.UseShellExecute = $false
        $replacement.CreateNoWindow = $true
        $replacement.RedirectStandardInput = $true
        $replacement.RedirectStandardOutput = $true
        $replacement.RedirectStandardError = $true
        $replacement.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $replacement.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $replacement.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $argumentJson = @($OriginalStartInfo.CSXArguments) | ConvertTo-Json -Depth 10 -Compress
        $encodedArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentJson))
        $barrierRoot = Join-Path (Split-Path -Parent ([string]$OriginalStartInfo.CSXResponsePath)) '.replicate-barrier'
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-File', $fakeExecPath,
            '-EncodedArguments', $encodedArguments,
            '-BarrierRoot', $barrierRoot,
            '-PresentationPass', [string]$PresentationPass,
            '-Replicate', [string]$Replicate
        )) {
            [void]$replacement.ArgumentList.Add($argument)
        }
        return $replacement
    }

    $executionRoot = Join-Path $fakeWorkingDirectory 'successful execution'
    New-Item -ItemType Directory -Path $executionRoot | Out-Null
    $passes = New-ProviderTestPasses -Root $executionRoot -SchemaPath $schemaPath `
        -Images @($imageOne, $imageTwo) -PromptSuffix 'delay=25'
    $execution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $passes -Preflight $preflight -DeadlineSeconds 15 `
        -ProcessStartInfoAdapter $fakeProcessAdapter
    $executionStderr = @($execution.batches | ForEach-Object { $_.stderr } | Where-Object { $_ }) -join ' | '
    Assert-ProviderTest $execution.ok "The fake parallel provider execution failed: $($execution.errors -join ' | ') stderr=$executionStderr"
    Assert-ProviderTest (@($execution.batches).Count -eq 6) 'The provider did not return six batch results.'
    Assert-ProviderTest (-not $execution.deadlineReached) 'The successful fake execution reached its deadline.'
    foreach ($batch in $execution.batches) {
        Assert-ProviderTest ($batch.exitCode -eq 0 -and $batch.status -eq 'completed') 'A successful fake batch did not report completion.'
        Assert-ProviderTest ($batch.launched -and $batch.exitVerified -and $batch.streamDrainComplete -and $batch.inputCompleted) 'A successful fake batch omitted completed process-custody evidence.'
        Assert-ProviderTest (-not $batch.terminationRequested -and -not $batch.unresolvedProcess -and @($batch.terminationErrors).Count -eq 0) 'A successful fake batch reported unexpected process cleanup.'
        Assert-ProviderTest (Test-Path -LiteralPath $batch.responsePath -PathType Leaf) 'A fake response was not captured.'
        Assert-ProviderTest (Test-Path -LiteralPath $batch.eventsPath -PathType Leaf) 'Fake stdout JSONL was not preserved.'
        Assert-ProviderTest (@($batch.stdoutJsonl).Count -eq 1) 'Fake stdout JSONL was not parsed.'
        Assert-ProviderTest ([int]$batch.stdoutJsonl[0].imageCount -eq 2) 'Repeated image arguments were not preserved by the child process.'
        Assert-ProviderTest ([bool]$batch.response.fake -and [int]$batch.response.imageCount -eq 2) 'The schema response was not captured or parsed.'
        Assert-ProviderTest ([string]::IsNullOrEmpty($batch.stderr)) 'The successful fake process wrote unexpected stderr.'
    }
    $passOne = @($execution.batches | Where-Object presentationPass -eq 1)
    $passTwo = @($execution.batches | Where-Object presentationPass -eq 2)
    $latestPassOneStart = @($passOne | ForEach-Object { [DateTimeOffset]::Parse($_.startedUtc) } | Sort-Object)[-1]
    $earliestPassOneCompletion = @($passOne | ForEach-Object { [DateTimeOffset]::Parse($_.completedUtc) } | Sort-Object)[0]
    $latestPassOneCompletion = @($passOne | ForEach-Object { [DateTimeOffset]::Parse($_.completedUtc) } | Sort-Object)[-1]
    $earliestPassTwoStart = @($passTwo | ForEach-Object { [DateTimeOffset]::Parse($_.startedUtc) } | Sort-Object)[0]
    Assert-ProviderTest ($latestPassOneStart -lt $earliestPassOneCompletion) 'Replicate processes were not concurrent within presentation pass 1.'
    Assert-ProviderTest ($earliestPassTwoStart -ge $latestPassOneCompletion) 'Presentation pass 2 overlapped presentation pass 1.'

    $timeoutRoot = Join-Path $fakeWorkingDirectory 'deadline execution'
    New-Item -ItemType Directory -Path $timeoutRoot | Out-Null
    $timeoutPasses = New-ProviderTestPasses -Root $timeoutRoot -SchemaPath $schemaPath `
        -Images @($imageOne) -PromptSuffix 'delay=5000'
    $timeoutExecution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $timeoutPasses -Preflight $preflight -DeadlineSeconds 1 `
        -ProcessStartInfoAdapter $fakeProcessAdapter
    Assert-ProviderTest (-not $timeoutExecution.ok -and $timeoutExecution.deadlineReached) 'The shared deadline did not fail closed.'
    Assert-ProviderTest (@($timeoutExecution.batches).Count -eq 6) 'Deadline execution did not return all six batch identities.'
    Assert-ProviderTest (@($timeoutExecution.batches | Where-Object { $_.presentationPass -eq 1 -and $_.timedOut }).Count -eq 3) 'Running replicate processes were not timed out together.'
    Assert-ProviderTest (@($timeoutExecution.batches | Where-Object { $_.presentationPass -eq 1 -and $_.terminationRequested -and $_.terminationConfirmed -and -not $_.unresolvedProcess }).Count -eq 3) 'Timed-out replicate custody was not terminated and verified.'
    Assert-ProviderTest (@($timeoutExecution.batches | Where-Object { $_.presentationPass -eq 2 -and $_.status -eq 'not_started_deadline' }).Count -eq 3) 'The second presentation pass started after the shared deadline.'

    $nonReadingAdapter = {
        param(
            [Diagnostics.ProcessStartInfo]$OriginalStartInfo,
            [int]$PresentationPass,
            [int]$Replicate
        )

        $replacement = [Diagnostics.ProcessStartInfo]::new()
        $replacement.FileName = $pwshPath
        $replacement.WorkingDirectory = $OriginalStartInfo.WorkingDirectory
        $replacement.UseShellExecute = $false
        $replacement.CreateNoWindow = $true
        $replacement.RedirectStandardInput = $true
        $replacement.RedirectStandardOutput = $true
        $replacement.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo', '-NoProfile', '-Command', '[Threading.Thread]::Sleep(5000)')) {
            [void]$replacement.ArgumentList.Add($argument)
        }
        return $replacement
    }
    $blockedInputRoot = Join-Path $fakeWorkingDirectory 'blocked input execution'
    New-Item -ItemType Directory -Path $blockedInputRoot | Out-Null
    $blockedInputPasses = New-ProviderTestPasses -Root $blockedInputRoot -SchemaPath $schemaPath `
        -Images @($imageOne) -PromptSuffix ('x' * (8 * 1024 * 1024))
    $blockedInputExecution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $blockedInputPasses -Preflight $preflight -DeadlineSeconds 1 `
        -ProcessStartInfoAdapter $nonReadingAdapter
    Assert-ProviderTest ([double]$blockedInputExecution.durationMs -lt 2000) 'Blocked standard-input delivery bypassed the provider execution deadline.'
    Assert-ProviderTest (@($blockedInputExecution.batches | Where-Object { $_.presentationPass -eq 1 -and -not $_.inputCompleted }).Count -gt 0) 'The blocked-input fixture did not preserve incomplete prompt delivery.'
    Assert-ProviderTest (@($blockedInputExecution.batches | Where-Object { $_.presentationPass -eq 1 -and $_.terminationConfirmed -and -not $_.unresolvedProcess }).Count -eq 3) 'Blocked-input children were not terminated within their shared budget.'

    $setupFailureAdapter = {
        param(
            [Diagnostics.ProcessStartInfo]$OriginalStartInfo,
            [int]$PresentationPass,
            [int]$Replicate
        )

        $replacement = & $nonReadingAdapter $OriginalStartInfo $PresentationPass $Replicate
        $replacement.RedirectStandardOutput = $false
        return $replacement
    }
    $setupFailureRoot = Join-Path $fakeWorkingDirectory 'post launch setup failure'
    New-Item -ItemType Directory -Path $setupFailureRoot | Out-Null
    $setupFailurePasses = New-ProviderTestPasses -Root $setupFailureRoot -SchemaPath $schemaPath `
        -Images @($imageOne) -PromptSuffix 'setup failure'
    $setupFailureExecution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $setupFailurePasses -Preflight $preflight -DeadlineSeconds 5 `
        -ProcessStartInfoAdapter $setupFailureAdapter
    Assert-ProviderTest (@($setupFailureExecution.batches | Where-Object { $_.launched -and $_.status -eq 'setup_failed' }).Count -eq 6) 'Post-launch setup failures were mislabeled as unstarted processes.'
    Assert-ProviderTest (@($setupFailureExecution.batches | Where-Object { $_.terminationRequested -and $_.terminationConfirmed -and $_.exitVerified -and -not $_.unresolvedProcess }).Count -eq 6) 'Post-launch setup failures lost owned-child termination evidence.'

    $selfExitAdapter = {
        param(
            [Diagnostics.ProcessStartInfo]$OriginalStartInfo,
            [int]$PresentationPass,
            [int]$Replicate
        )

        $replacement = & $nonReadingAdapter $OriginalStartInfo $PresentationPass $Replicate
        $replacement.ArgumentList.Clear()
        foreach ($argument in @('-NoLogo', '-NoProfile', '-Command', '[Threading.Thread]::Sleep(1500)')) {
            [void]$replacement.ArgumentList.Add($argument)
        }
        return $replacement
    }
    $refusedTermination = { param([Diagnostics.Process]$Process, [string]$Reason); throw 'synthetic termination refusal' }
    $unresolvedRoot = Join-Path $fakeWorkingDirectory 'unresolved execution'
    New-Item -ItemType Directory -Path $unresolvedRoot | Out-Null
    $unresolvedPasses = New-ProviderTestPasses -Root $unresolvedRoot -SchemaPath $schemaPath `
        -Images @($imageOne) -PromptSuffix 'unresolved custody'
    $unresolvedExecution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $unresolvedPasses -Preflight $preflight -DeadlineSeconds 1 `
        -ProcessStartInfoAdapter $selfExitAdapter -ProcessTerminationAdapter $refusedTermination
    $unresolvedBatches = @($unresolvedExecution.batches | Where-Object presentationPass -eq 1)
    Assert-ProviderTest (@($unresolvedBatches | Where-Object { $_.status -eq 'unresolved_process' -and $_.unresolvedProcess -and -not $_.exitVerified }).Count -eq 3) 'Failed termination did not retain exact unresolved child custody.'
    Assert-ProviderTest (@($unresolvedBatches | Where-Object { (@($_.terminationErrors) -join ' | ') -match 'synthetic termination refusal' }).Count -eq 3) 'Termination failures were discarded from unresolved child receipts.'
    [Threading.Thread]::Sleep(2000)
    foreach ($processId in @($unresolvedBatches.processId)) {
        try {
            $remainingProcess = [Diagnostics.Process]::GetProcessById([int]$processId)
            try { Assert-ProviderTest $remainingProcess.HasExited "Synthetic unresolved child PID $processId did not self-exit." }
            finally { $remainingProcess.Dispose() }
        }
        catch [ArgumentException] { }
    }

    'Automated visual review provider tests passed.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolvedCleanup = [IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedCleanup.StartsWith($testTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a test fixture outside the temporary directory: $resolvedCleanup"
        }
        Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
    }
}
