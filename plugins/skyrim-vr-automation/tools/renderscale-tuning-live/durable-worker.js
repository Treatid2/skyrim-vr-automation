// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const os = require("node:os");
const { spawn } = require("node:child_process");
const { Worker } = require("node:worker_threads");
const { runRenderScaleTuningLive } = require("./runner.js");

const MAX_DISPATCH_GAP_MS = 250;

function atomicJson(file, value) {
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(value));
    fs.renameSync(temporary, file);
}

function statusPublisher(file) {
    let pending = null, active = null, failure = null;
    return {
        publish(value) {
            pending = JSON.stringify(value);
            if (!active) active = (async () => {
                while (pending !== null) {
                    const next = pending; pending = null;
                    const temporary = `${file}.${process.pid}.tmp`;
                    await fs.promises.writeFile(temporary, next);
                    // Windows readers can briefly prevent replacement; retry off the dispatch path.
                    for (let attempt = 0; ; attempt++) {
                        try { await fs.promises.rename(temporary, file); break; }
                        catch (error) {
                            if (!["EPERM", "EACCES", "EBUSY"].includes(error.code) || attempt === 24) throw error;
                            await new Promise(resolve => setTimeout(resolve, 20));
                        }
                    }
                }
            })().catch(error => { failure = error; }).finally(() => { active = null; });
        },
        async drain() { await active; if (failure) throw failure; },
    };
}

function envelopeRoot(envelope) {
    if (envelope?.isError || envelope?.content?.[0]?.type !== "text") {
        throw new Error("invalid_mcp_envelope");
    }
    return JSON.parse(envelope.content[0].text);
}

function readRequest(file) {
    const request = JSON.parse(fs.readFileSync(file, "utf8"));
    if (!["nvidia", "amd"].includes(request.variant) || !/^[a-zA-Z0-9_-]+$/.test(request.runId) ||
        !/^[a-fA-F0-9]{64}$/.test(request.buildId) || !path.isAbsolute(request.workspace)) {
        throw new Error("invalid_worker_request");
    }
    const configured = JSON.parse(fs.readFileSync(path.join(__dirname, "../../.mcp.json"), "utf8"));
    const selected = configured.mcpServers?.devbench_vr;
    const endpoint = new URL(selected?.url);
    if (selected.type !== "http" || endpoint.protocol !== "http:" ||
        !["127.0.0.1", "[::1]"].includes(endpoint.hostname) ||
        endpoint.pathname !== "/mcp" || endpoint.username || endpoint.password ||
        endpoint.search || endpoint.hash) throw new Error("invalid_selected_mcp_endpoint");
    request.endpoint = endpoint.href;
    request.root = path.join(request.workspace, "artifacts", "renderscale-tuning", request.runId);
    request.ownerRoot = path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), ".local", "state"),
        "SkyrimVRAutomation", "renderscale-tuning");
    request.matrix = JSON.parse(fs.readFileSync(path.join(__dirname,
        `../../skills/renderscale-tuning-${request.variant}/references/matrix.v1.json`), "utf8"));
    return request;
}

class ReceiptQueue {
    constructor(root, writer = new Worker(path.join(__dirname, "journal-worker.js"), { workerData: { root } })) {
        this.root = root;
        this.writer = writer;
        this.sequence = 0;
        this.pending = new Map();
        this.error = null;
        this.waiters = [];
        this.closing = false;
        this.highWaterReceipts = 0;
        this.flushWaiters = [];
        writer.on("message", message => {
            if (message.error) this.fail(new Error(`receipt_write_failed: ${message.error}`));
            if (message.flushed) {
                for (const waiter of this.flushWaiters.splice(0)) waiter.resolve();
                return;
            }
            if (!this.pending.has(message.sequence)) return this.fail(new Error("receipt_ack_mismatch"));
            this.pending.delete(message.sequence);
            this.settle();
        });
        writer.on("error", error => this.fail(error));
        writer.on("exit", code => {
            if (!this.closing || this.pending.size) this.fail(new Error(`receipt_writer_exit: ${code}`));
        });
    }
    fail(error) {
        this.error ||= error; this.settle();
        for (const waiter of this.flushWaiters.splice(0)) waiter.reject(this.error);
    }
    check() { if (this.error) throw this.error; }
    settle() {
        if (this.error || this.pending.size === 0) {
            for (const waiter of this.waiters.splice(0)) {
                if (this.error) waiter.reject(this.error); else waiter.resolve();
            }
        }
    }
    async write(receiptKey, value) {
        this.check();
        const sequence = ++this.sequence;
        this.pending.set(sequence, true);
        this.highWaterReceipts = Math.max(this.highWaterReceipts, this.pending.size);
        // postMessage snapshots this revision; the writer may drain it after measurement.
        try { this.writer.postMessage({ sequence, receiptKey, value }); }
        catch (error) { this.fail(error); throw error; }
    }
    async drain() {
        this.check();
        if (this.pending.size) await new Promise((resolve, reject) => this.waiters.push({ resolve, reject }));
        this.check();
        await new Promise((resolve, reject) => {
            this.flushWaiters.push({ resolve, reject });
            this.writer.postMessage({ flush: true });
        });
    }
    async close() {
        try { await this.drain(); }
        finally { this.closing = true; await this.writer.terminate(); }
    }
}

