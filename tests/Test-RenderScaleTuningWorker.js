// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const http = require("node:http");
const { EventEmitter } = require("node:events");
const { spawn } = require("node:child_process");
const { ReceiptQueue, runWorker, McpClient } =
    require("../tools/renderscale-tuning-live/durable-worker.js");
const { createMock, positioningRoot, envelope, buildId } = require("./Test-RenderScaleTuningLiveRunner.js");
const source = path.resolve(__dirname, "..");
const matrix = JSON.parse(fs.readFileSync(path.join(source,
    "skills/renderscale-tuning-nvidia/references/matrix.v1.json")));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "tuning-worker-test-"));
function request(name) {
    const root = path.join(temporary, name);
    fs.mkdirSync(path.join(root, "raw", "journal"), { recursive: true });
    const positioning = positioningRoot();
    positioning.results.find(step => step.label === "position-health").result = { pid: 7, exe: "SkyrimVR.exe", vr: true };
    return { root, runId: name, variant: "nvidia", buildId, matrix, positioningRoot: positioning,
        startupReceipts: { prepare: envelope({ ready: true }), positioning: envelope(positioning) } };
}
function clientFor(mock) {
    return { initialize: async () => {}, close: async () => {}, call: (name, args) =>
        name === "inspect" ? Promise.resolve(envelope({ pid: 7, exe: "SkyrimVR.exe", vr: true })) :
        mock.context.tools[name === "scenario" ? "mcp__devbench_vr__scenario" :
            "mcp__devbench_vr__communityshaders_renderscale"](args) };
}
async function testQueue() {
    const req = request("queue");
    const writer = new EventEmitter(); writer.postMessage = message => {
        if (message.flush) queueMicrotask(() => writer.emit("message", { flushed: true }));
        else messages.push(structuredClone(message));
    };
    writer.terminate = async () => {};
    const messages = [];
    const queue = new ReceiptQueue(req.root, writer);
    const value = { before: true };
    await queue.write("queue:row", value);
    value.before = false;
    assert.equal(messages[0].value.before, true);
    assert.equal(queue.pending.size, 1, "enqueue waited for a disk acknowledgement");
    for (let i = 1; i < 300; i++) await queue.write(`queue:${i}`, {});
    assert.equal(queue.pending.size, 300, "a save backlog blocked or stopped measurement");
    let drained = false;
    const draining = queue.drain().then(() => { drained = true; });
    await new Promise(resolve => setImmediate(resolve)); assert.equal(drained, false);
    for (const message of messages) writer.emit("message", { sequence: message.sequence });
    await draining; await queue.close();
    const broken = new ReceiptQueue(req.root, writer);
    writer.emit("error", new Error("disk full"));
    await assert.rejects(broken.write("queue:failed", {}), /disk full/);
    await assert.rejects(broken.close(), /disk full/);
}
async function testFullMatrix() {
    const req = request("complete");
    const mock = createMock(0);
    const result = await runWorker(req, { client: clientFor(mock) });
    assert.equal(result.state, "COMPLETE", JSON.stringify(result));
    assert.equal(result.completedTransitions, 66);
    assert.equal(result.cleanupVerified, true);
    const journal = fs.readFileSync(path.join(req.root, "raw", "journal.ndjson"), "utf8").trim().split("\n");
    const last = JSON.parse(journal.at(-1));
    assert.equal(last.receiptKey, "complete:live-result");
    assert.equal(last.value.status, "COMPLETE");
    const records = journal.map(line => JSON.parse(line));
    const rows = new Map(records.filter(entry => /:pass-\d+:transition-\d+$/.test(entry.receiptKey))
        .map(entry => [entry.receiptKey, entry.value]));
    assert.equal(rows.size, 66, "The document omitted measured transitions");
    for (const row of rows.values()) {
        assert.equal(row.waiter.timing.elapsedMs, 1);
        assert.equal(row.waiter.timing.dispatchTick, 10);
        assert.equal(row.waiter.timing.stableTick, 11);
    }
    assert.ok(fs.statSync(path.join(req.root, "worker-status.json")).size < 6000);
}
async function testSlowSavingAndFailure() {
    const req = request("slow");
    const mock = createMock(0);
    let pending = 0, overlapped = false;
    const client = clientFor(mock), call = client.call;
    client.call = (name, args) => {
        if (name === "scenario" && args.steps[0]?.label === "transition-pace" && pending) overlapped = true;
        return call(name, args);
    };
    const saves = [];
    const journal = { root: req.root, check() {}, write: async () => {
        pending++; saves.push(new Promise(resolve => setTimeout(() => { pending--; resolve(); }, 30)));
    }, drain: () => Promise.all(saves), close: () => Promise.all(saves) };
    const result = await runWorker(req, { client, journal });
    assert.equal(result.state, "COMPLETE"); assert.equal(overlapped, true); assert.equal(pending, 0);

    const failed = request("write-failure"), failureMock = createMock(0);
    let writes = 0;
    const failingJournal = { root: failed.root, check() {}, write: async () => {
        if (++writes >= 8) throw new Error("disk full");
    }, drain: async () => {}, close: async () => {} };
    const interrupted = await runWorker(failed, { client: clientFor(failureMock), journal: failingJournal });
    assert.equal(interrupted.state, "INTERRUPTED");
    assert.equal(interrupted.cleanupVerified, true, "disk errors prevented ownership cleanup");
}
async function testPacing() {
    const req = request("pacing"), mock = createMock(0);
    const real = clientFor(mock), call = real.call;
    real.call = async (name, args) => {
        const value = await call(name, args);
        return value;
    };
    const queue = { root: req.root, check() {}, write: async key => {
        if (key.endsWith(":pass-1:transition-1:scenario")) await new Promise(resolve => setTimeout(resolve, 300));
    }, drain: async () => {}, close: async () => {} };
    const result = await runWorker(req, { client: real, journal: queue });
    assert.equal(result.state, "COMPLETE"); assert.equal(result.pacing.status, "EXCEEDED");
    assert.equal(result.completedTransitions, 66); assert.equal(result.cleanupVerified, true);
}
async function testDetachedAndMcp() {
    const fixture = path.join(temporary, "plugin");
    fs.mkdirSync(path.join(fixture, "tools"), { recursive: true });
    fs.cpSync(path.join(source, "tools", "renderscale-tuning-live"), path.join(fixture, "tools", "renderscale-tuning-live"), { recursive: true });
    fs.mkdirSync(path.join(fixture, "skills/renderscale-tuning-nvidia/references"), { recursive: true });
    fs.writeFileSync(path.join(fixture, "skills/renderscale-tuning-nvidia/references/matrix.v1.json"), JSON.stringify(matrix));
    const mock = createMock(0), mockClient = clientFor(mock);
    const sessions = new Map();
    let sessionSerial = 0;
    const server = http.createServer(async (req, res) => {
        const sessionId = req.headers["mcp-session-id"];
        if (req.method === "DELETE") { sessions.delete(sessionId); res.writeHead(200).end(); return; }
        if (req.method === "GET") {
            assert.ok(sessions.has(sessionId));
            res.writeHead(200, { "Content-Type": "text/event-stream" });
            const beat = () => { sessions.set(sessionId, Date.now()); res.write(": heartbeat\r\n\r\n"); };
            beat();
            const timer = setInterval(beat, 10);
            res.on("close", () => clearInterval(timer));
            return;
        }
        let text = ""; for await (const chunk of req) text += chunk;
        const rpc = JSON.parse(text);
        res.setHeader("Content-Type", "application/json");
        if (rpc.method === "initialize") {
            const created = `test-session-${++sessionSerial}`;
            sessions.set(created, Date.now()); res.setHeader("Mcp-Session-Id", created);
        } else if (!sessions.has(sessionId) || Date.now() - sessions.get(sessionId) > 100) {
            res.writeHead(404).end('{"error":"Session not found"}'); return;
        }
        if (rpc.method === "notifications/initialized") { res.writeHead(202).end(); return; }
        const result = rpc.method === "initialize" ? {} : await mockClient.call(rpc.params.name, rpc.params.arguments);
        // Simulates server-owned work continuing while the launching client exits.
        if (rpc.params?.name === "scenario") await new Promise(resolve =>
            setTimeout(resolve, process.argv.includes("--detached-only") ? 100 : 5));
        res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result }));
    });
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    try {
    const endpoint = `http://127.0.0.1:${server.address().port}/mcp`;
    fs.writeFileSync(path.join(fixture, ".mcp.json"), JSON.stringify({ mcpServers: { devbench_vr: { type: "http", url: endpoint } } }));
    const req = request("detached-startup");
    req.runId = "detached"; req.workspace = temporary;
    const file = path.join(temporary, "request.json"); fs.writeFileSync(file, JSON.stringify(req));
    const entrypoint = path.join(fixture, "tools/renderscale-tuning-live/durable-worker.js");
    const child = spawn(process.execPath, [entrypoint, "start", file], {
        env: { ...process.env, LOCALAPPDATA: path.join(temporary, "state") }, windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "", errors = "";
    child.stdout.on("data", data => { output += data; }); child.stderr.on("data", data => { errors += data; });
    await new Promise((resolve, reject) => child.on("exit", code => code === 0 ? resolve() : reject(new Error(errors))));
    const launched = JSON.parse(output);
    assert.ok(launched.pid > 0);
    const started = Date.now(); let state;
    do {
        await new Promise(resolve => setTimeout(resolve, 50));
        if (fs.existsSync(launched.statusPath)) state = JSON.parse(fs.readFileSync(launched.statusPath));
    } while ((!state || state.state === "RUNNING") && Date.now() - started < 20000);
    assert.equal(state?.state, "COMPLETE", JSON.stringify(state));
    assert.equal(state.completedTransitions, 66, "worker stopped after launcher exited");
    assert.equal(state.cleanupVerified, true);
    const rpc = new McpClient(endpoint); await rpc.initialize(); await rpc.close();
    } finally {
        server.closeAllConnections();
        await new Promise(resolve => server.close(resolve));
    }
}
async function testStreamingResponse() {
    let cancelled = false;
    const stream = new ReadableStream({
        start(controller) {
            controller.enqueue(new TextEncoder().encode('event: message\r\ndata: {"jsonrpc":"2.0",'));
            controller.enqueue(new TextEncoder().encode('"id":9,"result":{}}\r\n\r\n'));
        }, cancel() { cancelled = true; },
    });
    const response = await new McpClient("http://127.0.0.1/mcp").eventResponse(
        new Response(stream), 9);
    assert.equal(response.id, 9); assert.equal(cancelled, true);
}
async function testCleanupRecovery() {
    for (const mode of ["expired", "lost-stop-response", "changed-process", "foreign-capture", "incomplete-status", "unavailable"]) {
        const req = request(`cleanup-${mode}`), mock = createMock(0);
        const client = clientFor(mock), originalCall = client.call;
        let failed = false, reconnected = 0, stopBatches = 0, measuredCalls = 0;
        client.reconnectForCleanup = async () => {
            reconnected++;
            if (mode === "unavailable") throw new Error("connection refused");
            return {};
        };
        client.call = async (name, args) => {
            if (name === "inspect" && reconnected && mode === "changed-process") {
                return envelope({ pid: 8, exe: "SkyrimVR.exe", vr: true });
            }
            const measured = args.steps?.[0]?.label === "transition-pace";
            if (measured) measuredCalls++;
            const stopBatch = args.steps?.some(step => step.label === "measured-stress-stop");
            if (stopBatch) {
                stopBatches++;
                assert.equal(args.continueOnError, true);
                assert.equal(args.steps.find(step => step.label === "cpu-performance-stop").args.expectedSessionId, 11);
                assert.equal(args.steps.find(step => step.label === "gpu-performance-stop").args.expectedStartFrame, 10);
            }
            if (mode !== "lost-stop-response" && measured && measuredCalls === 2) {
                failed = true;
                throw new Error("mcp_http_404: Session not found");
            }
            if (failed && !reconnected) throw new Error("mcp_http_404: Session not found");
            const result = await originalCall(name, args);
            if (mode === "lost-stop-response" && stopBatch && !failed) {
                failed = true;
                throw new Error("response connection reset after stops executed");
            }
            if (["foreign-capture", "incomplete-status"].includes(mode) && reconnected &&
                args.steps?.some(step => step.label === "cpu-status")) {
                const root = JSON.parse(result.content[0].text);
                const cpu = root.results.find(step => step.label === "cpu-status").result.cpuPerformance;
                if (mode === "foreign-capture") cpu.sessionId = 999;
                else delete cpu.active;
                return envelope(root);
            }
            return result;
        };
        const result = await runWorker(req, { client });
        assert.equal(reconnected, 1, mode);
        if (mode === "expired") {
            assert.equal(result.state, "INTERRUPTED");
            assert.equal(result.cleanupVerified, true);
            assert.equal(result.cleanup.state, "VERIFIED_INACTIVE");
            assert.equal(measuredCalls, 2, "failed transition was replayed");
            assert.equal(stopBatches, 1);
        } else if (mode === "lost-stop-response") {
            assert.equal(result.state, "INTERRUPTED", JSON.stringify(result));
            assert.equal(result.cleanupVerified, true);
            assert.equal(stopBatches, 1, "a stop batch was replayed instead of verified");
            assert.equal(measuredCalls, 33, "measurement resumed on a cleanup connection");
        } else {
            assert.equal(result.state, "INTERRUPTED");
            assert.equal(result.cleanupVerified, false);
            assert.equal(stopBatches, 0, "unproven ownership was mutated");
            assert.equal(result.cleanup.state, "BLOCKED");
            assert.equal(result.ownership.cpuSessionId, 11);
            assert.equal(result.ownership.gpuStartFrame, 10);
            assert.equal(result.ownership.pid, 7);
        }
    }
}
async function testCleanupStopFailure() {
    const req = request("stop-failure"), mock = createMock(0);
    const client = clientFor(mock), originalCall = client.call;
    let stopBatches = 0, finalStatus;
    client.call = async (name, args) => {
        if (args.steps?.some(step => step.label === "measured-stress-stop")) {
            stopBatches++;
            assert.equal(args.continueOnError, true);
            const result = await originalCall(name, { ...args,
                steps: args.steps.filter(step => step.label !== "cpu-performance-stop") });
            const root = JSON.parse(result.content[0].text);
            root.ok = false;
            root.results.push({ label: "cpu-performance-stop", ok: false, error: "stop refused" });
            return envelope(root);
        }
        const result = await originalCall(name, args);
        if (stopBatches && args.steps?.some(step => step.label === "cpu-status")) {
            finalStatus = JSON.parse(result.content[0].text);
        }
        return result;
    };
    const result = await runWorker(req, { client });
    assert.equal(stopBatches, 1, "failed stop batch was replayed");
    assert.equal(result.cleanupVerified, false);
    assert.equal(result.cleanup.error, "cleanup_verification_failed");
    const by = Object.fromEntries(finalStatus.results.map(step => [step.label, step.result]));
    assert.equal(by["cpu-status"].cpuPerformance.active, true);
    assert.equal(by["gpu-status"].capture.active, false);
    assert.equal(by["texture-status"].capture.active, false);
    assert.equal(by["profiler-status"].result.enabled, false);
}
(async () => {
    if (process.argv.includes("--detached-only")) {
        await testDetachedAndMcp();
        console.log(`Detached tool-boundary test passed; fixtures: ${temporary}`);
        return;
    }
    await testQueue(); await testFullMatrix(); await testSlowSavingAndFailure();
    await testPacing(); await testStreamingResponse(); await testCleanupRecovery();
    await testCleanupStopFailure(); await testDetachedAndMcp();
    console.log(`Durable tuning worker tests passed; fixtures: ${temporary}`);
})().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
