export class CleanupBag {
  constructor(label) {
    this.label = label
    this.cleanups = []
    this.cleaned = false
  }

  add(cleanup) {
    if (typeof cleanup !== "function") return cleanup

    if (this.cleaned) {
      cleanup()
    } else {
      this.cleanups.push(cleanup)
    }

    return cleanup
  }

  addEventListener(target, event, handler, options) {
    if (!target) return

    target.addEventListener(event, handler, options)
    this.add(() => target.removeEventListener(event, handler, options))
  }

  cleanup() {
    if (this.cleaned) return

    this.cleaned = true

    for (const cleanup of this.cleanups.splice(0).reverse()) {
      cleanup()
    }
  }
}
