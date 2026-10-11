# SPDX-License-Identifier: GPL-3.0-or-later
# Private planner qualification only: no runtime/session or capture dispatch.
# Preserve raw member types; a singleton array is never a scalar capability.
function Read-RenderMapSelectionMember($Value, [string]$Name) {
    $raw = $null
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { $raw = $Value[$Name] }
    } elseif ($Value -is [pscustomobject]) {
        $property = $Value.PSObject.Properties[$Name]
        if ($null -ne $property) { $raw = $property.Value }
    }
    return [pscustomobject]@{ value = $raw }
}

function Get-RenderMapGeometryCapabilityQualification($ResolvedRegistry, $Capability) {
    if ($Capability -isnot [string]) { return $null }
    if ($Capability -ceq 'optional native Boolean') {
        return [pscustomobject]@{ basis = 'reviewed-literal-native-boolean'; sourceCommit = $null }
    }
    # One exact source-proven compatibility record, not arbitrary prose matching.
    # AD25 DevBenchBridge blob443db2b... explicitly rejects non-Booleans and
    # requires actual false for VR late/eye selection. Unknown successors refuse.
    $description = 'optional; when true, draws require either an active selected geometry scope or the one-shot same-thread next-draw handoff from selected SetupGeometry'
    if ($Capability -cne $description) { return $null }
    $native = $ResolvedRegistry.envelope
    $contract = (Read-RenderMapSelectionMember $native 'contract').value
    $server = (Read-RenderMapSelectionMember $native 'server').value
    $major = (Read-RenderMapSelectionMember $contract 'major').value
    $minor = (Read-RenderMapSelectionMember $contract 'minor').value
    $revision = (Read-RenderMapSelectionMember $contract 'schemaRevision').value
    $name = (Read-RenderMapSelectionMember $contract 'name').value
    $source = (Read-RenderMapSelectionMember $server 'sourceCommit').value
    $build = (Read-RenderMapSelectionMember $server 'buildId').value
    $dirty = (Read-RenderMapSelectionMember $server 'sourceDirty').value
    if ($null -eq $major -or $major.GetType() -notin @([int],[long]) -or $major -ne 1 -or
        $null -eq $minor -or $minor.GetType() -notin @([int],[long]) -or $minor -ne 26 -or
        $null -eq $revision -or $revision.GetType() -notin @([int],[long]) -or $revision -ne 28 -or
        $name -isnot [string] -or $name -cne 'communityshaders.render-map' -or
        $source -isnot [string] -or $source -cne 'ad25cd6edfb5f3d2da8386cb07a43c34e3d5efda' -or
        $build -isnot [string] -or $build -cne '91278a15be065cee3cd583d80b29991f9ae4d19b472b54717418052c8fcb8fff' -or
        $ResolvedRegistry.producerBuildId -cne $build -or $dirty -isnot [bool] -or $dirty) { return $null }
    return [pscustomobject]@{ basis = 'source-bound-ad25-descriptive-native-boolean'; sourceCommit = $source;
        producerBuildId = $build; contractMinor = $minor; schemaRevision = $revision;
        handlerGitBlob = '443db2b24a27fa4a9ef80d8818e4f6705d09643a' }
}

