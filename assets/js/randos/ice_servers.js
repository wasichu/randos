const DEFAULT_ICE_SERVERS = [{urls: "stun:stun.l.google.com:19302"}]

// ICE servers (with fresh TURN credentials) are rendered per call onto the
// call's element as data-ice-servers.
export const iceServersFrom = element => {
  const content = element?.dataset.iceServers

  if (!content) return DEFAULT_ICE_SERVERS

  try {
    const iceServers = JSON.parse(content)
    return Array.isArray(iceServers) && iceServers.length > 0 ? iceServers : DEFAULT_ICE_SERVERS
  } catch (_error) {
    return DEFAULT_ICE_SERVERS
  }
}
