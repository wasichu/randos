// Development-only voice lab: render/measure silently, and exercise playback
// through muted Chrome. No microphone and no audio reaches the test machine.
import {writeFileSync} from "node:fs"
import {Browser, BASE_URL} from "./cdp.mjs"

const failures = []
const check = (ok, message) => ok || failures.push(message)
const browser = await Browser.launch()
try {
  const page = await browser.newPage("lab")
  // Recovery controls are usable before the bundled Listen samples finish
  // loading. Navigation in that window must close audio and cancel setup.
  const {identifier: earlyScript} = await page.send("Page.addScriptToEvaluateOnNewDocument", {source: `
    (() => {
    window.earlyLabErrors = 0; window.earlyLabDecodes = 0;
    window.addEventListener("error", () => window.earlyLabErrors++);
    window.addEventListener("unhandledrejection", () => window.earlyLabErrors++);
    const fetch = window.fetch.bind(window);
    window.fetch = (url, ...args) => url === "/dev/voice-lab/clips"
      ? new Promise(resolve => { window.releaseEarlyLabSources = () => resolve(fetch(url, ...args)); })
      : fetch(url, ...args);
    const resume = AudioContext.prototype.resume;
    AudioContext.prototype.resume = function(...args) { window.earlyRecoveryContext = this; return resume.apply(this, args); };
    const decode = OfflineAudioContext.prototype.decodeAudioData;
    OfflineAudioContext.prototype.decodeAudioData = function(...args) {
      return decode.apply(this, args).then(buffer => { window.earlyLabDecodes++; return buffer; });
    };
    })();
  `})
  await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
  await page.waitFor(`!!window.releaseEarlyLabSources`, "held initial source loading", 10_000)
  await page.labView('recovery')
  await page.eval(`document.querySelectorAll("[data-recovery-audio] source").forEach(source => { source.src = "/dev/voice-lab/clips/high_voice.wav"; })`)
  await page.click("#voice-lab-recovery-play-all")
  await page.waitFor(`document.getElementById("voice-lab-recovery-playback-status").dataset.state === "playing"`, "recovery before Listen initialization", 10_000)
  await page.eval(`document.dispatchEvent(new Event("phx:page-loading-start"))`)
  await page.waitFor(`window.earlyRecoveryContext.state === "closed"`, "early navigation audio cleanup", 10_000)
  await page.eval(`document.getElementById("voice-lab").remove(); window.releaseEarlyLabSources()`)
  await page.waitFor(`window.earlyLabDecodes >= 4`, "cancelled initializer's outstanding decodes", 10_000)
  await page.eval(`new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))`)
  check(await page.eval(`window.earlyLabErrors === 0`), "cancelled initialization must not access detached lab controls")
  await page.send("Page.removeScriptToEvaluateOnNewDocument", {identifier: earlyScript})

  // Parameter edits are not navigation: they must not cancel initialization
  // while the next worklet module is still loading.
  const {identifier: parameterScript} = await page.send("Page.addScriptToEvaluateOnNewDocument", {source: `
    (() => {
    const add = AudioWorklet.prototype.addModule;
    AudioWorklet.prototype.addModule = function(url, ...args) {
      if (!String(url).includes("/voice_lab/mcadams.js")) return add.call(this, url, ...args);
      return new Promise(resolve => { window.releaseParameterWorklet = () => resolve(add.call(this, url, ...args)); });
    };
    })();
  `})
  await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
  await page.waitFor(`!!window.releaseParameterWorklet && !!document.getElementById("voice-lab-param-pitch_shift-semitones")`, "pitch controls before next worklet", 10_000)
  await page.eval(`{
    const slider = document.getElementById("voice-lab-param-pitch_shift-semitones");
    slider.value = "-3.5"; slider.dispatchEvent(new Event("input", {bubbles: true}));
    window.releaseParameterWorklet();
  }`)
  await page.waitFor(`document.getElementById("voice-lab-status").dataset.state === "rendered" && !document.getElementById("voice-lab-play").disabled`, "startup after an early parameter edit", 30_000)
  check(await page.eval(`document.getElementById("voice-lab-param-pitch_shift-semitones-number").value === "-3.5"`), "early parameter edit should be retained")
  await page.send("Page.removeScriptToEvaluateOnNewDocument", {identifier: parameterScript})
  await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
  await page.waitFor(`document.querySelector("#voice-lab-status")?.dataset.state === "rendered"`, "the lab and its initial spectrogram to load", 30_000)
  const playing = version => `document.querySelector("#voice-lab").dataset.playing === "${version}"`
  const choose = async (id, value) => page.eval(`{
    const input = document.getElementById(${JSON.stringify(id)});
    input.value = ${JSON.stringify(value)};
    input.dispatchEvent(new Event("change", {bubbles: true}));
  }`)
  const rendered = () => page.waitFor(`document.querySelector("#voice-lab-status").dataset.state === "rendered"`, "the modified sample to prepare", 60_000)

  // First-click playback prepares the modification; original needs no render.
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "original playback", 10_000)
  check(await page.eval(`!!document.querySelector("#voice-lab-result-modified").dataset.realTimeFactor`), "the initial modified spectrogram should be prepared without pressing Play")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "automatic preparation and playback", 60_000)
  check(await page.eval(`document.querySelector("#voice-lab-play-original").getAttribute("aria-pressed") === "false" && document.querySelector("#voice-lab-play").getAttribute("aria-pressed") === "true"`), "only modified should be playing")
  await page.click("#voice-lab-play")
  check(await page.eval(`${playing("none")} && !document.querySelector("#voice-lab-play [data-play-icon]").hidden`), "the active play button should become Stop and stop playback")
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "switching back to original", 10_000)
  await page.labView('basics')
  check(await page.eval(`${playing("none")} && document.querySelector("#voice-lab-panel-listen").hidden && !document.querySelector("#voice-lab-panel-basics").hidden`), "leaving Listen must stop playback and switch panels")

  check(await page.eval(`document.getElementById('voice-lab-view').labels[0]?.control===document.getElementById('voice-lab-view')&&document.querySelectorAll('#voice-lab-view optgroup').length===4`), "view selector has an accessible label and four groups")
  await page.labView('benchmark')
  check(await page.eval(`!document.querySelector('#voice-lab-panel-benchmark').hidden`), "selector opens Benchmark")
  await page.labView('listen')

  check(await page.eval(`[...document.querySelectorAll("#voice-lab-params label")].every(label => label.control?.type === "range")`), "slider labels should name the range inputs")
  const sources = JSON.parse(await page.eval(`JSON.stringify([...document.querySelectorAll("#voice-lab-source option")].map(o => o.value))`))
  check(sources.length >= 5 && sources.includes("mencken_wasichu.wav"), `expected 4 clips (including Mencken) and a tone, got ${sources}`)
  // Capture real playback nodes to check looping across a clip boundary.
  await page.eval(`{
    const original = AudioBufferSourceNode.prototype.start;
    window.restoreLabStart = () => { AudioBufferSourceNode.prototype.start = original; };
    AudioBufferSourceNode.prototype.start = function(...args) {
      if (this.context instanceof AudioContext) window.labPlayback = {node: this, started: this.context.currentTime};
      return original.apply(this, args);
    };
  }`)
  await choose("voice-lab-source", "test_tone")
  check(await page.eval(`document.querySelector("#voice-lab-loop").getAttribute("aria-pressed") === "false"`), "loop should default off")
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "one-shot original playback", 10_000)
  await page.waitFor(`${playing("none")} && document.querySelector("#voice-lab-stop").disabled`, "automatic cleanup at the end of the sample", 10_000)
  await page.click("#voice-lab-loop")
  check(await page.eval(`document.querySelector("#voice-lab-loop [data-loop-label]").textContent === "Loop on"`), "loop label should show the enabled state")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "looped modified playback", 60_000)
  await page.waitFor(`window.labPlayback.node.context.currentTime - window.labPlayback.started > window.labPlayback.node.buffer.duration + 0.2`, "playback across the loop boundary", 10_000)
  check(await page.eval(`${playing("modified")} && window.labPlayback.node.loop`), "modified audio should keep playing across a loop boundary")
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "looped original playback", 10_000)
  check(await page.eval(`window.labPlayback.node.loop`), "loop choice should apply to both versions")
  await page.click("#voice-lab-loop")
  check(await page.eval(`!window.labPlayback.node.loop`), "loop can be disabled during playback")
  await page.waitFor(playing("none"), "playback to finish after disabling loop", 10_000)
  await page.eval(`window.restoreLabStart()`)

  // Concatenation gives an Original -> Modified comparison with brief pauses on one
  // cancellable playback node. Loop repeats the pair, not just its first half.
  await page.eval(`{
    const start = AudioBufferSourceNode.prototype.start;
    window.restoreComparisonStart = () => { AudioBufferSourceNode.prototype.start = start; };
    AudioBufferSourceNode.prototype.start = function(...args) {
      if (this.context instanceof AudioContext) { window.labComparisonNode = this; window.labComparisonStartedAt = this.context.currentTime; window.labComparisonOffset = args[1]; }
      return start.apply(this, args);
    };
  }`)
  await page.click("#voice-lab-play-comparison")
  await page.waitFor(playing("comparison"), "back-to-back comparison", 10_000)
  check(await page.eval(`{
    const samples = window.labComparisonNode.buffer.getChannelData(0);
    const rate = window.labComparisonNode.buffer.sampleRate;
    samples.length === 8.5 * rate && samples.subarray(0, 4 * rate).some(v => Math.abs(v) > .01) && samples.subarray(4 * rate, 4.25 * rate).every(v => v === 0) && samples.subarray(4.25 * rate, 8.25 * rate).some(v => Math.abs(v) > .01) && samples.subarray(8.25 * rate).every(v => v === 0);
  }`), "comparison should preserve both complete clips with quarter-second pauses")
  await page.click("#voice-lab-loop")
  check(await page.eval(`window.labComparisonNode.loop`), "loop should repeat the complete comparison")
  await page.click("#voice-lab-play-comparison")
  check(await page.eval(playing("none")), "active comparison button should stop the pair")
  await page.click("#voice-lab-loop")
  await page.click("#voice-lab-play-comparison")
  await page.waitFor(playing("comparison"), "comparison before its inter-clip pause", 10_000)
  await page.eval(`Object.defineProperty(window.labComparisonNode.context, "currentTime", {value: window.labComparisonStartedAt + 4.1, configurable: true})`)
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "switching from the pause to Modified", 10_000)
  check(await page.eval(`window.labComparisonOffset === 0`), "switching during the pause should start Modified at its beginning")
  await page.click("#voice-lab-stop")
  await page.eval(`window.restoreComparisonStart()`)

  for (const source of sources) {
    await choose("voice-lab-source", source)
    await rendered()
    check(await page.eval(playing("none")), "changing a sample should prepare its spectrogram silently")
    const result = JSON.parse(await page.eval(`JSON.stringify({
      rtf: Number(document.querySelector("#voice-lab-result-modified").dataset.realTimeFactor),
      delay: Number(document.querySelector("#voice-lab-result-modified").dataset.latencyMs),
      width: document.querySelector("#voice-lab-result-modified canvas").width
    })`))
    console.log(`${source} pitch shift: ${JSON.stringify(result)}`)
    check(result.width > 0 && result.rtf < 0.5, `${source}: invalid spectrogram or render time`)
    check(result.delay > 5 && result.delay < 60, `${source}: unexpected signal delay ${result.delay}`)
  }

  // A failed privacy benchmark must not prevent listening to an experiment.
  // Capture the actual rendered audio to catch a silent/incorrect WASM entry.
  await page.eval(`{
    const render = OfflineAudioContext.prototype.startRendering;
    window.restoreMcAdamsRender = () => { OfflineAudioContext.prototype.startRendering = render; };
    const start = AudioBufferSourceNode.prototype.start;
    window.restoreMcAdamsStart = () => { AudioBufferSourceNode.prototype.start = start; };
    AudioBufferSourceNode.prototype.start = function(...args) {
      if (this.context instanceof AudioContext) window.mcAdamsPlayback = {context: this.context, startedAt: this.context.currentTime};
      return start.apply(this, args);
    };
    OfflineAudioContext.prototype.startRendering = async function() {
      const result = await render.call(this);
      window.labRendered = result;
      return result;
    };
  }`)
  await choose("voice-lab-source", "mencken_wasichu.wav")
  await rendered()
  await choose("voice-lab-processor", "mcadams")
  await rendered()
  check(await page.eval(`document.querySelector("#voice-lab-result-modified").dataset.processor === "mcadams" && [...document.querySelector("#voice-lab-params").children].filter(row => !row.hidden).length === 1`), "McAdams should prepare automatically and show only its own coefficient")
  check(await page.eval(`document.querySelector("#voice-lab-param-mcadams-alpha-number").value === "0.9"`), "McAdams should start at the tested 0.9 setting")
  check(await page.eval(`window.labRendered.length === 6 * 48000 + 1022 && window.labRendered.getChannelData(0).some(value => Math.abs(value) > 0.01)`), "McAdams should render non-silent speech and flush its delayed tail")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "McAdams playback", 10_000)
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "original alongside McAdams", 10_000)
  await page.eval(`{
    const alpha = document.querySelector("#voice-lab-param-mcadams-alpha-number");
    alpha.value = "0.7";
    alpha.dispatchEvent(new Event("change", {bubbles: true}));
  }`)
  check(await page.eval(playing("none")), "coefficient edits should stop playback")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "McAdams 0.7 playback", 10_000)
  await choose("voice-lab-processor", "pitch_shift")
  await rendered()
  check(await page.eval(playing("none")), "changing modification should stop playback")
  await choose("voice-lab-processor", "mcadams")
  await rendered()
  check(await page.eval(`document.querySelector("#voice-lab-param-mcadams-alpha-number").value === "0.7"`), "switching modifications should preserve each set of parameters")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "McAdams before tail switch", 10_000)
  await page.eval(`Object.defineProperty(window.mcAdamsPlayback.context, "currentTime", {value: window.mcAdamsPlayback.startedAt + 6.01, configurable: true})`)
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("none"), "switching past the original's end should finish without restarting", 10_000)
  await page.eval(`window.restoreMcAdamsRender(); window.restoreMcAdamsStart()`)
  await choose("voice-lab-processor", "pitch_shift")
  await rendered()

  // Numeric entry and buttons stay synchronized with the compact sliders.
  await page.eval(`{
    const number = document.querySelector("#voice-lab-param-pitch_shift-semitones-number");
    number.value = "-3.5";
    number.dispatchEvent(new Event("input", {bubbles: true}));
  }`)
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones").value === "-3.5"`), "numeric pitch should update the slider")
  await page.click("#voice-lab-param-pitch_shift-semitones-number + [data-increase]")
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones-number").value === "-3"`), "plus should advance pitch by half a semitone")
  await page.eval(`{
    const number = document.querySelector("#voice-lab-param-pitch_shift-semitones-number");
    number.value = "999";
    number.dispatchEvent(new Event("change", {bubbles: true}));
  }`)
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones-number").value === "12" && document.querySelector("#voice-lab-param-pitch_shift-semitones-number + [data-increase]").disabled`), "typed out-of-range values should clamp and disable plus at the limit")
  await page.eval(`{
    const number = document.querySelector("#voice-lab-param-pitch_shift-semitones-number");
    number.value = "";
    number.dispatchEvent(new Event("input", {bubbles: true}));
  }`)
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones-number").value === ""`), "empty numeric input should remain editable")
  await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones-number").dispatchEvent(new Event("change", {bubbles: true}))`)
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-semitones-number").value === "12"`), "committing an empty value should restore the previous setting")
  await page.eval(`{
    const pitch = document.querySelector("#voice-lab-param-pitch_shift-semitones-number");
    pitch.value = "-4";
    pitch.dispatchEvent(new Event("input", {bubbles: true}));
    const window = document.querySelector("#voice-lab-param-pitch_shift-window_ms-number");
    window.value = "45";
    window.dispatchEvent(new Event("input", {bubbles: true}));
  }`)
  check(await page.eval(`document.querySelector("#voice-lab-param-pitch_shift-window_ms").value === "45"`), "numeric slice length should update the slider")
  await page.eval(`{
    const window = document.querySelector("#voice-lab-param-pitch_shift-window_ms-number");
    window.value = "40";
    window.dispatchEvent(new Event("input", {bubbles: true}));
  }`)

  // Slider edits must stop and invalidate a prepared result.
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "pitch playback", 60_000)
  await page.eval(`{
    const slider = document.querySelector("#voice-lab-param-pitch_shift-semitones");
    slider.value = 4;
    slider.dispatchEvent(new Event("input", {bubbles: true}));
  }`)
  check(await page.eval(`${playing("none")} && !document.querySelector("#voice-lab-result-modified").dataset.realTimeFactor`), "slider change must stop and invalidate old audio")

  // Hold the next offline render until Stop has cancelled playback intent.
  await page.eval(`{
    const original = OfflineAudioContext.prototype.startRendering;
    OfflineAudioContext.prototype.startRendering = function() {
      OfflineAudioContext.prototype.startRendering = original;
      return new Promise(resolve => { window.releaseLabRender = () => resolve(original.call(this)); });
    };
  }`)
  await page.click("#voice-lab-play")
  await page.waitFor(`!!window.releaseLabRender`, "the held preparation", 10_000)
  await page.click("#voice-lab-stop")
  await page.eval(`window.releaseLabRender()`)
  await rendered()
  check(await page.eval(playing("none")), "Stop during preparation must prevent delayed playback")

  // Failure must leave both playback and preparation controls usable.
  await page.eval(`{
    const slider = document.querySelector("#voice-lab-param-pitch_shift-semitones");
    slider.value = 5;
    slider.dispatchEvent(new Event("input", {bubbles: true}));
    const original = OfflineAudioContext.prototype.startRendering;
    OfflineAudioContext.prototype.startRendering = function() {
      OfflineAudioContext.prototype.startRendering = original;
      return Promise.reject(new Error("injected render failure"));
    };
  }`)
  await page.click("#voice-lab-play")
  await page.waitFor(`document.querySelector("#voice-lab-status").dataset.state === "failed" && document.querySelector("#voice-lab-stop").disabled`, "render failure recovery", 10_000)
  await page.click("#voice-lab-play-original")
  await page.waitFor(playing("original"), "original after render failure", 10_000)
  await choose("voice-lab-source", sources[1])
  check(await page.eval(playing("none")), "source change must stop playback")
  await page.click("#voice-lab-play")
  await page.waitFor(playing("modified"), "retry after render failure", 60_000)

  await page.labView('delay')
  await page.click("#voice-lab-measure")
  await page.waitFor(`["measured", "failed"].includes(document.querySelector("#voice-lab-seam-result").dataset.state)`, "the delay measurement", 30_000)
  const seam = await page.eval(`document.querySelector("#voice-lab-seam-result").textContent`)
  console.log(seam)
  check(!seam.startsWith("Measurement failed"), seam)

  // Exercise player exclusivity using bundled fixtures: generated recovery
  // WAVs are deliberately local and are not required for CI/offline tests.
  await page.labView('recovery')
  await page.eval(`{
    window.restoreRecoverySources = [];
    for (const player of document.querySelectorAll("[data-recovery-audio]")) {
      const source = player.querySelector("source");
      window.restoreRecoverySources.push(() => { source.src = source.dataset.original; player.load(); });
      source.dataset.original = source.src;
      source.src = "/dev/voice-lab/clips/high_voice.wav";
      player.load();
    }
  }`)
  const recoveryPlaying = `document.querySelectorAll("[data-recovery-audio]").values().some(player => !player.paused)`
  await page.eval(`document.querySelector("[data-recovery-case]:not([hidden]) audio").play()`)
  await page.waitFor(recoveryPlaying, "recovery reference playback", 10_000)
  await page.eval(`document.querySelectorAll("[data-recovery-case]:not([hidden]) audio")[1].play()`)
  check(await page.eval(`[...document.querySelectorAll("[data-recovery-audio]")].filter(player => !player.paused).length === 1`), "recovery audio should be exclusive")
  await page.click("#voice-lab-recovery-loop")
  check(await page.eval(`[...document.querySelectorAll("[data-recovery-case] audio")].every(player => player.loop)`), "recovery clips should support looping")
  await page.eval(`{
    const choice = document.querySelector("#voice-lab-recovery-choice");
    choice.selectedIndex = 1;
    choice.dispatchEvent(new Event("change", {bubbles: true}));
  }`)
  check(await page.eval(`!(${recoveryPlaying}) && document.querySelectorAll("[data-recovery-case]:not([hidden])").length === 1`), "switching recovery cases should stop and show one comparison")

  // The group comparison uses one real decoded buffer in explicit version
  // order. Small distinct PCM fixtures keep this independent of generated WAVs.
  await page.eval(`{
    const fetch = window.fetch.bind(window), decode = AudioContext.prototype.decodeAudioData;
    const start = AudioBufferSourceNode.prototype.start;
    window.restoreRecoverySequence = () => { window.fetch = fetch; AudioContext.prototype.decodeAudioData = decode; AudioBufferSourceNode.prototype.start = start; };
    window.recoverySequenceStarts = 0;
    AudioBufferSourceNode.prototype.start = function(...args) {
      if (this.context instanceof AudioContext) { window.recoverySequenceNode = this; window.recoverySequenceStarts++; }
      return start.apply(this, args);
    };
    AudioContext.prototype.decodeAudioData = function(bytes) {
      const pending = decode.call(this, bytes);
      if (!window.holdRecoveryDecode) return pending;
      window.holdRecoveryDecode = false;
      window.recoveryDecodeContext = this;
      return pending.then(buffer => new Promise(resolve => { window.releaseRecoveryDecode = () => resolve(buffer); }));
    };
    function fixture(level) {
      const bytes = new ArrayBuffer(44 + 24000 * 2), data = new DataView(bytes);
      const text = (at, value) => [...value].forEach((c, i) => data.setUint8(at+i, c.charCodeAt(0)));
      text(0,"RIFF"); data.setUint32(4,36+48000,true); text(8,"WAVE"); text(12,"fmt ");
      data.setUint32(16,16,true); data.setUint16(20,1,true); data.setUint16(22,1,true);
      data.setUint32(24,48000,true); data.setUint32(28,96000,true); data.setUint16(32,2,true); data.setUint16(34,16,true);
      text(36,"data"); data.setUint32(40,48000,true);
      for(let i=0;i<24000;i++) data.setInt16(44+i*2,Math.round(level*32767),true);
      return bytes;
    }
    for (const source of document.querySelectorAll("[data-recovery-version] source")) {
      source.src = "/dev/voice-lab/clips/high_voice.wav?sequence=" + source.parentElement.dataset.recoveryVersion;
      source.parentElement.load();
    }
    window.fetch = (url, options) => {
      const part = new URL(url, location.href).searchParams.get("sequence");
      if (!part) return fetch(url, options);
      if (window.failRecoveryFetch) return Promise.resolve(new Response("missing", {status:404}));
      return Promise.resolve(new Response(fixture({original:.1, disguised:.2, recovered:.3}[part] ?? .1)));
    };
  }`)
  const sequenceState = `document.getElementById("voice-lab-recovery-playback-status").dataset.state`
  await page.click("#voice-lab-recovery-play-all")
  await page.waitFor(`${sequenceState} === "playing"`, "three-way recovery comparison", 10_000)
  check(await page.eval(`{
    const node=window.recoverySequenceNode, data=node.buffer.getChannelData(0);
    node.loop && node.buffer.length === 108000 && Math.abs(data[23999]-.1)<.001 && data.subarray(24000,36000).every(v=>v===0) && Math.abs(data[59999]-.2)<.001 && data.subarray(60000,72000).every(v=>v===0) && Math.abs(data[95999]-.3)<.001 && data.subarray(96000).every(v=>v===0);
  }`), "sequence should preserve all three clips with pauses between them and at the loop boundary")
  check(await page.eval(`!(${recoveryPlaying})`), "group playback must pause native players")
  await page.click("#voice-lab-recovery-loop")
  check(await page.eval(`!window.recoverySequenceNode.loop`), "Loop changes should apply to the active sequence")
  await page.waitFor(`${sequenceState} === "idle" && window.recoverySequenceNode.context.state === "closed"`, "sequence end cleanup", 10_000)

  await page.eval(`window.holdRecoveryDecode = true`)
  await page.click("#voice-lab-recovery-play-all")
  await page.waitFor(`!!window.releaseRecoveryDecode`, "held recovery decode", 10_000)
  await page.click("#voice-lab-recovery-stop")
  await page.eval(`window.releaseRecoveryDecode()`)
  await page.waitFor(`window.recoveryDecodeContext.state === "closed" && ${sequenceState} === "idle"`, "Stop during recovery preparation", 10_000)
  check(await page.eval(`window.recoverySequenceStarts === 1`), "cancelled decode must not start delayed playback")

  await page.eval(`window.failRecoveryFetch = true`)
  await page.click("#voice-lab-recovery-play-all")
  await page.waitFor(`${sequenceState} === "failed"`, "recovery loading failure", 10_000)
  check(await page.eval(`document.getElementById("voice-lab-recovery-play-all").getAttribute("aria-pressed") === "false"`), "failed group playback should reset its button")
  await page.eval(`window.failRecoveryFetch = false`)
  await page.click("#voice-lab-recovery-play-all")
  await page.waitFor(`${sequenceState} === "playing"`, "recovery retry", 10_000)
  await page.eval(`document.querySelector("[data-recovery-case]:not([hidden]) audio").play()`)
  await page.waitFor(`${sequenceState} === "idle" && window.recoverySequenceNode.context.state === "closed"`, "native playback to cancel the sequence", 10_000)
  await page.labView('listen')
  check(await page.eval(`!(${recoveryPlaying})`), "leaving Recovery should stop its audio")
  await page.eval(`window.restoreRecoverySequence(); window.restoreRecoverySources.forEach(restore => restore())`)

  // Live microphone preview uses fake devices and muted output in this harness.
  await page.eval(`{
    const capture = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    window.labMicStreams = [];
    window.labRuntimeWorklets = []; window.labRuntimeContexts = [];
    const Worklet = window.AudioWorkletNode, Context = window.AudioContext;
    window.AudioWorkletNode = class extends Worklet { constructor(...args) { super(...args); window.labRuntimeWorklets.push(this); } };
    window.AudioContext = class extends Context { constructor(...args) { super(...args); window.labRuntimeContexts.push(this); } };
    window.labCapture = async (...args) => {
      const stream = await capture(...args);
      window.labMicStreams.push(stream);
      return stream;
    };
    navigator.mediaDevices.getUserMedia = window.labCapture;
  }`)
  const micStopped = `window.labMicStreams.every(stream => stream.getTracks().every(track => track.readyState === "ended"))`
  const monitoring = `document.querySelector("#voice-lab-live-status").dataset.state === "monitoring"`
  await page.labView('voice')
  await page.click("#voice-lab-live-modified")
  await page.waitFor(monitoring, "modified live microphone preview", 10_000)
  await page.click("#voice-lab-live-original")
  check(await page.eval(`document.querySelector("#voice-lab").dataset.live === "original" && window.labMicStreams.length === 1`), "switching live versions should reuse one microphone")
  await page.labView('listen')
  await page.waitFor(micStopped, "microphone teardown on tab change", 10_000)

  await choose("voice-lab-processor", "mcadams")
  await page.labView('voice')
  check(await page.eval(`document.querySelector("#voice-lab-live-settings").textContent.includes("McAdams")`), "live preview should describe the selected modification")
  await page.click("#voice-lab-live-modified")
  await page.waitFor(monitoring, "McAdams live microphone preview at 48 kHz", 10_000)
  await page.labView('listen')
  await page.waitFor(micStopped, "McAdams microphone teardown", 10_000)
  await choose("voice-lab-processor", "pitch_shift")

  // Stop during a permission prompt must close a late-granted microphone.
  await page.labView('voice')
  await page.eval(`window.labBeforeLateGrant = window.labMicStreams.length;
    navigator.mediaDevices.getUserMedia = (...args) => new Promise(resolve => {
    window.grantLabMic = async () => resolve(await window.labCapture(...args));
  })`)
  await page.click("#voice-lab-live-modified")
  await page.waitFor(`!!window.grantLabMic`, "the held microphone permission", 10_000)
  await page.click("#voice-lab-live-stop")
  await page.eval(`window.grantLabMic()`)
  await page.waitFor(`window.labMicStreams.length === window.labBeforeLateGrant + 1 && ${micStopped}`, "late permission to be closed without monitoring", 10_000)
  check(await page.eval(`document.querySelector("#voice-lab").dataset.live === "none"`), "cancelled microphone must not start later")

  // Permission denial and worklet failure must release resources and allow retry.
  await page.eval(`navigator.mediaDevices.getUserMedia = async () => { throw new DOMException("Denied", "NotAllowedError"); }`)
  await page.click("#voice-lab-live-original")
  await page.waitFor(`document.querySelector("#voice-lab-live-status").dataset.state === "failed"`, "permission denial feedback", 10_000)
  await page.eval(`{
    navigator.mediaDevices.getUserMedia = window.labCapture;
    window.labBeforeWorkletFailure = window.labMicStreams.length;
    const original = AudioWorklet.prototype.addModule;
    AudioWorklet.prototype.addModule = function(...args) {
      AudioWorklet.prototype.addModule = original;
      return Promise.reject(new Error("injected worklet failure"));
    };
  }`)
  await page.click("#voice-lab-live-modified")
  await page.waitFor(`document.querySelector("#voice-lab-live-status").dataset.state === "failed" && window.labMicStreams.length === window.labBeforeWorkletFailure + 1 && ${micStopped}`, "worklet failure cleanup", 10_000)
  await page.click("#voice-lab-live-modified")
  await page.waitFor(monitoring, "modified runtime preview", 10_000)
  // Chromium binds onprocessorerror to "error"; also exercise the spec name.
  // https://chromium.googlesource.com/chromium/src/+/refs/heads/main/third_party/blink/renderer/modules/webaudio/audio_worklet_node.h
  await page.eval(`window.retiredLabWorklet=window.labRuntimeWorklets.at(-1);for(const type of ['error','processorerror'])window.retiredLabWorklet.dispatchEvent(new ErrorEvent(type,{message:'Injected runtime failure'}))`)
  await page.waitFor(`${micStopped}&&document.querySelector('#voice-lab-live-status').dataset.state==='failed'&&window.labRuntimeContexts.every(c=>c.state==='closed')`, "runtime worklet failure closes capture and context", 10_000)
  await page.click("#voice-lab-live-original")
  await page.waitFor(monitoring, "original monitoring after failure", 10_000)
  await page.eval(`for(const type of ['error','processorerror'])window.retiredLabWorklet.dispatchEvent(new ErrorEvent(type,{message:'Retired runtime failure'}))`)
  check(await page.eval(`${monitoring}`), "retired worklet failure cannot stop replacement preview")
  await page.eval(`for(const type of ['error','processorerror'])window.labRuntimeWorklets.at(-1).dispatchEvent(new ErrorEvent(type,{message:'Original-route runtime failure'}))`)
  await page.waitFor(`${micStopped}&&document.querySelector('#voice-lab-live-status').dataset.state==='failed'&&window.labRuntimeContexts.every(c=>c.state==='closed')`, "runtime failure also closes the original monitoring route", 10_000)
  await page.click("#voice-lab-live-original")
  await page.waitFor(monitoring, "microphone retry", 10_000)
  await page.eval(`window.labMicStreams.at(-1).getAudioTracks()[0].dispatchEvent(new Event("ended"))`)
  await page.waitFor(`${micStopped} && document.querySelector("#voice-lab").dataset.live === "none"`, "device loss cleanup", 10_000)
  await page.click("#voice-lab-live-original")
  await page.waitFor(monitoring, "microphone before navigation", 10_000)
  await page.eval(`document.dispatchEvent(new Event("phx:page-loading-start"))`)
  await page.waitFor(micStopped, "microphone teardown on navigation", 10_000)

  if (process.env.SCREENSHOT) {
    await page.labView('listen')
    await page.send("Emulation.setDeviceMetricsOverride", {width: 1200, height: 1300, deviceScaleFactor: 1, mobile: false})
    await page.eval(`new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))`)
    await page.eval(`document.getAnimations().forEach(animation => animation.finish())`)
    const {data} = await page.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true})
    writeFileSync(process.env.SCREENSHOT, Buffer.from(data, "base64"))
    await page.labView('delay')
    await page.eval(`document.documentElement.dataset.theme = "dark"; document.getAnimations().forEach(animation => animation.finish())`)
    const delay = await page.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true})
    writeFileSync(process.env.SCREENSHOT.replace(/\.png$/, "-delay-dark.png"), Buffer.from(delay.data, "base64"))
    await page.labView('voice')
    await page.eval(`document.getAnimations().forEach(animation => animation.finish())`)
    const live = await page.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true})
    writeFileSync(process.env.SCREENSHOT.replace(/\.png$/, "-voice-dark.png"), Buffer.from(live.data, "base64"))
    await page.labView('benchmark')
    await page.eval(`document.getAnimations().forEach(animation => animation.finish())`)
    const benchmark = await page.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true})
    writeFileSync(process.env.SCREENSHOT.replace(/\.png$/, "-benchmark-dark.png"), Buffer.from(benchmark.data, "base64"))
    await page.labView('listen')
    await page.send("Emulation.setDeviceMetricsOverride", {width: 390, height: 844, deviceScaleFactor: 1, mobile: true})
    check(await page.eval(`document.documentElement.scrollWidth <= window.innerWidth`), "Listen should fit a narrow screen")
    for (const tab of ["voice", "recovery", "models", "basics", "delay", "benchmark"]) {
      await page.labView(tab)
      check(await page.eval(`document.documentElement.scrollWidth <= window.innerWidth`), `${tab} should fit a narrow screen`)
    }
  }
  // Global navigation callbacks must remain safe after LiveView removes the lab.
  check(await page.eval(`{
    let errors = 0;
    const onError = () => { errors++; };
    window.addEventListener("error", onError);
    document.querySelector("#voice-lab").remove();
    document.dispatchEvent(new Event("phx:page-loading-start"));
    window.dispatchEvent(new Event("pagehide"));
    window.removeEventListener("error", onError);
    errors === 0;
  }`), "navigation cleanup should tolerate the lab DOM being removed")
} finally {
  await browser.close()
}
for (const failure of failures) console.log(`✗ ${failure}`)
console.log(failures.length ? `${failures.length} failed` : "voice lab ok")
process.exit(failures.length ? 1 : 0)
