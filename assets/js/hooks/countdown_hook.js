import {CleanupBag} from "../randos/cleanup"
import {callCountdownValue, startInterval} from "../randos/timers"

export const CallCountdown = {
  mounted() {
    this.cleanupBag = new CleanupBag("call-countdown")
    this.tick = () => {
      const countdown = callCountdownValue({
        deadlineUnixMs: Number(this.el.dataset.deadlineUnixMs),
      })
      const value = this.el.querySelector("[data-countdown-value]")
        || this.el.querySelector("#call-countdown-value")
        || this.el.querySelector("#extension-countdown-value")

      if (value) {
        if (this.el.dataset.countdownMode === "seconds") {
          value.textContent = countdown.decisionLabel
        } else {
          value.textContent = countdown.label
        }
      }

      this.el.dataset.underMinute = countdown.underMinute ? "true" : "false"
    }

    this.tick()
    this.cleanupBag.add(startInterval(this.tick, 1000))
  },

  updated() {
    this.tick()
  },

  destroyed() {
    this.cleanup()
  },

  disconnected() {
    this.cleanup()
  },

  cleanup() {
    this.cleanupBag?.cleanup()
  },
}
