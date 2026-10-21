// The current call's resume ticket: how this page gets back into its call
// if its connection to the server drops (participant_channel.md, Client
// obligations). The server sends it (the "randos:resume_ticket" event) when
// the call starts and after each resume; the LiveSocket sends it back as a
// connect param when it reconnects. In memory only, on purpose: never
// stored, so a reload or a new tab starts fresh.

let ticket = null

export const setResumeTicket = value => {
  ticket = typeof value === "string" ? value : null
}

export const resumeTicket = () => ticket
