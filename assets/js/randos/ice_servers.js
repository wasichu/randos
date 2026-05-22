const DEFAULT_ICE_SERVERS = [{urls: "stun:stun.l.google.com:19302"}]

export const iceServersFromPage = () => {
  const content = document.querySelector("meta[name='randos-ice-servers']")?.content

  if (!content) return DEFAULT_ICE_SERVERS

  try {
    const iceServers = JSON.parse(content)
    return Array.isArray(iceServers) && iceServers.length > 0 ? iceServers : DEFAULT_ICE_SERVERS
  } catch (_error) {
    return DEFAULT_ICE_SERVERS
  }
}
