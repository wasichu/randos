// Only language codes: shared across tabs for the browser-defined session.
// No microphone, masking choice, age acknowledgment or participant identifier.
const cookieName = 'randos_conversation'
const speakingSelector = 'select[name="conversation[speaking_language]"]'
const hearingSelector = 'input[type="checkbox"][name="conversation[hearing_languages][]"]'

function valid(value, supported) {
  return value?.version === 1 && supported.has(value.speaks) &&
    Array.isArray(value.hears) && value.hears.length <= supported.size &&
    value.hears.every(code => supported.has(code)) && new Set(value.hears).size === value.hears.length
}

function saved(supported) {
  try {
    const entry = document.cookie.split(';').map(part => part.trim()).find(part => part.startsWith(`${cookieName}=`))
    if (!entry || entry.length > 1024) return null
    const value = JSON.parse(decodeURIComponent(entry.slice(cookieName.length + 1)))
    return valid(value, supported) ? value : null
  } catch { return null }
}

export const ConversationPreferences = {
  mounted() {
    const speaking = this.el.querySelector(speakingSelector)
    const supported = new Set(Array.from(speaking.options, option => option.value).filter(Boolean))
    const preference = saved(supported)
    if (preference) {
      // One restoration, before any subsequent form action. LiveView remains
      // the owner; no per-field synthetic events or restore on later patches.
      speaking.value = preference.speaks
      for (const input of this.el.querySelectorAll(hearingSelector)) input.checked = preference.hears.includes(input.value)
      this.pushEvent('update_preferences', {conversation: {
        speaking_language: preference.speaks, hearing_languages: preference.hears,
      }})
    }
    this.remember = event => {
      // A stale tab's age checkbox must not overwrite another tab's choices.
      if (!event.target.matches?.(`${speakingSelector}, ${hearingSelector}`)) return
      const value = {
        version: 1,
        speaks: this.el.querySelector(speakingSelector).value,
        hears: Array.from(this.el.querySelectorAll(hearingSelector)).filter(input => input.checked).map(input => input.value),
      }
      if (!valid(value, supported)) return
      try {
        // Deliberately no Max-Age/Expires or Domain. Browser session restore
        // may retain session cookies; no hard restart-expiry promise is made.
        document.cookie = `${cookieName}=${encodeURIComponent(JSON.stringify(value))}; Path=/; SameSite=Lax${location.protocol === 'https:' ? '; Secure' : ''}`
      } catch { /* Blocked cookies must not prevent normal form use. */ }
    }
    this.el.addEventListener('change', this.remember)
  },
  destroyed() {
    this.el.removeEventListener('change', this.remember)
  },
}
