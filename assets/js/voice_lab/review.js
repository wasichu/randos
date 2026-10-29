// Dev-only text feedback. Drafts survive failed requests; audio is never included.
const STORAGE_KEY = "randos.voiceLab.reviews.v1"
const canonical = value => value && typeof value === "object" && !Array.isArray(value)
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value
const keyFor = value => JSON.stringify(canonical(value))
const hasAnswers = payload => Object.keys(payload.ratings).length > 0 || payload.notes.trim() !== ""
const payloadFor = draft => {
  const payload = {context: draft.context, ratings: draft.ratings, notes: draft.notes}
  return hasAnswers(payload) ? payload : {...payload, notes: "", withdrawn: true}
}

export function setupReviews({listenContext, comparisonContexts = {}}) {
  const drafts = new Map(), pending = new Map(), errors = new Map(), attempts = new Map(), unpersisted = new Set()
  let storageAvailable = true, timer = null, saving = null, destroyed = false
  let forms = []
  try {
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null")
    if (stored?.version === 1 && Array.isArray(stored.drafts)) {
      for (const draft of stored.drafts) {
        if (draft?.context && draft.ratings && typeof draft.notes === "string") drafts.set(keyFor(draft.context), draft)
      }
    }
  } catch { storageAvailable = false }

  function persisted() {
    const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null")
    return new Map(stored?.version === 1 && Array.isArray(stored.drafts)
      ? stored.drafts.filter(draft => draft?.context && draft.ratings && typeof draft.notes === "string").map(draft => [keyFor(draft.context), draft]) : [])
  }
  function store(key, signature = null) {
    try {
      const latest = persisted()
      let draft = drafts.get(key)
      if (signature) {
        draft = unpersisted.has(key) ? draft : latest.get(key) ?? draft
        // Confirm the posted snapshot, preserving edits (including a revert) made later.
        draft = {...draft, savedSignature: signature}
        drafts.set(key, draft)
      }
      latest.set(key, draft)
      localStorage.setItem(STORAGE_KEY, JSON.stringify({version: 1, drafts: [...latest.values()]}))
      unpersisted.delete(key)
      storageAvailable = true
    } catch { storageAvailable = false; unpersisted.add(key) }
  }

  const dirty = key => {
    const draft = drafts.get(key)
    return draft && (hasAnswers(draft) || draft.savedSignature || draft.submitted) && draft.savedSignature !== keyFor(payloadFor(draft))
  }
  function indicateAll() { for (const form of forms) form.indicate() }
  function schedule() {
    clearTimeout(timer)
    timer = null
    if (saving || destroyed || pending.size === 0) return
    const due = Math.min(...[...pending.values()].map(item => item.due))
    timer = setTimeout(drain, Math.max(0, due - Date.now()))
  }
  function queue(key, delay = 1000) {
    if (!dirty(key)) { pending.delete(key); return }
    const first = pending.get(key)?.first ?? Date.now()
    pending.set(key, {first, due: Math.min(Date.now() + delay, first + 5000)})
    schedule()
  }

  async function drain() {
    if (saving) return
    const next = [...pending].sort((a, b) => a[1].due - b[1].due)[0]
    if (!next) return
    if (next[1].due > Date.now()) { schedule(); return }
    const [key] = next
    pending.delete(key)
    if (storageAvailable && !unpersisted.has(key)) {
      try { const latest = persisted().get(key); if (latest) drafts.set(key, latest) } catch { storageAvailable = false }
    }
    if (!dirty(key)) { schedule(); return }
    const snapshot = JSON.parse(JSON.stringify(payloadFor(drafts.get(key))))
    const signature = keyFor(snapshot)
    // A request may reach the server even when its acknowledgment is lost.
    // Keep that fact across edits/reloads so clearing an in-flight first save
    // still sends a withdrawal instead of silently restoring the old judgment.
    const submitted = {...drafts.get(key), submitted: true}
    // An older confirmation cannot describe server state after this request.
    // A reload must resend a later revert/reactivation until it is confirmed.
    delete submitted.savedSignature
    drafts.set(key, submitted)
    store(key)
    saving = key
    errors.delete(key)
    indicateAll()
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 12000)
    let retryable = true
    try {
      const token = document.querySelector("meta[name=csrf-token]")?.content
      if (!token) { retryable = false; throw new Error("Reload the page before saving.") }
      const response = await fetch("/dev/voice-lab/reviews", {
        method: "POST", credentials: "same-origin", keepalive: true, signal: controller.signal,
        headers: {"content-type": "application/json", "x-csrf-token": token},
        body: JSON.stringify(snapshot),
      })
      const result = await response.json().catch(() => null)
      if (!response.ok) {
        retryable = response.status >= 500 || response.status === 429
        throw new Error(result?.error ?? "Could not save the review.")
      }
      if (typeof result?.saved_at !== "string") throw new Error("The save was not confirmed.")
      attempts.delete(key)
      if (!destroyed) {
        // The departing page must not overwrite a newly mounted page's outbox.
        store(key, signature)
        if (!storageAvailable) drafts.set(key, {...drafts.get(key), savedSignature: signature})
      }
      // A reply confirms only its snapshot. Edits made in flight go next.
      if (!destroyed && dirty(key)) queue(key, 0)
    } catch (error) {
      errors.set(key, `${error.name === "AbortError" ? "Saving timed out." : error.message} ${retryable ? "Will retry automatically." : "Edit or use Save now to retry."} Your draft is kept here.`)
      if (retryable && dirty(key) && !pending.has(key) && !destroyed) {
        const attempt = (attempts.get(key) ?? 0) + 1
        attempts.set(key, attempt)
        pending.set(key, {first: Date.now(), due: Date.now() + Math.min(30000, 5000 * 2 ** Math.min(attempt - 1, 3))})
      }
    } finally {
      clearTimeout(timeout)
      saving = null
      indicateAll()
      if (!destroyed) schedule()
    }
  }

  function flush() {
    for (const key of drafts.keys()) if (dirty(key)) queue(key, 0)
    for (const item of pending.values()) item.due = Date.now()
    clearTimeout(timer)
    timer = null
    void drain()
  }

  forms = [...document.querySelectorAll("[data-voice-review]")].map(form => {
    const controls = [...form.querySelectorAll("[data-review-question]")]
    const notes = form.querySelector("[data-review-notes]")
    const status = form.querySelector("[data-review-status]")
    const button = form.querySelector("[data-review-save]")
    const state = {key: null, context: null}
    const resemblance = controls.filter(control => control.dataset.reviewQuestion === "resemblance").map(control => {
      const label = control.labels?.[0]?.querySelector("span")
      return {control, label, text: label?.textContent, options: [...control.options].map(option => option.textContent)}
    })

    function collect() {
      const ratings = {}
      for (const control of controls) {
        if (!control.value) continue
        const voice = control.dataset.reviewVoice
        ratings[voice] ??= {}
        ratings[voice][control.dataset.reviewQuestion] = control.value
      }
      return {context: state.context, ratings, notes: notes.value}
    }
    function show(text, kind) { status.textContent = text; status.dataset.state = kind }
    function indicate() {
      if (!form.isConnected) return
      const payload = payloadFor(collect())
      const saved = state.context && drafts.get(state.key)?.savedSignature === keyFor(payload)
      button.disabled = saving === state.key || !state.context || !dirty(state.key)
      if (saving === state.key && state.key) show(payload.withdrawn ? "Withdrawing review…" : "Saving review…", "saving")
      else if (saved) show(payload.withdrawn ? "Review withdrawn. Earlier entries remain in history." : "Saved automatically. Say “reviews ready” when you're finished.", payload.withdrawn ? "withdrawn" : "saved")
      else if (errors.has(state.key)) show(errors.get(state.key), "failed")
      else if (payload.withdrawn && dirty(state.key)) show("Withdrawal queued. Auto-saving shortly…", "draft")
      else if (hasAnswers(payload)) show(storageAvailable ? "Draft backed up here. Auto-saving shortly…" : "Browser drafts unavailable. Auto-saving to the checkout…", "draft")
      else show("Not judged yet. Answers and notes save automatically.", "empty")
    }
    function remember() {
      if (!state.context) return
      drafts.set(state.key, {...drafts.get(state.key), ...collect()})
      errors.delete(state.key)
      attempts.delete(state.key)
      store(state.key)
      queue(state.key)
      indicateAll()
    }
    function refresh() {
      let selected
      if (Object.hasOwn(comparisonContexts, form.dataset.voiceReview)) selected = comparisonContexts[form.dataset.voiceReview]()
      else if (form.dataset.voiceReview === "listen") selected = listenContext()
      else if (form.dataset.voiceReview === "model") {
        const choice = document.getElementById("voice-lab-model-choice")
        const item = [...document.querySelectorAll("[data-model-case]")].find(item => item.dataset.modelCase === choice?.value)
        if (item?.dataset.ready === "true") selected = {context: JSON.parse(item.dataset.reviewContext), label: choice.selectedOptions[0].textContent}
      } else {
        const choice = document.getElementById("voice-lab-recovery-choice")
        const item = [...document.querySelectorAll("[data-recovery-case]")].find(item => item.dataset.recoveryCase === choice?.value)
        if (item) selected = {context: JSON.parse(item.dataset.reviewContext), label: choice.selectedOptions[0].textContent}
      }
      const nextKey = selected ? keyFor(selected.context) : null
      if (state.key && state.key !== nextKey) queue(state.key, 0)
      state.context = selected ? JSON.parse(JSON.stringify(selected.context)) : null
      state.key = nextKey
      for (const item of resemblance) {
        const reference = state.context?.mode === "chunked_world"
        if (item.label) item.label.textContent = reference ? "Resemblance to the whole-recording WORLD voice" : item.text
        for (const [index, option] of [...item.control.options].entries()) {
          option.textContent = reference ? ({same: "Sounds like the reference voice", partial: "Partly resembles the reference", different: "Sounds different from the reference voice"}[option.value] ?? item.options[index]) : item.options[index]
        }
      }
      if (Object.hasOwn(comparisonContexts, form.dataset.voiceReview)) {
        for (const control of controls) control.disabled = !selected
        notes.disabled = !selected
      }
      const draft = drafts.get(state.key)
      for (const control of controls) control.value = draft?.ratings[control.dataset.reviewVoice]?.[control.dataset.reviewQuestion] ?? ""
      notes.value = draft?.notes ?? ""
      form.querySelector("[data-review-context-label]").textContent = selected ? `Reviewing: ${selected.label}. Answers attach to these exact settings.` : Object.hasOwn(comparisonContexts, form.dataset.voiceReview) ? "Choose a sample and wait for all versions before reviewing." : "No prepared output for this sample. Choose another sample or modification."
      indicate()
    }
    const submit = event => { event.preventDefault(); remember(); queue(state.key, 0) }
    form.addEventListener("input", remember)
    form.addEventListener("change", remember)
    form.addEventListener("submit", submit)
    return {refresh, indicate, destroy() {
      form.removeEventListener("input", remember)
      form.removeEventListener("change", remember)
      form.removeEventListener("submit", submit)
    }}
  })

  function refresh() { for (const form of forms) form.refresh() }
  function hidden() { if (document.visibilityState === "hidden") flush() }
  function destroy() {
    flush()
    destroyed = true
    clearTimeout(timer)
    document.removeEventListener("visibilitychange", hidden)
    document.removeEventListener("phx:page-loading-start", destroy)
    window.removeEventListener("online", flush)
    window.removeEventListener("pagehide", flush)
    for (const form of forms) form.destroy()
  }
  document.addEventListener("visibilitychange", hidden)
  document.addEventListener("phx:page-loading-start", destroy)
  window.addEventListener("online", flush)
  window.addEventListener("pagehide", flush)
  refresh()
  for (const key of drafts.keys()) queue(key)
  return {refresh, destroy}
}
