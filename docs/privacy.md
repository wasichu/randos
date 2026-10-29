# Privacy: what each part of randos sees and keeps

This is for readers who want to check rather than trust. Every claim
below links to the configuration or code that makes it true, and the
claims that matter most are guarded by tests or by a check that runs on
every commit (`just check-privacy`, part of `just precommit` and CI). Where
something can't be checked from the outside, this says so.

## The short version

- **Nobody hears your call but the person you're talking to.** Audio is
  encrypted end to end (WebRTC's DTLS-SRTP). The keys are negotiated
  between the two of you; neither the randos server nor the relay has them.
- **The person you're talking to never sees your IP address.** Every call
  goes through our relay, and the server removes direct addresses from
  everything it passes between you, even if a client sends them.
- **Nothing is stored.** There is no database. The waiting room and calls
  live in the server's memory and vanish when they end. The logs that do
  exist contain no IP addresses and nothing about who you are.

## Component by component

| Part | What it sees | What it logs | Kept for |
| --- | --- | --- | --- |
| **The web server** (Phoenix, on Fly.io) | Your IP address while you're connected (any website does); the languages you chose (and the interface language a terminal client asks for at join: only a code like `es`, as a browser's `Accept-Language` says); the connection messages for your call, never the audio | Events such as "call started" and "call ended", tagged with random call and match IDs. No IP addresses, no languages, no identifiers that outlive the call. | Our host, Fly.io, keeps app logs for a limited time; we don't send them anywhere else |
| **The relay** (coturn, a DigitalOcean droplet) | Both IP addresses of each relayed call, its timing, and its encrypted packets, which it can't decrypt | Errors only, with every IP address zeroed before it's written | 7 days |
| **Your browser** | Your choice of interface language, if you pick one | A `randos_locale` cookie holding only the language code (e.g. `es`), so the next visit is in your language; it identifies no one and goes nowhere else. Phoenix's session cookie (CSRF protection) also carries the language for the page. | A year, or until you clear it |
| **Your browser (display preferences)** | Your color theme and whether you have opened keyboard shortcuts | Local storage only: `randos:theme` and the boolean flag `randos:shortcuts-opened`. No identifier or audio; these values are not sent to the server. See [theme](../assets/js/app.js) and [shortcuts](../assets/js/hooks/home_shortcuts.js). | Until you clear this site's local storage |
| **Your terminal (the TUI)** | Nothing new | A settings file on your own computer (`~/.config/randos/config.json`, or `~/Library/Application Support/randos/config.json` on macOS): your languages, the TUI's own interface language, that you confirmed the 18+ notice, and the mic and speaker names. It never leaves your computer. | Until you delete it |
| **Your rando's browser or terminal** | The relay's address, never yours; your voice | Nothing (randos has no recording feature) | Not applicable |

### The web server

- **No database and no accounts:** there's no Ecto or other storage in
  [`mix.exs`](../mix.exs); state is processes
  ([`Randos.Matchmaking.Matchmaker`](../lib/randos/matchmaking/matchmaker.ex),
  one [`CallCoordinator`](../lib/randos/calls/call_coordinator.ex) per call).
- **What it logs:** the `Logger` calls in
  [`call_coordinator.ex`](../lib/randos/calls/call_coordinator.ex) and
  [`matchmaker.ex`](../lib/randos/matchmaking/matchmaker.ex), at `info`
  ([`config/prod.exs`](../config/prod.exs)). Phoenix's request logs
  include no client addresses. We checked production's logs on
  2026-10-21: no line contained an IP address.
