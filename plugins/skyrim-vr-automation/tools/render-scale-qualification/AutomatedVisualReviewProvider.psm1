# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CSXCodexVisualReviewModel = 'gpt-5.6-sol'
$script:CSXCodexModelProbePrompt = 'Reply with READY only.'
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

if (-not ('CSXProviderStreamCapture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public sealed class CSXProviderStreamCapture
{
    private readonly object gate = new object();
    private readonly StringBuilder text = new StringBuilder();
    public Task Completion { get; }

    public CSXProviderStreamCapture(TextReader reader)
    {
        Completion = PumpAsync(reader);
    }

    private async Task PumpAsync(TextReader reader)
    {
        var buffer = new char[4096];
        while (true)
        {
            int count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
            if (count == 0) return;
            lock (gate) text.Append(buffer, 0, count);
        }
    }

    public string Snapshot()
    {
        lock (gate) return text.ToString();
    }
}
'@
}

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
        [Parameter(Mandatory)][int]$TimeoutMilliseconds,
        [switch]$CloseStandardInput
    )

    $workingDirectory = Split-Path -Parent $ExecutablePath
    $startInfo = New-CSXProviderProcessStartInfo -ExecutablePath $ExecutablePath `
        -Arguments $Arguments -WorkingDirectory $workingDirectory `
        -RedirectStandardInput:$CloseStandardInput
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedUtc = [DateTimeOffset]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $processDeadlineMilliseconds = [Math]::Max(1, $TimeoutMilliseconds - [Math]::Min(250, [Math]::Max(50, $TimeoutMilliseconds / 10)))
    $launched = $false
    $processId = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutCapture = $null
    $stderrCapture = $null
    $stdinCloseTask = $null
    $setupError = $null
    $timedOut = $false
    $exitVerified = $false
    $exitCode = $null
    $terminationRequested = $false
    $terminationConfirmed = $false
    $terminationErrors = [Collections.Generic.List[string]]::new()
    $streamDrainComplete = $false
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $launched = $true
        $processId = $process.Id
        $stdoutCapture = [CSXProviderStreamCapture]::new($process.StandardOutput)
        $stderrCapture = [CSXProviderStreamCapture]::new($process.StandardError)
        $stdoutTask = $stdoutCapture.Completion
        $stderrTask = $stderrCapture.Completion
        if ($CloseStandardInput) { $stdinCloseTask = $process.StandardInput.DisposeAsync().AsTask() }
    }
    catch {
        $setupError = $_.Exception.Message
    }

    if ($launched) {
        while ($watch.ElapsedMilliseconds -lt $processDeadlineMilliseconds) {
            try {
                if ($process.HasExited) {
                    $exitVerified = $true
                    $exitCode = $process.ExitCode
                    if ($null -eq $stdoutTask -or $null -eq $stderrTask -or
                        ($stdoutTask.IsCompleted -and $stderrTask.IsCompleted -and
                            ($null -eq $stdinCloseTask -or $stdinCloseTask.IsCompleted))) { break }
                }
            }
            catch { $terminationErrors.Add("Unable to inspect the provider command process: $($_.Exception.Message)"); break }
            [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, $processDeadlineMilliseconds - $watch.ElapsedMilliseconds)))
        }
        if (-not $exitVerified) {
            try {
                if ($process.HasExited) {
                    $exitVerified = $true
                    $exitCode = $process.ExitCode
                }
            }
            catch { $terminationErrors.Add("Unable to inspect the provider command process at its deadline: $($_.Exception.Message)") }
        }
        if (-not $exitVerified) {
            $timedOut = $null -eq $setupError
            $terminationRequested = $true
            try { $process.Kill($true) }
            catch { $terminationErrors.Add("Provider command process-tree termination failed for PID $processId`: $($_.Exception.Message)") }
        }
        while (-not $exitVerified -and $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            try {
                if ($process.HasExited) {
                    $exitVerified = $true
                    $exitCode = $process.ExitCode
                    break
                }
            }
            catch { $terminationErrors.Add("Unable to verify provider command process exit for PID $processId`: $($_.Exception.Message)"); break }
            [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, $TimeoutMilliseconds - $watch.ElapsedMilliseconds)))
        }
        $terminationConfirmed = $terminationRequested -and $exitVerified
        while ($exitVerified -and
            (($null -ne $stdoutTask -and -not $stdoutTask.IsCompleted) -or
                ($null -ne $stderrTask -and -not $stderrTask.IsCompleted) -or
                ($null -ne $stdinCloseTask -and -not $stdinCloseTask.IsCompleted)) -and
            $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, $TimeoutMilliseconds - $watch.ElapsedMilliseconds)))
        }
        $streamDrainComplete = $null -ne $stdoutTask -and $null -ne $stderrTask -and
            $stdoutTask.IsCompletedSuccessfully -and $stderrTask.IsCompletedSuccessfully
        if (-not $streamDrainComplete) {
            $terminationErrors.Add('Provider command stream drain did not complete successfully within the command deadline.')
        }
        if ($null -ne $stdinCloseTask -and -not $stdinCloseTask.IsCompletedSuccessfully) {
            $terminationErrors.Add('Provider command standard-input closure did not complete successfully within the command deadline.')
        }
    }
    $stdout = if ($null -ne $stdoutCapture) { $stdoutCapture.Snapshot() } else { '' }
    $stderr = if ($null -ne $stderrCapture) { $stderrCapture.Snapshot() } else { '' }
    $watch.Stop()
    try {
        return [pscustomobject][ordered]@{
            launched = $launched
            processId = $processId
            exitCode = $exitCode
            stdout = $stdout
            stderr = $stderr
            timedOut = $timedOut
            setupError = $setupError
            exitVerified = $exitVerified
            terminationRequested = $terminationRequested
            terminationConfirmed = $terminationConfirmed
            unresolvedProcess = $launched -and -not $exitVerified
            streamDrainComplete = $streamDrainComplete
            inputCompleted = $null -eq $stdinCloseTask -or $stdinCloseTask.IsCompletedSuccessfully
            terminationErrors = @($terminationErrors)
            startedUtc = $startedUtc.ToString('o')
            completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertTo-CSXProviderProcessEvidence {
    param($Result)

    $exitCode = Get-CSXProviderPropertyValue $Result 'exitCode'
    $timedOut = [bool](Get-CSXProviderPropertyValue $Result 'timedOut' $false)
    $processId = Get-CSXProviderPropertyValue $Result 'processId'
    $launched = [bool](Get-CSXProviderPropertyValue $Result 'launched' ($null -ne $processId))
    $exitVerified = [bool](Get-CSXProviderPropertyValue $Result 'exitVerified' ($null -ne $exitCode -and -not $timedOut))
    return [pscustomobject][ordered]@{
        launched = $launched
        processId = $processId
        exitCode = $exitCode
        timedOut = $timedOut
        setupError = Get-CSXProviderPropertyValue $Result 'setupError'
        exitVerified = $exitVerified
        terminationRequested = [bool](Get-CSXProviderPropertyValue $Result 'terminationRequested' $false)
        terminationConfirmed = [bool](Get-CSXProviderPropertyValue $Result 'terminationConfirmed' $false)
        unresolvedProcess = [bool](Get-CSXProviderPropertyValue $Result 'unresolvedProcess' ($launched -and -not $exitVerified))
        streamDrainComplete = [bool](Get-CSXProviderPropertyValue $Result 'streamDrainComplete' ($null -ne $Result))
        inputCompleted = [bool](Get-CSXProviderPropertyValue $Result 'inputCompleted' ($null -ne $Result))
        terminationErrors = @((Get-CSXProviderPropertyValue $Result 'terminationErrors' @()))
    }
}

function Get-CSXCodexVisualReviewProviderPreflight {
    [CmdletBinding()]
    param(
        [string]$CodexExecutable = 'codex',
        [ValidateRange(100, 15000)][int]$CommandTimeoutMilliseconds = 5000,
        [ValidateRange(1000, 60000)][int]$ModelProbeTimeoutMilliseconds = 30000,
        [scriptblock]$CommandAdapter
    )

    $errors = [Collections.Generic.List[string]]::new()
    $executablePath = $null
    $versionResult = $null
    $rootHelpResult = $null
    $execHelpResult = $null
    $modelProbeResult = $null
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
    $processEvidence = [pscustomobject][ordered]@{
        version = ConvertTo-CSXProviderProcessEvidence $versionResult
        rootHelp = ConvertTo-CSXProviderProcessEvidence $rootHelpResult
        execHelp = ConvertTo-CSXProviderProcessEvidence $execHelpResult
        modelProbe = $null
    }
    if ($null -eq $versionResult) {
        $errors.Add('Codex --version did not return a result.')
    }
    else {
        if ([bool](Get-CSXProviderPropertyValue $versionResult 'timedOut' $false)) {
            $errors.Add('Codex --version timed out.')
        }
        elseif ([int](Get-CSXProviderPropertyValue $versionResult 'exitCode' -1) -ne 0) {
            $errors.Add("Codex --version failed: $(([string](Get-CSXProviderPropertyValue $versionResult 'stderr' '')).Trim())")
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
            $errors.Add("Codex --help failed: $(([string](Get-CSXProviderPropertyValue $rootHelpResult 'stderr' '')).Trim())")
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
            $errors.Add("Codex exec --help failed: $(([string](Get-CSXProviderPropertyValue $execHelpResult 'stderr' '')).Trim())")
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

    if ($errors.Count -eq 0) {
        $modelProbeArguments = [string[]]@(
            '--ask-for-approval', 'never',
            'exec',
            '--ephemeral',
            '--ignore-user-config',
            '--skip-git-repo-check',
            '--sandbox', 'read-only',
            '--json',
            '--model', $script:CSXCodexVisualReviewModel,
            $script:CSXCodexModelProbePrompt
        )
        try {
            if ($CommandAdapter) {
                $modelProbeResult = & $CommandAdapter $executablePath $modelProbeArguments $ModelProbeTimeoutMilliseconds
            }
            else {
                $modelProbeResult = Invoke-CSXProviderCommand -ExecutablePath $executablePath `
                    -Arguments $modelProbeArguments -TimeoutMilliseconds $ModelProbeTimeoutMilliseconds `
                    -CloseStandardInput
            }
            if ($null -eq $modelProbeResult) {
                $errors.Add('Codex model capability probe did not return a result.')
            }
            elseif ([bool](Get-CSXProviderPropertyValue $modelProbeResult 'timedOut' $false)) {
                $errors.Add("Codex model capability probe timed out for '$($script:CSXCodexVisualReviewModel)'.")
            }
            elseif ([int](Get-CSXProviderPropertyValue $modelProbeResult 'exitCode' -1) -ne 0) {
                $probeError = ([string](Get-CSXProviderPropertyValue $modelProbeResult 'stderr' '')).Trim()
                $errors.Add("Codex model capability probe failed for '$($script:CSXCodexVisualReviewModel)': $probeError")
            }
            elseif ([string]::IsNullOrWhiteSpace([string](Get-CSXProviderPropertyValue $modelProbeResult 'stdout' ''))) {
                $errors.Add("Codex model capability probe returned no output for '$($script:CSXCodexVisualReviewModel)'.")
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string](Get-CSXProviderPropertyValue $modelProbeResult 'stderr' ''))) {
                $errors.Add("Codex model capability probe returned stderr for '$($script:CSXCodexVisualReviewModel)'.")
            }
        }
        catch {
            $errors.Add("Codex model capability probe failed for '$($script:CSXCodexVisualReviewModel)': $($_.Exception.Message)")
        }
    }
    $processEvidence.modelProbe = ConvertTo-CSXProviderProcessEvidence $modelProbeResult

    foreach ($commandEvidence in @(
        [pscustomobject]@{ label = 'Codex --version'; value = $processEvidence.version; result = $versionResult },
        [pscustomobject]@{ label = 'Codex --help'; value = $processEvidence.rootHelp; result = $rootHelpResult },
        [pscustomobject]@{ label = 'Codex exec --help'; value = $processEvidence.execHelp; result = $execHelpResult },
        [pscustomobject]@{ label = 'Codex model capability probe'; value = $processEvidence.modelProbe; result = $modelProbeResult }
    )) {
        if ($null -eq $commandEvidence.result) { continue }
        if (-not [bool]$commandEvidence.value.launched) {
            $setupDetail = [string](Get-CSXProviderPropertyValue $commandEvidence.value 'setupError' 'process identity unavailable')
            $errors.Add("$($commandEvidence.label) did not establish a launched process identity: $setupDetail")
        }
        elseif ([bool]$commandEvidence.value.unresolvedProcess) {
            $errors.Add("$($commandEvidence.label) left unresolved process PID $([string]$commandEvidence.value.processId).")
        }
        elseif ([bool]$commandEvidence.value.launched -and -not [bool]$commandEvidence.value.exitVerified) {
            $errors.Add("$($commandEvidence.label) process exit was not verified.")
        }
        if ([bool]$commandEvidence.value.launched -and -not [bool]$commandEvidence.value.streamDrainComplete) {
            $errors.Add("$($commandEvidence.label) stream drain was incomplete.")
        }
        foreach ($terminationError in @($commandEvidence.value.terminationErrors)) {
            $errors.Add("$($commandEvidence.label) cleanup: $terminationError")
        }
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
        model = $script:CSXCodexVisualReviewModel
        processes = $processEvidence
        modelProbe = [pscustomobject][ordered]@{
            attempted = $null -ne $modelProbeResult
            ok = $null -ne $modelProbeResult -and
                -not [bool](Get-CSXProviderPropertyValue $modelProbeResult 'timedOut' $false) -and
                [int](Get-CSXProviderPropertyValue $modelProbeResult 'exitCode' -1) -eq 0 -and
                -not [string]::IsNullOrWhiteSpace([string](Get-CSXProviderPropertyValue $modelProbeResult 'stdout' '')) -and
                [string]::IsNullOrWhiteSpace([string](Get-CSXProviderPropertyValue $modelProbeResult 'stderr' ''))
            timeoutMilliseconds = $ModelProbeTimeoutMilliseconds
            exitCode = Get-CSXProviderPropertyValue $modelProbeResult 'exitCode'
            timedOut = [bool](Get-CSXProviderPropertyValue $modelProbeResult 'timedOut' $false)
            stdoutSha256 = $(
                $probeOutput = [string](Get-CSXProviderPropertyValue $modelProbeResult 'stdout' '')
                if ($probeOutput) { Get-CSXProviderTextSha256 $probeOutput } else { $null }
            )
            stderr = ([string](Get-CSXProviderPropertyValue $modelProbeResult 'stderr' '')).Trim()
            process = $processEvidence.modelProbe
        }
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
        launched = $false
        processId = $null
        exitCode = $null
        timedOut = $true
        exitVerified = $false
        terminationRequested = $false
        terminationConfirmed = $false
        unresolvedProcess = $false
        streamDrainComplete = $false
        inputCompleted = $false
        terminationErrors = @()
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

function Request-CSXProviderContextTermination {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Reason)

    if (-not $Context.launched -or $Context.exitVerified -or $Context.terminationRequested) { return }
    $Context.terminationRequested = $true
    try {
        if ($Context.terminationAdapter) {
            & $Context.terminationAdapter $Context.process $Reason | Out-Null
        }
        else {
            $Context.process.Kill($true)
        }
    }
    catch {
        $Context.terminationErrors.Add("Process-tree termination failed for PID $($Context.processId) ($Reason): $($_.Exception.Message)")
    }
}

function Update-CSXProviderContextState {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch
    )

    if (-not $Context.launched) { return }
    if (-not $Context.exitVerified) {
        try {
            if ($Context.process.HasExited) {
                $Context.exitVerified = $true
                $Context.exitCode = $Context.process.ExitCode
                if ($Context.terminationRequested) { $Context.terminationConfirmed = $true }
            }
        }
        catch {
            $Context.terminationErrors.Add("Unable to verify provider process exit for PID $($Context.processId): $($_.Exception.Message)")
        }
    }
    if ($null -ne $Context.inputTask -and -not $Context.inputCompleted -and -not $Context.inputFailed) {
        if ($Context.inputTask.IsCompletedSuccessfully) {
            if ($null -eq $Context.inputCloseTask) {
                try { $Context.inputCloseTask = $Context.process.StandardInput.DisposeAsync().AsTask() }
                catch {
                    $Context.inputFailed = $true
                    if (-not $Context.setupError) { $Context.setupError = "Standard-input close failed: $($_.Exception.Message)" }
                }
            }
            if ($null -ne $Context.inputCloseTask) {
                if ($Context.inputCloseTask.IsCompletedSuccessfully) { $Context.inputCompleted = $true }
                elseif ($Context.inputCloseTask.IsFaulted -or $Context.inputCloseTask.IsCanceled) {
                    $Context.inputFailed = $true
                    $closeFailure = if ($Context.inputCloseTask.IsFaulted) { $Context.inputCloseTask.Exception.GetBaseException().Message } else { 'input closure was canceled' }
                    if (-not $Context.setupError) { $Context.setupError = "Standard-input close failed: $closeFailure" }
                }
            }
        }
        elseif ($Context.inputTask.IsFaulted -or $Context.inputTask.IsCanceled) {
            $Context.inputFailed = $true
            $inputFailure = if ($Context.inputTask.IsFaulted) { $Context.inputTask.Exception.GetBaseException().Message } else { 'input delivery was canceled' }
            if (-not $Context.setupError) { $Context.setupError = "Standard-input delivery failed: $inputFailure" }
        }
    }
    if ($Context.setupError -and -not $Context.exitVerified) {
        Request-CSXProviderContextTermination -Context $Context -Reason 'post-launch setup failure'
    }
    $tasksSettled = ($null -eq $Context.inputTask -or $Context.inputTask.IsCompleted) -and
        ($null -eq $Context.inputCloseTask -or $Context.inputCloseTask.IsCompleted) -and
        ($null -eq $Context.stdoutTask -or $Context.stdoutTask.IsCompleted) -and
        ($null -eq $Context.stderrTask -or $Context.stderrTask.IsCompleted)
    if ($Context.exitVerified -and $tasksSettled -and $null -eq $Context.completedUtc) {
        $Context.completedUtc = [DateTimeOffset]::UtcNow
        $Context.completedElapsedMs = $Stopwatch.Elapsed.TotalMilliseconds
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
        [scriptblock]$ProcessStartInfoAdapter,
        [scriptblock]$ProcessTerminationAdapter
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
            if ($stopwatch.ElapsedMilliseconds -ge $processDeadlineMilliseconds) {
                $deadlineReached = $true
                $results.Add((New-CSXProviderUnstartedResult -Batch $batch `
                    -PresentationPass $pass.presentationPass -Reason 'The shared provider deadline elapsed before this batch started.' `
                    -CompletedUtc ([DateTimeOffset]::UtcNow)))
                continue
            }
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
                stdoutCapture = $null
                stderrCapture = $null
                inputTask = $null
                inputCloseTask = $null
                inputCompleted = $false
                inputFailed = $false
                launched = $false
                processId = $null
                startedUtc = $startedUtc
                startedElapsedMs = $startedElapsedMs
                completedUtc = $null
                completedElapsedMs = $null
                startError = $null
                setupError = $null
                timedOut = $false
                exitVerified = $false
                exitCode = $null
                terminationRequested = $false
                terminationConfirmed = $false
                terminationErrors = [Collections.Generic.List[string]]::new()
                terminationAdapter = $ProcessTerminationAdapter
            }
            try {
                if (-not $process.Start()) { throw 'Process.Start returned false.' }
                $context.launched = $true
                $context.processId = $process.Id
                if (-not $effectiveStartInfo.RedirectStandardOutput -or
                    -not $effectiveStartInfo.RedirectStandardError -or
                    -not $effectiveStartInfo.RedirectStandardInput) {
                    throw 'Provider process streams are not fully redirected.'
                }
                $context.stdoutCapture = [CSXProviderStreamCapture]::new($process.StandardOutput)
                $context.stderrCapture = [CSXProviderStreamCapture]::new($process.StandardError)
                $context.stdoutTask = $context.stdoutCapture.Completion
                $context.stderrTask = $context.stderrCapture.Completion
                $context.inputTask = $process.StandardInput.WriteAsync($batch.promptText)
            }
            catch {
                if ($context.launched) {
                    $context.setupError = $_.Exception.Message
                    Request-CSXProviderContextTermination -Context $context -Reason 'post-launch setup failure'
                }
                else { $context.startError = $_.Exception.Message }
            }
            $contexts.Add($context)
        }

        while ($true) {
            $allSettled = $true
            foreach ($context in $contexts) {
                Update-CSXProviderContextState -Context $context -Stopwatch $stopwatch
                if ($context.launched -and $null -eq $context.completedUtc) { $allSettled = $false }
            }
            if ($allSettled) { break }
            $remainingMilliseconds = $processDeadlineMilliseconds - $stopwatch.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) {
                $deadlineReached = $true
                break
            }
            [Threading.Thread]::Sleep([int][Math]::Min(20, $remainingMilliseconds))
        }

        if ($deadlineReached) {
            foreach ($context in $contexts) {
                Update-CSXProviderContextState -Context $context -Stopwatch $stopwatch
                if ($context.launched -and $null -eq $context.completedUtc) {
                    $context.timedOut = $true
                    Request-CSXProviderContextTermination -Context $context -Reason 'shared provider deadline'
                }
            }
            while ($stopwatch.ElapsedMilliseconds -lt $budgetMilliseconds) {
                $allCleanupSettled = $true
                foreach ($context in $contexts) {
                    Update-CSXProviderContextState -Context $context -Stopwatch $stopwatch
                    if ($context.launched -and -not $context.exitVerified) { $allCleanupSettled = $false }
                }
                if ($allCleanupSettled) { break }
                [Threading.Thread]::Sleep([int][Math]::Min(10, [Math]::Max(1, $budgetMilliseconds - $stopwatch.ElapsedMilliseconds)))
            }
        }

        foreach ($context in $contexts) {
            Update-CSXProviderContextState -Context $context -Stopwatch $stopwatch
            $batch = $context.batch
            $errors = [Collections.Generic.List[string]]::new()
            $stdout = ''
            $stderr = ''
            $exitCode = $context.exitCode
            if ($context.startError) {
                $errors.Add("Unable to start Codex: $($context.startError)")
            }
            if ($context.setupError) {
                $errors.Add("Codex launched but provider setup failed: $($context.setupError)")
            }
            $stdoutComplete = $null -ne $context.stdoutTask -and $context.stdoutTask.IsCompletedSuccessfully
            $stderrComplete = $null -ne $context.stderrTask -and $context.stderrTask.IsCompletedSuccessfully
            $streamDrainComplete = $stdoutComplete -and $stderrComplete
            if ($null -ne $context.stdoutCapture) { $stdout = $context.stdoutCapture.Snapshot() }
            if ($null -ne $context.stderrCapture) { $stderr = $context.stderrCapture.Snapshot() }
            if (-not $stdoutComplete) { $errors.Add('Codex stdout collection did not complete successfully within the shared provider deadline.') }
            if (-not $stderrComplete) { $errors.Add('Codex stderr collection did not complete successfully within the shared provider deadline.') }
            if ($context.launched -and -not $context.inputCompleted) { $errors.Add('Codex prompt delivery did not complete within the shared provider deadline.') }
            if ($context.launched -and -not $context.exitVerified) { $errors.Add("Codex PID $($context.processId) remains unresolved after owned process-tree termination.") }
            foreach ($terminationError in @($context.terminationErrors)) { $errors.Add($terminationError) }
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
                ok = $errors.Count -eq 0 -and $exitCode -eq 0 -and $context.exitVerified -and $streamDrainComplete -and $context.inputCompleted
                status = $(if ($context.launched -and -not $context.exitVerified) { 'unresolved_process' } elseif ($context.timedOut) { 'timed_out' } elseif ($context.setupError) { 'setup_failed' } elseif ($context.startError) { 'start_failed' } elseif ($errors.Count -gt 0) { 'failed' } else { 'completed' })
                launched = [bool]$context.launched
                processId = $context.processId
                exitCode = $exitCode
                timedOut = [bool]$context.timedOut
                exitVerified = [bool]$context.exitVerified
                terminationRequested = [bool]$context.terminationRequested
                terminationConfirmed = [bool]$context.terminationConfirmed
                unresolvedProcess = [bool]($context.launched -and -not $context.exitVerified)
                streamDrainComplete = [bool]$streamDrainComplete
                inputCompleted = [bool]$context.inputCompleted
                terminationErrors = @($context.terminationErrors)
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
