# SPDX-License-Identifier: GPL-3.0-or-later
# DevBench CalendarControl schema1 read receipt; never a hold/release outcome.
function Get-DevBenchCalendarStatusRead {
    param([Collections.IDictionary]$Arguments, [AllowEmptyCollection()][object[]]$Content, $ExpectedRuntimeIdentity)
    $reasons = [Collections.Generic.List[string]]::new()
    function Require([bool]$Good, [string]$Path) {
        if (-not $Good) { $reasons.Add("Calendar status read: $Path is missing, malformed or unsupported.") }
    }
    function Member($Node, [string]$Name) {
        if ($Node -isnot [pscustomobject]) { return $null }
        $p = $Node.PSObject.Properties[$Name]
        if ($p -and $p.Name -ceq $Name) { return ,$p.Value }
        return $null
    }
    function UInt($Value, [decimal]$Max = [uint64]::MaxValue, [decimal]$Min = 0) {
        return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int],[uint32],[long],[uint64]) -and [decimal]$Value -ge $Min -and [decimal]$Value -le $Max
    }
    function Finite($Value) {
        return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int],[uint32],[long],[uint64],[single],[double],[decimal]) -and [double]::IsFinite([double]$Value)
    }
    function Shape($Node, [string[]]$Fields, [string]$Path, [string[]]$Optional = @()) {
        Require ($Node -is [pscustomobject]) $Path
        if ($Node -isnot [pscustomobject]) { return }
        foreach ($name in $Fields) { Require ($null -ne $Node.PSObject.Properties[$name] -and $Node.PSObject.Properties[$name].Name -ceq $name) "$Path.$name" }
        foreach ($p in $Node.PSObject.Properties) { Require ($p.Name -cin ($Fields + $Optional)) "$Path unexpected field $($p.Name)" }
    }
    function Binding($Node, [string]$Path) {
        Shape $Node @('pid','processSession','loadGeneration','cellFormId','globalFormIds') $Path
        $pidValue = Member $Node 'pid'; $session = Member $Node 'processSession'
        Require (UInt $pidValue ([uint32]::MaxValue) 1) "$Path.pid"
        Require ($session -is [string] -and $session -cmatch '^[1-9][0-9]*:[0-9A-F]{16}$' -and $session.Split(':')[0] -ceq [string]$pidValue) "$Path.processSession/pid"
        Require (UInt (Member $Node 'loadGeneration') ([uint64]::MaxValue) 1) "$Path.loadGeneration"
        Require (UInt (Member $Node 'cellFormId') ([uint32]::MaxValue)) "$Path.cellFormId"
        $ids = Member $Node 'globalFormIds'
        Require ($ids -is [array] -and $ids.Count -eq 6 -and @($ids | Where-Object { -not (UInt $_ ([uint32]::MaxValue) 1) }).Count -eq 0) "$Path.globalFormIds"
    }
    function Values($Node, [string]$Path) {
        $fields = @('year','month','day','gameHour','daysPassed','calendarRate','engineMultiplier')
        Shape $Node $fields $Path
        foreach ($name in $fields) { Require (Finite (Member $Node $name)) "$Path.$name finite JSON number" }
    }
    $payloads = @($Content)
    $payload = if ($payloads.Count -eq 1 -and $payloads[0] -is [pscustomobject]) { $payloads[0] } else { $null }
    Require ($Arguments.Count -eq 1 -and $Arguments.Contains('action') -and @($Arguments.Keys)[0] -ceq 'action' -and $Arguments['action'] -is [string] -and $Arguments['action'] -ceq 'status') 'exact action-only status request'
    Shape $payload @('action','ok','status','schemaVersion','plugin','version','binding','frame','readbackFresh','available','worldLoaded','values','observedMonotonicMs','restored','globalOrder','serviceStopping','outstanding','leaseActive','expiryDue','cleanupPending','disconnectRecovery','holdValid','lastTransition','commandId') 'payload' @('lease','error','errors')
    if ($null -ne $payload) {
        foreach ($pair in @(@('action','status'),@('status','observed'),@('plugin','devbench'),@('commandId',''),@('disconnectRecovery','expiry-bounded; no disconnect callback'))) {
            $v = Member $payload $pair[0]; Require ($v -is [string] -and $v -ceq $pair[1]) "payload.$($pair[0])"
        }
        Require (UInt (Member $payload 'schemaVersion') 1 1) 'schemaVersion1'
        $version = Member $payload 'version'; Require ($version -is [string] -and $version -cmatch '^[0-9]+\.[0-9]+\.[0-9]+$') 'native version'
        foreach ($name in @('ok','readbackFresh','available')) { $v = Member $payload $name; Require ($v -is [bool] -and $v) "payload.$name true Boolean" }
        foreach ($name in @('worldLoaded','serviceStopping','outstanding','leaseActive','expiryDue','cleanupPending','holdValid')) { Require ((Member $payload $name) -is [bool]) "payload.$name Boolean telemetry" }
        $restored = Member $payload 'restored'; Require ($restored -is [bool] -and -not $restored) 'status does not report current restoration'
        Binding (Member $payload 'binding') 'binding'
        if ($null -ne $ExpectedRuntimeIdentity) {
            # Pure offline classification proves shape only. The actual call
            # also binds current payload identity to its admitted process.
            try {
                $identity = $ExpectedRuntimeIdentity
                $processSession = '{0}:{1:X16}' -f $identity.listenerPid, ([datetime]::Parse($identity.process.startTimeUtc).ToUniversalTime().ToFileTimeUtc())
                Require ($identity.verified -is [bool] -and $identity.verified -and $identity.complete -is [bool] -and $identity.complete -and
                    $payload.binding.pid -eq $identity.listenerPid -and $payload.binding.processSession -ceq $processSession) 'current admitted runtime process/session binding'
            } catch { Require $false 'current admitted runtime process/session binding' }
        }
        Require (UInt (Member $payload 'frame')) 'frame'
        Require (UInt (Member $payload 'observedMonotonicMs') ([long]::MaxValue)) 'observedMonotonicMs'
        Values (Member $payload 'values') 'values'
        $order = Member $payload 'globalOrder'; $expected = @('year','month','day','gameHour','daysPassed','calendarRate')
        $ordered = $order -is [array] -and $order.Count -eq 6
        if ($ordered) { for ($i=0; $i -lt 6; $i++) { if ($order[$i] -isnot [string] -or $order[$i] -cne $expected[$i]) { $ordered = $false } } }
        Require $ordered 'globalOrder exact ordered inventory'
        # Historical transition/lease facts do not veto this fresh read merely
        # because a previous mutation failed or restoration is false.
        $last = Member $payload 'lastTransition'; Shape $last @('status','ok','restored') 'lastTransition'
        $state = Member $last 'status'; Require ($state -is [string] -and $state.Length -ge 1 -and $state.Length -le 128) 'lastTransition.status'
        foreach ($name in @('ok','restored')) { Require ((Member $last $name) -is [bool]) "lastTransition.$name" }
        if ($payload.PSObject.Properties['lease']) {
            $lease = Member $payload 'lease'
            Shape $lease @('id','owner','commandId','binding','deadlineMonotonicMs','applied','captured','cleanupAttempted') 'lease'
            foreach ($name in @('id','owner','commandId')) { $v = Member $lease $name; Require ($v -is [string] -and $v.Length -ge 1 -and $v.Length -le 128) "lease.$name" }
            Binding (Member $lease 'binding') 'lease.binding'
            Values (Member $lease 'captured') 'lease.captured'
            Require (UInt (Member $lease 'deadlineMonotonicMs') ([long]::MaxValue)) 'lease.deadlineMonotonicMs'
            foreach ($name in @('applied','cleanupAttempted')) { Require ((Member $lease $name) -is [bool]) "lease.$name" }
        }
        if ($payload.PSObject.Properties['error']) { $v = Member $payload 'error'; Require ($null -eq $v -or ($v -is [string] -and $v -ceq '')) 'no explicit current error' }
        if ($payload.PSObject.Properties['errors']) { $v = Member $payload 'errors'; Require ($null -eq $v -or ($v -is [array] -and $v.Count -eq 0)) 'no explicit current errors' }
    }
    $ok = $reasons.Count -eq 0
    return [pscustomobject]@{
        known=$true; ok=$ok; outcome=$(if ($ok) { 'calendar-status-read-contract-satisfied' } else { 'calendar-status-read-contract-failed' })
        guarded=(-not $ok); transient=$false; codes=@(); states=@(); reasons=@($reasons)
        completionBasis='read-schema-only'; explicitOutcomeEvidence=$(if ($ok) { @('native-calendar-schema1-fresh-available-observation') } else { @() })
        qualifiedCalendarStatus=$(if ($ok) { $payload } else { $null })
        runtimeBindingChecked=($null -ne $ExpectedRuntimeIdentity)
    }
}