- **The status page** (`/status`): counted for each UTC day (reset at
  midnight): calls started and connected, how they ended (finished,
  couldn't connect, connection lost, canceled), calls continued past 10
  minutes, connected lengths in whole minutes (for the typical length),
  and calls per language pair (the two speaking languages, unordered). No
  addresses, no ids, nothing per person, no cookies. Published only above
  small counts: a language pair shows once it has 3 calls (smaller ones are
  summed under "other"), and the typical length once 3 calls connected.
  The relay check sets up and releases a test allocation with fresh
  credentials; it involves no one's call. Each day's counts are kept in a
  small JSON file on the server's disk (a Fly volume), so they survive
  restarts: exactly the aggregates above, and nothing else
  ([`Randos.Stats.FileStore`](../lib/randos/stats/file_store.ex)). Old days'
  files are kept, as a history of totals; they hold nothing about anyone.
  The terminal client shows the same data, fetched over its channel
  (`status`); asking sends nothing about the asker.
- **The translations page** (`/translations`): read-only; it stores and
  sends nothing. "Suggest a fix" is a plain link to GitHub, so nothing
  reaches GitHub until you follow it, and what you submit there is a
  public issue under your GitHub account.
- **Resume tickets.** During a call, each person's client holds a
  one-time resume ticket, 128 random bits that name only their seat in
  that call, so a dropped connection can rejoin without ending the call.
  The client keeps it in memory only (never stored; a reload starts
  fresh). The server keeps only a hash of it, in the call's own process,
  gone when the call ends. It identifies no one and is never logged.
- **Invitation links.** "Invite someone" makes a one-time link: 128
  random bits in the part after `#`, which browsers never send to a
  server, so the token can't land in a request log, a `Referer`, or a link
  preview's fetch. The `/join` page sends it over the socket only when you
  press "Join the call"; a page that merely loads claims nothing. Until the
  link is used, cancelled or expires (15 minutes at most), the server
  keeps, in the matchmaker's memory only: the token's hash (never the
  token), the creator's anonymous id for that visit, and the creator's
  languages. The creator's own connection holds the link itself, to show
  it to them, and forgets it with the invitation. Nothing is written
  anywhere; the log has only "invitation made", "invitation used" and
  "inviter went away" (no ids that outlive the call), and the token is
  filtered from request logs like the resume ticket. The status page counts invitation calls among
  calls started, and in no language pair (the joiner picks no language).
  ([`Matchmaker.invite/2`](../lib/randos/matchmaking/matchmaker.ex),
  [`invitations.md`](architecture/invitations.md).)
- **What it briefly remembers:** after a call, the server remembers for 90
  seconds that the two of you just talked (by the anonymous ids of that
  visit only), so "Next" finds someone new. A call that never connected
  isn't remembered.
- **What it can't do:** it relays the connection messages (offers,
  answers, candidates) between the two of you, but it never receives audio.

### The relay (coturn)

Its whole configuration is in
[`infra/coturn/cloud-init.yaml.tftpl`](../infra/coturn/cloud-init.yaml.tftpl),
applied by OpenTofu from this repository.

- **It can't tell callers apart.** Credentials are minted per call from a
  secret shared with the server (`use-auth-secret`, `static-auth-secret`).
  The username is only an expiry time
  ([`turn_username/0`](../lib/randos_web/ice_servers.ex)), the same for
  everyone who connected in the same second. There's no user database.
- **It logs errors only** (`log-min-level=error`): no line per session.
- **Addresses are scrubbed before anything is written.** coturn's error
  lines can include a caller's address (for example "Connection reset by
  peer <address>"), and coturn has no option to leave it out. So Docker
  sends its output to rsyslog on the droplet (`--log-driver syslog`), whose
  `mmanon` module zeroes every IPv4 and IPv6 address before writing
  `/var/log/coturn.log`; nothing goes to the system journal or the general
  syslog, and Docker keeps no local copy (`cache-disabled=true`). logrotate
  keeps 7 days. (A side effect: any long number is zeroed too, such as the
  expiry time in a credential's username.)
- **It keeps nothing else.** The container's only mount is its read-only
  config (`-v /etc/coturn:/etc/coturn:ro`); it's replaced, not upgraded,
  when the server is rebuilt. Its admin CLI is off (coturn's default
  since 4.18; nothing in the config turns it on).
- **A recovered call leaves an old allocation behind for a while.** When
  a network change breaks a call and ICE restarts (obligation 10 in
  [`participant_channel.md`](architecture/participant_channel.md)), the
  client allocates again from its new address; the old allocation can't
  be released from the dead one, so it simply expires on the relay (up to
  10 minutes), in memory like every allocation. Nothing new is kept.
- **It can't hear calls.** It forwards encrypted packets; the encryption
  keys are negotiated between the two clients.
- **It relays only to the public internet:** private, loopback, and
  cloud-metadata addresses are refused (`denied-peer-ip`), so it can't be
  used to reach anything behind it.

Until 2026-10-21 the relay's error log kept callers' addresses; that log
was deleted when the scrubbed one replaced it.

### Relay-only, enforced by the server

Clients are told to connect only through the relay (obligation 8 in
[`participant_channel.md`](architecture/participant_channel.md)). The
server doesn't rely on that:
[`Randos.Signaling.relay_only/2`](../lib/randos/signaling.ex) runs on
every relayed message and:

- drops every candidate that isn't a relay candidate (host, server
  reflexive, peer reflexive);
