// Presentation only: no queue estimates, capture or matchmaking timers.
export const SearchActivity = {
  mounted() {
    this.inView = false
    this.syncMotion = () => {
      this.el.dataset.searchRunning = String(this.inView && !document.hidden)
    }
    this.observer = new IntersectionObserver(([entry]) => {
      this.inView = entry.isIntersecting
      this.syncMotion()
    })
    this.observer.observe(this.el)
    document.addEventListener("visibilitychange", this.syncMotion)
    this.syncMotion()
  },

  destroyed() {
    this.observer.disconnect()
    document.removeEventListener("visibilitychange", this.syncMotion)
  },
}
