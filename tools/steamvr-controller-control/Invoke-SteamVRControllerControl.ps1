# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('inspect','new-owner','set','reset','tap','sequence')][string]$Command='inspect',
    [string]$RequestPath,
    [ValidateRange(100,10000)][int]$AcknowledgementTimeoutMilliseconds=2000,
    [ValidateRange(100,10000)][int]$WriterLockTimeoutMilliseconds=2000,
    [switch]$Compact,
    [switch]$NoExit
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$mapping=$null; $view=$null; $mutex=[IntPtr]::Zero; $receipts=@()
$result=[ordered]@{schemaVersion='steamvr.controllers.result.1';command=$Command;ok=$false;state='controller-error';timestampUtc=[DateTime]::UtcNow.ToString('o');errors=@();data=$null}
try {
    if($PSVersionTable.PSVersion.Major -lt 7 -or -not [Environment]::Is64BitProcess) { throw 'PowerShell 7 x64 is required.' }
    Import-Module (Join-Path $PSScriptRoot 'ControllerProtocol.psm1') -Force -DisableNameChecking
    if($Command -eq 'new-owner') {
        if($RequestPath) {throw 'new-owner does not accept a request.'}
        $result.ok=$true;$result.state='controller-owner-created';$result.data=@{ownerNonce=(New-ControllerNonce).ToString();leaseAcquired=$false}
    } else {
        $request=$null;$binding=$null;$owner=[uint64]0;$frames=@();$lease=0;$cursor=$null
        if($RequestPath) {
            $info=Get-Item -LiteralPath $RequestPath
            if($info.PSIsContainer -or $info.Length -gt 262144){throw 'Request must be a JSON file no larger than 256 KiB.'}
            $request=Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -AsHashtable
        }
        if($Command -eq 'inspect') {
            if($null -ne $request) { Assert-ControllerKeys $request @('cursor') 'inspect request'; if($request.Contains('cursor')){$cursor=$request.cursor} }
        } else {
            Assert-ControllerKeys $request @('binding','ownerNonce','leaseMilliseconds','pair','hand','button','holdMilliseconds','frames') 'request'
            Assert-ControllerKeys $request.binding @('creatorPid','creatorFileTime','driverNonce') 'binding'
            $pidNumber=Convert-ControllerNumber $request.binding.creatorPid 1 ([uint32]::MaxValue)
            if($pidNumber -ne [Math]::Floor($pidNumber)){throw 'creatorPid must be an integer.'}
            $null=Convert-ControllerUInt64 $request.binding.creatorFileTime -Nonzero
            $null=Convert-ControllerUInt64 $request.binding.driverNonce -Nonzero
            $binding=$request.binding
            $owner=Convert-ControllerUInt64 $request.ownerNonce -Nonzero
            $allowed=@('binding','ownerNonce')
            switch($Command) {
                set {
                    $allowed+=@('pair','leaseMilliseconds')
                    $n=Convert-ControllerNumber $request.leaseMilliseconds 100 60000
                    if($n -ne [Math]::Floor($n)){throw 'Lease milliseconds must be an integer.'};$lease=[int]$n
                    $frames=@(@{pair=(Convert-ControllerPair $request.pair);wait=0})
                }
                tap {
                    $allowed+=@('hand','button','holdMilliseconds')
                    if($request.hand -cnotin @('left','right')){throw 'hand must be left or right.'}
                    $buttons=@{system=0;application_menu=1;grip=2;trackpad=32;trigger=33;thumbstick=34}
                    if($request.button -isnot [string] -or $request.button -cnotin $buttons.Keys){throw 'Unsupported button name.'}
                    $n=Convert-ControllerNumber $request.holdMilliseconds 1 10000
                    if($n -ne [Math]::Floor($n)){throw 'holdMilliseconds must be an integer.'}
                    $lease=[int]$n+2*$AcknowledgementTimeoutMilliseconds+1000
                    $frames=@(@{pair=$null;wait=[int]$n})
                }
                sequence {
                    $allowed+=@('frames')
                    if($request.frames -isnot [array] -or $request.frames.Count -lt 1 -or $request.frames.Count -gt 128){throw 'Sequence requires 1..128 frames.'}
                    [long]$total=0
                    foreach($frame in $request.frames) {
                        Assert-ControllerKeys $frame @('pair','holdMilliseconds') 'frame'
                        $n=Convert-ControllerNumber $frame.holdMilliseconds 0 10000
                        if($n -ne [Math]::Floor($n)){throw 'holdMilliseconds must be an integer.'}
                        $total+=[long]$n
                        $frames+=@(@{pair=(Convert-ControllerPair $frame.pair);wait=[int]$n})
                    }
                    $lease=$total+($frames.Count+1)*$AcknowledgementTimeoutMilliseconds+1000
                    if($lease -gt 60000){throw 'Sequence worst-case duration including all acknowledgements must fit 60 seconds.'}
                }
            }
            Assert-ControllerKeys $request $allowed "$Command request"
        }
        # Never CreateOrOpen: a missing provider cannot become a synthetic runtime.
        $mapping=[IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting('Local\CSXVRControllers-v1',[IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
        $view=$mapping.CreateViewAccessor(0,1304,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        if($Command -ne 'inspect') { $mutex=[SkyrimVRAutomation.ControllerAtomics]::Lock([uint32]$WriterLockTimeoutMilliseconds) }
        $state=Read-ControllerSnapshot $view; Assert-ControllerIdentity $state $binding
        if($Command -eq 'inspect') {
            $result.ok=$true;$result.state='controller-inspected'
            $result.data=[ordered]@{binding=@{creatorPid=$state.creatorPid;creatorFileTime=$state.creatorFileTime;driverNonce=$state.driverNonce};provider=$state;haptics=(Get-ControllerHaptics $state $cursor);gameConsumed=$false}
        } else {
            Assert-ControllerOwner $state $owner
            $defaultPair=[ordered]@{left=(New-ControllerDefaultHand left);right=(New-ControllerDefaultHand right)}
            $receipts=@();$deadline=[uint64]0
            if($Command -eq 'tap') {
                # A tap must not borrow pressed controls belonging to an earlier call.
                if(-not (Test-ControllerNeutral $state.pair)){throw 'Tap requires a neutral pair; inspect/set/reset explicitly first.'}
                $tapPair=Convert-ControllerPair $state.pair
                $tapPair[$request.hand].pressed=([uint64]1 -shl $buttons[$request.button]).ToString()
                $frames[0].pair=$tapPair
            }
            if($Command -ne 'reset'){ $deadline=(Get-ControllerTick)+[uint64]$lease }
            $allAccepted=$true
            if($Command -eq 'reset') {
                $receipts+=@(Send-ControllerCommand $view $binding $owner $defaultPair 0 1 $AcknowledgementTimeoutMilliseconds)
                $allAccepted=$receipts[-1].ok
            } else {
                foreach($frame in $frames) {
                    $receipt=Send-ControllerCommand $view $binding $owner $frame.pair $deadline 0 $AcknowledgementTimeoutMilliseconds
                    $receipts+=@($receipt)
                    if(-not $receipt.ok){$allAccepted=$false;break}
                    if($frame.wait -gt 0){[Threading.Thread]::Sleep($frame.wait)}
                }
                if($allAccepted -and $Command -in @('tap','sequence')) {
                    # Convenience release clears inputs without teleporting either
                    # hand. Only the explicit reset command restores default poses.
                    $neutral=Clear-ControllerInputs $receipts[-1].observed.pair
                    $releaseDeadline=(Get-ControllerTick)+[uint64]100
                    $receipts+=@(Send-ControllerCommand $view $binding $owner $neutral $releaseDeadline 0 $AcknowledgementTimeoutMilliseconds)
                    $allAccepted=$receipts[-1].ok
                    if($allAccepted) {
                        $releaseSequence=$receipts[-1].requestedSequence
                        $receipts+=@(Wait-ControllerRelease $view $binding $releaseSequence $releaseDeadline $AcknowledgementTimeoutMilliseconds)
                        $allAccepted=$receipts[-1].ok
                    }
                }
            }
            $result.ok=$allAccepted
            $result.state=if($allAccepted){"controller-$Command-complete"}else{$receipts[-1].state}
            $cleanup=if($allAccepted -and $Command -eq 'reset'){'owned-reset-acknowledged'}elseif($allAccepted -and $Command -in @('tap','sequence')){'neutral-release-acknowledged-and-native-expiry-observed; poses-retained'}else{'native-lease-expiry; inspect before any further command'}
            $result.data=[ordered]@{receipts=$receipts;leaseDeadlineTickMs=$deadline.ToString();cleanup=$cleanup;gameConsumed=$false}
        }
    }
} catch {
    $cause=$_.Exception.GetBaseException()
    $result.ok=$false;$result.state='controller-error';$result.errors=@($cause.Message)
    if($cause -is [IO.FileNotFoundException]){$result.state='controller-provider-unavailable'}
    elseif($cause -is [UnauthorizedAccessException] -or ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 5)){$result.state='controller-access-denied'}
    elseif($cause.Message -match '^controller-[a-z-]+$'){$result.state=$cause.Message}
    $result.data=@{retryAllowed=$false;partialReceipts=$receipts;gameConsumed=$false;cleanup='No replay attempted; an accepted non-reset command expires at its original native deadline.'}
} finally {
    try {
        if($mutex -ne [IntPtr]::Zero){[SkyrimVRAutomation.ControllerAtomics]::Unlock($mutex)}
    } catch {$result.ok=$false;$result.state='controller-writer-release-failed';$result.errors+=@($_.Exception.Message)}
    finally {if($view){$view.Dispose()};if($mapping){$mapping.Dispose()}}
}
$result | ConvertTo-Json -Depth 32 -Compress:$Compact
if(-not $NoExit){exit $(if($result.ok){0}else{1})}
