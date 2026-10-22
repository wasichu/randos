// What a failing e2e scenario leaves behind, so the cause can be read from
// the failing run itself (several obligation 9 failures were blamed on the
// test before a log showed the real bug):
//
//   tmp/smoke-failures/<scenario>/error.txt       the assertion
//   tmp/smoke-failures/<scenario>/server.log      the server's log during the
//                                                  scenario (when SMOKE_SERVER_LOG
//                                                  names it: local and CI runs)
//   tmp/smoke-failures/<scenario>/<page>.log       each page's console since the
//                                                  scenario began
//
// CI uploads the folder as an artifact.

import fs from "node:fs"
import path from "node:path"
import {allPages} from "./cdp.mjs"

const ROOT = path.resolve("tmp/smoke-failures")

// Call at a scenario's start; the returned function saves the evidence.
export function watch(name) {
  const since = new Date().toISOString()
  const serverLog = process.env.SMOKE_SERVER_LOG
  const offset = serverLog && fs.existsSync(serverLog) ? fs.statSync(serverLog).size : 0

  return error => {
    const dir = path.join(ROOT, name.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "").toLowerCase())
    fs.rmSync(dir, {recursive: true, force: true})
    fs.mkdirSync(dir, {recursive: true})
    fs.writeFileSync(path.join(dir, "error.txt"), `${name}\n${error.stack ?? error}\n`)

    if (serverLog && fs.existsSync(serverLog)) {
      const log = fs.readFileSync(serverLog)
      fs.writeFileSync(path.join(dir, "server.log"), log.subarray(Math.min(offset, log.length)))
    }

    for (const page of allPages) {
      const lines = page.logs.filter(line => line >= since)
      if (lines.length) fs.writeFileSync(path.join(dir, `${page.name}.log`), lines.join("\n") + "\n")
    }
    return dir
  }
}
