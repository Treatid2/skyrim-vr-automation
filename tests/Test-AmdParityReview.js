"use strict";
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = path.resolve(__dirname, '..');
const root = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'amd-parity-review-'));
const { runWorker } = require(path.join(source, 'tools/renderscale-tuning-live/durable-worker.js'));
const { createMock, positioningRoot, envelope, buildId } = require(path.join(source, 'tests/Test-RenderScaleTuningLiveRunner.js'));
const { memoryConfirmation } = require(path.join(source, 'tools/renderscale-tuning-finalizer/memory-confirmation.js'));
const { writeMemoryFixture } = require(path.join(source, 'tests/Test-RenderScaleMemoryConfirmation.js'));
const { finalizeEvidence } = require(path.join(source, 'tools/renderscale-tuning-finalizer/finalizer.js'));
const matrix = JSON.parse(fs.readFileSync(path.join(source, 'skills/renderscale-tuning-amd/references/matrix.v1.json')));

function request(name, fsr4Available = false) {
    const runRoot = path.join(root, name);
    fs.mkdirSync(path.join(runRoot, 'raw'), { recursive: true });
    const position = positioningRoot({ supportedFSRRuntimeMask: fsr4Available ? 3 : 1,
        fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: fsr4Available ? 0 : 1 }] });
    position.results.find(step => step.label === 'position-health').result = { pid: 7, exe: 'SkyrimVR.exe', vr: true };
    return { root: runRoot, runId: name, variant: 'amd', buildId, matrix, positioningRoot: position,
        startupReceipts: { prepare: envelope({ ready: true }), positioning: envelope(position) } };
}
function clientFor(mock) {
    return { initialize: async () => {}, close: async () => {},
        call: (name, args) => name === 'inspect' ? Promise.resolve(envelope({ pid: 7, exe: 'SkyrimVR.exe', vr: true })) :
            mock.context.tools[name === 'scenario' ? 'mcp__devbench_vr__scenario' : 'mcp__devbench_vr__communityshaders_renderscale'](args) };
}

async function traceFailure(refuseCleanup = false, loseStart = false) {
    const req = request(`amd-trace-failure-${refuseCleanup}-${loseStart}`);
    const mock = createMock(0), client = clientFor(mock), originalCall = client.call;
    client.call = async (name, args) => {
        if (loseStart && args.steps?.some(step => step.label === 'amd-dlss-trace-start')) {
            await originalCall(name, args);
            throw new Error('lost start response');
        }
        if (args.steps?.some(step => step.label === 'amd-dlss-trace-stop' ||
            refuseCleanup && step.label === 'dlss-trace-stop')) {
            return envelope({ ok: false, aborted: true, results: [
                { label: args.steps[0].label, ok: false, error: 'stop refused' }] });
        }
        return originalCall(name, args);
    };
    const result = await runWorker(req, { client });
    const check = await originalCall('scenario', { action: 'run', async: false, continueOnError: false,
        steps: [{ label: 'trace-after-worker', tool: 'communityshaders.renderscale', args: { action: 'dlss_trace_status' } }] });
    const trace = JSON.parse(check.content[0].text).results[0].result.capture;
    assert.equal(result.state, 'INTERRUPTED');
    assert.equal(trace.active, refuseCleanup || loseStart);
    assert.equal(Boolean(result.cleanupVerified || !result.mutationDispatched), !refuseCleanup && !loseStart);
    assert.equal(result.mutationDispatched, true);
    if (!loseStart) assert.equal(result.ownership.traceSessionId, 1);
    return { workerState: result.state, cleanupVerified: result.cleanupVerified,
        mutationDispatched: result.mutationDispatched ?? null, ownership: result.ownership,
        captureAfterTerminal: trace,
        launchExitWouldReleaseEndpointLock: result.cleanupVerified || !result.mutationDispatched,
        measuredTransitions: result.completedTransitions };
}

async function foreignTrace() {
    const req = request('amd-foreign-trace');
    const mock = createMock(0), client = clientFor(mock), original = client.call;
    client.call = async (name, args) => {
        const response = await original(name, args);
        if (args.steps?.some(step => step.label === 'amd-dlss-trace-status')) {
            const root = JSON.parse(response.content[0].text);
            root.results[0].result.capture.active = true;
            root.results[0].result.capture.sessionID = 71;
            return envelope(root);
        }
        return response;
    };
    const result = await runWorker(req, { client });
    assert.equal(result.state, 'INTERRUPTED');
    assert(!mock.scenarioCalls.some(call => call.steps.some(step =>
        ['dlss_trace_reset', 'dlss_trace_start', 'dlss_trace_stop'].includes(step.args?.action))));
}

