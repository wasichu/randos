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
| **The web server** (Phoenix, on Fly.io) | Your IP address while you're connected (any website does); the languages you chose; the connection messages for your call, never the audio | Events such as "call started" and "call ended", tagged with random call and match IDs. No IP addresses, no languages, no identifiers that outlive the call. | Our host, Fly.io, keeps app logs for a limited time; we don't send them anywhere else |
| **The relay** (coturn, a DigitalOcean droplet) | Both IP addresses of each relayed call, its timing, and its encrypted packets, which it can't decrypt | Errors only, with every IP address zeroed before it's written | 7 days |
| **Your browser** | Your choice of interface language, if you pick one | A `randos_locale` cookie holding only the language code (e.g. `es`), so the next visit is in your language; it identifies no one and goes nowhere else. Phoenix's session cookie (CSRF protection) also carries the language for the page. | A year, or until you clear it |
| **Your terminal (the TUI)** | Nothing new | A settings file on your own computer (`~/.config/randos/config.json`, or `~/Library/Application Support/randos/config.json` on macOS): your languages, that you confirmed the 18+ notice, and the mic and speaker names. It never leaves your computer. | Until you delete it |
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
  when the server is rebuilt. Its admin CLI is off (`no-cli`).
- **It can't hear calls.** It forwards encrypted packets; the encryption
  keys are negotiated between the two clients.
- **It relays only to the public internet:** private, loopback, and
  cloud-metadata addresses are refused (`denied-peer-ip`), so it can't be
  used to reach anything behind it.

**What we found, and fixed (2026-10-21).** Reading the live relay's log
showed that coturn's error lines included callers' addresses: in two days,
42 distinct public addresses besides the relay's own (most of them, by
their pattern, internet scanners probing the TLS port; some from real
calls), kept in two rotated 1 MB files that would have held them for
months. That log was deleted the same day, when the relay switched to the
scrubbed log above; we checked the switch with a real error from a test,
written as `0.0.0.0`. The same check found that the relay keeps no other
files (no database), and that its certificate renewal works.

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

## What you have to trust

You can read exactly how every part is configured, and see that the
checks pass. You can't verify from outside that the servers run this
code. What you don't have to trust is the encryption: the audio is
end-to-end encrypted whatever the servers do, and relay-only is enforced
by the server rather than left to each client.

Run your own instance ([self-hosting](self-hosting.md)) if you'd rather
trust only yourself.