class McpClient {
    constructor(endpoint) {
        this.endpoint = endpoint; this.id = 0; this.session = null; this.protocol = "2025-03-26";
        this.streamAbort = null; this.streamTask = null; this.transportError = null;
        this.streamReader = null; this.closeTimeoutMs = 5000;
        this.requestTimeoutMs = 90000;
    }
    async openNotifications() {
        const controller = new AbortController();
        this.streamAbort = controller;
        const timeout = setTimeout(() => controller.abort(new Error("mcp_stream_connect_timeout")), 5000);
        let response;
        try {
            response = await fetch(this.endpoint, { method: "GET", redirect: "error",
                headers: { Accept: "text/event-stream", "Mcp-Session-Id": this.session,
                    "MCP-Protocol-Version": this.protocol }, signal: controller.signal });
            if (!response.ok) throw new Error(`mcp_stream_http_${response.status}`);
            if (!(response.headers.get("content-type") || "").includes("text/event-stream")) {
                throw new Error("mcp_stream_content_type_invalid");
            }
        } catch (error) { controller.abort(); throw error; }
        finally { clearTimeout(timeout); }
        // Drain notifications on this session while POST owns every tool response.
        this.streamTask = (async () => {
            const reader = response.body.getReader();
            this.streamReader = reader;
            try {
                while (!(await reader.read()).done) { /* The runner consumes correlated POST receipts. */ }
                if (!controller.signal.aborted) throw new Error("mcp_notification_stream_closed");
            } finally {
                reader.releaseLock();
                if (this.streamReader === reader) this.streamReader = null;
            }
        })().catch(error => {
            if (!controller.signal.aborted) this.transportError = error;
        });
    }
    async eventResponse(response, id) {
        const reader = response.body.getReader(), decoder = new TextDecoder();
        let buffered = "";
        try {
            while (true) {
                const { value, done } = await reader.read();
                buffered += decoder.decode(value, { stream: !done });
                let boundary;
                while ((boundary = /\r?\n\r?\n/.exec(buffered))) {
                    const block = buffered.slice(0, boundary.index);
                    buffered = buffered.slice(boundary.index + boundary[0].length);
                    const data = block.split(/\r?\n/).filter(line => line.startsWith("data:"))
                        .map(line => line.slice(5).trimStart()).join("\n");
                    if (!data) continue;
                    const message = JSON.parse(data);
                    if (message.id === id) return message;
                }
                if (done) throw new Error("mcp_response_missing");
            }
        } finally { await reader.cancel(); }
    }
    async rpc(method, params, notification = false) {
        if (this.transportError) throw this.transportError;
        try { return await this.request(method, params, notification); }
        catch (error) { this.transportError = error; throw error; }
    }
    async request(method, params, notification) {
        const id = ++this.id;
        const headers = { "Content-Type": "application/json", Accept: "application/json, text/event-stream" };
        if (this.session) headers["Mcp-Session-Id"] = this.session;
        headers["MCP-Protocol-Version"] = this.protocol;
        const response = await fetch(this.endpoint, {
            method: "POST", headers,
            body: JSON.stringify({ jsonrpc: "2.0", ...(notification ? {} : { id }), method, params }),
            signal: AbortSignal.timeout(this.requestTimeoutMs), redirect: "error",
        });
        if (!response.ok) {
            const detail = (await response.text()).slice(0, 1024);
            throw new Error(`mcp_http_${response.status}: ${detail}`);
        }
        if (method === "initialize") this.session = response.headers.get("Mcp-Session-Id");
        if (notification) { await response.arrayBuffer(); return; }
        let payload;
        if ((response.headers.get("content-type") || "").includes("text/event-stream")) {
            payload = await this.eventResponse(response, id);
        } else payload = await response.json();
        if (!payload || payload.id !== id || payload.jsonrpc !== "2.0" || payload.error) {
            throw new Error(`mcp_response_invalid: ${JSON.stringify(payload?.error || null)}`);
        }
        return payload.result;
    }
    async initialize() {
        const initialized = await this.rpc("initialize", { protocolVersion: this.protocol, capabilities: {},
            clientInfo: { name: "renderscale-tuning-worker", version: "1" } });
        if (initialized?.protocolVersion) this.protocol = initialized.protocolVersion;
        if (!this.session) throw new Error("mcp_session_missing");
        await this.rpc("notifications/initialized", {}, true);
        await this.openNotifications();
    }
    call(name, args) { return this.rpc("tools/call", { name, arguments: args }); }
    async close() {
        const reader = this.streamReader, streamTask = this.streamTask, session = this.session;
        const controller = new AbortController();
        let timeout;
        const deadline = new Promise((_resolve, reject) => {
            timeout = setTimeout(() => {
                const error = new Error("mcp_close_timeout");
                controller.abort(error); reject(error);
            }, this.closeTimeoutMs);
        });
        try {
            this.streamAbort?.abort();
            const stopStream = (async () => {
                // Fetch abort can leave a body read pending; cancel its reader explicitly.
                try { await reader?.cancel(); }
                catch (error) { if (error.name !== "AbortError") throw error; }
                await streamTask;
            })();
            const deleteSession = (async () => {
                if (!session) return;
                const response = await fetch(this.endpoint, { method: "DELETE", redirect: "error",
                    headers: { "Mcp-Session-Id": session }, signal: controller.signal });
                if (!response.ok && response.status !== 404) throw new Error(`mcp_close_${response.status}`);
                if (this.session === session) this.session = null;
                await response.body?.cancel();
            })();
            await Promise.race([Promise.all([stopStream, deleteSession]), deadline]);
        } finally { clearTimeout(timeout); controller.abort(); }
    }
    async reconnectForCleanup() {
        // Reconnection is restricted to cleanup; no failed measurement is replayed.
        this.requestTimeoutMs = 10000;
        let closeError = null;
        try { await this.close(); } catch (error) { closeError = String(error.message || error); }
        this.session = null;
        this.transportError = null;
        await this.initialize();
        return { closeError };
    }
}

