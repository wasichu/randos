// Failed startup must release the CDP pipe/process too. The fake browser exits
// on pipe EOF, so even killing this test cannot strand it (AGENTS.md).
import test from "node:test"
import assert from "node:assert/strict"
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {Browser, eventually} from "./cdp.mjs"

test("browser spawn failure and startup timeout clean up", {timeout: 35_000}, async () => {
  const directory = mkdtempSync(join(tmpdir(), "randos-cdp-startup-"))
  const previous = process.env.CHROME_BIN
  try {
    process.env.CHROME_BIN = join(directory, "missing")
    await assert.rejects(Browser.launch(), /could not start|EPIPE/)
    const executable = join(directory, "fake-chrome")
    const pidfile = join(directory, "pid")
    writeFileSync(executable, `#!/usr/bin/env node
const fs = require("node:fs");
fs.writeFileSync(${JSON.stringify(pidfile)}, String(process.pid));
const input = fs.createReadStream(null, {fd:3});
input.on("data", () => {});
input.on("end", () => process.exit(0));
input.on("error", () => process.exit(0));
`, {mode: 0o755})
    process.env.CHROME_BIN = executable
    await assert.rejects(Browser.launch(), /did not start/)
    const pid = Number(readFileSync(pidfile, "utf8"))
    await eventually(async () => {
      try { process.kill(pid, 0); return false } catch (error) { return error.code === "ESRCH" }
    }, "timed-out browser to exit", 5_000)
  } finally {
    if (previous === undefined) delete process.env.CHROME_BIN
    else process.env.CHROME_BIN = previous
    rmSync(directory, {recursive: true, force: true})
  }
})
