# SPDX-License-Identifier: GPL-3.0-or-later
Set-StrictMode -Version Latest

function Assert-CalendarBinding($Binding) {
    if ($Binding -isnot [pscustomobject] -or @($Binding.PSObject.Properties).Count -ne 5) { throw 'Calendar binding must have exactly five native fields.' }
    if (-not $Binding.PSObject.Properties['processSession'] -or $Binding.processSession -isnot [string] -or [string]::IsNullOrWhiteSpace($Binding.processSession)) { throw 'Calendar processSession is missing.' }
    foreach ($name in @('pid','loadGeneration','cellFormId')) {
        $property=$Binding.PSObject.Properties[$name]
        if (-not $property -or $property.Value -isnot [ValueType] -or $property.Value.GetType() -notin @([int],[long],[uint32],[uint64]) -or $property.Value -lt $(if ($name -eq 'cellFormId') { 0 } else { 1 })) { throw "Invalid calendar binding $name." }
    }
    if (-not $Binding.PSObject.Properties['globalFormIds'] -or $Binding.globalFormIds -isnot [array] -or $Binding.globalFormIds.Count -ne 6) { throw 'Calendar requires six native globalFormIds.' }
    foreach ($id in $Binding.globalFormIds) { if ($null -eq $id -or $id.GetType() -notin @([int],[long],[uint32],[uint64]) -or $id -lt 1 -or $id -gt [uint32]::MaxValue) { throw 'Invalid calendar global form ID.' } }
}

function Test-CalendarStorageBindingEqual($Left,$Right) {
    Assert-CalendarBinding $Left; Assert-CalendarBinding $Right
    # Public identities corroborate the native SameStorage proof; raw calendar
    # and global addresses remain native-only and are not guessed by this client.
    if ($Left.processSession -cne $Right.processSession -or $Left.pid -ne $Right.pid -or $Left.loadGeneration -ne $Right.loadGeneration) { return $false }
    for($i=0;$i -lt 6;$i++) { if($Left.globalFormIds[$i] -ne $Right.globalFormIds[$i]) { return $false } }
    return $true
}

function Test-CalendarBindingEqual($Left,$Right) {
    if (-not (Test-CalendarStorageBindingEqual $Left $Right)) { return $false }
    return $Left.cellFormId -eq $Right.cellFormId
}

function Assert-CalendarReadback($Payload) {
    if ($Payload -isnot [pscustomobject]) { throw 'Calendar requires one structured native payload.' }
    foreach ($name in @('ok','readbackFresh','available','worldLoaded')) { if (-not $Payload.PSObject.Properties[$name] -or $Payload.$name -isnot [bool] -or -not $Payload.$name) { throw "Calendar $name is not positively qualified." } }
    foreach ($name in @('outstanding','leaseActive','expiryDue','cleanupPending','holdValid','serviceStopping','restored')) { if (-not $Payload.PSObject.Properties[$name] -or $Payload.$name -isnot [bool]) { throw "Calendar $name must be Boolean." } }
    if ($Payload.serviceStopping -or $null -eq $Payload.schemaVersion -or $Payload.schemaVersion.GetType() -notin @([int],[long],[uint32],[uint64]) -or $Payload.schemaVersion -ne 1 -or $Payload.plugin -isnot [string] -or $Payload.plugin -cne 'devbench' -or $Payload.status -isnot [string]) { throw 'Unsupported calendar state/schema.' }
    Assert-CalendarBinding $Payload.binding
    if ($Payload.values -isnot [pscustomobject]) { throw 'Fresh calendar values are missing.' }
    foreach ($name in @('year','month','day','gameHour','daysPassed','calendarRate','engineMultiplier')) {
        $property=$Payload.values.PSObject.Properties[$name]
        if (-not $property -or $null -eq $property.Value -or $property.Value.GetType() -notin @([int],[long],[uint32],[uint64],[double],[single],[decimal]) -or -not [double]::IsFinite([double]$property.Value)) { throw "Invalid calendar value $name." }
    }
    if ($Payload.values.engineMultiplier -le 0 -or $Payload.values.year -lt 0 -or $Payload.values.month -lt 0 -or $Payload.values.month -ge 12 -or $Payload.values.day -lt 1 -or $Payload.values.day -gt 31 -or $Payload.values.gameHour -lt 0 -or $Payload.values.gameHour -ge 24 -or $Payload.values.daysPassed -lt 0) { throw 'Calendar values are outside the native operating boundary.' }
}

