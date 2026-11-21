# SPDX-License-Identifier: GPL-3.0-or-later
param([Parameter(Mandatory)][string]$PlanPath, [Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$references = @('System.Drawing.Common.dll', 'System.Private.Windows.GdiPlus.dll',
    'System.Drawing.Primitives.dll', 'System.Private.Windows.Core.dll') |
    ForEach-Object { Join-Path $PSHOME $_ } | Where-Object { Test-Path -LiteralPath $_ }
$references += [AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object { $_.Location -and (Test-Path -LiteralPath $_.Location) } | ForEach-Object Location
Add-Type -Path (Join-Path $PSScriptRoot 'ImageMetrics.cs') -ReferencedAssemblies ($references | Sort-Object -Unique)
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$rows = foreach ($job in $plan) {
    $regions = @($job.regions | ForEach-Object {
        $region = [ImageRegion]::new()
        foreach ($property in $_.PSObject.Properties) { $region.($property.Name) = $property.Value }
        $region
    })
    $analyzer = [ImageMetrics]::new($job.width, $job.height, [ImageRegion[]]$regions)
    foreach ($frame in $job.frames) {
        foreach ($metric in $analyzer.Measure($frame.path)) {
            [pscustomobject]@{
                view = $job.view; kind = $job.kind; ordinal = $frame.ordinal
                timestampUs = $frame.timestampUs; eye = $metric.Eye; region = $metric.Zone
                samples = $metric.Samples
                meanLuma = $metric.MeanLuma.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                edgeContrast = $metric.EdgeContrast.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                previousMeanAbsDiff = if ($null -ne $metric.PreviousMeanAbsDiff) {
                    $metric.PreviousMeanAbsDiff.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                } else { '' }
            }
        }
    }
}
$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
