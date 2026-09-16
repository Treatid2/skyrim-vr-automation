// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const path = require("node:path");

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function populatedString(value) {
    return typeof value === "string" && value.trim().length > 0 &&
        !/^replace-with-/i.test(value.trim());
}

function populatedObject(value) {
    return isObject(value) && Object.keys(value).length > 0;
}

function sha256(value) {
    return typeof value === "string" && /^[0-9a-f]{64}$/i.test(value);
}

function commit(value) {
    return typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(value);
}

function positiveNumber(value) {
    return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function validateCampaign(campaign) {
    const errors = [];
    const requireValue = (condition, field, message = "is missing or invalid") => {
        if (!condition) errors.push(`${field} ${message}`);
    };

    requireValue(isObject(campaign), "$", "must be an object");
    if (!isObject(campaign)) return errors;
    requireValue(campaign.schema === "csx.fork-reciprocal-search.v1",
        "schema", "must be csx.fork-reciprocal-search.v1");
    requireValue(populatedString(campaign.campaignId), "campaignId");
    const fixed = campaign.fixedContract;
    requireValue(isObject(fixed), "fixedContract", "must be an object");
    if (!isObject(fixed)) return errors;

    requireValue(populatedString(fixed.matrix && fixed.matrix.name),
        "fixedContract.matrix.name");
    requireValue(commit(fixed.matrix && fixed.matrix.sourceCommit),
        "fixedContract.matrix.sourceCommit");
    requireValue(sha256(fixed.matrix && fixed.matrix.sha256),
        "fixedContract.matrix.sha256");
    for (const field of ["automationCommit", "runtimeLane", "mo2Modlist",
        "testProfileSource", "saveFixtureId", "backgroundLoadPolicy"]) {
        const value = fixed[field];
        requireValue(field === "automationCommit" ? commit(value) :
            populatedString(value), `fixedContract.${field}`);
    }

    const gpu = fixed.gpu;
    requireValue(isObject(gpu), "fixedContract.gpu", "must be an object");
    if (isObject(gpu)) {
        for (const field of ["vendor", "device", "driver", "powerPolicy"]) {
            requireValue(populatedString(gpu[field]), `fixedContract.gpu.${field}`);
        }
        requireValue(isObject(gpu.clocks), "fixedContract.gpu.clocks",
            "must be an object");
        if (isObject(gpu.clocks)) {
            requireValue(positiveNumber(gpu.clocks.coreMHz),
                "fixedContract.gpu.clocks.coreMHz");
            requireValue(positiveNumber(gpu.clocks.memoryMHz),
                "fixedContract.gpu.clocks.memoryMHz");
            requireValue(populatedString(gpu.clocks.policy),
                "fixedContract.gpu.clocks.policy");
        }
    }

    const hmd = fixed.hmd;
    requireValue(isObject(hmd), "fixedContract.hmd", "must be an object");
    if (isObject(hmd)) {
        for (const field of ["mode", "profile"]) {
            requireValue(populatedString(hmd[field]), `fixedContract.hmd.${field}`);
        }
        for (const field of ["refreshRateHz", "renderWidth", "renderHeight"]) {
            requireValue(positiveNumber(hmd[field]), `fixedContract.hmd.${field}`);
        }
        requireValue(typeof hmd.motionSmoothing === "boolean" ||
            populatedString(hmd.motionSmoothing),
        "fixedContract.hmd.motionSmoothing");
        requireValue(isObject(hmd.eyeGeometry), "fixedContract.hmd.eyeGeometry",
            "must be an object");
        if (isObject(hmd.eyeGeometry)) {
            requireValue(populatedString(hmd.eyeGeometry.source),
                "fixedContract.hmd.eyeGeometry.source");
            requireValue(populatedObject(hmd.eyeGeometry.left),
                "fixedContract.hmd.eyeGeometry.left");
            requireValue(populatedObject(hmd.eyeGeometry.right),
                "fixedContract.hmd.eyeGeometry.right");
        }
    }

    const quality = fixed.qualityAssessment;
    requireValue(isObject(quality), "fixedContract.qualityAssessment",
        "must be an object");
    if (isObject(quality)) {
        requireValue(quality.humanViewing === false,
            "fixedContract.qualityAssessment.humanViewing", "must be false");
        for (const field of ["protocol", "model", "modelRuntime"]) {
            requireValue(populatedString(quality[field]),
                `fixedContract.qualityAssessment.${field}`);
        }
        requireValue(Number.isSafeInteger(quality.promptRevision) &&
            quality.promptRevision > 0,
        "fixedContract.qualityAssessment.promptRevision");
        requireValue(sha256(quality.motionRecordingSha256),
            "fixedContract.qualityAssessment.motionRecordingSha256");
    }

    requireValue(Array.isArray(campaign.forks) && campaign.forks.length === 2,
        "forks", "must contain exactly two forks");
    const ids = [];
    for (const [index, fork] of (Array.isArray(campaign.forks) ?
        campaign.forks : []).entries()) {
        const prefix = `forks[${index}]`;
        requireValue(isObject(fork), prefix, "must be an object");
        if (!isObject(fork)) continue;
        requireValue(populatedString(fork.id), `${prefix}.id`);
        if (populatedString(fork.id)) ids.push(fork.id);
        requireValue(commit(fork.head), `${prefix}.head`);
        requireValue(populatedString(fork.baselineSettings),
            `${prefix}.baselineSettings`);
        requireValue(populatedString(fork.searchSpaceManifest),
            `${prefix}.searchSpaceManifest`);
        requireValue(populatedString(fork.adapterBuild),
            `${prefix}.adapterBuild`);
        requireValue(isObject(fork.artifact), `${prefix}.artifact`,
            "must be an object");
        if (isObject(fork.artifact)) {
            requireValue(sha256(fork.artifact.buildId),
                `${prefix}.artifact.buildId`);
            for (const kind of ["package", "dll"]) {
                const artifact = fork.artifact[kind];
                requireValue(isObject(artifact), `${prefix}.artifact.${kind}`,
                    "must be an object");
                if (isObject(artifact)) {
                    requireValue(populatedString(artifact.path),
                        `${prefix}.artifact.${kind}.path`);
                    requireValue(sha256(artifact.sha256),
                        `${prefix}.artifact.${kind}.sha256`);
                }
            }
        }
    }
    requireValue(new Set(ids).size === ids.length, "forks[].id",
        "must be unique");
    requireValue(ids.includes(campaign.firstMover), "firstMover",
        "must identify one declared fork");
    return errors;
}

function main(argv) {
    const input = argv[2];
    if (!input) {
        process.stderr.write("Usage: node validate-campaign.js <campaign.json>\n");
        return 2;
    }
    let campaign;
    try {
        campaign = JSON.parse(fs.readFileSync(path.resolve(input), "utf8"));
    } catch (error) {
        process.stdout.write(`${JSON.stringify({
            ok: false,
            errors: [`campaign_read_failed: ${error.message}`],
        }, null, 2)}\n`);
        return 2;
    }
    const errors = validateCampaign(campaign);
    process.stdout.write(`${JSON.stringify({
        schema: "csx.fork-reciprocal-search-validation.v1",
        ok: errors.length === 0,
        campaignPath: path.resolve(input),
        errors,
    }, null, 2)}\n`);
    return errors.length === 0 ? 0 : 2;
}

if (require.main === module) {
    process.exitCode = main(process.argv);
}

module.exports = { validateCampaign };
