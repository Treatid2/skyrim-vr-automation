# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$entrypoint = Join-Path $PSScriptRoot 'Start-CSXRenderScaleQualification.ps1'

function Assert-EntrypointFailure {
    param(
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$ExpectedError
    )

    $text = & $entrypoint @Arguments -NoExit -Compact | Out-String
    $result = $text | ConvertFrom-Json -Depth 20
    if ([string]$result.status -ne 'INFRASTRUCTURE_ERROR') {
        throw "Entrypoint did not fail closed: $text"
    }
    if ($ExpectedError -notin @($result.errors)) {
        throw "Entrypoint did not report '$ExpectedError': $text"
    }
}

$buildId = 'a' * 64
$baselineError = 'Baseline inputs require -PrMode; local qualification cannot silently ignore them.'
Assert-EntrypointFailure -Arguments @{ BaselinePath = 'C:\baseline' } -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{ ExpectedBaselineBuildId = $buildId } -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{
    BaselinePath = 'C:\baseline'
    ExpectedBaselineBuildId = $buildId
} -ExpectedError $baselineError
Assert-EntrypointFailure -Arguments @{ PrMode = $true } `
    -ExpectedError 'PR mode requires -BaselinePath and -ExpectedBaselineBuildId.'

'Render-scale qualification entrypoint tests passed.'
