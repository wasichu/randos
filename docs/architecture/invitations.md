# Invitation links (design, 2026-10-22; decided; building since 2026-10-24)

Proposed by the owner: **anonymous, one-time invitation links**, after
Lichess's anonymous challenges. Two people who already found each other
elsewhere (Discord, Reddit, a language exchange) get a private, audio-only
place to talk. randos stays the same one-to-one call; people can now
either meet a stranger or bring their own.

## The experience

1. On the idle screen, next to "Find a rando", a quieter "Invite someone".
2. randos shows a link and a Copy button, and waits ("Waiting for your
   rando to open the link…", with Cancel). Sharing it happens elsewhere.
3. The other person opens the link and sees one screen: the 18+
   acknowledgement and "Join the call".
4. The first to join is in a one-to-one call with the creator: the same
   call as any other (timing, extension vote, audio, recovery).
5. The link stops working once used, when it expires, or when the
   creator cancels or leaves.

What it doesn't add: no accounts, names, contact lists, history,
messaging, scheduling, or managing invitations; no group calls; nothing
stored. Random matchmaking is unchanged.

## How it fits (the simplest version)

**The Matchmaker holds invitations.** An invitation is a waiting
participant found by its token instead of by language. The Matchmaker
already does everything around that: it validates the entry (the 18+
acknowledgement), monitors the waiting person (leaving cancels), refuses
someone who is already waiting (`:already_queued`, so nobody is in the
queue and inviting at once), and starts the call through the same
`CallCoordinator.start_match`. It's one process, so two people claiming one
link at the same moment are served one after the other: the first gets the
call, the second "this link isn't valid any more". No new process, no new
supervision, no database. (A separate `Invitations` process would need its
own copy of the monitoring and call start; it isn't worth it at this
size.) Production is one node today; the Matchmaker is already the
singleton that a second node would have to solve for, and invitations
ride on whatever that becomes.

- `Matchmaker.invite(attrs)` → `{:invited, token, expires_at}`: a 128-bit
  random token; only its SHA-256 is kept (as `Randos.Calls.ResumeTicket`
  does), with the waiting entry, a monitor and an expiry timer. Not in the
  public waiting list, so random matching never sees it.
- `Matchmaker.accept(token, attrs)` → `{:matched, match}` or
  `{:error, :invitation_invalid}`. No language check (they chose each
  other); the 18+ acknowledgement and `audio?` agreement still apply (a
  client without audio can't join a browser's call: `:audio_mismatch`,
  and the link stays valid for someone who can).
- Invitations live in their own map (token hash → entry, monitor, expiry
  timer), not in `waiting`: the DOWN handler checks both, `snapshot`
  (the status page's queue counts) leaves them out, and an invitation
  call records no rematch pair when it ends.
- `Matchmaker.cancel_invitation(pid)`, and the monitor: the creator's
  process going away (tab closed, reload) cancels it.
- The expiry: `Lifecycle.invitation_seconds/0` (15 minutes proposed), the
  timing constants' one home.

**The call is an ordinary call** with one mark: `Match` gets
`kind: :random | :invitation`, carried on `Call`. The coordinator doesn't
care; two places do:

- **After the call, both go idle**, never into the random queue
  (`Participant`'s ended-call branch, which today requeues unless
  `stop_after_call?`). Someone who came to talk to a friend shouldn't find
  themselves matched with a stranger when the friend hangs up.
- **No "Next rando"** in an invitation call (there's no next). End stays.
- The rematch window doesn't apply (it exists so "Next" finds someone new).

**The participant core** (`Randos.Participant`, pure) gets one status,
`:inviting`, and events `{:invite, prefs}`, `:cancel_invitation` and
`{:accept_invitation, token, prefs}`; `:inviting` adopts its call exactly as
`:looking` does. Both shells (LiveView, channel) map onto it, so the TUI
and the browser stay interoperable: a browser can invite a TUI and the
reverse.

**The link.** `https://randos.slowinput.org/join#<token>`, built from
the Endpoint's URL (`PHX_HOST`; in production a Fly secret,
`randos.slowinput.org`, overriding `fly.toml`'s `randos.fly.dev`, which
rejects browser sockets), never from the request's host: the token in the
URL fragment, which browsers never send to the server. So it can't end up
in a request log, a `Referer`, or a link preview's fetch, and a preview
bot (Discord, Slack, iMessage) gets a plain page with nothing to claim.
`/join` is a `live_action` of `HomeLive`, not a LiveView of its own, so
the joiner lands on the same call screen with nothing duplicated. It reads
the fragment in a hook and sends it over the
socket only when the person presses "Join the call"; even then, a page
that merely loads claims nothing. The TUI accepts the pasted link (or the
bare token) and takes the part after `#`.

**Protocol** (`participant_channel.md`; a mini-pass trigger: both clients
and the obligation tests):
- `invite {speaks, adult_acknowledged, audio, ice_restart}` → state
  `inviting`, with `invitation: {"url", "expires_at_unix_ms"}`;
- `cancel_invitation {}` → `idle`;
- `accept_invitation {token, speaks, adult_acknowledged, audio,
  ice_restart}` → a call, or `error: "invitation_invalid"` /
  `"audio_mismatch"`. One reason for unknown, used, expired and cancelled
  alike: the joiner can't act differently on them, and it tells a
  guesser nothing;
- rate-limited with `find`'s token bucket.

**Languages.** The creator's languages come from their usual settings
(the form's, or the TUI's saved ones). The joiner's page asks nothing
about languages (decision 8): the joiner is taken to speak what the
creator wants to hear. So the joiner sees `peer_speaks` as usual (the
creator's speaking language), and the creator sees the creator's own
hearing language; with several, `peer_speaks` is the first (what older
clients show) and `peer_speaks_any` lists them all ("German or
Japanese").

**Privacy** (`docs/privacy.md`): the server holds an invitation's token
hash, the creator's anonymous participant id and their speaking
language, in memory, until it's used, cancelled or expires (15 minutes at
most); nothing is written anywhere. The token never reaches the server
in a URL. The status page counts invitation calls among calls started;
whether they also count toward language pairs is a decision below.

## Tests

- Matchmaker: create, accept, invalid after use, after expiry, after
  cancel, after the creator's process exits; the creator accepting their
  own link (invalid); someone waiting can't invite, someone inviting
  can't join the queue; two `accept`s racing (many
  processes at once, exactly one call); not in the random list (a random
  joiner with matching languages isn't matched to it); `:already_queued`
  both ways; the audio mismatch leaves the link valid.
- Participant: `:inviting` → call → idle after the end, either side
  hanging up; no requeue; no `next`.
- LiveView: create, copy, cancel; `/join` without a fragment, with a bad
  one, with a good one (the 18+ box, then the call); the page loading
  alone claims nothing.
- Channel: the three events, their errors and the rate limit; a TUI
  inviting a browser and a browser inviting a TUI.
- Smoke (`call_smoke.mjs`): one headless Chrome invites, the other opens
  the link, audio flows both ways, both end idle; `tui-smoke`: a TUI
  accepts a browser's link (once the TUI has it).

## Decisions (the owner, 2026-10-22)

1. **After an invitation call, both go idle**, never back to looking.
2. **The same limit as any call:** 10 minutes, +10 by mutual vote, 30 at
   most. One kind of call; they can make a new link to keep talking.
3. **The token in the fragment** (`/join#<token>`).
4. **A link expires after 15 minutes** unclaimed
   (`Lifecycle.invitation_seconds/0`).
5. **Both clients in the first cut**: the TUI gets `i` to invite (it shows
   the link) and a prompt to paste one; `tui-smoke` covers browser↔TUI.
6. **The status page** counts invitation calls among calls started, and
   leaves them out of language pairs.
7. **The button says "Invite someone"**, a quieter secondary button
   beside "Find a rando".

All seven were the proposals.

**Before building (the owner, 2026-10-24), after an advisor check:**

8. **The joiner picks no language.** The join screen is the 18+
   click-through and "Join the call"; the joiner is taken to speak the
   creator's hearing language (all of them, when several).
9. **Translations:** the new strings go through `just translate-update`
   for both catalogs when the wording is final, without asking again.
10. **TUI keys: `v` invites, `j` joins** (a prompt for the link; a paste
    on the idle screen opens it): `i`/`o` already pick the mic and
    speaker there, so decision 5's `i` moved.
11. **A design review before translating** (the owner, 2026-10-24):
    screenshots of every step, web and TUI, in a review wizard the owner
    approves step by step, with notes; translations only after.

**The review's first round (2026-10-24)** approved the home form, the
inviting screen, the call and the TUI's idle and call screens, and asked
for: messages that say only what went wrong (no advice); a notice that
the call ended for whoever didn't end it (`notice: call_ended`); the
website's progress list with invitation steps (the creator's Invite,
Waiting, Connecting, In call, Time is up; the joiner's Join, Connecting,
In call, Time is up); `y` to copy the link in the TUI (`Tui.Clipboard`);
and the TUI's join prompt staying open until the 18+ box is ticked (tab
ticks it there). No call length on /join (the call shows a countdown).
A second round shows those changes.

Nothing is open.
