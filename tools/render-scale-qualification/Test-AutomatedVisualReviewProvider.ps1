# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'AutomatedVisualReviewProvider.psm1'
Import-Module $modulePath -Force

function Assert-ProviderTest {
    param([bool]$Condition, [Parameter(Mandatory)][string]$Message)

    if (-not $Condition) { throw $Message }
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
            return [pscustomobject]@{ exitCode = 0; stdout = "codex-cli 9.8.7-test`n"; stderr = ''; timedOut = $false }
        }
        if (($CommandArguments -join '|') -in @('--help', 'exec|--help')) {
            return [pscustomobject]@{ exitCode = 0; stdout = $fakeHelp; stderr = ''; timedOut = $false }
        }
        throw "Unexpected preflight arguments: $($CommandArguments -join ' ')"
    }
    $pwshPath = [IO.Path]::GetFullPath([string](Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    $preflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $fakeCommandAdapter
    Assert-ProviderTest $preflight.ok "The fake preflight did not pass: $($preflight.errors -join ' | ')"
    Assert-ProviderTest ($preflight.version -eq '9.8.7-test') 'The preflight did not preserve the Codex version.'
    Assert-ProviderTest (@($preflight.missingFeatures).Count -eq 0) 'The preflight reported missing required CLI features.'

    $missingFeatureAdapter = {
        param([string]$ExecutablePath, [string[]]$CommandArguments, [int]$TimeoutMilliseconds)

        if (($CommandArguments -join '|') -eq '--version') {
            return [pscustomobject]@{ exitCode = 0; stdout = "codex-cli 9.8.7-test`n"; stderr = ''; timedOut = $false }
        }
        return [pscustomobject]@{ exitCode = 0; stdout = '--ephemeral'; stderr = ''; timedOut = $false }
    }
    $failedPreflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $pwshPath `
        -CommandAdapter $missingFeatureAdapter
    Assert-ProviderTest (-not $failedPreflight.ok) 'A preflight with missing CLI features passed.'
    Assert-ProviderTest (@($failedPreflight.missingFeatures).Count -gt 0) 'Missing CLI features were not reported.'

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
param([Parameter(Mandatory)][string]$EncodedArguments)
$ErrorActionPreference = 'Stop'
$argumentsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedArguments))
$RemainingArguments = [string[]]@($argumentsJson | ConvertFrom-Json -Depth 20)
$responseIndex = [Array]::IndexOf($RemainingArguments, '--output-last-message')
if ($responseIndex -lt 0 -or $responseIndex + 1 -ge $RemainingArguments.Count) { throw 'missing response path' }
$responsePath = $RemainingArguments[$responseIndex + 1]
$imageCount = @($RemainingArguments | Where-Object { $_ -eq '-i' }).Count
$promptText = [Console]::In.ReadToEnd()
$delay = if ($promptText -match 'delay=(?<delay>[0-9]+)') { [int]$Matches.delay } else { 500 }
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
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $fakeExecPath, '-EncodedArguments', $encodedArguments)) {
            [void]$replacement.ArgumentList.Add($argument)
        }
        return $replacement
    }

    $executionRoot = Join-Path $fakeWorkingDirectory 'successful execution'
    New-Item -ItemType Directory -Path $executionRoot | Out-Null
    $passes = New-ProviderTestPasses -Root $executionRoot -SchemaPath $schemaPath `
        -Images @($imageOne, $imageTwo) -PromptSuffix 'delay=500'
    $execution = Invoke-CSXCodexVisualReviewProvider -WorkingDirectory $fakeWorkingDirectory `
        -Passes $passes -Preflight $preflight -DeadlineSeconds 15 `
        -ProcessStartInfoAdapter $fakeProcessAdapter
    $executionStderr = @($execution.batches | ForEach-Object { $_.stderr } | Where-Object { $_ }) -join ' | '
    Assert-ProviderTest $execution.ok "The fake parallel provider execution failed: $($execution.errors -join ' | ') stderr=$executionStderr"
    Assert-ProviderTest (@($execution.batches).Count -eq 6) 'The provider did not return six batch results.'
    Assert-ProviderTest (-not $execution.deadlineReached) 'The successful fake execution reached its deadline.'
    foreach ($batch in $execution.batches) {
        Assert-ProviderTest ($batch.exitCode -eq 0 -and $batch.status -eq 'completed') 'A successful fake batch did not report completion.'
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
    Assert-ProviderTest (@($timeoutExecution.batches | Where-Object { $_.presentationPass -eq 2 -and $_.status -eq 'not_started_deadline' }).Count -eq 3) 'The second presentation pass started after the shared deadline.'

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