function Get-RenderMapStartSelection($BoundParameters, $ResolvedRegistry, [object[]]$EventKinds) {
    $fields = @('Activation', 'MaxActivationWaitMs', 'ExecutionWithinSelectedGeometry')
    $supplied = @($fields | Where-Object { $BoundParameters.ContainsKey($_) })
    $schemaFields = @('InputSchemaPath', 'ExpectedInputSchemaSha256')
    $schemaSupplied = @($schemaFields | Where-Object { $BoundParameters.ContainsKey($_) })
    $selected = [ordered]@{}
    $geometryQualification = $null
    if ($supplied.Count -eq 0 -and $schemaSupplied.Count -eq 0) {
        return [pscustomobject]@{ arguments = $selected; evidence = $null }
    }
    if ($schemaSupplied.Count -ne 2) { throw 'Explicit start selection requires InputSchemaPath and ExpectedInputSchemaSha256.' }
    $capture = Read-RenderMapAllocationEvidence $BoundParameters.InputSchemaPath $BoundParameters.ExpectedInputSchemaSha256
    $descriptor = $capture.data
    if ((Get-Property $descriptor 'name') -cne 'communityshaders.render_map') { throw 'Input schema descriptor must name exact tool communityshaders.render_map.' }
    $schema = Get-Property $descriptor 'inputSchema'
    $properties = Get-Property $schema 'properties'
    if ((Get-Property $schema 'type') -cne 'object' -or $null -eq $properties -or $ResolvedRegistry.major -ne 1) { throw 'Unsupported render-map start schema or registry major.' }
    $majorSchema = Get-Property $properties 'contractMajor'
    if ((Get-Property $majorSchema 'type') -cne 'integer' -or
        (Require-PositiveLong (Get-Property $majorSchema 'const') 'schema.contractMajor.const') -ne $ResolvedRegistry.major -or
        (Get-Property (Get-Property $properties 'action') 'type') -cne 'string' -or
        'start' -cnotin @(Get-Property (Get-Property $properties 'action') 'enum')) { throw 'Input schema does not advertise this exact start contract.' }

    if ($BoundParameters.ContainsKey('Activation')) {
        $activation = $BoundParameters.Activation
        $modes = @(Get-Property $ResolvedRegistry.registry 'activationModes')
        $field = Get-Property $properties 'activation'
        if ($activation -isnot [string] -or $activation -cnotin @('immediate','main_post_processing') -or
            $modes.Count -eq 0 -or @($modes | Where-Object { $_ -isnot [string] }).Count -gt 0 -or
            $activation -cnotin $modes -or (Get-Property $field 'type') -cne 'string' -or
            $activation -cnotin @(Get-Property $field 'enum')) { throw 'Activation must be an exact supported name advertised by registry and input schema.' }
        $selected.activation = $activation
    }
    if ($BoundParameters.ContainsKey('ExecutionWithinSelectedGeometry')) {
        $execution = $BoundParameters.ExecutionWithinSelectedGeometry
        $geometry = Get-Property $ResolvedRegistry.registry 'geometrySelection'
        # Read the value without function-pipeline enumeration: a singleton array
        # must remain an array, not become an apparently supported scalar string.
        $capability = $null
        if ($geometry -is [Collections.IDictionary]) {
            if ($geometry.Contains('executionWithinSelectedGeometry')) { $capability = $geometry['executionWithinSelectedGeometry'] }
        } elseif ($null -ne $geometry) {
            $property = $geometry.PSObject.Properties['executionWithinSelectedGeometry']
            if ($null -ne $property) { $capability = $property.Value }
        }
        $geometryQualification = Get-RenderMapGeometryCapabilityQualification $ResolvedRegistry $capability
        if ($execution -isnot [bool] -or
            (Get-Property (Get-Property $properties 'executionWithinSelectedGeometry') 'type') -cne 'boolean' -or
            $null -eq $geometryQualification) { throw 'ExecutionWithinSelectedGeometry requires an actual Boolean and exact reviewed registry/schema support.' }
        # Presence, not truthiness: explicit false must survive immutable receipt.
        $selected.executionWithinSelectedGeometry = $execution
    }
    $late = $selected.Contains('activation') -and $selected.activation -ceq 'main_post_processing'
    if ($late) {
        $window = Get-Property $ResolvedRegistry.registry 'lateWindow'
        if ((Get-Property $window 'runtime') -cne 'SkyrimVR' -or
            -not $selected.Contains('executionWithinSelectedGeometry') -or $selected.executionWithinSelectedGeometry -or
            'eye-submitted' -cnotin @($EventKinds) -or -not $BoundParameters.ContainsKey('MaxActivationWaitMs')) { throw 'Late activation requires advertised SkyrimVR support, explicit unrestricted geometry, eye-submitted selection and an explicit bounded wait.' }
    }
    if ($BoundParameters.ContainsKey('MaxActivationWaitMs')) {
        if (-not $late) { throw 'MaxActivationWaitMs requires explicit main_post_processing activation.' }
        $wait = Require-PositiveLong $BoundParameters.MaxActivationWaitMs 'MaxActivationWaitMs'
        $field = Get-Property $properties 'maxActivationWaitMs'
        if ((Get-Property $field 'type') -cne 'integer') { throw 'Input schema does not support integer maxActivationWaitMs.' }
        $minimum = Require-PositiveLong (Get-Property $field 'minimum') 'schema.maxActivationWaitMs.minimum'
        $maximum = Require-PositiveLong (Get-Property $field 'maximum') 'schema.maxActivationWaitMs.maximum'
        $registryMaximum = Require-PositiveLong (Get-Property (Get-Property $ResolvedRegistry.registry 'lateWindow') 'maximumActivationWaitMs') 'registry.lateWindow.maximumActivationWaitMs'
        if ($minimum -gt $maximum -or $wait -lt $minimum -or $wait -gt $maximum -or $wait -gt $registryMaximum) { throw 'MaxActivationWaitMs is outside advertised schema/registry bounds.' }
        $selected.maxActivationWaitMs = $wait
    }
    return [pscustomobject]@{
        arguments = $selected
        evidence = [pscustomobject]@{
            inputSchemaPath = $capture.path; inputSchemaSha256 = $capture.sha256
            inputSchemaBytes = $capture.bytes; registryMajor = $ResolvedRegistry.major
            producerBuildId = $ResolvedRegistry.producerBuildId
            geometryCapabilityQualification = $geometryQualification
            selected = [pscustomobject]$selected
            qualification = 'Caller-retained schema descriptor plus registry capabilities; offline planning does not prove live currency. Capture both from the same selected answering runtime and revalidate that binding before dispatch.'
        }
    }
}
