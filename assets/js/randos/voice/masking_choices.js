// Device-local session choices. Nothing here is persisted or sent in signaling.
export const MASKING_STYLES = Object.freeze({
  lower_resonance: {pitch: 0, scale: .8},
  lower_resonance_pitch: {pitch: -1, scale: .8},
  higher_resonance: {pitch: 0, scale: 1.25},
  higher_resonance_pitch: {pitch: 1, scale: 1.25},
})
let choice = {family: 'off', tone: 'fuller'}
let stop = () => Promise.resolve()
let lastCleanup = Promise.resolve()
export const getChoice = () => ({...choice})
export function setChoice(family, tone) {
  if (!['off', 'tone', 'tone_pitch'].includes(family) || !['fuller', 'brighter'].includes(tone)) throw Error('Unsupported voice choice')
  choice = {family, tone}
}
export function selectedMasking() {
  if (choice.family === 'off') return null
  return `${choice.tone === 'fuller' ? 'lower' : 'higher'}_resonance${choice.family === 'tone_pitch' ? '_pitch' : ''}`
}
export function ownAudition(cleanup) {
  stop = cleanup
  return () => {
    if (stop !== cleanup) return
    lastCleanup = Promise.all([lastCleanup, cleanup()]).then(() => {})
    stop = () => Promise.resolve()
  }
}
export function stopAudition() {
  lastCleanup = Promise.all([lastCleanup, stop()]).then(() => {})
  return lastCleanup
}
