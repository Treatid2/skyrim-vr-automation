# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
$guide=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'COLOUR-PROBE-COORDINATES.md') -Raw
$pattern='(?s)<!-- coordinate-example -->\s*\x60{3}powershell\r?\n(.*?)\r?\n\x60{3}'
$matchesFound=[regex]::Matches($guide,$pattern)
Check ($matchesFound.Count -eq 1) 'Exactly one repository-owned arithmetic example'
# Execute only the explicit marked example in this trusted repository guide.
$example=& ([scriptblock]::Create($matchesFound[0].Groups[1].Value))
Check ($example.stagingByteOffset -eq 0) 'Right-eye first local pixel addresses staging origin'
Check ($example.absoluteSourcePixel[0] -eq 1512 -and $example.absoluteSourcePixel[1] -eq 0) 'Absolute report adds source origin'
Check ($example.sourcePixel[0] -eq 0 -and $example.sourcePixel[1] -eq 0) 'Original local coordinates preserved'
$cases=@(
    @{origin=@(0,0);local=@(0,0);pitch=128;bpp=4;expectedOffset=0;absolute=@(0,0);width=32;height=8},
    @{origin=@(1512,0);local=@(0,0);pitch=12288;bpp=8;expectedOffset=0;absolute=@(1512,0);width=1512;height=1680},
    @{origin=@(1512,0);local=@(16,3);pitch=12288;bpp=8;expectedOffset=36992;absolute=@(1528,3);width=1512;height=1680},
    @{origin=@(1512,64);local=@(16,3);pitch=12288;bpp=8;expectedOffset=36992;absolute=@(1528,67);width=1512;height=1680}
)
foreach($c in $cases){
    $localX=[uint64]$c.local[0];$localY=[uint64]$c.local[1]
    $offset=$localY*[uint64]$c.pitch+$localX*[uint64]$c.bpp
    $absolute=@(($c.origin[0]+$localX),($c.origin[1]+$localY))
    Check ($localX -lt $c.width -and $localY -lt $c.height) 'Synthetic local coordinates inside crop'
    Check ($c.pitch -ge $c.width*$c.bpp) 'Stride can hold payload and padding'
    Check ($offset -eq $c.expectedOffset) 'Origin-independent padded staging address'
    Check ($absolute[0] -eq $c.absolute[0] -and $absolute[1] -eq $c.absolute[1]) 'Source-resource report includes both origins'
}
[pscustomobject]@{ok=$true;checks=$checks;scope='offline executable documentation and synthetic coordinate arithmetic only; no native execution or scientific qualification'}|ConvertTo-Json -Compress
