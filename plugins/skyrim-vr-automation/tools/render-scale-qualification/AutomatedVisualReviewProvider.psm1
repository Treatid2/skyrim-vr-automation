# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CSXCodexVisualReviewModel = 'gpt-5.6-sol'
$script:CSXCodexRequiredRootHelpFeatures = @(
    '--ask-for-approval'
)
$script:CSXCodexRequiredExecHelpFeatures = @(
    '--ephemeral',
    '--ignore-user-config',
    '--skip-git-repo-check',
    '--sandbox',
    '--json',
    '--output-schema',
    '--output-last-message',
    '--image',
    '--model'
)

function Get-CSXProviderPropertyValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        return $(if ($InputObject.Contains($Name)) { $InputObject[$Name] } else { $Default })
    }
    $property = $InputObject.PSObject.Properties[$Name]
    return $(if ($property) { $property.Value } else { $Default })
}

function Get-CSXProviderTextSha256 {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-CSXProviderFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-CSXCodexExecutablePath {
    param([Parameter(Mandatory)][string]$CodexExecutable)

    if ([string]::IsNullOrWhiteSpace($CodexExecutable)) {
        throw 'The Codex executable cannot be empty.'
    }
    if ([IO.Path]::IsPathFullyQualified($CodexExecutable)) {
        $resolved = [IO.Path]::GetFullPath($CodexExecutable)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "The Codex executable does not exist: $resolved"
        }
        return $resolved
    }

    $command = Get-Command -Name $CodexExecutable -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        throw "Unable to resolve the Codex executable '$CodexExecutable'."
    }
    return [IO.Path]::GetFullPath([string]$command.Source)
}

function Resolve-CSXProviderInputFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be an absolute path."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "$Label does not exist: $fullPath"
    }
    return $fullPath
}

function Resolve-CSXProviderOutputFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "$Label must be an absolute path."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Label parent directory does not exist: $parent"
    }
    if (Test-Path -LiteralPath $fullPath) {
        throw "$Label already exists and will not be overwritten: $fullPath"
    }
    return $fullPath
}

function New-CSXProviderProcessStartInfo {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$RedirectStandardInput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = [bool]$RedirectStandardInput
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($RedirectStandardInput) {
        $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    }
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    return $startInfo
}