- blanks the "related address" a relay candidate can carry (`raddr`,
  `rport`), which would otherwise name the address behind the relay;
- in an offer or answer, does the same for its candidate lines, and
  blanks the addresses in its `c=`, `a=rtcp:` and `o=` lines.

Tests: the filter's unit tests
([`signaling_test.exs`](../test/randos/signaling_test.exs)), and a
browser test that runs two clients which ignore the policy on purpose
against a relay that never answers
([`relay_only_smoke.mjs`](../test/e2e/relay_only_smoke.mjs)): they must
not connect, which they would within a second if any direct address got
through. With the filter switched off, that test fails.

## The caveat a WebRTC expert will raise

The server carries the offers and answers that set up the encryption,
and those include the DTLS fingerprints that the two clients use to
authenticate each other. A malicious signaling server could swap them and
put itself in the middle of the call. randos doesn't: the relay-only
filter above is the only change the server makes to these messages, and a
test checks that fingerprints, ICE credentials and codecs stay byte for
byte as sent ("in SDP, changes only candidates and addresses ICE doesn't
use" in [`signaling_test.exs`](../test/randos/signaling_test.exs)). A
possible hardening for the future would be letting clients show the call's
fingerprint so two people could compare.

## Local voice masking

Browser and TUI voice choices start Off and stay in this session's memory only.
They are not added to cookies, local storage, the TUI settings file, participant
signaling or server call records. The selection freezes for a call. When enabled,
the TUI processes locally after echo cancellation and before Opus; the browser
uses a same-origin, locally built Worker/worklet containing the same DSP core.
Muted or unconnected input is excluded before the buffered DSP; closure purges
its history/queues and reopening discards pending capture/resampler history.
Processing failure stops the call instead of sending the unmodified voice.
Stop discards queued speech. This adds no server audio, audio upload, storage,
model download or external process. The tests write only generated synthetic
tones to temporary WAVs. See [`voice.rs`](../clients/tui/native/src/voice.rs),
[`call.rs`](../clients/tui/native/src/call.rs),
[`audio.rs`](../clients/tui/native/src/audio.rs) and the
[`bridge safety audit`](../voice-native/README.md).

Hear myself (TUI: p in the voice panel) explicitly opens a local microphone
audition through headphones. It records/uploads nothing, and stops on Stop,
exit or before call capture. Style/tone changes keep the microphone open while
replacing the processor; Off explicitly plays the original. Late microphone
grants are closed.
Masking is not a guarantee against recognizing a speaker. See the browser
[`owner`](../assets/js/randos/voice/masking.js),
[`session choices`](../assets/js/randos/voice/masking_choices.js) and
[`preview hook`](../assets/js/hooks/voice_settings.js).

## What you have to trust

You can read exactly how every part is configured, and see that the
checks pass. You can't verify from outside that the servers run this
code. What you don't have to trust is the encryption: the audio is
end-to-end encrypted whatever the servers do, and relay-only is enforced
by the server rather than left to each client.

Run your own instance ([self-hosting](self-hosting.md)) if you'd rather
trust only yourself.

## Local development voice lab

The development-only `/dev/voice-lab` can play bundled public-domain samples
or monitor the developer’s microphone locally through headphones. Microphone
access starts only on an explicit preview button press. The preview uses no
recorder or audio upload, and closes its tracks on Stop, tab exit, navigation,
setup failure, or device loss. Cancellation during a permission prompt also
closes any subsequently granted stream before connecting audio output.
See [`live.js`](../assets/js/voice_lab/live.js) and the explicit
[DSP preview](../assets/js/voice_lab/dsp/live.js) for capture and cleanup, and
[`lab.js`](../assets/js/voice_lab/lab.js) for the UI lifecycle. This page and
its bundle are development-only; none of this changes production call handling.

The optional Signalsmith/WORLD live experiment keeps bounded, in-flight PCM
only in browser memory: a small [AudioWorklet bridge](../assets/js/voice_lab/dsp/bridge_worklet.js)
passes transferable buffers directly to a [local Worker](../assets/js/voice_lab/dsp/worker.js).
Its compiled code is vendored and bundled from this repository; it fetches no
remote model or runtime script. The preview sends no microphone PCM to the server,
creates no recording/replay, and discards buffers on Stop/failure/navigation.
An overload fails visibly rather than playing an unintended original-voice path.
The original/modified switch is explicit. Tests alone enable bounded fixture
capture in the bridge, using generated inputs and muted fake microphones; the UI
never enables it. This remains a dev-only headset experiment, not a call feature.

The optional shorter-buffer experiment changes only local output prefill and
retains the same bounded queues and stop-on-failure behavior. Its eligibility
comes from generated public-fixture tests and source hashes. The gentler-pitch
choice changes pitch independently of resonance; zero pitch is processed output,
not an original-voice bypass. Neither adds audio persistence or network uploads.

The lab's Recovery test serves offline-generated derivatives of the four
public LibriVox excerpts, not microphone or call recordings. `just voice-recovery`
reads those bundled files and writes review WAVs under ignored
`tmp/voice-recovery/` plus a saved experiment report. Only WAV basenames in
that directory can be served by the dev-only recovery route
([`voice_lab_clips.ex`](../dev/randos_dev/voice_lab_clips.ex)); audio players
pause on case/view changes. The inverse receives the disguised public sample
and its known setting; the original is used only in the offline controls and
assessment ([`reconstruction.py`](../tools/voice-eval/randos_voice_eval/reconstruction.py)).

The Models tab similarly serves only offline derivatives of those public
excerpts. `just voice-model` downloads pinned pretrained weights from Hugging
Face and upstream code from GitHub, then performs inference locally; these
downloads expose the developer's network request, never any audio upload.
Generated WAVs stay in ignored `tmp/voice-model`, served by a separate dev-only
WAV-basename route. Neither model code nor weights enter production assets or
call handling. See [`probe.py`](../tools/voice-model/probe.py),
[`models.json`](../tools/voice-model/models.json) and
[`voice_lab_clips.ex`](../dev/randos_dev/voice_lab_clips.ex).

Prepared model/DSP choices in Listen & compare fetch only paired, immutable
WAV derivatives of those public clips. Selecting them does not download model
weights, run neural inference, or enable model processing of the microphone.
Their source/run/build metadata attaches to explicit local text reviews,
including the same contexts used in the research sections. See
[`prepared.js`](../assets/js/voice_lab/prepared.js) and
[`voice_lab_models.ex`](../dev/randos_dev/voice_lab_models.ex).

`just voice-browser` is an additional local-only public-clip experiment. It
prepares a fixed target embedding and native reference, then a throwaway
loopback site serves the pretrained TVTSyn model to muted Chrome for actual
browser inference. No audio leaves the machine. Its browser/server processes
end with the runner; code/weights remain outside production bundles. The
dev-only `/dev/voice-lab/browser-probe` route serves only generated
fixed report files (HTML, JS, CSS), embedding public comparison WAVs in the report;
it cannot serve model weights or arbitrary paths. See
[`run.mjs`](../tools/voice-browser/run.mjs),
[`prepare.py`](../tools/voice-browser/prepare.py), and
[`voice_lab_clips.ex`](../dev/randos_dev/voice_lab_clips.ex).

Listening feedback is optional, development-only research data. Answers are
drafted in this browser's localStorage, separate for each source/setting/build
or recovery/model run. Editing a review automatically sends ratings, notes and
experiment metadata to the local dev server after a short pause, periodically
while typing and when changing context. Untouched forms are not submitted.
**Save now** is an immediate shortcut. Failed requests keep the draft and retry;
unsent browser drafts resume on reload. The server appends validated text to ignored
`tools/voice-eval/results/listening-reviews.jsonl`; no audio is accepted or
saved by this endpoint. The assistant can read that file on a later task turn,
so the owner need not copy the answers into chat. A save does not itself start
an assistant turn. The route is inside the dev-only scope and browser CSRF
pipeline; see [`voice_lab_reviews.ex`](../dev/randos_dev/voice_lab_reviews.ex)
and [`review.js`](../assets/js/voice_lab/review.js). No account, tracking,
production feedback collection or database is added.
