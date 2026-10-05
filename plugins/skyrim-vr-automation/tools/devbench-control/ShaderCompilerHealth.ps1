# SPDX-License-Identifier: GPL-3.0-or-later
# Native source contract: CSX ad8c7a2a8cf7dc9295d40dadd3f45da85fec4dd0,
# ShaderDevBenchBridge.cpp / ServiceFoundation.cpp / ShaderCache.cpp.
# This is a read/admission classifier, never a compiler/cache repair.
function Test-DevBenchShaderSnapshotRequest {
    param([Collections.IDictionary]$Arguments)
    if ($null -eq $Arguments -or @($Arguments.Keys | Where-Object { $_ -cnotin @('contractMajor','clientId','commandId','action','expectedBuildId') }).Count) { return $false }
    if (-not $Arguments.Contains('action') -or $Arguments.action -isnot [string] -or $Arguments.action -cne 'snapshot') { return $false }
    if (-not $Arguments.Contains('contractMajor') -or $Arguments.contractMajor -isnot [ValueType] -or $Arguments.contractMajor -is [bool] -or $Arguments.contractMajor.GetType() -notin @([byte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -or $Arguments.contractMajor -ne 1) { return $false }
    foreach ($key in @('clientId','commandId')) {
        if (-not $Arguments.Contains($key) -or $Arguments[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Arguments[$key]) -or [Text.Encoding]::UTF8.GetByteCount($Arguments[$key]) -gt 128) { return $false }
    }
    return -not $Arguments.Contains('expectedBuildId') -or ($Arguments.expectedBuildId -is [string] -and -not [string]::IsNullOrWhiteSpace($Arguments.expectedBuildId))
}

function Get-DevBenchShaderCompilerHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Arguments,
          [AllowEmptyCollection()][object[]]$Content)
    $reasons = [Collections.Generic.List[string]]::new()
    function Shader-Member($Object,[string]$Name) {
        if ($Object -isnot [pscustomobject]) { return $null }
        $p=$Object.PSObject.Properties[$Name]; if ($p) { return ,$p.Value }; return $null
    }
    function Shader-UInt($Value) {
        return $null -ne $Value -and $Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64]) -and [decimal]$Value -ge 0 -and [decimal]$Value -le [uint64]::MaxValue
    }
    function Shader-String($Value) { return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value) }
    $payloads=@($Content)
    $p=if ($payloads.Count -eq 1 -and $payloads[0] -is [pscustomobject]) { $payloads[0] } else { $null }
    if (-not (Test-DevBenchShaderSnapshotRequest $Arguments)) { $reasons.Add('Only the exact versioned shader snapshot request qualifies.') }
    if ($null -eq $p) { $reasons.Add('Shader snapshot requires exactly one structured native receipt.') }
    $contract=Shader-Member $p 'contract'; $command=Shader-Member $p 'command'
    $server=Shader-Member $p 'server'; $result=Shader-Member $p 'result'
    $snapshot=Shader-Member $result 'snapshot'; $compile=Shader-Member $snapshot 'compilation'
    $custom=Shader-Member $snapshot 'customShaders'; $provenance=Shader-Member $snapshot 'provenance'
    $ok=Shader-Member $p 'ok'
    if ($ok -isnot [bool] -or -not $ok) { $reasons.Add('Native envelope ok must be Boolean true.') }
    if (-not (Shader-String (Shader-Member $contract 'name')) -or (Shader-Member $contract 'name') -cne 'csx.shader') { $reasons.Add('Foreign shader service contract.') }
    if ($null -ne $p -and @($p.PSObject.Properties.Name | Where-Object { $_ -cnotin @('ok','contract','command','timestampUtc','server','result','idempotentReplay') }).Count) { $reasons.Add('Unsupported outer shader receipt fields or explicit error.') }
    if ($result -is [pscustomobject] -and @($result.PSObject.Properties.Name | Where-Object { $_ -cnotin @('status','snapshot','idempotentReplay') }).Count) { $reasons.Add('Unsupported shader result fields or explicit error.') }
    foreach ($field in @(@('major',1),@('minor',0),@('schemaRevision',1))) {
        $value=Shader-Member $contract $field[0]
        if (-not (Shader-UInt $value) -or $value -ne $field[1]) { $reasons.Add("Unsupported typed contract $($field[0]).") }
    }
    foreach ($field in @('action','clientId','commandId')) {
        $value=Shader-Member $command $field
        if (-not (Shader-String $value) -or -not $Arguments.Contains($field) -or $value -cne $Arguments[$field]) { $reasons.Add("Native command $field does not match this request.") }
    }
    # Compiler error text inside recentFailures is diagnostic data, not an outer
    # API failure. Other explicit errors always veto schema qualification.
    foreach ($object in @($p,$result,$snapshot,$compile,$custom,$contract,$command)) {
        foreach ($field in @('error','errors')) {
            $value=Shader-Member $object $field
            if ($null -ne $value -and ($value -isnot [array] -or $value.Count -gt 0)) { $reasons.Add("Explicit $field on shader response.") }
        }
        foreach ($field in @('success','ok')) {
            if ($object -is [pscustomobject] -and $object.PSObject.Properties[$field] -and ((Shader-Member $object $field) -isnot [bool] -or -not (Shader-Member $object $field))) { $reasons.Add("Contradictory $field flag.") }
        }
    }
    if (-not (Shader-String (Shader-Member $result 'status')) -or (Shader-Member $result 'status') -cne 'success') { $reasons.Add('Shader API snapshot status is not success.') }
    $timestamp=Shader-Member $p 'timestampUtc'; $parsed=[DateTimeOffset]::MinValue
    if ($timestamp -isnot [string] -or -not $timestamp.EndsWith('Z',[StringComparison]::Ordinal) -or -not [DateTimeOffset]::TryParse($timestamp,[ref]$parsed)) { $reasons.Add('Native UTC timestamp missing or malformed.') }
    foreach ($field in @('buildId','shaderCacheAbiId','shaderCompilerIdentity')) {
        $value=Shader-Member $provenance $field
        if (-not (Shader-String $value) -or -not (Shader-String (Shader-Member $server $field)) -or $value -cne (Shader-Member $server $field)) { $reasons.Add("Snapshot/server $field missing or inconsistent.") }
    }
    if (-not (Shader-String (Shader-Member $server 'component')) -or (Shader-Member $server 'component') -cne 'CommunityShaders' -or -not (Shader-String (Shader-Member $server 'sessionId')) -or -not (Shader-String (Shader-Member $server 'serviceSessionId')) -or (Shader-Member $server 'sessionId') -cne (Shader-Member $server 'serviceSessionId')) { $reasons.Add('Missing or inconsistent CSX shader service-session identity.') }
    if ($Arguments.Contains('expectedBuildId') -and $Arguments.expectedBuildId -cne (Shader-Member $server 'buildId')) { $reasons.Add('Shader producer build differs from expectedBuildId.') }
    foreach ($field in @('stateRevision','capabilities')) {
        if (-not (Shader-UInt (Shader-Member $snapshot $field))) { $reasons.Add("Snapshot $field must be unsigned integral telemetry.") }
    }
    $available=Shader-Member $snapshot 'available'
    if ($available -isnot [bool]) { $reasons.Add('Snapshot available must be Boolean.') }
    foreach ($field in @('requested','effective','transitionPending')) {
        if ((Shader-Member $custom $field) -isnot [bool]) { $reasons.Add("customShaders.$field must be Boolean.") }
    }
    foreach ($field in @('active','async','skipUnchanged','activeShaderCapture')) {
        if ((Shader-Member $compile $field) -isnot [bool]) { $reasons.Add("compilation.$field must be Boolean.") }
    }
    foreach ($field in @('totalTasks','completedTasks','failedTasks','currentFailedShaders','memoryCacheHits','diskCacheHits','sourceCompiles','slowTasks','verySlowTasks','heavyTasksInFlight','foregroundThreadCount','backgroundThreadCount')) {
        if (-not (Shader-UInt (Shader-Member $compile $field))) { $reasons.Add("compilation.$field must be uint64 telemetry.") }
    }
    if ((Shader-Member $compile 'statisticsText') -isnot [string]) { $reasons.Add('Compilation statistics text missing.') }
    $failures=Shader-Member $compile 'recentFailures'
    if ($failures -isnot [array] -or $failures.Count -gt 32) { $reasons.Add('Recent failures must be a bounded native array of at most 32 entries.') }
    else {
        foreach ($failure in $failures) {
            foreach ($field in @('key','path','error')) {
                if (-not (Shader-String (Shader-Member $failure $field))) { $reasons.Add("Recent failure $field must retain native diagnostic text.") }
            }
            $text=Shader-Member $failure 'error'
            if ($text -is [string] -and [Text.Encoding]::UTF8.GetByteCount($text) -gt 2000) { $reasons.Add('Recent failure error exceeds native byte limit.') }
            if (-not (Shader-UInt (Shader-Member $failure 'epoch')) -or -not (Shader-UInt (Shader-Member $failure 'frame')) -or (Shader-Member $failure 'frame') -gt [uint32]::MaxValue) { $reasons.Add('Recent failure epoch/frame must retain typed native counters.') }
        }
    }
    $readQualified=$reasons.Count -eq 0
    foreach ($object in @($p,$result)) {
        if ($object -is [pscustomobject] -and $object.PSObject.Properties['idempotentReplay'] -and $object.idempotentReplay -isnot [bool]) { $reasons.Add('idempotentReplay must be Boolean when present.'); $readQualified=$false }
    }
    $state='INDETERMINATE'
    if ($readQualified) {
        if (-not $available) { $state='UNAVAILABLE'; $reasons.Add('Shader snapshot is unavailable.') }
        elseif ($compile.failedTasks -gt 0 -or $compile.currentFailedShaders -gt 0) { $state='FAILED_COMPILATION'; $reasons.Add('Native shader task/current-entry failures prohibit healthy evidence.') }
        elseif ($failures.Count -gt 0) { $state='FAILED_COMPILATION_HISTORY'; $reasons.Add('Native recent failure history taints this admission; no epoch-reset inference.') }
        elseif (($p.PSObject.Properties['idempotentReplay'] -and $p.idempotentReplay -ne $false) -or ($result.PSObject.Properties['idempotentReplay'] -and $result.idempotentReplay -ne $false)) { $reasons.Add('Replayed snapshots cannot prove fresh current-session compiler health.') }
        elseif ($compile.active -or $compile.heavyTasksInFlight -gt 0 -or $custom.transitionPending -or $custom.requested -ne $custom.effective -or ([decimal]$compile.completedTasks + [decimal]$compile.failedTasks) -lt [decimal]$compile.totalTasks) { $state='COMPILATION_PENDING'; $reasons.Add('Compilation or custom-shader transition is pending.') }
        elseif ([decimal]$compile.completedTasks -gt [decimal]$compile.totalTasks) { $reasons.Add('Incoherent/non-atomic compilation task counters; take a fresh read, never repair.') }
        elseif (-not $custom.requested -or -not $custom.effective) { $state='CUSTOM_SHADERS_DISABLED'; $reasons.Add('CSX custom shaders are not requested and effective.') }
        elseif ($compile.totalTasks -eq 0) { $state='COMPILATION_UNPROVEN'; $reasons.Add('Zero-task initialization is not a qualified compiler baseline.') }
        else { $state='COMPILER_HEALTHY_AT_SNAPSHOT' }
    }
    return [pscustomobject][ordered]@{
        schema='auto-tools.shader-compiler-health.1'; readQualified=$readQualified
        admissible=$state -ceq 'COMPILER_HEALTHY_AT_SNAPSHOT'; state=$state
        buildId=Shader-Member $server 'buildId'; serviceSessionId=Shader-Member $server 'serviceSessionId'
        stateRevision=Shader-Member $snapshot 'stateRevision'; timestampUtc=$timestamp
        compilation=$compile; producer=$server; reasons=@($reasons | Select-Object -Unique)
        scope='compiler snapshot only; not package/include/provider closure, visual correctness or capture completion'
    }
}

function Test-DevBenchShaderCompilerWindow {
    param($Before,$After)
    $reasons=[Collections.Generic.List[string]]::new()
    foreach ($check in @($Before,$After)) {
        if ($null -eq $check -or -not $check.admissible) { $reasons.Add('Both compiler boundaries must be admitted.') }
    }
    if ($reasons.Count -eq 0) {
        foreach ($key in @('buildId','serviceSessionId','stateRevision')) {
            if ($Before.$key -cne $After.$key) { $reasons.Add("Compiler boundary $key changed.") }
        }
        foreach ($key in @('totalTasks','completedTasks','failedTasks','currentFailedShaders','sourceCompiles','diskCacheHits','memoryCacheHits')) {
            if ($Before.compilation.$key -ne $After.compilation.$key) { $reasons.Add("Compilation/cache activity changed $key during evidence call.") }
        }
        if ([DateTimeOffset]$After.timestampUtc -lt [DateTimeOffset]$Before.timestampUtc) { $reasons.Add('Compiler boundary chronology regressed.') }
    }
    return [pscustomobject]@{valid=$reasons.Count -eq 0; before=$Before; after=$After; reasons=@($reasons); scope='same-session compiler boundary bracket, not an atomic render or future health guarantee'}
}

