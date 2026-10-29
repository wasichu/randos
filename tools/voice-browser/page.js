// Local-only probe controller. It releases paced audio independently of the
// inference worker, so slow inference cannot slow down the input clock.
const status = document.getElementById("status")
const clock = () => performance.timeOrigin + performance.now()
const worker = new Worker("/worker.js", {type: "module"})
let input, start, index, timer
window.probe = {events: [], outputs: {}, stopped: false}
worker.onerror = event => {
  window.probe.events.push({type: "failed", error: event.message})
  status.textContent = event.message
  clearTimeout(timer)
  window.probe.stopped = true
}
worker.onmessage = ({data}) => {
  window.probe.events.push(data.type === "complete" ? {type: data.type, report: data.report} : data)
  status.textContent = JSON.stringify(window.probe.events.at(-1), null, 2)
  if (data.type === "complete") window.probe.outputs[data.report.mode] = Array.from(new Float32Array(data.pcm))
  if (data.type === "failed") { clearTimeout(timer); window.probe.stopped = true }
}
window.probe.init = async (provider, threads = 4) => {
  input = new Float32Array(await (await fetch("/input.f32")).arrayBuffer())
  worker.postMessage({type: "init", provider, threads})
}
window.probe.runtime = threads => worker.postMessage({type: "runtime", threads})
window.probe.run = (mode, retain = true) => {
  start = clock()
  index = 0
  worker.postMessage({type: "start", mode, start, retain})
  if (mode === "parity") {
    for (let offset = 0; offset < input.length; offset += 1600) {
      const pcm = input.slice(offset, offset + 1600)
      worker.postMessage({type: "chunk", pcm: pcm.buffer}, [pcm.buffer])
    }
    worker.postMessage({type: "end"})
    return
  }
  function release() {
    if (window.probe.stopped) return
    const scheduled = start + (index + 1) * 100
    const pcm = input.slice((index * 1600) % input.length, (index * 1600) % input.length + 1600)
    worker.postMessage({type: "chunk", pcm: pcm.buffer, lateness: Math.max(0, clock() - scheduled)}, [pcm.buffer])
    index++
    if (index === 600) worker.postMessage({type: "end"})
    else timer = setTimeout(release, Math.max(0, start + (index + 1) * 100 - clock()))
  }
  timer = setTimeout(release, 100)
}
window.probe.close = () => { clearTimeout(timer); worker.terminate(); window.probe.stopped = true }
addEventListener("pagehide", window.probe.close)
