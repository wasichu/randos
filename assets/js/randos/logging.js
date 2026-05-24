const LOG_PREFIX = "randos"

const debugEnabled = () => window.localStorage.getItem("randos:debug") === "true"

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
