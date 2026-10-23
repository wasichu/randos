// A call whose media path dies comes back (obligation 10, ICE restart),
// end to end in two headless Chromes: relay-only through a local test TURN
// relay (clients/tui/native/examples/test_turn) that can cut a client's
// 5-tuple, as a network change does. The page's websocket is a different
// path: drop_proxy.mjs cuts that one, and the last scenario cuts both.
//
//   just recovery-smoke
//
// This script starts the relay first (the test server must know its port at
// boot), then the test server through with_test_server.sh, holding both by
// their stdin so neither can outlive it (AGENTS.md, Testing).

import {spawn} from "node:child_process"
import {createInterface} from "node:readline"
import {Browser, appeared, audioFlows, launchBehind, sleep} from "./cdp.mjs"
import {startDropProxy} from "./drop_proxy.mjs"
import {watch} from "./failures.mjs"

const TURN = process.env.TEST_TURN_BIN ?? "target/debug/examples/test_turn"
const SERVER_LOG = "tmp/recovery-server.log"
// So a failing scenario keeps its slice of the server's log (failures.mjs).
process.env.SMOKE_SERVER_LOG = SERVER_LOG
const BASE_URL = "http://localhost:4010"
const results = []

async function scenario(name, fn) {
  const started = Date.now()
  const save = watch(name)
  try {
    await fn()
    results.push({name, ok: true})
    console.log(`  ✓ ${name} (${Date.now() - started}ms)`)
  } catch (error) {
    results.push({name, ok: false})
    console.log(`  ✗ ${name}\n      ${error.message}\n      logs: ${save(error)}`)
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

// The relay: its first line names its port; later lines are its report.
async function startTurn() {
  const turn = spawn(TURN, [], {stdio: ["pipe", "pipe", "inherit"]})
  const lines = createInterface({input: turn.stdout})
  const port = await new Promise((resolve, reject) => {
    turn.once("error", reject)
    lines.once("line", line => resolve(Number(line.match(/listening 127\.0\.0\.1:(\d+)/)?.[1])))
  })
  assert(port, "test_turn didn't say its port")
  return {port, send: command => turn.stdin.write(command + "\n"), stop: () => turn.stdin.end()}
}

async function startServer(port) {
  const iceServers = JSON.stringify([
    {urls: `turn:127.0.0.1:${port}?transport=udp`, username: "randos", credential: "randos"},
  ])
  // `cat` runs until we close its stdin; the script then stops the server.
  const server = spawn("test/e2e/with_test_server.sh", [SERVER_LOG, "cat"], {
    stdio: ["pipe", "inherit", "inherit"],
    env: {...process.env, RANDOS_TEST_ICE_SERVERS: iceServers},
  })
  for (let i = 0; i < 120; i++) {
    if (await fetch(BASE_URL).then(r => r.ok, () => false)) return {stop: () => server.stdin.end()}
    await sleep(500)
  }
  server.stdin.end()
  throw new Error(`the test server didn't come up (see ${SERVER_LOG})`)
}

const turn = await startTurn()
const server = await startServer(turn.port)
const browser = await Browser.launch()
console.log(`recovery smoke against ${BASE_URL} (test TURN on :${turn.port})`)

try {
  await scenario("both media paths cut: the call restarts ICE and comes back", async () => {
    const a = await browser.newPage("A")
    const b = await browser.newPage("B")
    await Promise.all([a.open(BASE_URL), b.open(BASE_URL)])
    await a.findRando("en", "es")
    await b.findRando("es", "en")
    await Promise.all([a.webrtcStateIs("connected"), b.webrtcStateIs("connected")])
    assert(await a.eval(`document.querySelector("#webrtc-audio")?.dataset.iceTransportPolicy === "relay"`),
      "the call isn't relay-only (the test TURN wasn't used)")
    await Promise.all([audioFlows(a, "A"), audioFlows(b, "B")])

    const callElement = `document.querySelector("[id^='call-media-']")?.id`
    const before = await a.eval(callElement)
    const peers = await a.eval(`window.__randosPeers.length`)
    await Promise.all([a.watchAppears("call-recovering"), b.watchAppears("call-recovering")])

    // Both clients' relay 5-tuples die, as after a move.
    turn.send("cut-all")

    // Back within the budget (15 s): the restart's new allocations carry it.
    await a.waitFor(appeared("call-recovering"), "A told it's reconnecting", 15_000)
    await a.waitFor(`!document.querySelector("#call-recovering")`, "A recovered", 20_000)
    await b.waitFor(`!document.querySelector("#call-recovering")`, "B recovered", 5_000)
    // Gone because it recovered, not because the call ended.
    for (const page of [a, b])
      assert(await page.eval(`!!document.querySelector("#call-panel, #extension-panel")`),
        `the call ended for ${page.name}`)
    await Promise.all([audioFlows(a, "A after the restart"), audioFlows(b, "B after the restart")])
    // The same call and peer connection: a restart, not a new call.
    assert((await a.eval(callElement)) === before, "a new call element (a new call?)")
    assert((await a.eval(`window.__randosPeers.length`)) === peers, "a new peer connection was made")
    assert(Number(await a.eval(`document.querySelector("#webrtc-audio").dataset.iceGeneration`)) >= 1,
      "no restart was asked for")

    await a.hangUp()
    await b.waitFor(`window.__randosCallEnds > 0`, "the call to end for B")
    await b.stopLooking()
    turn.send("heal")
  })

  await scenario("a network change (media and websocket at once): back in the same call", async () => {
    const proxy = await startDropProxy()
    const proxied = await launchBehind(proxy)
    try {
      const mover = await proxied.newPage("mover")
      const stayer = await browser.newPage("stayer")
      await Promise.all([mover.open(BASE_URL), stayer.open(BASE_URL)])
      await mover.findRando("ko", "it")
      await stayer.findRando("it", "ko")
      await Promise.all([mover.webrtcStateIs("connected"), stayer.webrtcStateIs("connected")])
      await Promise.all([
        mover.waitFor(`!!document.querySelector("#call-panel")`, "the call active for the mover"),
        stayer.waitFor(`!!document.querySelector("#call-panel")`, "the call active for the stayer"),
      ])
      const before = await mover.eval(`document.querySelector("[id^='call-media-']")?.id`)
      await stayer.watchAppears("call-recovering")

      turn.send("cut-all")
      proxy.outage(3_000)

      // The websocket comes back first; ICE notices the dead path a few
      // seconds later, and the restart follows. Both within the budget.
      await stayer.waitFor(appeared("call-recovering"), "the stayer told the audio is reconnecting", 15_000)
      await stayer.waitFor(`!document.querySelector("#peer-reconnecting, #call-recovering")`,
        "the stayer sees it recover", 20_000)
      assert(await stayer.eval(`!!document.querySelector("#call-panel, #extension-panel")`),
        "the call ended for the stayer")
      assert((await mover.eval(`document.querySelector("[id^='call-media-']")?.id`)) === before,
        "the mover is in a new call")
      await Promise.all([audioFlows(mover, "the mover", 8_000), audioFlows(stayer, "the stayer", 8_000)])

      await mover.hangUp()
      await stayer.waitFor(`window.__randosCallEnds > 0`, "the call to end for the stayer")
      await stayer.stopLooking()
    } finally {
      await proxied.close()
      proxy.close()
      turn.send("heal")
    }
  })
} finally {
  await browser.close()
  server.stop()
  turn.stop()
}

const failed = results.filter(r => !r.ok).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
