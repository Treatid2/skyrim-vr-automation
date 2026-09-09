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
    const server = http.createServer(async (req, res) => {
        if (req.method === "DELETE") { res.writeHead(200).end(); return; }
        let text = ""; for await (const chunk of req) text += chunk;
        const rpc = JSON.parse(text);
        res.setHeader("Content-Type", "application/json"); res.setHeader("Mcp-Session-Id", "test-session");
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
(async () => {
    if (process.argv.includes("--detached-only")) {
        await testDetachedAndMcp();
        console.log(`Detached tool-boundary test passed; fixtures: ${temporary}`);
        return;
    }
    await testQueue(); await testFullMatrix(); await testSlowSavingAndFailure();
    await testPacing(); await testStreamingResponse(); await testDetachedAndMcp();
    console.log(`Durable tuning worker tests passed; fixtures: ${temporary}`);
})().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
