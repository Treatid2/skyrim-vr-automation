// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
    validateCampaign,
} = require("../tools/fork-reciprocal-search/validate-campaign.js");

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

const templatePath = path.join(__dirname, "..", "docs", "fork-parity",
    "reciprocal-search.template.json");
const template = JSON.parse(fs.readFileSync(templatePath, "utf8"));
const templateErrors = validateCampaign(template);
assert(templateErrors.length > 0 &&
    templateErrors.some((error) => error.startsWith("fixedContract.matrix.sha256")) &&
    templateErrors.some((error) => error.startsWith("forks[0].artifact")) &&
    templateErrors.some((error) => error.startsWith("fixedContract.gpu.clocks")) &&
    templateErrors.some((error) =>
        error.startsWith("fixedContract.hmd.eyeGeometry")),
"The unmaterialized template was not rejected with the required identity gaps.");

const complete = structuredClone(template);
complete.campaignId = "campaign-20260906";
complete.fixedContract.matrix.sha256 = "1".repeat(64);
complete.fixedContract.automationCommit = "2".repeat(40);
complete.fixedContract.runtimeLane = "Skyrim VR 1.4.15";
complete.fixedContract.mo2Modlist = "MGO RC4";
complete.fixedContract.testProfileSource = "Primary";
complete.fixedContract.saveFixtureId = "Breezehome-003";
complete.fixedContract.backgroundLoadPolicy = "idle-host";
Object.assign(complete.fixedContract.gpu, {
    vendor: "NVIDIA",
    device: "RTX fixture",
    driver: "fixture-driver",
    powerPolicy: "maximum-performance",
});
Object.assign(complete.fixedContract.gpu.clocks, {
    coreMHz: 2500,
    memoryMHz: 10500,
    policy: "locked",
});
Object.assign(complete.fixedContract.hmd, {
    mode: "SteamVR null-HMD",
    profile: "steamvr-null",
    refreshRateHz: 90,
    renderWidth: 2112,
    renderHeight: 2112,
    motionSmoothing: false,
});
complete.fixedContract.hmd.eyeGeometry = {
    source: "OpenVR projection",
    left: { tanLeft: -1, tanRight: 1, tanUp: 1, tanDown: -1 },
    right: { tanLeft: -1, tanRight: 1, tanUp: 1, tanDown: -1 },
};
Object.assign(complete.fixedContract.qualityAssessment, {
    model: "gpt-5.6-sol",
    modelRuntime: "codex-cli",
    promptRevision: 1,
    motionRecordingSha256: "3".repeat(64),
});
for (const [index, fork] of complete.forks.entries()) {
    fork.searchSpaceManifest = `${fork.id}-search-space.json`;
    fork.adapterBuild = `${fork.id}-adapter-v1`;
    fork.artifact.buildId = String(index + 4).repeat(64);
    fork.artifact.package = {
        path: `${fork.id}.7z`,
        sha256: String(index + 6).repeat(64),
    };
    fork.artifact.dll = {
        path: `${fork.id}/CommunityShaders.dll`,
        sha256: String(index + 8).repeat(64),
    };
}
assert(validateCampaign(complete).length === 0,
    `A complete campaign was rejected: ${validateCampaign(complete).join("; ")}`);

const variants = [
    ["fork artifact hash", (value) => {
        value.forks[0].artifact.dll.sha256 = null;
    }, "forks[0].artifact.dll.sha256"],
    ["adapter build", (value) => {
        value.forks[1].adapterBuild = null;
    }, "forks[1].adapterBuild"],
    ["GPU clocks", (value) => {
        value.fixedContract.gpu.clocks.coreMHz = null;
    }, "fixedContract.gpu.clocks.coreMHz"],
    ["background load", (value) => {
        value.fixedContract.backgroundLoadPolicy = null;
    }, "fixedContract.backgroundLoadPolicy"],
    ["eye geometry", (value) => {
        value.fixedContract.hmd.eyeGeometry.left = null;
    }, "fixedContract.hmd.eyeGeometry.left"],
];
for (const [label, mutate, expected] of variants) {
    const value = structuredClone(complete);
    mutate(value);
    assert(validateCampaign(value).some((error) => error.startsWith(expected)),
        `Unset ${label} did not fail materialization.`);
}

process.stdout.write("Fork reciprocal-search contract tests passed.\n");
