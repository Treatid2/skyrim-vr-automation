// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { parentPort, workerData } = require("node:worker_threads");
const fd = fs.openSync(path.join(workerData.root, "raw", "journal.ndjson"), "wx");

// A dedicated writer keeps JSON encoding and disk flushes off the dispatch thread.
parentPort.on("message", ({ sequence, receiptKey, value, flush }) => {
    try {
        if (flush) {
            fs.fsyncSync(fd);
            parentPort.postMessage({ flushed: true });
            return;
        }
        fs.writeFileSync(fd, `${JSON.stringify({ sequence, receiptKey, value })}\n`);
        parentPort.postMessage({ sequence });
    } catch (error) {
        parentPort.postMessage({ sequence, error: String(error.message || error) });
    }
});
