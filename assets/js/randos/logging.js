const LOG_PREFIX = "randos"

// localStorage can throw (privacy modes, blocked storage); logging must never
// break the call flow.
const debugEnabled = () => {
  try {
    return window.localStorage.getItem("randos:debug") === "true"
  } catch {
    return false
  }
}

export const logEvent = (event, details = {}) => {
  if (!debugEnabled()) return

  console.info(`[${LOG_PREFIX}]`, {event, ...details})
}

export const logDebug = (event, details = {}) => {
  if (!debugEnabled()) return

  console.debug(`[${LOG_PREFIX}]`, {event, ...details})
}

export const logWarning = (event, details = {}) => {
  console.warn(`[${LOG_PREFIX}]`, {event, ...details})
}