function blockedMemory(fsr4Available) {
    const memoryRoot = path.join(root, `memory-${fsr4Available}`);
    fs.mkdirSync(memoryRoot, { recursive: true });
    const active = fsr4Available ? ['explicit_fsr4', 'explicit_fsr3'] : ['explicit_fsr3', 'fsr4_to_fsr3_fallback'];
    const fixtures = active.map(lane => writeMemoryFixture(memoryRoot, { variant: 'amd', lane }));
    const options = { ...fixtures[0], retained: fixtures.flatMap(fixture => fixture.retained),
        liveResult: { ...fixtures[0].liveResult,
            lanes: matrix.lanes.map(lane => ({ id: lane.id, status: active.includes(lane.id) ? 'COMPLETE' : 'BLOCKED',
                eligibility: { supportedFSRRuntimeMask: fsr4Available ? 3 : 1,
                    fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: fsr4Available ? 0 : 1 }] },
                passes: active.includes(lane.id) ? [{ pass: 1, status: 'COMPLETE' }, { pass: 2, status: 'COMPLETE' }] : [] })) } };
    const positionPath = path.join(memoryRoot, 'raw/startup/positioning.json');
    fs.mkdirSync(path.dirname(positionPath), { recursive: true });
    fs.writeFileSync(positionPath, JSON.stringify(positioningRoot(options.liveResult.lanes[0].eligibility)));
    const result = memoryConfirmation(options);
    for (const lane of active) assert.equal(result.lanes[lane].status, 'complete');
    assert.equal(result.status, 'complete');
    const blocked = matrix.lanes.find(lane => !active.includes(lane.id)).id;
    assert.equal(result.lanes[blocked].status, 'not_applicable');
    assert.equal(result.lanes[blocked].boundaries.pass1.start.processPrivateMiB, null);
    const incomplete = structuredClone(options.liveResult);
    fs.writeFileSync(positionPath, JSON.stringify(positioningRoot({})));
    assert.equal(memoryConfirmation({ ...options, liveResult: incomplete }).status, 'incomplete');
    fs.writeFileSync(positionPath, JSON.stringify(positioningRoot(options.liveResult.lanes[0].eligibility)));
    incomplete.lanes.find(lane => lane.id === blocked).passes = [{ pass: 1 }];
    assert.equal(memoryConfirmation({ ...options, liveResult: incomplete }).status, 'incomplete');
    return { fsr4Available, status: result.status, lanes: Object.fromEntries(Object.entries(result.lanes).map(([key, lane]) =>
        [key, { status: lane.status, execution: lane.laneExecutionStatus, passesCompleted: lane.passesCompleted,
            issueCount: lane.issues.length, firstIssues: lane.issues.slice(0, 3) }])) };
}

async function wrongBackend() {
    const req = request('amd-fsr4-with-fsr3-proof', true);
    const mock = createMock(0, waiter => {
        const effective = waiter.upscalingSnapshot.profiles.effective;
        waiter.target = { method: effective.method.name, qualityMode: ['native_aa', 'hoshipa', 'ultra_quality', 'quality',
            'balanced', 'performance', 'ultra_performance'].indexOf(effective.qualityMode.name),
            renderScaleMode: effective.renderScaleMode, fsrRuntime: effective.fsrRuntime.name };
        if (waiter.target.method === 'fsr' && !waiter.target.renderScaleMode) {
            waiter.nativeVendorExecution = { actualBackend: 'fsr_host', actualRuntimeFallbackObserved: false };
        }
        return waiter;
    });
    const result = await runWorker(req, { client: clientFor(mock) });
    const summary = finalizeEvidence({ root: req.root, runId: req.runId, variant: 'amd', buildId, expectedRows: 124 }).summary;
    const bad = summary.transitions.filter(row => row.lane === 'explicit_fsr4' && row.target.method === 'fsr' &&
        row.target.renderScaleMode && row.actualBackend === 'fsr_host');
    assert.ok(bad.length > 0);
    assert.ok(bad.every(row => row.renderVerdict === 'PASS' && row.task2Verdict === 'PASS'));
    assert.ok(bad.every(row => row.laneQualification.verdict === 'FAIL'));
    assert.equal(summary.laneQualification.verdict, 'FAIL');
    return { workerState: result.state, incorrectBackendRows: bad.length,
        rows: bad.slice(0, 3).map(row => ({ lane: row.lane, pass: row.pass, ordinal: row.ordinal,
            target: row.target, actualBackend: row.actualBackend, laneQualification: row.laneQualification, renderVerdict: row.renderVerdict, task2Verdict: row.task2Verdict })) };
}

function backendCases() {
    const { qualifyLaneBackend } = require(path.join(source, 'tools/renderscale-tuning-live/runner.js'));
    for (const lane of matrix.lanes) {
        const fallback = lane.id === 'fsr4_to_fsr3_fallback';
        const capabilities = { supportedFSRRuntimeMask: fallback ? 1 : 3,
            fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: fallback ? 1 : 0 }] };
        for (const scaled of [true, false]) for (const backend of lane.expectedBackends) {
            const waiter = { nativeVendorExecution: { actualBackend: backend, actualRuntimeFallbackObserved: fallback },
                replacementTimeline: { terminal: { presentationProof: { backend,
                    leftEye: { backend, vendorRuntimeFallback: fallback },
                    rightEye: { backend, vendorRuntimeFallback: fallback } } } } };
            const target = { method: 'fsr', fsrRuntime: lane.configuredFsrRuntime, renderScaleMode: scaled };
            assert.equal(qualifyLaneBackend(waiter, target, lane, capabilities).verdict, 'PASS');
            assert.equal(qualifyLaneBackend(waiter, { ...target, fsrRuntime: 'auto' }, lane, capabilities).verdict, 'FAIL');
            if (lane.requiresFsr4Available || fallback) {
                const missing = structuredClone(waiter);
                delete missing.nativeVendorExecution.actualRuntimeFallbackObserved;
                delete missing.replacementTimeline.terminal.presentationProof.leftEye.vendorRuntimeFallback;
                assert.equal(qualifyLaneBackend(missing, target, lane, capabilities).verdict, 'FAIL');
            }
            if (fallback) assert.equal(qualifyLaneBackend(waiter, target, lane,
                { ...capabilities, fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: 0 }] }).verdict, 'FAIL');
        }
    }
}

(async () => {
    backendCases();
    await foreignTrace();
    const result = { fixtureRoot: root, traceFailure: [await traceFailure(), await traceFailure(true), await traceFailure(false, true)], blockedMemory: [blockedMemory(false), blockedMemory(true)],
        wrongBackend: await wrongBackend() };
    console.log(JSON.stringify(result, null, 2));
    fs.rmSync(root, { recursive: true, force: true });
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
