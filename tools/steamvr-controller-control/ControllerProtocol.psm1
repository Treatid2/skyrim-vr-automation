# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Runtime interop, as in head-pose-control; no repository-local native build.
if (-not ('SkyrimVRAutomation.ControllerAtomics' -as [type])) {
    Add-Type -CompilerOptions '/unsafe' -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using Microsoft.Win32.SafeHandles;
namespace SkyrimVRAutomation {
 public static unsafe class ControllerAtomics {
  public static ulong Read(SafeMemoryMappedViewHandle h, long off, long field) {
   bool held=false; h.DangerousAddRef(ref held);
   try { return unchecked((ulong)Interlocked.Read(ref *(long*)((byte*)h.DangerousGetHandle()+off+field))); }
   finally { if(held) h.DangerousRelease(); }
  }
  public static void Exchange(SafeMemoryMappedViewHandle h, long off, long field, ulong v) {
   bool held=false; h.DangerousAddRef(ref held);
   try { Interlocked.Exchange(ref *(long*)((byte*)h.DangerousGetHandle()+off+field),unchecked((long)v)); }
   finally { if(held) h.DangerousRelease(); }
  }
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  [StructLayout(LayoutKind.Sequential)] struct SA { public int length; public IntPtr descriptor; public int inherit; }
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s, uint rev, out IntPtr p, out uint bytes);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateMutexEx(ref SA sa, string name, uint flags, uint access);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr p,uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReleaseMutex(IntPtr p);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr p);
  public static IntPtr Lock(uint ms) {
   IntPtr sd; uint n; string sid=WindowsIdentity.GetCurrent().User.Value;
   if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;GA;;;"+sid+")",1,out sd,out n)) throw new Win32Exception();
   IntPtr h;
   try { var sa=new SA {length=Marshal.SizeOf<SA>(),descriptor=sd}; h=CreateMutexEx(ref sa,"Local\\CSXVRControllersWriter-v1",0,0x00100001); }
   finally { LocalFree(sd); }
   if(h==IntPtr.Zero) throw new Win32Exception();
   uint r=WaitForSingleObject(h,ms);
   if(r==0 || r==0x80) return h;
   CloseHandle(h);
   if(r==0x102) throw new TimeoutException("controller-writer-busy");
   throw new Win32Exception();
  }
  public static void Unlock(IntPtr h) { try { if(!ReleaseMutex(h)) throw new Win32Exception(); } finally { CloseHandle(h); } }
 }
}
'@
}