function Assert-CalendarLease($Payload,[string]$Owner,[string]$CommandId,$Binding) {
    $lease=$Payload.PSObject.Properties['lease']
    if (-not $lease -or $lease.Value -isnot [pscustomobject]) { throw 'Exact calendar lease receipt is absent.' }
    $lease=$lease.Value
    if ($lease.id -isnot [string] -or [string]::IsNullOrWhiteSpace($lease.id) -or $lease.owner -cne $Owner -or $lease.commandId -cne $CommandId -or $lease.applied -isnot [bool] -or -not $lease.applied -or -not (Test-CalendarBindingEqual $lease.binding $Binding)) { throw 'Calendar lease owner/command/binding/applied mismatch.' }
    if ($lease.captured -isnot [pscustomobject] -or $null -eq $lease.captured.calendarRate -or $lease.captured.calendarRate.GetType() -notin @([int],[long],[uint32],[uint64],[double],[single],[decimal]) -or -not [double]::IsFinite([double]$lease.captured.calendarRate) -or $lease.captured.calendarRate -le 0) { throw 'Captured prior calendar rate is unqualified.' }
    return $lease
}

function Test-CalendarPositiveCleanupReason($Reason) {
    # Native Tick may retire the same lease before explicit release dispatch.
    # Reason is corroboration only; callers still require all custody/readback proof.
    return $Reason -is [string] -and $Reason -cin @('released','expired','scene_lost')
}