function Invoke-CSXProviderCommand {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $workingDirectory = Split-Path -Parent $ExecutablePath
    $startInfo = New-CSXProviderProcessStartInfo -ExecutablePath $ExecutablePath `
        -Arguments $Arguments -WorkingDirectory $workingDirectory
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedUtc = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) {
            try { $process.Kill($true) } catch { }
            [void]$process.WaitForExit(1000)
        }
        if ($process.HasExited) { $process.WaitForExit() }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject][ordered]@{
            exitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null })
            stdout = $stdout
            stderr = $stderr
            timedOut = $timedOut
            startedUtc = $startedUtc.ToString('o')
            completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-CSXCodexVisualReviewProviderPreflight {
    [CmdletBinding()]
    param(
        [string]$CodexExecutable = 'codex',
        [ValidateRange(100, 15000)][int]$CommandTimeoutMilliseconds = 5000,
        [scriptblock]$CommandAdapter
    )

    $errors = [Collections.Generic.List[string]]::new()
    $executablePath = $null
    $versionResult = $null
    $rootHelpResult = $null
    $execHelpResult = $null
    try {
        $executablePath = Resolve-CSXCodexExecutablePath -CodexExecutable $CodexExecutable
        if ($CommandAdapter) {
            $versionResult = & $CommandAdapter $executablePath ([string[]]@('--version')) $CommandTimeoutMilliseconds
            $rootHelpResult = & $CommandAdapter $executablePath ([string[]]@('--help')) $CommandTimeoutMilliseconds
            $execHelpResult = & $CommandAdapter $executablePath ([string[]]@('exec', '--help')) $CommandTimeoutMilliseconds
        }
        else {
            $versionResult = Invoke-CSXProviderCommand -ExecutablePath $executablePath `
                -Arguments @('--version') -TimeoutMilliseconds $CommandTimeoutMilliseconds
            $rootHelpResult = Invoke-CSXProviderCommand -ExecutablePath $executablePath `
                -Arguments @('--help') -TimeoutMilliseconds $CommandTimeoutMilliseconds
            $execHelpResult = Invoke-CSXProviderCommand -ExecutablePath $executablePath `
                -Arguments @('exec', '--help') -TimeoutMilliseconds $CommandTimeoutMilliseconds
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    $versionText = [string](Get-CSXProviderPropertyValue $versionResult 'stdout' '')
    $rootHelpText = [string](Get-CSXProviderPropertyValue $rootHelpResult 'stdout' '')
    $execHelpText = [string](Get-CSXProviderPropertyValue $execHelpResult 'stdout' '')
    if ($null -eq $versionResult) {
        $errors.Add('Codex --version did not return a result.')
    }
    else {
        if ([bool](Get-CSXProviderPropertyValue $versionResult 'timedOut' $false)) {
            $errors.Add('Codex --version timed out.')
        }
        elseif ([int](Get-CSXProviderPropertyValue $versionResult 'exitCode' -1) -ne 0) {
            $errors.Add("Codex --version failed: $([string](Get-CSXProviderPropertyValue $versionResult 'stderr' '')).Trim()")
        }
        elseif ($versionText -notmatch '(?m)^codex-cli\s+(?<version>\S+)\s*$') {
            $errors.Add('Codex --version did not return a codex-cli version identifier.')
        }
    }
    if ($null -eq $rootHelpResult) {
        $errors.Add('Codex --help did not return a result.')
    }
    else {
        if ([bool](Get-CSXProviderPropertyValue $rootHelpResult 'timedOut' $false)) {
            $errors.Add('Codex --help timed out.')
        }
        elseif ([int](Get-CSXProviderPropertyValue $rootHelpResult 'exitCode' -1) -ne 0) {
            $errors.Add("Codex --help failed: $([string](Get-CSXProviderPropertyValue $rootHelpResult 'stderr' '')).Trim()")
        }
    }
    if ($null -eq $execHelpResult) {
        $errors.Add('Codex exec --help did not return a result.')
    }
    else {
        if ([bool](Get-CSXProviderPropertyValue $execHelpResult 'timedOut' $false)) {
            $errors.Add('Codex exec --help timed out.')
        }
        elseif ([int](Get-CSXProviderPropertyValue $execHelpResult 'exitCode' -1) -ne 0) {
            $errors.Add("Codex exec --help failed: $([string](Get-CSXProviderPropertyValue $execHelpResult 'stderr' '')).Trim()")
        }
    }

    $features = [ordered]@{}
    $missingFeatures = [Collections.Generic.List[string]]::new()
    foreach ($feature in $script:CSXCodexRequiredRootHelpFeatures) {
        $present = $rootHelpText.Contains($feature, [StringComparison]::Ordinal)
        $features[$feature] = $present
        if (-not $present) { $missingFeatures.Add($feature) }
    }
    foreach ($feature in $script:CSXCodexRequiredExecHelpFeatures) {
        $present = $execHelpText.Contains($feature, [StringComparison]::Ordinal)
        $features[$feature] = $present
        if (-not $present) { $missingFeatures.Add($feature) }
    }
    if ($missingFeatures.Count -gt 0) {
        $errors.Add("Codex exec --help omits required features: $($missingFeatures -join ', ')")
    }

    $version = $null
    if ($versionText -match '(?m)^codex-cli\s+(?<version>\S+)\s*$') {
        $version = $Matches.version
    }
    return [pscustomobject][ordered]@{
        schema = 'csx-codex-visual-review-preflight-v1'
        ok = $errors.Count -eq 0
        executablePath = $executablePath
        version = $version
        versionText = $versionText.Trim()
        versionSha256 = $(if ($versionText) { Get-CSXProviderTextSha256 $versionText } else { $null })
        rootHelpSha256 = $(if ($rootHelpText) { Get-CSXProviderTextSha256 $rootHelpText } else { $null })
        execHelpSha256 = $(if ($execHelpText) { Get-CSXProviderTextSha256 $execHelpText } else { $null })
        features = [pscustomobject]$features
        missingFeatures = @($missingFeatures)
        errors = @($errors)
    }
}

function New-CSXCodexVisualReviewProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodexExecutablePath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string[]]$Images,
        [Parameter(Mandatory)][string]$OutputSchemaPath,
        [Parameter(Mandatory)][string]$ResponsePath
    )

    if (-not [IO.Path]::IsPathFullyQualified($CodexExecutablePath)) {
        throw 'CodexExecutablePath must be absolute.'
    }
    $executablePath = Resolve-CSXCodexExecutablePath -CodexExecutable $CodexExecutablePath
    if (-not [IO.Path]::IsPathFullyQualified($WorkingDirectory)) {
        throw 'WorkingDirectory must be absolute.'
    }
    $workingDirectoryPath = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $workingDirectoryPath -PathType Container)) {
        throw "WorkingDirectory does not exist: $workingDirectoryPath"
    }
    if ([string]::IsNullOrWhiteSpace($PromptText)) { throw 'PromptText cannot be empty.' }
    if (@($Images).Count -eq 0) { throw 'At least one image is required.' }

    $schemaPath = Resolve-CSXProviderInputFile -Path $OutputSchemaPath -Label 'OutputSchemaPath'
    $responseFile = Resolve-CSXProviderOutputFile -Path $ResponsePath -Label 'ResponsePath'
    $resolvedImages = [Collections.Generic.List[string]]::new()
    $imageSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($image in @($Images)) {
        $resolvedImage = Resolve-CSXProviderInputFile -Path ([string]$image) -Label 'Image'
        if (-not $imageSet.Add($resolvedImage)) { throw "The image list contains a duplicate path: $resolvedImage" }
        $resolvedImages.Add($resolvedImage)
    }

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '--ask-for-approval', 'never',
        'exec',
        '--ephemeral',
        '--ignore-user-config',
        '--skip-git-repo-check',
        '--sandbox', 'read-only',
        '--json',
        '--output-schema', $schemaPath,
        '--output-last-message', $responseFile,
        '--model', $script:CSXCodexVisualReviewModel
    )) {
        $arguments.Add([string]$argument)
    }
    foreach ($image in $resolvedImages) {
        $arguments.Add('-i')
        $arguments.Add($image)
    }
    $arguments.Add('-')

    $startInfo = New-CSXProviderProcessStartInfo -ExecutablePath $executablePath `
        -Arguments @($arguments) -WorkingDirectory $workingDirectoryPath -RedirectStandardInput
    $startInfo | Add-Member -NotePropertyName CSXPromptText -NotePropertyValue $PromptText
    $startInfo | Add-Member -NotePropertyName CSXPromptSha256 -NotePropertyValue (Get-CSXProviderTextSha256 $PromptText)
    $startInfo | Add-Member -NotePropertyName CSXArguments -NotePropertyValue ([string[]]@($arguments))
    $startInfo | Add-Member -NotePropertyName CSXImagePaths -NotePropertyValue ([string[]]@($resolvedImages))
    $startInfo | Add-Member -NotePropertyName CSXOutputSchemaPath -NotePropertyValue $schemaPath
    $startInfo | Add-Member -NotePropertyName CSXResponsePath -NotePropertyValue $responseFile
    return $startInfo
}

function Write-CSXProviderNewTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][Parameter(Mandatory)][string]$Text
    )

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function ConvertFrom-CSXProviderJsonLines {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Text)

    $records = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $lineNumber = 0
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json -Depth 100)) }
        catch { $errors.Add("stdout line $lineNumber is not JSON: $($_.Exception.Message)") }
    }
    return [pscustomobject][ordered]@{ records = @($records); errors = @($errors) }
}

function New-CSXProviderUnstartedResult {
    param(
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][int]$PresentationPass,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][DateTimeOffset]$CompletedUtc
    )

    return [pscustomobject][ordered]@{
        presentationPass = $PresentationPass
        replicate = [int]$Batch.replicate
        ok = $false
        status = 'not_started_deadline'
        processId = $null
        exitCode = $null
        timedOut = $true
        startedUtc = $null
        completedUtc = $CompletedUtc.ToString('o')
        durationMs = 0
        promptSha256 = [string]$Batch.promptSha256
        imageBindings = @($Batch.imageBindings)
        outputSchemaPath = [string]$Batch.outputSchemaPath
        responsePath = [string]$Batch.responsePath
        eventsPath = [string]$Batch.eventsPath
        stdout = ''
        stdoutJsonl = @()
        stderr = ''
        response = $null
        responseText = ''
        responseSha256 = $null
        eventsSha256 = $null
        errors = @($Reason)
    }
}

function Invoke-CSXCodexVisualReviewProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][object[]]$Passes,
        [string]$CodexExecutable = 'codex',
        $Preflight,
        [ValidateRange(1, 90)][int]$DeadlineSeconds = 90,
        [scriptblock]$PreflightCommandAdapter,
        [scriptblock]$ProcessStartInfoAdapter
    )

    if (-not [IO.Path]::IsPathFullyQualified($WorkingDirectory)) {
        throw 'WorkingDirectory must be absolute.'
    }
    $workingDirectoryPath = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $workingDirectoryPath -PathType Container)) {
        throw "WorkingDirectory does not exist: $workingDirectoryPath"
    }
    if ($null -eq $Preflight) {
        $Preflight = Get-CSXCodexVisualReviewProviderPreflight -CodexExecutable $CodexExecutable `
            -CommandAdapter $PreflightCommandAdapter
    }
    if (-not [bool](Get-CSXProviderPropertyValue $Preflight 'ok' $false)) {
        throw "Codex visual-review provider preflight failed: $(@(Get-CSXProviderPropertyValue $Preflight 'errors' @()) -join ' | ')"
    }
    $executablePath = Resolve-CSXCodexExecutablePath -CodexExecutable `
        ([string](Get-CSXProviderPropertyValue $Preflight 'executablePath'))

    $passList = @($Passes)
    if ($passList.Count -ne 2) { throw 'Passes must contain exactly two presentation passes.' }
    $normalizedPasses = [Collections.Generic.List[object]]::new()
    $allOutputPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($passIndex = 0; $passIndex -lt 2; $passIndex++) {
        $pass = $passList[$passIndex]
        $presentationPass = [int](Get-CSXProviderPropertyValue $pass 'presentationPass' 0)
        if ($presentationPass -ne $passIndex + 1) {
            throw "Presentation pass at index $passIndex must have presentationPass $($passIndex + 1)."
        }
        $batches = @(Get-CSXProviderPropertyValue $pass 'batches' @())
        if ($batches.Count -ne 3) { throw "Presentation pass $presentationPass must contain exactly three batches." }
        $normalizedBatches = [Collections.Generic.List[object]]::new()
        for ($batchIndex = 0; $batchIndex -lt 3; $batchIndex++) {
            $batch = $batches[$batchIndex]
            $replicate = [int](Get-CSXProviderPropertyValue $batch 'replicate' 0)
            if ($replicate -ne $batchIndex + 1) {
                throw "Presentation pass $presentationPass batch at index $batchIndex must have replicate $($batchIndex + 1)."
            }
            $promptText = [string](Get-CSXProviderPropertyValue $batch 'promptText' '')
            $images = [string[]]@(Get-CSXProviderPropertyValue $batch 'images' @())
            $outputSchemaPath = [string](Get-CSXProviderPropertyValue $batch 'outputSchemaPath' '')
            $responsePath = [string](Get-CSXProviderPropertyValue $batch 'responsePath' '')
            $eventsPath = Resolve-CSXProviderOutputFile `
                -Path ([string](Get-CSXProviderPropertyValue $batch 'eventsPath' '')) `
                -Label "Presentation pass $presentationPass replicate $replicate eventsPath"
            $startInfo = New-CSXCodexVisualReviewProcessStartInfo -CodexExecutablePath $executablePath `
                -WorkingDirectory $workingDirectoryPath -PromptText $promptText -Images $images `
                -OutputSchemaPath $outputSchemaPath -ResponsePath $responsePath
            foreach ($outputPath in @([string]$startInfo.CSXResponsePath, $eventsPath)) {
                if (-not $allOutputPaths.Add($outputPath)) {
                    throw "Provider output paths must be unique across all batches: $outputPath"
                }
            }
            $imageBindings = foreach ($imagePath in @($startInfo.CSXImagePaths)) {
                $item = Get-Item -LiteralPath $imagePath
                [pscustomobject][ordered]@{
                    path = $imagePath
                    byteLength = [uint64]$item.Length
                    sha256 = Get-CSXProviderFileSha256 $imagePath
                }
            }
            $normalizedBatches.Add([pscustomobject][ordered]@{
                replicate = $replicate
                promptText = $promptText
                promptSha256 = [string]$startInfo.CSXPromptSha256
                imageBindings = @($imageBindings)
                outputSchemaPath = [string]$startInfo.CSXOutputSchemaPath
                responsePath = [string]$startInfo.CSXResponsePath
                eventsPath = $eventsPath
                startInfo = $startInfo
            })
        }
        $normalizedPasses.Add([pscustomobject][ordered]@{
            presentationPass = $presentationPass
            batches = @($normalizedBatches)
        })
    }

    $executionStartedUtc = [DateTimeOffset]::UtcNow
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $budgetMilliseconds = [int64]$DeadlineSeconds * 1000
    $terminationReserveMilliseconds = [int64][Math]::Min(1000, [Math]::Max(100, $budgetMilliseconds / 10))
    $processDeadlineMilliseconds = $budgetMilliseconds - $terminationReserveMilliseconds
    $results = [Collections.Generic.List[object]]::new()
    $deadlineReached = $false

    foreach ($pass in $normalizedPasses) {
        if ($stopwatch.ElapsedMilliseconds -ge $processDeadlineMilliseconds) {
            $deadlineReached = $true
            foreach ($batch in $pass.batches) {
                $results.Add((New-CSXProviderUnstartedResult -Batch $batch `
                    -PresentationPass $pass.presentationPass -Reason 'The shared provider deadline elapsed before this batch started.' `
                    -CompletedUtc ([DateTimeOffset]::UtcNow)))
            }
            continue
        }

        $contexts = [Collections.Generic.List[object]]::new()
        foreach ($batch in $pass.batches) {
            $startedUtc = [DateTimeOffset]::UtcNow
            $startedElapsedMs = $stopwatch.Elapsed.TotalMilliseconds
            $process = [Diagnostics.Process]::new()
            $effectiveStartInfo = $batch.startInfo
            if ($ProcessStartInfoAdapter) {
                $effectiveStartInfo = & $ProcessStartInfoAdapter $batch.startInfo $pass.presentationPass $batch.replicate
                if ($effectiveStartInfo -isnot [Diagnostics.ProcessStartInfo]) {
                    throw 'ProcessStartInfoAdapter must return System.Diagnostics.ProcessStartInfo.'
                }
            }
            $process.StartInfo = $effectiveStartInfo
            $context = [pscustomobject][ordered]@{
                batch = $batch
                process = $process
                stdoutTask = $null
                stderrTask = $null
                processId = $null
                startedUtc = $startedUtc
                startedElapsedMs = $startedElapsedMs
                completedUtc = $null
                completedElapsedMs = $null
                startError = $null
                timedOut = $false
            }
            try {
                if (-not $process.Start()) { throw 'Process.Start returned false.' }
                $context.processId = $process.Id
                $context.stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $context.stderrTask = $process.StandardError.ReadToEndAsync()
                $process.StandardInput.Write($batch.promptText)
                $process.StandardInput.Close()
            }
            catch {
                $context.startError = $_.Exception.Message
                try { if (-not $process.HasExited) { $process.Kill($true) } } catch { }
            }
            $contexts.Add($context)
        }

        while ($true) {
            $allExited = $true
            foreach ($context in $contexts) {
                if ($context.startError) { continue }
                if (-not $context.process.HasExited) {
                    $allExited = $false
                    continue
                }
                if ($null -eq $context.completedUtc) {
                    $context.completedUtc = [DateTimeOffset]::UtcNow
                    $context.completedElapsedMs = $stopwatch.Elapsed.TotalMilliseconds
                }
            }
            if ($allExited) { break }
            $remainingMilliseconds = $processDeadlineMilliseconds - $stopwatch.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) {
                $deadlineReached = $true
                break
            }
            [Threading.Thread]::Sleep([int][Math]::Min(20, $remainingMilliseconds))
        }

        if ($deadlineReached) {
            foreach ($context in $contexts) {
                if ($context.startError -or $context.process.HasExited) { continue }
                $context.timedOut = $true
                try { $context.process.Kill($true) } catch { }
            }
        }

        foreach ($context in $contexts) {
            $batch = $context.batch
            $errors = [Collections.Generic.List[string]]::new()
            $stdout = ''
            $stderr = ''
            $exitCode = $null
            if ($context.startError) {
                $errors.Add("Unable to start Codex: $($context.startError)")
            }
            else {
                if (-not $context.process.HasExited) {
                    $remainingCleanupMilliseconds = [Math]::Max(0, $budgetMilliseconds - $stopwatch.ElapsedMilliseconds)
                    if ($remainingCleanupMilliseconds -gt 0) {
                        [void]$context.process.WaitForExit([int][Math]::Min(250, $remainingCleanupMilliseconds))
                    }
                }
                if ($context.process.HasExited) {
                    $context.process.WaitForExit()
                    $exitCode = $context.process.ExitCode
                    if ($null -eq $context.completedUtc) {
                        $context.completedUtc = [DateTimeOffset]::UtcNow
                        $context.completedElapsedMs = $stopwatch.Elapsed.TotalMilliseconds
                    }
                    $stdout = $context.stdoutTask.GetAwaiter().GetResult()
                    $stderr = $context.stderrTask.GetAwaiter().GetResult()
                }
                else {
                    $errors.Add('Codex did not exit after its owned process was terminated.')
                }
            }
            if ($context.timedOut) { $errors.Add('The shared provider deadline elapsed while this batch was running.') }
            if ($null -ne $exitCode -and $exitCode -ne 0) { $errors.Add("Codex exited with code $exitCode.") }

            $jsonLines = ConvertFrom-CSXProviderJsonLines -Text $stdout
            foreach ($parseError in $jsonLines.errors) { $errors.Add($parseError) }
            $eventsSha256 = $null
            try {
                Write-CSXProviderNewTextFile -Path $batch.eventsPath -Text $stdout
                $eventsSha256 = Get-CSXProviderFileSha256 $batch.eventsPath
            }
            catch { $errors.Add("Unable to preserve Codex JSONL events: $($_.Exception.Message)") }

            $responseText = ''
            $response = $null
            $responseSha256 = $null
            if (Test-Path -LiteralPath $batch.responsePath -PathType Leaf) {
                try {
                    $responseText = [IO.File]::ReadAllText($batch.responsePath, [Text.Encoding]::UTF8)
                    $responseSha256 = Get-CSXProviderFileSha256 $batch.responsePath
                    $response = $responseText | ConvertFrom-Json -Depth 100
                }
                catch { $errors.Add("Codex response is not valid JSON: $($_.Exception.Message)") }
            }
            else { $errors.Add('Codex did not write its schema-constrained response file.') }

            if ($null -eq $context.completedUtc) {
                $context.completedUtc = [DateTimeOffset]::UtcNow
                $context.completedElapsedMs = $stopwatch.Elapsed.TotalMilliseconds
            }
            $durationMs = [Math]::Max(0, [double]$context.completedElapsedMs - [double]$context.startedElapsedMs)
            $results.Add([pscustomobject][ordered]@{
                presentationPass = [int]$pass.presentationPass
                replicate = [int]$batch.replicate
                ok = $errors.Count -eq 0 -and $exitCode -eq 0
                status = $(if ($context.timedOut) { 'timed_out' } elseif ($context.startError) { 'start_failed' } elseif ($errors.Count -gt 0) { 'failed' } else { 'completed' })
                processId = $context.processId
                exitCode = $exitCode
                timedOut = [bool]$context.timedOut
                startedUtc = $context.startedUtc.ToString('o')
                completedUtc = $context.completedUtc.ToString('o')
                durationMs = [Math]::Round($durationMs, 3)
                promptSha256 = [string]$batch.promptSha256
                imageBindings = @($batch.imageBindings)
                outputSchemaPath = [string]$batch.outputSchemaPath
                responsePath = [string]$batch.responsePath
                eventsPath = [string]$batch.eventsPath
                stdout = $stdout
                stdoutJsonl = @($jsonLines.records)
                stderr = $stderr
                response = $response
                responseText = $responseText
                responseSha256 = $responseSha256
                eventsSha256 = $eventsSha256
                errors = @($errors)
            })
            $context.process.Dispose()
        }
    }
    $stopwatch.Stop()
    $executionCompletedUtc = [DateTimeOffset]::UtcNow
    $orderedResults = @($results | Sort-Object presentationPass, replicate)
    return [pscustomobject][ordered]@{
        schema = 'csx-codex-visual-review-execution-v1'
        ok = $orderedResults.Count -eq 6 -and @($orderedResults | Where-Object { -not $_.ok }).Count -eq 0
        provider = 'codex_cli'
        model = $script:CSXCodexVisualReviewModel
        preflight = $Preflight
        deadlineSeconds = $DeadlineSeconds
        deadlineReached = $deadlineReached
        startedUtc = $executionStartedUtc.ToString('o')
        completedUtc = $executionCompletedUtc.ToString('o')
        durationMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        batches = $orderedResults
        errors = @($orderedResults | ForEach-Object { $_.errors } | Select-Object -Unique)
    }
}

Export-ModuleMember -Function @(
    'Get-CSXCodexVisualReviewProviderPreflight',
    'New-CSXCodexVisualReviewProcessStartInfo',
    'Invoke-CSXCodexVisualReviewProvider'
)