function Get-ControllerTick { [SkyrimVRAutomation.ControllerAtomics]::GetTickCount64() }
function Read-ControllerAtomic($View, [long]$Offset) {
    [SkyrimVRAutomation.ControllerAtomics]::Read($View.SafeMemoryMappedViewHandle, $View.PointerOffset, $Offset)
}
function Write-ControllerAtomic($View, [long]$Offset, [uint64]$Value) {
    [SkyrimVRAutomation.ControllerAtomics]::Exchange($View.SafeMemoryMappedViewHandle, $View.PointerOffset, $Offset, $Value)
}
function New-ControllerNonce {
    $bytes = [byte[]]::new(8)
    do { [Security.Cryptography.RandomNumberGenerator]::Fill($bytes); $n = [BitConverter]::ToUInt64($bytes) } while ($n -eq 0)
    $n
}
function Assert-ControllerKeys($Object, [string[]]$Keys, [string]$Label) {
    if ($Object -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object." }
    foreach ($key in $Object.Keys) { if ($key -cnotin $Keys) { throw "Unknown $Label field: $key" } }
}
function Convert-ControllerNumber($Value, [double]$Min, [double]$Max) {
    if ($Value -is [bool] -or $Value -is [string] -or $null -eq $Value -or $Value -is [System.Collections.IEnumerable]) { throw 'A finite JSON number is required.' }
    $n = [double]$Value
    if (-not [double]::IsFinite($n) -or $n -lt $Min -or $n -gt $Max) { throw "Number outside [$Min,$Max]." }
    $n
}
function Convert-ControllerUInt64($Value, [switch]$Nonzero) {
    # Canonical decimal strings preserve all bits across JavaScript/JSON clients.
    if ($Value -isnot [string] -or $Value -cnotmatch '^(0|[1-9][0-9]{0,19})$') { throw 'UInt64 values must be canonical decimal strings.' }
    $n = [uint64]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($Nonzero -and $n -eq 0) { throw 'A nonzero nonce is required.' }
    $n
}
function Convert-ControllerHand($Hand) {
    Assert-ControllerKeys $Hand @('position','quaternion','pressed','touched','trackpad','trigger','grip','stick') 'hand'
    foreach ($key in @('position','quaternion','pressed','touched','trackpad','trigger','grip','stick')) {
        if (-not $Hand.Contains($key)) { throw "Missing hand field: $key" }
    }
    $result = [ordered]@{}
    foreach ($item in @(@('position',3,-1000,1000),@('quaternion',4,-2,2),@('trackpad',2,-1,1),@('stick',2,-1,1))) {
        $key=$item[0]; $values=$Hand[$key]
        if ($values -isnot [array] -or $values.Count -ne $item[1]) { throw "$key requires exactly $($item[1]) numbers." }
        $result[$key] = @($values | ForEach-Object { Convert-ControllerNumber $_ $item[2] $item[3] })
    }
    $norm = 0.0; foreach ($q in $result.quaternion) { $norm += $q*$q }
    if ($norm -le 0.25 -or $norm -ge 4) { throw 'Quaternion squared norm must be strictly between 0.25 and 4.' }
    foreach ($key in @('pressed','touched')) {
        $mask = Convert-ControllerUInt64 $Hand[$key]
        if (($mask -bor [uint64]30064771079) -ne [uint64]30064771079) { throw 'Unsupported button mask.' }
        $result[$key] = $mask.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    foreach ($key in @('trigger','grip')) { $result[$key] = Convert-ControllerNumber $Hand[$key] 0 1 }
    $result
}
function New-ControllerDefaultHand([string]$Hand) {
    [ordered]@{ position=@($(if($Hand -eq 'left'){-0.25}else{0.25}),1.25,-0.35); quaternion=@(1.0,0.0,0.0,0.0); pressed='0'; touched='0'; trackpad=@(0.0,0.0); trigger=0.0; grip=0.0; stick=@(0.0,0.0) }
}
function Convert-ControllerPair($Pair) {
    Assert-ControllerKeys $Pair @('left','right') 'pair'
    if (-not $Pair.Contains('left') -or -not $Pair.Contains('right')) { throw 'Both full hand snapshots are required.' }
    [ordered]@{ left=(Convert-ControllerHand $Pair.left); right=(Convert-ControllerHand $Pair.right) }
}
function Write-ControllerHand($View, [long]$Offset, $Hand) {
    for ($i=0; $i -lt 3; $i++) { $View.Write($Offset+8*$i,[double]$Hand.position[$i]) }
    for ($i=0; $i -lt 4; $i++) { $View.Write($Offset+24+8*$i,[double]$Hand.quaternion[$i]) }
    $View.Write($Offset+56,[uint64]$Hand.pressed); $View.Write($Offset+64,[uint64]$Hand.touched)
    $values=@($Hand.trackpad[0],$Hand.trackpad[1],$Hand.trigger,$Hand.grip,$Hand.stick[0],$Hand.stick[1])
    for($i=0;$i -lt 6;$i++) { $View.Write($Offset+72+4*$i,[single]$values[$i]) }
    for($i=0;$i -lt 4;$i++) { $View.Write($Offset+96+8*$i,[uint64]0) }
}
function Read-ControllerHand($View, [long]$Offset) {
    [ordered]@{
        position=@($View.ReadDouble($Offset),$View.ReadDouble($Offset+8),$View.ReadDouble($Offset+16))
        quaternion=@($View.ReadDouble($Offset+24),$View.ReadDouble($Offset+32),$View.ReadDouble($Offset+40),$View.ReadDouble($Offset+48))
        pressed=$View.ReadUInt64($Offset+56).ToString(); touched=$View.ReadUInt64($Offset+64).ToString()
        trackpad=@($View.ReadSingle($Offset+72),$View.ReadSingle($Offset+76)); trigger=$View.ReadSingle($Offset+80)
        grip=$View.ReadSingle($Offset+84); stick=@($View.ReadSingle($Offset+88),$View.ReadSingle($Offset+92))
    }
}
function Read-ControllerSnapshot($View) {
    if ($View.ReadUInt32(0) -ne 0x43585343 -or $View.ReadUInt16(4) -ne 1 -or $View.ReadUInt16(6) -ne 1304) { throw 'controller-protocol-mismatch' }
    for($attempt=0;$attempt -lt 20;$attempt++) {
        $first=Read-ControllerAtomic $View 56
        if ($first -eq 0 -or ($first -band 1) -ne 0) { [Threading.Thread]::Sleep(1); continue }
        $s=[ordered]@{
            creatorPid=$View.ReadUInt32(48); creatorFileTime=$View.ReadUInt64(40).ToString(); driverNonce=$View.ReadUInt64(32).ToString()
            telemetrySequence=$first.ToString(); appliedSequence=(Read-ControllerAtomic $View 16).ToString()
            acknowledgedWriterNonce=$View.ReadUInt64(24).ToString(); status=$View.ReadUInt32(52)
            activeOwner=$View.ReadUInt64(360).ToString(); deadlineTickMs=$View.ReadUInt64(368).ToString()
            acceptedSequence=$View.ReadUInt64(376).ToString(); expirationCount=$View.ReadUInt64(384).ToString()
            inputHealthy=$View.ReadUInt32(392) -eq 1
            pair=[ordered]@{left=(Read-ControllerHand $View 400);right=(Read-ControllerHand $View 528)}
            hapticSequence=$View.ReadUInt64(656).ToString(); haptics=@()
        }
        for($i=0;$i -lt 16;$i++) {
            $o=664+40*$i; $seq=$View.ReadUInt64($o)
            if($seq -eq 0) {continue}
            $s.haptics+=@([ordered]@{sequence=$seq.ToString();hand=$View.ReadUInt32($o+8);durationSeconds=$View.ReadSingle($o+16);frequencyHz=$View.ReadSingle($o+20);amplitude=$View.ReadSingle($o+24);tickMs=$View.ReadUInt64($o+32).ToString()})
        }
        [Threading.Thread]::MemoryBarrier()
        if($first -eq (Read-ControllerAtomic $View 56)) { return $s }
    }
    throw 'controller-telemetry-busy'
}
function Assert-ControllerIdentity($State, $Binding) {
    if ($State.driverNonce -eq '0' -or $State.creatorPid -eq 0 -or $State.creatorFileTime -eq '0') { throw 'controller-instance-unidentified' }
    try { $process=Get-Process -Id $State.creatorPid -ErrorAction Stop } catch { throw 'controller-instance-expired' }
    try {
        if($process.ProcessName -cne 'vrserver' -or [uint64]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [uint64]$State.creatorFileTime -or $process.HasExited) { throw 'controller-instance-expired' }
    } finally { $process.Dispose() }
    if($null -ne $Binding -and ($Binding.creatorPid -ne $State.creatorPid -or $Binding.creatorFileTime -cne $State.creatorFileTime -or $Binding.driverNonce -cne $State.driverNonce)) { throw 'controller-instance-changed' }
}
function Assert-ControllerOwner($State, [uint64]$Owner) {
    if($State.activeOwner -ne '0' -and [uint64]$State.activeOwner -ne $Owner) { throw 'controller-owner-busy' }
}
function Test-ControllerNeutral($Pair) {
    foreach($h in @('left','right')) {
        if($Pair[$h].pressed -ne '0' -or $Pair[$h].touched -ne '0' -or $Pair[$h].trigger -ne 0 -or $Pair[$h].grip -ne 0) { return $false }
        foreach($axis in @($Pair[$h].trackpad+$Pair[$h].stick)) { if($axis -ne 0){return $false} }
    }
    return $true
}
function Clear-ControllerInputs($Pair) {
    $neutral=Convert-ControllerPair $Pair
    foreach($h in @('left','right')) {
        $neutral[$h].pressed=$neutral[$h].touched='0'
        $neutral[$h].trackpad=@(0.0,0.0);$neutral[$h].stick=@(0.0,0.0)
        $neutral[$h].trigger=$neutral[$h].grip=0.0
    }
    return $neutral
}
function Wait-ControllerRelease($View, $Binding, [string]$AcceptedSequence, [uint64]$Deadline, [int]$Timeout) {
    $until=$Deadline+[uint64]$Timeout
    do {
        $s=Read-ControllerSnapshot $View;Assert-ControllerIdentity $s $Binding
        if($s.acceptedSequence -cne $AcceptedSequence) { throw 'controller-release-state-changed' }
        if($s.activeOwner -eq '0' -and $s.deadlineTickMs -eq '0' -and $s.inputHealthy -and (Test-ControllerNeutral $s.pair)) {
            return @{ok=$true;state='controller-release-expiry-observed';observed=$s;gameConsumed=$false}
        }
        [Threading.Thread]::Sleep(5)
    } while((Get-ControllerTick) -lt $until)
    return @{ok=$false;state='controller-release-expiry-unobserved';observed=$s;retryAllowed=$false;gameConsumed=$false}
}
function Get-ControllerHaptics($State, $Cursor) {
    [uint64]$after=0
    if($null -ne $Cursor) {
        Assert-ControllerKeys $Cursor @('driverNonce','sequence') 'haptic cursor'
        $null=Convert-ControllerUInt64 $Cursor.driverNonce -Nonzero
        $after=Convert-ControllerUInt64 $Cursor.sequence
        if($Cursor.driverNonce -cne $State.driverNonce) { throw 'controller-haptic-cursor-instance-changed' }
    }
    [uint64]$latest=$State.hapticSequence
    if($after -gt $latest) { throw 'controller-haptic-cursor-ahead' }
    [uint64]$floor=if($latest -gt 16){$latest-16}else{0}
    [uint64]$lost=if($after -lt $floor){$floor-$after}else{0}
    [uint64]$start=if($after -gt $floor){$after}else{$floor}
    $events=@($State.haptics | Where-Object { [uint64]$_.sequence -gt $start -and [uint64]$_.sequence -le $latest } | Sort-Object { [uint64]$_.sequence })
    if($events.Count -ne ($latest-$start)) { throw 'controller-haptic-ring-inconsistent' }
    for($i=0;$i -lt $events.Count;$i++) {
        if([uint64]$events[$i].sequence -ne $start+[uint64]$i+1) { throw 'controller-haptic-ring-inconsistent' }
    }
    [ordered]@{cursor=[ordered]@{driverNonce=$State.driverNonce;sequence=$latest.ToString()};overwritten=$lost.ToString();events=$events;physicalVibration=$false}
}
function Send-ControllerCommand($View, $Binding, [uint64]$Owner, $Pair, [uint64]$Deadline, [uint32]$Flags, [int]$AckTimeout) {
    $current=Read-ControllerSnapshot $View
    Assert-ControllerIdentity $current $Binding; Assert-ControllerOwner $current $Owner
    $pairChecked=Convert-ControllerPair $Pair
    [uint64]$now=Get-ControllerTick
    if($Flags -eq 0 -and ($Deadline -le $now -or $Deadline-$now -gt 60000)) { throw 'controller-command-expired' }
    [uint64]$base=Read-ControllerAtomic $View 8
    if($base -gt ([uint64]::MaxValue-3)) { throw 'controller-sequence-exhausted' }
    if(($base -band 1) -ne 0) { $base++ } # abandoned writer; never reuse its sequence
    [uint64]$sequence=$base+2; $nonce=New-ControllerNonce
    Write-ControllerAtomic $View 8 ($base+1)
    $View.Write(64,$Owner);$View.Write(72,$nonce);$View.Write(80,$Deadline);$View.Write(88,[uint64]$Binding.driverNonce)
    $View.Write(96,$Flags);$View.Write(100,[uint32]0)
    Write-ControllerHand $View 104 $pairChecked.left; Write-ControllerHand $View 232 $pairChecked.right
    [Threading.Thread]::MemoryBarrier(); Write-ControllerAtomic $View 8 $sequence
    $until=(Get-ControllerTick)+[uint64]$AckTimeout
    $observed=$null
    do {
        try { $observed=Read-ControllerSnapshot $View } catch { if($_.Exception.Message -ne 'controller-telemetry-busy'){throw} }
        if($null -ne $observed) {
            Assert-ControllerIdentity $observed $Binding
            if([uint64]$observed.appliedSequence -eq $sequence -and [uint64]$observed.acknowledgedWriterNonce -eq $nonce) {
                $accepted=$observed.status -eq 1 -and $observed.inputHealthy -and [uint64]$observed.acceptedSequence -eq $sequence
                return [ordered]@{ok=$accepted;state=$(if($accepted){'controller-applied'}else{'controller-rejected'});requestedSequence=$sequence.ToString();writerNonce=$nonce.ToString();observed=$observed;gameConsumed=$false}
            }
        }
        [Threading.Thread]::Sleep(5)
    } while((Get-ControllerTick) -lt $until)
    [ordered]@{ok=$false;state='controller-acknowledgement-timeout';requestedSequence=$sequence.ToString();writerNonce=$nonce.ToString();observed=$observed;indeterminate=$true;retryAllowed=$false;gameConsumed=$false}
}
Export-ModuleMember -Function *-Controller*