function compactProgress(value) {
    const names = ["phase", "status", "cellEditorId", "lane", "pass", "ordinal", "target",
        "satisfied", "nonStableNote", "renderVerdict", "evidenceVerdict", "task2Verdict", "elapsedMs", "outcome"];
    return Object.fromEntries(names.filter(name => value[name] !== undefined).map(name => [name, value[name]]));
}

async function runWorker(request, dependencies = {}) {
    const client = dependencies.client || new McpClient(request.endpoint);
    const journal = dependencies.journal || new ReceiptQueue(request.root);
    const runner = dependencies.runner || runRenderScaleTuningLive;
    const statusPath = path.join(request.root, "worker-status.json");
    const status = { runId: request.runId, variant: request.variant, buildId: request.buildId, pid: process.pid,
        state: "RUNNING", completedTransitions: 0, startedUtc: new Date().toISOString(),
        pacing: { status: "VALID", maximumClientDispatchGapMs: 0, budgetMs: MAX_DISPATCH_GAP_MS } };
    const publisher = statusPublisher(statusPath);
    const publish = () => publisher.publish({ ...status, updatedUtc: new Date().toISOString(),
        evidencePending: journal.pending?.size ?? 0 });
    let lastRowResponse = null;
    let previousWaiter = null;
    let cleanupVerified = false;
    let cleanupReconnects = 0;
    let transportFailed = false;
    let invocation = 0;
    const expected = request.positioningRoot?.results?.find(step => step.label === "position-health")?.result;
    const verifyProcess = async () => {
        const health = envelopeRoot(await client.call("inspect", { kind: "health" }));
        if (!Number.isSafeInteger(expected?.pid) || health.pid !== expected.pid ||
            health.exe !== expected.exe || health.vr !== true) throw new Error("positioned_process_changed");
    };
    const recoverCleanupTransport = async error => {
        if (!transportFailed && !client.transportError) return;
        if (++cleanupReconnects > 1 || typeof client.reconnectForCleanup !== "function") {
            throw new Error("cleanup_transport_recovery_unavailable");
        }
        status.cleanup = { state: "RECONNECTING", reason: String(error?.message || client.transportError || "transport_failure") };
        publish();
        const recovery = await client.reconnectForCleanup();
        await verifyProcess();
        transportFailed = false;
        status.cleanup = { state: "VERIFYING_OWNERS", reconnected: true, ...recovery };
        publish();
    };
    const call = async (name, args) => {
        try { return await client.call(name, args); }
        catch (error) {
            transportFailed = true;
            status.transportError = String(error.message || error);
            throw error;
        }
    };
    const tools = {
        mcp__devbench_vr__communityshaders_renderscale: args => call("communityshaders.renderscale", args),
        mcp__devbench_vr__scenario: async args => {
            const measured = args.steps?.[0]?.label === "transition-pace";
            const containsApply = args.steps?.some(step => step.label === "profile-apply" || step.label === "recovery-profile-apply");
            const containsCaptureStart = args.steps?.some(step =>
                ["start", "dlss_trace_start", "texture_lifetime_start", "load_presentation_start",
                    "cpu_performance_start", "gpu_performance_start"].includes(step.args?.action));
            // Storage failures must leave ownership-guarded cleanup callable.
            if (containsApply) journal.check();
            if (measured && lastRowResponse !== null) {
                const gap = performance.now() - lastRowResponse;
                status.pacing.maximumClientDispatchGapMs = Math.max(status.pacing.maximumClientDispatchGapMs, gap);
                if (gap > MAX_DISPATCH_GAP_MS) {
                    status.pacing.status = "EXCEEDED";
                }
            }
            if (!measured && args.steps?.some(step => step.label === "baseline-stress-reset")) {
                lastRowResponse = null; previousWaiter = null;
            }
            const invocationKey = `${request.runId}:invocation:${++invocation}`;
            if (containsApply) await journal.write(invocationKey, {
                state: "DISPATCHING", args, utc: new Date().toISOString() });
            if (containsApply || containsCaptureStart) {
                cleanupVerified = false; status.mutationDispatched = true;
                const owner = args.steps.find(step => step.label === "qualification-begin")?.args;
                status.qualification = owner ? { ownerId: owner.ownerId, transitionId: owner.transitionId } : null;
            }
            const result = await call("scenario", args);
            if (measured) lastRowResponse = performance.now();
            const root = envelopeRoot(result);
            const waiter = root.results?.find(step => step.label === "qualification-wait")?.result;
            if (measured && waiter) {
                if (previousWaiter) {
                    const frequency = waiter.timing?.tickFrequency;
                    const previousTick = previousWaiter.timing?.strictSatisfiedTick ?? previousWaiter.timing?.stableTick;
                    const dispatchTick = waiter.timing?.dispatchTick;
                    const gap = frequency > 0 && Number.isFinite(previousTick) && Number.isFinite(dispatchTick) ?
                        (dispatchTick - previousTick) * 1000 / frequency - 5000 : null;
                    await journal.write(`${request.runId}:cadence:${waiter.transitionId}`, {
                        previousTransitionId: previousWaiter.transitionId, transitionId: waiter.transitionId,
                        terminalToDispatchBeyondPacingMs: gap, pacingMilliseconds: 5000,
                        definition: "next dispatch QPC minus previous strict terminal QPC minus prescribed wait",
                    });
                    if (gap !== null && gap > MAX_DISPATCH_GAP_MS) {
                        status.pacing.status = "EXCEEDED";
                    }
                }
                previousWaiter = waiter;
            }
            return result;
        },
    };
    publish();
    let result;
    try {
        await client.initialize();
        await verifyProcess();
        result = await runner({ tools, store: () => {}, notify: value => {
            status.progress = compactProgress(value);
            if (value.ordinal) status.completedTransitions += 1;
            if ((value.ordinal && status.completedTransitions % 5 === 0) || !value.ordinal) {
                status.update = { sequence: (status.update?.sequence || 0) + 1,
                    completedTransitions: status.completedTransitions, ...status.progress };
            }
            publish();
        }, receiptJournal: journal, variant: request.variant, runId: request.runId,
        buildId: request.buildId, positioningRoot: request.positioningRoot,
        startupReceipts: request.startupReceipts, matrix: request.matrix,
        observeOwnership: owners => { status.ownership = { pid: expected.pid, buildId: request.buildId, ...owners }; },
        prepareCleanup: async () => {
            client.requestTimeoutMs = 10000;
            status.cleanup = { state: "VERIFYING_OWNERS" }; publish();
            await recoverCleanupTransport();
            await verifyProcess();
        },
        recoverCleanupTransport,
        cleanupComplete: () => {
            cleanupVerified = true;
            client.requestTimeoutMs = 90000;
            status.cleanup = { state: "VERIFIED_INACTIVE", reconnected: cleanupReconnects > 0 };
            publish();
            return cleanupReconnects === 0;
        },
        cleanupFailed: error => {
            status.cleanup = { ...status.cleanup, state: "BLOCKED", error: String(error.message || error) };
            publish();
        } });
        status.state = result.status;
        status.result = { ok: result.ok, status: result.status, lanes: result.lanes?.map(lane => ({
            id: lane.id, status: lane.status, passes: lane.passes.map(pass => ({ pass: pass.pass, status: pass.status,
                rows: pass.rows.length, error: pass.error, cleanupError: pass.cleanupError })) })) };
    } catch (error) {
        status.state = "INTERRUPTED";
        status.error = String(error.message || error);
    } finally {
        try { await journal.close(); } catch (error) {
            status.state = "INTERRUPTED"; status.evidenceError = String(error.message || error);
        }
        try { await client.close(); } catch (error) { status.transportCleanupError = String(error.message || error); }
        status.finishedUtc = new Date().toISOString();
        status.cleanupVerified = cleanupVerified;
        if (status.mutationDispatched && !cleanupVerified) {
            status.cleanup = { ...status.cleanup, state: "BLOCKED",
                error: status.cleanup?.error || status.result?.lanes?.flatMap(lane => lane.passes).find(pass => pass.cleanupError)?.cleanupError ||
                    status.error || "cleanup_not_verified", ownership: status.ownership };
        }
        publish();
        try { await publisher.drain(); }
        catch (error) {
            status.statusPublishError = String(error.message || error);
            atomicJson(path.join(request.root, "worker-terminal.json"), status);
        }
    }
    return status;
}

