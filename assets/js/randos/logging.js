const LOG_PREFIX = "randos"

export const logEvent = (event, details = {}) => {
  console.info(`[${LOG_PREFIX}]`, {event, ...details})
}

export const logDebug = (event, details = {}) => {
  console.debug(`[${LOG_PREFIX}]`, {event, ...details})
}

export const logWarning = (event, details = {}) => {
  console.warn(`[${LOG_PREFIX}]`, {event, ...details})
}
