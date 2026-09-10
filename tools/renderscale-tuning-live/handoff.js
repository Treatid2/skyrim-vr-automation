// SPDX-License-Identifier: GPL-3.0-or-later

/** Transfers an admitted startup to the persistent worker without exposing raw receipts. */
async function startRenderScaleTuningWorker({ tools, runId, buildId, positioningRoot,
    startupReceipts, pluginRoot, variant = "nvidia" }) {
    if (!["nvidia", "amd"].includes(variant) ||
        !/^[A-Za-z0-9_-]+$/.test(runId) || typeof pluginRoot !== "string") {
        throw new Error("invalid_worker_handoff");
    }
    const workspace = await tools.exec_command({ cmd: "(Get-Location).Path",
        shell: "powershell", login: false, max_output_tokens: 200 });
    if (workspace.exit_code !== 0) throw new Error("worker_workspace_unavailable");
    const root = workspace.output.trim().replaceAll("\\", "/");
    const requestPath = `${root}/artifacts/renderscale-tuning-requests/${runId}.json`;
    const request = { variant, runId, buildId, workspace: root,
        positioningRoot, startupReceipts };
    const saved = await tools.apply_patch(`*** Begin Patch\n*** Add File: ${requestPath}\n+${JSON.stringify(request)}\n*** End Patch`);
    if (saved && (saved.isError || saved.exit_code > 0)) throw new Error("worker_handoff_save_failed");
    const quote = value => `'${value.replaceAll("'", "''")}'`;
    const launched = await tools.exec_command({
        cmd: `pwsh -NoProfile -File ${quote(`${pluginRoot}/tools/renderscale-tuning-live/Invoke-RenderScaleTuningWorker.ps1`)} start -RequestPath ${quote(requestPath)}`,
        sandbox_permissions: "require_escalated",
        justification: `Start the authorized persistent ${variant.toUpperCase()} assay worker with its local endpoint ownership lock and selected DevBench MCP connection.`,
        max_output_tokens: 500,
    });
    if (launched.exit_code !== 0) throw new Error(`worker_launch_failed: ${launched.output}`);
    return JSON.parse(launched.output);
}

if (typeof module !== "undefined" && module.exports) module.exports = { startRenderScaleTuningWorker };
