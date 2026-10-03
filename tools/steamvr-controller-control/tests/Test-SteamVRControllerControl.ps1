# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\ControllerProtocol.psm1') -Force -PassThru -DisableNameChecking
$script:cases=0
function Check([string]$Name,[scriptblock]$Body){ & $Body; $script:cases++; Write-Output "PASS $Name" }
function Assert($Condition,[string]$Message='assertion failed'){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Body){$rejected=$false;try{& $Body | Out-Null}catch{$rejected=$true};Assert $rejected 'expected rejection'}
function Pair { @{left=(New-ControllerDefaultHand left);right=(New-ControllerDefaultHand right)} }
Check 'default left/right poses and neutral axes' { $p=Convert-ControllerPair (Pair);Assert ($p.left.position[0] -eq -0.25 -and $p.right.position[0] -eq 0.25 -and $p.left.pressed -eq '0') }
Check 'exact UInt64 decimal parsing' { Assert ((Convert-ControllerUInt64 '18446744073709551615') -eq [uint64]::MaxValue);Reject {Convert-ControllerUInt64 '18446744073709551616'} }
Check 'nonce rejects zero and noncanonical values' {foreach($v in @('0','01','+1','1.0',1,$true,$null)){Reject {Convert-ControllerUInt64 $v -Nonzero}}}
Check 'fresh cryptographic owner/writer nonces' { $a=New-ControllerNonce;$b=New-ControllerNonce;Assert ($a -ne 0 -and $b -ne 0 -and $a -ne $b) }
Check 'whole-pair and unknown-field rejection' {Reject {Convert-ControllerPair @{left=(New-ControllerDefaultHand left)}};$p=Pair;$p.extra=1;Reject {Convert-ControllerPair $p}}
Check 'strict numeric kind, length and finite range' {
    foreach($v in @($true,'1',$null,[double]::NaN,[double]::PositiveInfinity,1001.0)){ $h=New-ControllerDefaultHand left;$h.position[0]=$v;Reject {Convert-ControllerHand $h} }
    $h=New-ControllerDefaultHand left;$h.position=@(0,1);Reject {Convert-ControllerHand $h}
}
Check 'quaternion boundary and normalization contract' {
    foreach($q in @(0.5,2.0,0.0)){ $h=New-ControllerDefaultHand left;$h.quaternion=@($q,0,0,0);Reject {Convert-ControllerHand $h} }
    $h=New-ControllerDefaultHand left;$h.quaternion=@(1.5,0,0,0);$null=Convert-ControllerHand $h
}
Check 'button masks independent and only documented bits' {
    $h=New-ControllerDefaultHand left;$h.pressed='30064771079';$h.touched='4294967296';$c=Convert-ControllerHand $h;Assert ($c.pressed -eq '30064771079' -and $c.touched -eq '4294967296')
    $h.pressed='8';Reject {Convert-ControllerHand $h};$h.pressed='18446744073709551615';Reject {Convert-ControllerHand $h}
}
Check 'axis boundaries and wrong kinds' {foreach($key in @('trigger','grip')){$h=New-ControllerDefaultHand left;$h[$key]=1.0;$null=Convert-ControllerHand $h;$h[$key]=1.01;Reject {Convert-ControllerHand $h}};$h=New-ControllerDefaultHand left;$h.stick=@(-1,1);$null=Convert-ControllerHand $h;$h.trackpad=@(-1.1,0);Reject {Convert-ControllerHand $h}}
Check 'convenience neutral release retains both poses and clears all controls' {
    $p=Pair;$p.left.position=@(3,4,5);$p.right.quaternion=@(1.5,0,0,0);$p.left.pressed='8589934592';$p.left.touched='4';$p.left.trigger=0.5;$p.right.stick=@(-1,1)
    Assert (-not (Test-ControllerNeutral $p));$r=Clear-ControllerInputs $p;Assert ((Test-ControllerNeutral $r) -and $r.left.position[0] -eq 3 -and $r.right.quaternion[0] -eq 1.5 -and $p.left.trigger -eq 0.5)
}
Check 'ownership does not permit foreign reset or set' { Assert-ControllerOwner @{activeOwner='0'} 11;Assert-ControllerOwner @{activeOwner='11'} 11;Reject {Assert-ControllerOwner @{activeOwner='12'} 11} }
Check 'process identity fail-closed without vrserver' {Reject {Assert-ControllerIdentity @{driverNonce='1';creatorPid=$PID;creatorFileTime=([uint64](Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc()).ToString()} $null}}
$mapping=[IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew("Local\CSXVRControllerFixture-$([guid]::NewGuid().ToString('N'))",1304)
$view=$mapping.CreateViewAccessor(0,1304)
try {
    $view.Write(0,[uint32]0x43585343);$view.Write(4,[uint16]1);$view.Write(6,[uint16]1304)
    $view.Write(32,[uint64]123);$view.Write(40,[uint64]456);$view.Write(48,[uint32]789)
    $view.Write(360,[uint64]12);$view.Write(368,[uint64]345);$view.Write(376,[uint64]2);$view.Write(392,[uint32]1)
    Write-ControllerHand $view 400 (New-ControllerDefaultHand left);Write-ControllerHand $view 528 (New-ControllerDefaultHand right)
    Write-ControllerAtomic $view 56 2
    Check 'native 1304-byte offsets and reserved zeroes' {
        $s=Read-ControllerSnapshot $view;Assert ($s.creatorPid -eq 789 -and $s.creatorFileTime -eq '456' -and $s.driverNonce -eq '123' -and $s.activeOwner -eq '12' -and $s.pair.right.position[0] -eq 0.25)
        for($i=0;$i -lt 4;$i++){Assert ($view.ReadUInt64(400+96+8*$i) -eq 0)}
    }
    Check 'bit-exact interlocked high-bit sequence read/write' {Write-ControllerAtomic $view 8 ([uint64]::MaxValue-1);Assert ((Read-ControllerAtomic $view 8) -eq ([uint64]::MaxValue-1));Write-ControllerAtomic $view 8 0}
    Check 'hand pack/read round trip' {$h=New-ControllerDefaultHand right;$h.pressed='8589934592';$h.touched='17179869184';$h.trackpad=@(0.25,-0.5);$h.trigger=0.75;Write-ControllerHand $view 232 $h;$r=Read-ControllerHand $view 232;Assert ($r.pressed -eq '8589934592' -and $r.touched -eq '17179869184' -and $r.trigger -eq 0.75 -and $r.trackpad[1] -eq -0.5)}
    Check 'incompatible header rejects before telemetry use' {$view.Write(4,[uint16]2);Reject {Read-ControllerSnapshot $view};$view.Write(4,[uint16]1)}
    Check 'torn or unpublished telemetry is bounded failure' {Write-ControllerAtomic $view 56 1;Reject {Read-ControllerSnapshot $view};Write-ControllerAtomic $view 56 0;Reject {Read-ControllerSnapshot $view};Write-ControllerAtomic $view 56 2}
    Check 'haptic ring exact overwrite and scoped cursor' {
        $s=@{driverNonce='123';hapticSequence='20';haptics=@(5..20 | ForEach-Object {@{sequence=$_.ToString()}})}
        $h=Get-ControllerHaptics $s @{driverNonce='123';sequence='2'};Assert ($h.overwritten -eq '2' -and $h.events.Count -eq 16 -and $h.cursor.sequence -eq '20')
        Reject {Get-ControllerHaptics $s @{driverNonce='124';sequence='2'}};Reject {Get-ControllerHaptics $s @{driverNonce='123';sequence='21'}}
    }
    Check 'haptic cursor preserves integers beyond double precision' {
        [uint64]$n=9007199254741009;$s=@{driverNonce='123';hapticSequence=$n.ToString();haptics=@(1..16 | ForEach-Object {@{sequence=($n-16+$_).ToString()}})}
        $h=Get-ControllerHaptics $s @{driverNonce='123';sequence=($n-1).ToString()};Assert ($h.events.Count -eq 1 -and $h.overwritten -eq '0')
    }
    Check 'missing haptic event cannot claim lossless delivery' {Reject {Get-ControllerHaptics @{driverNonce='123';hapticSequence='1';haptics=@()} $null}}
    Check 'duplicate haptic entries cannot hide a missing sequence' {Reject {Get-ControllerHaptics @{driverNonce='123';hapticSequence='2';haptics=@(@{sequence='2'},@{sequence='2'})} $null}}
    # Run the production command publisher against an anonymous view. Replace
    # ONLY native process/telemetry fixtures inside this test's module instance.
    & $module {
        param($v)
        function script:Assert-ControllerIdentity($State,$Binding) {}
        $script:fixtureView=$v;$script:fixtureMode='applied'
        function script:Read-ControllerSnapshot($View) {
            $q=Read-ControllerAtomic $View 8
            $n=$View.ReadUInt64(72)
            if($script:fixtureMode -eq 'timeout'){$q=0;$n=0}
            @{driverNonce='123';creatorPid=789;creatorFileTime='456';activeOwner='0';deadlineTickMs='0';pair=@{left=(New-ControllerDefaultHand left);right=(New-ControllerDefaultHand right)};appliedSequence=$q.ToString();acknowledgedWriterNonce=$n.ToString();acceptedSequence=$q.ToString();status=$(if($script:fixtureMode -eq 'rejected'){3}else{1});inputHealthy=($script:fixtureMode -ne 'unhealthy')}
        }
    } $view
    Check 'publication exact pair, sequence, nonce, deadline and success ack' {
        $d=(Get-ControllerTick)+5000;$r=Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) $d 0 100
        Assert ($r.ok -and $r.requestedSequence -eq '2' -and $view.ReadUInt64(64) -eq 11 -and $view.ReadUInt64(80) -eq $d -and $view.ReadUInt64(88) -eq 123 -and $view.ReadUInt32(100) -eq 0 -and $r.gameConsumed -eq $false)
    }
    Check 'rejected exact ack is not acceptance' {& $module {$script:fixtureMode='rejected'};$r=Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) ((Get-ControllerTick)+5000) 0 100;Assert (-not $r.ok -and $r.state -eq 'controller-rejected')}
    Check 'unhealthy publication cannot acknowledge success' {& $module {$script:fixtureMode='unhealthy'};$r=Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) ((Get-ControllerTick)+5000) 0 100;Assert (-not $r.ok)}
    Check 'ack timeout indeterminate never replays' {& $module {$script:fixtureMode='timeout'};$before=Read-ControllerAtomic $view 8;$r=Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) ((Get-ControllerTick)+5000) 0 100;Assert (-not $r.ok -and $r.indeterminate -and -not $r.retryAllowed -and (Read-ControllerAtomic $view 8) -eq $before+2)}
    Check 'expired/future command rejects before publication' {foreach($d in @((Get-ControllerTick),((Get-ControllerTick)+70000))){$before=Read-ControllerAtomic $view 8;Reject {Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) $d 0 100};Assert ((Read-ControllerAtomic $view 8) -eq $before)}}
    Check 'sequence exhaustion refuses wrap' {Write-ControllerAtomic $view 8 ([uint64]::MaxValue-1);Reject {Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) ((Get-ControllerTick)+5000) 0 100};Write-ControllerAtomic $view 8 0}
    Check 'owned reset zero deadline and fresh exact nonce beyond double precision' {
        & $module {$script:fixtureMode='applied'};Write-ControllerAtomic $view 8 9007199254740994
        $r=Send-ControllerCommand $view @{driverNonce='123'} 11 (Pair) 0 1 100
        Assert ($r.ok -and $r.requestedSequence -eq '9007199254740996' -and $view.ReadUInt64(80) -eq 0 -and $view.ReadUInt32(96) -eq 1)
    }
    Check 'neutral-release expiry requires exact accepted sequence and health' {
        $seq=(Read-ControllerAtomic $view 8).ToString();$r=Wait-ControllerRelease $view @{driverNonce='123'} $seq (Get-ControllerTick) 25;Assert $r.ok
        Reject {Wait-ControllerRelease $view @{driverNonce='123'} '2' (Get-ControllerTick) 25}
        & $module {$script:fixtureMode='unhealthy'};$r=Wait-ControllerRelease $view @{driverNonce='123'} $seq (Get-ControllerTick) 25;Assert (-not $r.ok -and $r.state -eq 'controller-release-expiry-unobserved')
    }
} finally {$view.Dispose();$mapping.Dispose();Remove-Module $module}
$entry=Join-Path $PSScriptRoot '..\Invoke-SteamVRControllerControl.ps1'
Check 'public new-owner creates identity without acquiring runtime lease' {$r=& $entry new-owner -NoExit -Compact | ConvertFrom-Json;Assert ($r.ok -and $r.state -eq 'controller-owner-created' -and -not $r.data.leaseAcquired -and [uint64]$r.data.ownerNonce -ne 0)}
Check 'public mutating commands reject missing requests before opening runtime' {foreach($c in @('set','tap','sequence','reset')){$r=& $entry $c -NoExit -Compact | ConvertFrom-Json;Assert (-not $r.ok -and $r.state -eq 'controller-error' -and -not $r.data.retryAllowed)}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) "csx-controller-requests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    function Run-Invalid([string]$Command,$Request){
        $path=Join-Path $fixture 'request.json';[IO.File]::WriteAllText($path,($Request | ConvertTo-Json -Depth 20))
        $r=& $entry $Command -RequestPath $path -NoExit -Compact | ConvertFrom-Json
        Assert (-not $r.ok -and $r.state -eq 'controller-error' -and -not $r.data.retryAllowed) 'must reject before native mapping open'
    }
    function Bound { @{binding=@{creatorPid=1;creatorFileTime='1';driverNonce='1'};ownerNonce='1'} }
    Check 'public strict fields reject before dispatch' {$r=Bound;$r.force=$true;Run-Invalid reset $r}
    Check 'public set lease requires bounded integer' {foreach($n in @(1,100.5,$true,'500',60001)){$r=Bound;$r.pair=Pair;$r.leaseMilliseconds=$n;Run-Invalid set $r}}
    Check 'public set requires complete pair' {$r=Bound;$r.leaseMilliseconds=500;$r.pair=@{left=(New-ControllerDefaultHand left)};Run-Invalid set $r}
    Check 'public tap duration and names validated before dispatch' {foreach($button in @('TRIGGER','garbage',1)){$r=Bound;$r.hand='left';$r.button=$button;$r.holdMilliseconds=50;Run-Invalid tap $r};$r=Bound;$r.hand='right';$r.button='trigger';$r.holdMilliseconds=0;Run-Invalid tap $r}
    Check 'public sequence validates all frames and total ack budget' {$r=Bound;$r.frames=@(1..8 | ForEach-Object {@{pair=(Pair);holdMilliseconds=10000}});Run-Invalid sequence $r;$r.frames=@(@{pair=(Pair);holdMilliseconds=10},@{pair=@{};holdMilliseconds=10});Run-Invalid sequence $r}
    Check 'public identity and owner reject wrong kinds' {$r=Bound;$r.ownerNonce=1;Run-Invalid reset $r;$r=Bound;$r.binding.creatorPid=1.5;Run-Invalid reset $r}
    Check 'request schema parses and validates reset shape' { $schema=Join-Path $PSScriptRoot '..\request.schema.json';Assert (Test-Json -Json ((Bound)|ConvertTo-Json -Depth 10) -SchemaFile $schema) }
} finally {
    # Exactly this test-created, canonical temp directory; never production data.
    $resolved=[IO.Path]::GetFullPath($fixture);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture escaped temp root.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "RESULT $script:cases cases passed; offline only; no SteamVR/game/probe/mapping publication."
