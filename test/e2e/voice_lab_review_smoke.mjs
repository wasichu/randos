// Every page intercepts real-looking review writes before application startup.
// Validation/CSRF use invalid bodies; storage append tests use isolated ExUnit files.
import assert from "node:assert/strict"
import {Browser, BASE_URL} from "./cdp.mjs"

const browser = await Browser.launch()
try {
  const page = await browser.newPage("voice-review")
  await page.send("Page.addScriptToEvaluateOnNewDocument", {source: `(() => {
    const original=window.fetch.bind(window);
    window.reviewBodies=[];window.reviewBehavior='ok';
    window.fetch=(url,options)=>{
      if(url!=='/dev/voice-lab/reviews'||options?.body==='{}')return original(url,options);
      const body=JSON.parse(options.body);window.reviewBodies.push(body);
      window.reviewHasCsrf=!!options.headers['x-csrf-token'];
      const success=()=>new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201});
      if(window.reviewBehavior==='hold')return new Promise(resolve=>{window.releaseReviewSave=()=>resolve(success());});
      if(window.reviewBehavior==='fail')return Promise.resolve(new Response(JSON.stringify({error:'Injected write failure'}),{status:503}));
      return Promise.resolve(success());
    };
  })();`})
  const choose = (id, value) => page.eval(`{const control=document.getElementById(${JSON.stringify(id)});control.value=${JSON.stringify(value)};control.dispatchEvent(new Event('change',{bubbles:true}));}`)
  const note = text => page.eval(`{const control=document.getElementById('voice-lab-review-listen-notes');control.value=${JSON.stringify(text)};control.dispatchEvent(new Event('input',{bubbles:true}));}`)
  const status = `document.getElementById('voice-lab-review-listen-status').dataset.state`
  const ready = () => page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, "lab readiness", 30_000)
  const saved = () => page.waitFor(`${status}==='saved'`, "automatic review save", 10_000)
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await ready()
  assert(await page.eval(`document.querySelector('#voice-lab-review-listen [data-review-save]').disabled && window.reviewBodies.length===0`), "untouched feedback does not post")
  assert(await page.eval(`fetch('/dev/voice-lab/reviews',{method:'POST',headers:{'content-type':'application/json'},body:'{}'}).then(r=>r.status===403)`))
  assert(await page.eval(`fetch('/dev/voice-lab/reviews',{method:'POST',headers:{'content-type':'application/json','x-csrf-token':document.querySelector('meta[name=csrf-token]').content},body:'{}'}).then(r=>r.status===422)`))

  await choose("voice-lab-source", "mid_voice.wav")
  await choose("voice-lab-processor", "mcadams")
  await choose("voice-lab-param-mcadams-alpha-number", "0.75")
  await choose("voice-lab-review-listen-disguised-naturalness", "slightly_artificial")
  await choose("voice-lab-review-listen-disguised-clarity", "clear")
  await note("Nasal at 0.75; words are clear.")
  await saved()
  assert(await page.eval(`window.reviewBodies.length===1 && window.reviewHasCsrf && window.reviewBodies[0].context.parameters.alpha===.75 && window.reviewBodies[0].context.sample==='mid_voice.wav' && window.reviewBodies[0].notes.startsWith('Nasal')`), "edits coalesce and bind exact context")
  const count = await page.eval(`window.reviewBodies.length`)
  await page.eval(`new Promise(resolve=>setTimeout(resolve,1500))`)
  assert.equal(await page.eval(`window.reviewBodies.length`), count, "clean forms are not periodically appended again")

  // Clearing a saved judgment withdraws it, including whitespace-only notes.
  await page.eval(`window.reviewBehavior='fail'`)
  await choose("voice-lab-review-listen-disguised-naturalness", "")
  await choose("voice-lab-review-listen-disguised-clarity", "")
  await note("  ")
  await page.waitFor(`${status}==='failed'`, "failed withdrawal retains its draft", 10_000)
  assert(await page.eval(`window.reviewBodies.at(-1).withdrawn===true&&Object.keys(window.reviewBodies.at(-1).ratings).length===0&&window.reviewBodies.at(-1).notes===''`))
  await page.eval(`window.reviewBehavior='ok'`)
  await page.waitFor(`${status}==='withdrawn'`, "automatic withdrawal retry", 10_000)
  const withdrawnCount=await page.eval('window.reviewBodies.length')
  await page.eval(`new Promise(resolve=>setTimeout(resolve,1500))`)
  assert.equal(await page.eval('window.reviewBodies.length'),withdrawnCount,'confirmed withdrawals are not posted repeatedly')
  await page.open(`${BASE_URL}/dev/voice-lab`);await ready()
  await choose("voice-lab-processor", "mcadams")
  await choose("voice-lab-param-mcadams-alpha-number", "0.75")
  await choose("voice-lab-source", "mid_voice.wav")
  await page.waitFor(`${status}==='withdrawn'`, "withdrawn state survives reload", 10_000)
  assert.equal(await page.eval('window.reviewBodies.length'),0,'reload does not re-post confirmed withdrawal')
  await choose("voice-lab-review-listen-disguised-clarity", "clear")
  await saved()
  assert(await page.eval(`!Object.hasOwn(window.reviewBodies.at(-1),'withdrawn')`),'a new answer reactivates the review')

  // Undoing a withdrawal in flight needs a new confirmation, even if the
  // restored fields exactly equal the previously confirmed active answer.
  const activeBeforeReload=await page.eval('window.reviewBodies.at(-1)')
  await page.eval(`window.reviewBehavior='hold';delete window.releaseReviewSave`)
  await choose("voice-lab-review-listen-disguised-clarity", "")
  await page.waitFor('!!window.releaseReviewSave', "withdrawal in flight before exact reactivation", 10_000)
  assert(await page.eval('window.reviewBodies.at(-1).withdrawn===true'))
  await choose("voice-lab-review-listen-disguised-clarity", "clear")
  await page.open(`${BASE_URL}/dev/voice-lab`);await ready()
  await page.waitFor(`window.reviewBodies.some(b=>b.context.sample==='mid_voice.wav'&&!b.withdrawn&&b.ratings.disguised?.clarity==='clear')`, "reactivation resubmitted after reload", 10_000)
  assert.deepEqual(await page.eval(`window.reviewBodies.find(b=>b.context.sample==='mid_voice.wav'&&!b.withdrawn&&b.ratings.disguised?.clarity==='clear')`),activeBeforeReload)
  await choose("voice-lab-processor", "mcadams")
  await choose("voice-lab-param-mcadams-alpha-number", "0.75")
  await choose("voice-lab-source", "mid_voice.wav")
  await saved()

  await page.eval(`window.reviewBehavior='fail'`)
  await note("A failed write keeps this review.")
  await page.waitFor(`${status}==='failed'`, "automatic failure feedback", 10_000)
  await page.eval(`window.reviewBehavior='ok'`)
  await saved()
  assert(await page.eval(`document.getElementById('voice-lab-review-listen-notes').value.includes('failed write')`), "failed writes retry with the draft intact")

  await page.eval(`window.reviewBehavior='hold';delete window.releaseReviewSave`)
  await note("Snapshot before the held request.")
  await page.waitFor(`!!window.releaseReviewSave`, "held automatic save", 10_000)
  await note("Updated while saving; this must be the last saved version.")
  await choose("voice-lab-source", "high_voice.wav")
  await page.eval(`window.reviewBehavior='ok';window.releaseReviewSave()`)
  await page.waitFor(`window.reviewBodies.at(-1).notes.startsWith('Updated while saving')`, "queued edit after held request", 10_000)
  assert(await page.eval(`${status}!=='saved' && document.getElementById('voice-lab-review-listen-notes').value===''`), "late replies cannot mark a different source saved")
  await choose("voice-lab-source", "mid_voice.wav")
  await saved()
  assert(await page.eval(`document.getElementById('voice-lab-review-listen-notes').value.startsWith('Updated while saving')`))

  // Restoring an unsent draft submits that exact context, even if not selected.
  await page.eval(`window.reviewBehavior='hold';delete window.releaseReviewSave`)
  await note("Restore this unsent edit after reload.")
  await page.waitFor(`!!window.releaseReviewSave`, "unsent draft", 10_000)
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await ready()
  await page.waitFor(`window.reviewBodies.some(b=>b.notes.startsWith('Restore this unsent'))`, "restored draft autosave", 10_000)
  await choose("voice-lab-processor", "mcadams")
  await choose("voice-lab-param-mcadams-alpha-number", "0.75")
  await choose("voice-lab-source", "mid_voice.wav")
  await saved()

  // Save before the debounce deadline when the sample changes.
  await note("Flush this exact sample before switching.")
  await choose("voice-lab-source", "low_voice.wav")
  await page.waitFor(`window.reviewBodies.some(b=>b.notes.startsWith('Flush this exact'))`, "context-switch flush", 10_000)
  assert(await page.eval(`window.reviewBodies.find(b=>b.notes.startsWith('Flush this exact')).context.sample==='mid_voice.wav'`))

  // Continuous typing still submits within the periodic limit, then its final edit.
  await page.eval(`(async()=>{
    const input=document.getElementById('voice-lab-review-listen-notes');
    for(let i=0;i<11;i++){input.value='Continuous typing '+i;input.dispatchEvent(new Event('input',{bubbles:true}));await new Promise(resolve=>setTimeout(resolve,550));}
  })()`)
  assert(await page.eval(`window.reviewBodies.some(b=>b.notes.startsWith('Continuous typing ') && b.notes!=='Continuous typing 10')`), "periodic autosave happens without a typing pause")
  await saved()
  assert(await page.eval(`window.reviewBodies.at(-1).notes==='Continuous typing 10'`))

  // Quota failures do not block autosave or audio, and are visible before ack.
  await page.eval(`window.reviewSetItem=Storage.prototype.setItem;Storage.prototype.setItem=()=>{throw new DOMException('Quota','QuotaExceededError');}`)
  await note("Storage failure keeps an in-memory draft and still saves remotely.")
  assert(await page.eval(`document.getElementById('voice-lab-review-listen-status').textContent.includes('unavailable')`))
  await saved()
  await page.click("#voice-lab-play-original")
  await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='original'`, "audio despite storage error", 10_000)
  await page.click("#voice-lab-stop")
  await page.eval(`Storage.prototype.setItem=window.reviewSetItem`)

  await page.click("#voice-lab-tab-recovery")
  await choose("voice-lab-review-recovery-disguised-resemblance", "different")
  await choose("voice-lab-review-recovery-recovered-resemblance", "same")
  await page.waitFor(`document.getElementById('voice-lab-review-recovery-status').dataset.state==='saved'`, "recovery auto-save", 10_000)
  assert(await page.eval(`window.reviewBodies.at(-1).context.view==='recovery' && window.reviewBodies.at(-1).ratings.recovered.resemblance==='same'`))

  // Clearing the first save while it is in flight must survive a reload.
  await page.click("#voice-lab-tab-listen")
  await choose("voice-lab-source", "mencken_wasichu.wav")
  await page.eval(`window.reviewBehavior='hold';delete window.releaseReviewSave`)
  await note("First submission before clearing.")
  await page.waitFor('!!window.releaseReviewSave', "first save in flight", 10_000)
  await note("")
  assert(await page.eval(`JSON.parse(localStorage.getItem('randos.voiceLab.reviews.v1')).drafts.some(d=>d.context.sample==='mencken_wasichu.wav'&&d.submitted&&d.notes==='')`),'in-flight submission marker persists with cleared draft')
  await page.open(`${BASE_URL}/dev/voice-lab`);await ready()
  await page.waitFor(`window.reviewBodies.some(b=>b.withdrawn===true&&b.context.sample==='mencken_wasichu.wav')`, "cleared in-flight first save resumes as withdrawal", 10_000)
  await choose("voice-lab-processor", "mcadams")
  await choose("voice-lab-param-mcadams-alpha-number", "0.75")
  await choose("voice-lab-source", "mencken_wasichu.wav")
  await page.waitFor(`${status}==='withdrawn'`, "restored withdrawal confirmed", 10_000)

  // Navigation flushes; an old acknowledgment must not erase a new page's drafts.
  await page.click("#voice-lab-tab-listen")
  await page.eval(`window.reviewBehavior='hold';delete window.releaseReviewSave`)
  await note("Flush on navigation.")
  await page.eval(`document.dispatchEvent(new Event('phx:page-loading-start'))`)
  await page.waitFor(`!!window.releaseReviewSave`, "navigation flush", 10_000)
  await page.eval(`{
    const key='randos.voiceLab.reviews.v1', saved=JSON.parse(localStorage.getItem(key));
    const draft=saved.drafts.find(d=>d.notes==='Flush on navigation.');draft.notes='New page edit';
    saved.drafts.push({...draft,context:{...draft.context,sample:'other-page-context'},notes:'Another new-page draft'});
    localStorage.setItem(key,JSON.stringify(saved));window.releaseReviewSave();
  }`)
  await page.waitFor(`${status}!=='saving'`, "departed save acknowledgment", 10_000)
  assert(await page.eval(`JSON.parse(localStorage.getItem('randos.voiceLab.reviews.v1')).drafts.some(d=>d.notes==='New page edit') && JSON.parse(localStorage.getItem('randos.voiceLab.reviews.v1')).drafts.some(d=>d.notes==='Another new-page draft')`), "old outbox cannot overwrite new-page notes or other contexts")
  console.log("voice reviews: automatic coalescing, retry, serialization, periodic typing, context/reload/navigation recovery and storage failures passed")
} finally { await browser.close() }