function Invoke-DevBenchCalendarWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Call,
          [Parameter(Mandatory)][scriptblock]$AssertSession,
          [Parameter(Mandatory)][string]$Owner,
          [AllowEmptyCollection()][array]$Observations=@(),
          [Collections.IDictionary]$ColourPlan,
          [scriptblock]$CompilerGuard,
          [ValidateRange(1,300000)][int]$HoldMilliseconds=60000,
          [Parameter(Mandatory)][datetime]$DeadlineUtc,
          [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ExpectedProcessId,
          [ValidateRange(5,30)][int]$CleanupSeconds=15)
    $holdId=[guid]::NewGuid().ToString(); $releaseId=[guid]::NewGuid().ToString()
    $trace=[Collections.Generic.List[object]]::new(); $errors=[Collections.Generic.List[string]]::new()
    $lease=$null; $binding=$null; $holdAttempted=$false; $restorationVerified=$false; $continuity=$false; $uncertain=$false; $measurement=$null
    # Reserve a bounded cleanup budget from the outset, not an indefinite finally.
    $workDeadline=$DeadlineUtc.AddSeconds(-$CleanupSeconds)
    function Invoke-WindowCall([string]$Name,[hashtable]$Arguments,[bool]$Mutation,[datetime]$Bound) {
        & $AssertSession | Out-Null
        if ([datetime]::UtcNow -ge $Bound) { throw 'Calendar workflow deadline expired before dispatch.' }
        $entry=[ordered]@{ tool=$Name; arguments=$Arguments; mutation=$Mutation; intendedUtc=[datetime]::UtcNow.ToString('o'); data=$null; error=$null }
        $trace.Add($entry)
        try {
            $entry.data=& $Call $Name $Arguments $Mutation $Bound
            if([datetime]::UtcNow -ge $Bound){throw 'Calendar response arrived at or after its deadline.'}
            if($Name -ceq 'calendar') {
                $payload=Get-CalendarPayload $entry.data
                if($payload.action -isnot [string] -or $payload.action -cne $Arguments.action -or $payload.binding.pid -ne $ExpectedProcessId){throw 'Calendar response action/process differs from the exact runtime binding.'}
            }
            return $entry.data
        }
        catch { $entry.error=$_.Exception.Message; throw }
    }
    function Get-CalendarPayload($Data) {
        if ($null -eq $Data -or -not $Data.PSObject.Properties['content'] -or @($Data.content).Count -ne 1 -or $Data.content[0] -isnot [pscustomobject]) { throw 'Calendar requires exactly one native response.' }
        return $Data.content[0]
    }
    try {
        if ([string]::IsNullOrWhiteSpace($Owner) -or $Owner.Length -gt 128) { throw 'Calendar owner is required.' }
        if ($null -ne $ColourPlan) {
            Assert-ColourMeasurementPlan $ColourPlan
            if($Observations.Count -ne 0 -or $null -eq $CompilerGuard){throw 'Typed colour workflow cannot mix generic observations or omit compiler admission.'}
        } elseif($Observations.Count -lt 1 -or $Observations.Count -gt 16){throw 'Calendar finite1..16 observations are required.'}
        foreach($item in $Observations) {
            if($item -isnot [Collections.IDictionary] -or -not $item.Contains('tool') -or -not $item.Contains('arguments') -or $item.tool -isnot [string] -or $item.arguments -isnot [Collections.IDictionary] -or $item.tool -ceq 'calendar' -or -not (Test-DevBenchReadOnlyRequest -ToolName $item.tool -Arguments $item.arguments)) { throw 'Calendar composition rejects intrusive or unsupported observations.' }
        }
        $before=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $workDeadline)
        Assert-CalendarReadback $before
        if ($before.outstanding -or $before.expiryDue -or $before.cleanupPending -or $before.values.calendarRate -le 0) { throw 'Calendar initial state already has custody or unsupported progression.' }
        $binding=$before.binding
        if($null -ne $ColourPlan -and $binding.cellFormId -ne $ColourPlan.expectedCellFormId){throw 'Colour calibrated cell differs from fresh calendar binding.'}
        $holdAttempted=$true
        $held=Get-CalendarPayload (Invoke-WindowCall calendar @{action='hold';owner=$Owner;commandId=$holdId;binding=$binding;holdMs=$HoldMilliseconds} $true $workDeadline)
        # Retain only an exact owner/command/source lease for finally, even if
        # later held-state qualification fails. Never adopt an unrelated lease.
        $lease=Assert-CalendarLease $held $Owner $holdId $binding
        Assert-CalendarReadback $held
        if (-not (Test-CalendarBindingEqual $held.binding $binding) -or $held.status -cne 'held' -or -not $held.holdValid -or -not $held.outstanding -or -not $held.leaseActive -or $held.expiryDue -or $held.cleanupPending -or $held.values.calendarRate -ne 0) { throw 'Calendar hold was not currently valid.' }
        if($null -ne $ColourPlan){
            $measurement=Invoke-DevBenchColourMeasurement -Plan $ColourPlan -DeadlineUtc $workDeadline -CompilerGuard $CompilerGuard -CleanupDeadlineUtc $DeadlineUtc.AddSeconds(-5) -CleanupCall {
                param($name,$argsMap,$mutation,$bound)
                if($name -cne 'communityshaders.colour_pipeline_probe' -or $argsMap.action -cnotin @('status','reset')){throw 'Probe cleanup accepts only native exact status/reset.'}
                Invoke-WindowCall $name $argsMap $mutation $bound
            } -Call {
                param($name,$argsMap,$mutation,$bound)
                foreach($side in @('before','after')){
                    if($side -ceq 'after'){$response=Invoke-WindowCall $name $argsMap $mutation $bound}
                    $current=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $bound)
                    Assert-CalendarReadback $current
                    $currentLease=Assert-CalendarLease $current $Owner $holdId $binding
                    if($currentLease.id -cne $lease.id -or -not (Test-CalendarBindingEqual $current.binding $binding) -or -not $current.holdValid -or -not $current.leaseActive -or -not $current.outstanding -or $current.expiryDue -or $current.cleanupPending -or $current.values.calendarRate -ne 0){throw "Calendar continuity invalidated $side colour action."}
                }
                return $response
            }
            if(-not $measurement.ok){$uncertain=[bool]$measurement.indeterminate;throw ('Colour measurement: '+($measurement.errors -join '; '))}
        }
        foreach ($observation in $Observations) {
            $current=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $workDeadline)
            Assert-CalendarReadback $current
            $null=Assert-CalendarLease $current $Owner $holdId $binding
            if (-not (Test-CalendarBindingEqual $current.binding $binding) -or -not $current.holdValid -or -not $current.leaseActive -or -not $current.outstanding -or $current.expiryDue -or $current.cleanupPending) { throw 'Calendar hold continuity invalidated before observation.' }
            $observed=Invoke-WindowCall $observation.tool $observation.arguments $false $workDeadline
            $qualified=Get-DevBenchCallSemanticStatus -ToolName $observation.tool -Arguments $observation.arguments -Content @($observed.content)
            if (-not $qualified.known -or -not $qualified.ok) { throw "Calendar observation failed qualification: $($observation.tool)." }
            $current=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $workDeadline)
            Assert-CalendarReadback $current
            $null=Assert-CalendarLease $current $Owner $holdId $binding
            if (-not (Test-CalendarBindingEqual $current.binding $binding) -or -not $current.holdValid -or -not $current.leaseActive -or -not $current.outstanding -or $current.expiryDue -or $current.cleanupPending) { throw 'Calendar hold continuity invalidated after observation.' }
        }
        $continuity=$true
    }
    catch { $errors.Add($_.Exception.Message) }
    finally {
        if ($holdAttempted) {
            try {
                # A lost/already-started hold is read once on the same session,
                # never replayed. Absent authority stays explicitly uncertain.
                if ($null -eq $lease) {
                    $uncertain=$true
                    $reconcile=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $DeadlineUtc)
                    $lease=Assert-CalendarLease $reconcile $Owner $holdId $binding
                }
                $released=Get-CalendarPayload (Invoke-WindowCall calendar @{action='release';owner=$Owner;commandId=$releaseId;binding=$lease.binding;leaseId=$lease.id} $true $DeadlineUtc)
                Assert-CalendarReadback $released
                $releasedLease=Assert-CalendarLease $released $Owner $holdId $binding
                if ($releasedLease.id -cne $lease.id -or $releasedLease.captured.calendarRate -ne $lease.captured.calendarRate -or -not (Test-CalendarStorageBindingEqual $released.binding $binding) -or -not $released.restored -or $released.outstanding -or $released.leaseActive -or $released.expiryDue -or $released.cleanupPending -or $released.values.calendarRate -ne $lease.captured.calendarRate -or -not (Test-CalendarPositiveCleanupReason $released.status)) { throw 'Calendar release did not prove restoration of the exact original lease.' }
                $after=Get-CalendarPayload (Invoke-WindowCall calendar @{action='status'} $false $DeadlineUtc)
                Assert-CalendarReadback $after
                $afterLease=Assert-CalendarLease $after $Owner $holdId $binding
                # Cell drift still invalidates observation continuity above.
                # Cleanup may be independently proved in a different cell only
                # by exact retained custody plus positive native restoration and
                # fresh same-process/generation/global readback. No new authority,
                # binding substitution, lease adoption or automatic retry.
                if ($afterLease.id -cne $lease.id -or $afterLease.captured.calendarRate -ne $lease.captured.calendarRate -or -not (Test-CalendarStorageBindingEqual $after.binding $binding) -or $after.outstanding -or $after.leaseActive -or $after.expiryDue -or $after.cleanupPending -or $after.values.calendarRate -ne $lease.captured.calendarRate -or $after.lastTransition.restored -isnot [bool] -or -not $after.lastTransition.restored -or $after.lastTransition.ok -isnot [bool] -or -not $after.lastTransition.ok -or -not (Test-CalendarPositiveCleanupReason $after.lastTransition.status) -or $after.lastTransition.status -cne $released.status) { throw 'Fresh calendar restoration proof is incomplete.' }
                $restorationVerified=$true
            }
            catch { $errors.Add("Calendar cleanup: $($_.Exception.Message)"); $uncertain=$true }
        }
    }
    return [pscustomobject]@{ ok=($errors.Count -eq 0 -and $continuity -and $restorationVerified); continuityVerified=$continuity; restorationVerified=$restorationVerified; indeterminate=$uncertain; measurement=$measurement; owner=$Owner; holdCommandId=$holdId; releaseCommandId=$releaseId; lease=$lease; calls=@($trace); errors=@($errors); completionBasis='bounded-calendar-state-bracket-not-atomic-render'; disconnectRestorationClaimed=$false }
}
Export-ModuleMember -Function Invoke-DevBenchCalendarWindow

