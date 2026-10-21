import {CleanupBag} from "../randos/cleanup"
import {callCountdownValue, startInterval} from "../randos/timers"
import {label, labelsFrom} from "../randos/labels"

export const CallCountdown = {
  mounted() {
    this.cleanupBag = new CleanupBag("call-countdown")
    const labels = labelsFrom(this.el)
    this.tick = () => {
      const countdown = callCountdownValue({
        deadlineUnixMs: Number(this.el.dataset.deadlineUnixMs),
      })
      const value = this.el.querySelector("[data-countdown-value]")
      if (value) value.textContent = label(labels, "remaining", "%{time} remaining", {time: countdown.time})

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
