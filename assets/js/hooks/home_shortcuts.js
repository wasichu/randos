const openedStorageKey = 'randos:shortcuts-opened'
let openedInPage = false

function wasOpened() {
  try { return openedInPage || localStorage.getItem(openedStorageKey) === '1' }
  catch { return openedInPage }
}

function rememberOpened() {
  openedInPage = true
  try { localStorage.setItem(openedStorageKey, '1') } catch {}
}

const actions = {
  c: {key: 'c', selector: '#conversation_speaking_language', cycle: true},
  a: {key: 'a', selector: '#conversation_adult_acknowledgment'},
  b: {key: 'b', selector: '#voice-settings-toggle'},
  f: {key: 'f', selector: '#find-rando-button'},
  i: {key: 'i', selector: '#invite-button'},
  x: {key: 'x', selector: '#cancel-search-button'},
  e: {key: 'e', selector: '#end-call-button'},
  n: {key: 'n', selector: '#next-rando-button'},
  p: {key: 'p', selector: '#voice-preview', expand: true},
  s: {key: 's', selector: '#voice-family', panel: true, cycle: true},
  t: {key: 't', selector: '#voice-tone', panel: true, cycle: true},
  m: {key: 'm', selector: '[data-webrtc-mute]'},
  o: {key: 'o', selector: '#header-about-link'},
  r: {key: 'r', selector: '#header-status-link'},
  l: {key: 'l', selector: '#locale-switcher-toggle', language: true},
}

function targetFor(action) {
  if (action.panel && !document.querySelector('#voice-settings')?.open) return null
  return document.querySelector(action.selector)
}

function available(target, action) {
  if (!target || target.disabled || !target.isConnected) return false
  return action.expand || target.getClientRects().length > 0
}

function cycleSelect(select) {
  const options = Array.from(select.options).filter(option => !option.disabled && !option.closest('optgroup[disabled]'))
  if (options.length < 2) return
  const next = options[(options.indexOf(select.selectedOptions[0]) + 1) % options.length]
  select.value = next.value
  select.dispatchEvent(new Event('change', {bubbles: true}))
}

// The native language disclosure owns its keyboard while focus is inside it.
// Arrow keys only move focus; Enter/Space submit through the existing form.
function languageKey(event) {
  const menu = document.querySelector('#locale-switcher')
  const toggle = menu?.querySelector('summary')
  if (!menu?.open || !toggle?.getClientRects().length) return false
  if (event.key === 'Escape') {
    event.preventDefault(); menu.open = false
    toggle.focus({preventScroll: true})
    return true
  }
  if (!menu.contains(event.target)) return false
  const buttons = Array.from(menu.querySelectorAll('#locale-options button:not(:disabled)'))
  const current = buttons.indexOf(document.activeElement)
  let next
  switch (event.key) {
    case 'ArrowDown': next = (current + 1) % buttons.length; break
    case 'ArrowUp': next = ((current < 0 ? buttons.length : current) - 1 + buttons.length) % buttons.length; break
    case 'Home': next = 0; break
    case 'End': next = buttons.length - 1; break
    default: return true
  }
  if (buttons.length) { event.preventDefault(); buttons[next].focus() }
  return true
}

export const HomeShortcuts = {
  mounted() {
    this.panel = this.el.querySelector('#homepage-shortcuts-panel')
    this.toggleButton = this.el.querySelector('#homepage-shortcuts-help')
    this.closeButton = this.el.querySelector('#homepage-shortcuts-close')
    this.refresh = () => {
      if (this.panel.hidden) return
      for (const row of this.el.querySelectorAll('[data-shortcut]')) {
        const action = actions[row.dataset.shortcut]
        const target = document.querySelector(action.selector)
        row.hidden = !target
        row.classList.toggle('opacity-40', !!target && !available(targetFor(action), action))
      }
      for (const group of this.el.querySelectorAll('[data-shortcut-group]')) {
        group.hidden = !Array.from(group.querySelectorAll('[data-shortcut]')).some(row => !row.hidden)
      }
    }
    this.setOpen = open => {
      if (open) rememberOpened()
      if (!open && (this.panel.contains(document.activeElement) || document.activeElement === this.closeButton)) this.toggleButton.focus({preventScroll: true})
      this.panel.hidden = !open
      this.closeButton.hidden = !open
      this.toggleButton.setAttribute('aria-expanded', String(open))
      this.toggleButton.classList.toggle('text-teal-700', open)
      this.refresh()
    }
    this.toggle = () => this.setOpen(this.panel.hidden)
    this.close = () => this.setOpen(false)
    this.key = event => {
      if (event.defaultPrevented || event.isComposing || event.ctrlKey || event.altKey || event.metaKey) return
      if (document.querySelector('dialog[open]')) return
      if (languageKey(event) || event.repeat) return
      if (event.key === 'Escape' && !this.panel.hidden) { event.preventDefault(); this.close(); return }
      if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]')) return
      if (event.key === '?') { event.preventDefault(); this.toggle(); return }
      if (this.panel.hidden) return
      const key = event.key.toLowerCase()
      const action = actions[key]
      if (!action) return
      const target = targetFor(action)
      if (!available(target, action)) return
      event.preventDefault()
      if (action.expand) document.querySelector('#voice-settings').open = true
      if (action.cycle) cycleSelect(target)
      else target.click()
      if (action.language) {
        const menu = document.querySelector('#locale-switcher')
        if (menu.open) (menu.querySelector('[aria-current="true"]') || menu.querySelector('#locale-options button'))?.focus()
        else target.focus({preventScroll: true})
      }
      this.refresh()
    }
    this.toggleButton.addEventListener('click', this.toggle)
    this.closeButton.addEventListener('click', this.close)
    document.addEventListener('keydown', this.key)
    // Keep key hints in step with LiveView validation/call patches and native
    // disclosure state. Our own hidden/class changes are outside this filter.
    this.observer = new MutationObserver(this.refresh)
    this.observer.observe(document.querySelector('[data-phx-main]'), {
      subtree: true, childList: true, attributes: true, attributeFilter: ['disabled', 'open'],
    })
    this.setOpen(wasOpened())
  },
  destroyed() {
    this.observer.disconnect()
    document.removeEventListener('keydown', this.key)
    this.toggleButton.removeEventListener('click', this.toggle)
    this.closeButton.removeEventListener('click', this.close)
  },
}
