export const startInterval = (callback, delayMs) => {
  const interval = window.setInterval(callback, delayMs)

  return () => window.clearInterval(interval)
}

export const callCountdownValue = ({deadlineUnixMs, now = Date.now()}) => {
  const remainingMs = Math.max(deadlineUnixMs - now, 0)
  const totalSeconds = Math.ceil(remainingMs / 1000)
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60

  return {
    totalSeconds,
    underMinute: totalSeconds < 60,
    label: `${minutes}:${seconds.toString().padStart(2, "0")} remaining`,
    decisionLabel: `Decision closes in ${totalSeconds}s`,
  }
}
