import {logWarning} from "./logging"

// ICE servers (with fresh TURN credentials) are rendered per call onto the
// call's element as data-ice-servers. The server always provides them
// (RandosWeb.IceServers); there's deliberately no client-side default, which
// would hide a misconfiguration.
export const iceServersFrom = element => {
  try {
    const iceServers = JSON.parse(element?.dataset.iceServers || "[]")
    if (Array.isArray(iceServers) && iceServers.length > 0) return iceServers
  } catch (_error) {
    // fall through
  }

  logWarning("webrtc.no_ice_servers")
  return []
}
