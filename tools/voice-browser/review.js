import {createRecoveryPlayback} from "../../assets/js/voice_lab/recovery_playback"

let comparison
const players = [...document.querySelectorAll("audio")]
const button = document.getElementById("compare")
const status = document.getElementById("playback-status")
function stop() {
  comparison?.close()
  comparison = null
  for (const player of players) player.pause()
  button.textContent = "▶ Play original → native → browser"
  status.textContent = ""
}
for (const player of players) player.addEventListener("play", () => {
  comparison?.close()
  comparison = null
  button.textContent = "▶ Play original → native → browser"
  status.textContent = ""
  for (const other of players) if (other !== player) other.pause()
})
button.addEventListener("click", async () => {
  if (comparison) { stop(); return }
  stop()
  const current = createRecoveryPlayback({urls: players.map(player => player.src),
    loop: document.getElementById("loop").checked,
    onEnded: () => { if (comparison === current) stop() }})
  comparison = current
  button.textContent = "■ Stop comparison"
  status.textContent = "Preparing playback…"
  try {
    if (await current.ready && comparison === current) status.textContent = "Playing with 250 ms pauses."
  } catch (error) {
    if (comparison === current) { stop(); status.textContent = `Could not play: ${error.message}` }
  }
})
document.getElementById("loop").addEventListener("change", event => comparison?.setLoop(event.target.checked))
addEventListener("pagehide", stop)
