import {label, labelsFrom} from "../randos/labels"

// The invitation link's token lives in the URL fragment (/join#<token>),
// which browsers never send to the server. This hook tells the server only
// whether there is one, and puts it in the form as the form is submitted:
// a page that merely loads (a link preview's bot, say) claims nothing.
export const JoinLink = {
  mounted() {
    this.token = window.location.hash.slice(1)
    this.pushEvent("join_link", {has_token: this.token.length > 0})
    // Capture phase: before LiveView reads the form on its own submit listener.
    this.onSubmit = () => {
      const input = this.el.querySelector("input[name='token']")
      if (input) input.value = this.token
    }
    this.el.addEventListener("submit", this.onSubmit, true)
  },

  destroyed() {
    this.el.removeEventListener("submit", this.onSubmit, true)
  },
}

// Copies the invitation link, and says so for a moment.
export const CopyLink = {
  mounted() {
    const labels = labelsFrom(this.el)
    const text = this.el.querySelector("[data-copy-label]")
    this.onClick = async () => {
      try {
        await navigator.clipboard.writeText(this.el.dataset.url)
      } catch (_error) {
        // No clipboard (an insecure origin, a denied permission): select the
        // link so it can be copied by hand.
        document.getElementById("invitation-url")?.select()
        return
      }
      if (text) text.textContent = label(labels, "copied", "Copied")
      clearTimeout(this.reset)
      this.reset = setTimeout(() => {
        if (text) text.textContent = label(labels, "copy", "Copy")
      }, 2000)
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    clearTimeout(this.reset)
    this.el.removeEventListener("click", this.onClick)
  },
}