async function launch(requestFile) {
    const request = readRequest(requestFile);
    const parent = path.dirname(request.root);
    fs.mkdirSync(parent, { recursive: true });
    // A single endpoint owner prevents a second chat from starting a competing worker.
    fs.mkdirSync(request.ownerRoot, { recursive: true });
    const lock = path.join(request.ownerRoot, `endpoint-${crypto.createHash("sha256").update(request.endpoint).digest("hex").slice(0, 16)}.lock`);
    let fd = fs.openSync(lock, "wx");
    let created = false;
    try {
        fs.mkdirSync(request.root); created = true;
        fs.mkdirSync(path.join(request.root, "raw"), { recursive: true });
        const file = path.join(request.root, "worker-request.json");
        fs.writeFileSync(file, JSON.stringify(request), { flag: "wx" });
        fs.writeFileSync(fd, JSON.stringify({ runId: request.runId, root: request.root }));
        const log = fs.openSync(path.join(request.root, "worker.log"), "a");
        let child;
        try { child = spawn(process.execPath, [__filename, "run", file, lock], {
            detached: true, windowsHide: true, stdio: ["ignore", log, log], cwd: request.workspace,
        }); } finally { fs.closeSync(log); }
        await new Promise((resolve, reject) => { child.once("spawn", resolve); child.once("error", reject); });
        child.unref();
        return { ok: true, runId: request.runId, pid: child.pid, root: request.root,
            statusPath: path.join(request.root, "worker-status.json") };
    } catch (error) {
        if (created) atomicJson(path.join(request.root, "worker-status.json"), { state: "LAUNCH_FAILED", error: error.message });
        fs.closeSync(fd); fd = undefined;
        fs.unlinkSync(lock); throw error;
    } finally { if (fd !== undefined) fs.closeSync(fd); }
}

if (require.main === module) {
    (async () => {
        const [command, file, lock] = process.argv.slice(2);
        if (command === "start") console.log(JSON.stringify(await launch(file)));
        else if (command === "status") console.log(fs.readFileSync(file, "utf8"));
        else if (command === "run") {
            const request = readRequest(file);
            const result = await runWorker(request);
            if (result.cleanupVerified || !result.mutationDispatched) {
                const owner = JSON.parse(fs.readFileSync(lock, "utf8"));
                if (owner.runId !== request.runId || owner.root !== request.root) throw new Error("worker_lock_owner_changed");
                fs.unlinkSync(lock);
            }
            // Evidence and terminal status are saved before abandoned transport handles exit.
            process.exit(result.state === "COMPLETE" && !result.transportCleanupError ? 0 : 1);
        } else throw new Error("usage: durable-worker.js start REQUEST | status STATUS");
    })().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
}

module.exports = { ReceiptQueue, McpClient, compactProgress, runWorker, launch,
    MAX_DISPATCH_GAP_MS };
