# Randos Architecture Summary After Step 5

## 1. High-level architecture

Randos is currently a Phoenix LiveView application with three deliberately separate layers:

- `Randos.Comms` is the Ash domain. It defines the domain resources and lifecycle rules.
- `Randos.Matchmaking.Matchmaker` owns the live matchmaking queue in one GenServer.
- `Randos.Calls.CallCoordinator` owns one ephemeral mock call process per matched pair.
- `RandosWeb.HomeLive` renders the user flow and relays user events to the process layer.
- `Randos.Signaling` defines the future WebRTC signaling message boundary.

The supervision tree in `Randos.Application` starts `Randos.PubSub`, a `DynamicSupervisor` named `Randos.Calls.CallSupervisor`, the singleton `Randos.Matchmaking.Matchmaker`, and then `RandosWeb.Endpoint`.

The core boundary is:

- Ash models domain facts and valid call state transitions.
- GenServers own realtime state, queue membership, timers, votes, and process monitoring.
- LiveView owns UI assigns and browser-facing events.
- PubSub carries notifications from processes to each participant LiveView.

There is still no WebRTC, microphone capture, audio transport, persistence, accounts, profiles, contacts, or media handling on the server.

## 2. Ash domain/resources

`Randos.Comms` is the Ash domain and registers:

- `Randos.Comms.AnonymousSession`
- `Randos.Comms.CallSession`

Both resources currently use `Ash.DataLayer.Ets`, so records are transient and disappear when the server restarts.

`Randos.Comms.AnonymousSession` models an anonymous visitor, not an account. Its attributes are:

- `id`
- `speaks_language`
- `listens_language`
- `auto_requeue`
- `accepted_adult_terms`
- `inserted_at`

Its actions are:

- `create_session`
- `update_language_preferences`
- `update_auto_requeue`
- `accept_adult_terms`

It validates `speaks_language` and `listens_language` against `Randos.ConversationLanguages.codes/0`. `matchmaking_ready?/1` returns true only when `accepted_adult_terms` is true.

`Randos.Comms.CallSession` models the domain lifecycle of a matched call. Important constants are:

- `default_call_duration_seconds/0` -> `600`
- `extension_duration_seconds/0` -> `600`
- `max_call_duration_seconds/0` -> `1_800`
- `max_extension_count/0` -> `2`
- `extension_response_timeout_seconds/0` -> `20`

Its main attributes are:

- participant language preferences: `speaks_language_a`, `listens_language_a`, `speaks_language_b`, `listens_language_b`
- lifecycle fields: `status`, `started_at`, `ended_at`, `ended_reason`
- duration fields: `default_call_duration_seconds`, `extension_duration_seconds`, `max_duration_seconds`, `max_extension_count`, `extension_count`

Valid `ended_reason` values are:

- `:canceled`
- `:completed`
- `:extension_declined`
- `:extension_timeout`
- `:hangup`
- `:disconnected`
- `:max_duration_reached`

## 3. Matchmaker process

`Randos.Matchmaking.Matchmaker` is a singleton GenServer. It owns only live queue membership. Its state struct has:

- `queues`: map keyed by `{speaks_language, listens_language}` with waiting participants
- `participants`: map keyed by participant LiveView pid
- `monitors`: monitor reference to participant pid
- `pubsub`: usually `Randos.PubSub`
- `call_supervisor`: usually `Randos.Calls.CallSupervisor`
- `call_options`
- `call_starter`: default `{Randos.Calls.CallCoordinator, :start_match}`

Participants are maps with:

- `id`
- `pid`
- `topic`
- `speaks_language`
- `listens_language`
- `accepted_adult_terms`

`join/2` rejects participants without `accepted_adult_terms`, rejects unsupported language codes, and rejects double queueing by checking `state.participants`.

The matching rule is:

```elixir
compatible_key = {participant.listens_language, participant.speaks_language}
```

If a waiting participant exists in that queue, the matchmaker removes them, starts a call process through `CallCoordinator.start_match/2`, adds `call_pid` to the match map, and broadcasts `{:randos_match, match}` to both participant topics.

The match map contains:

- `id`
- `participant_a`
- `participant_b`
- `offerer: :participant_a`
- `answerer: :participant_b`
- `call_pid`

The waiting participant is `participant_a` and the joining participant is `participant_b`, which gives deterministic role assignment and avoids future offer collisions.

## 4. Call coordinator process

`Randos.Calls.CallCoordinator` is a per-call GenServer started under `Randos.Calls.CallSupervisor`. It owns the ephemeral call lifecycle.

Its state struct includes:

- `match`
- `call_session`
- `status`
- `timeout_ref`
- `extension_timeout_ref`
- `call_deadline_unix_ms`
- `extension_deadline_unix_ms`
- `pubsub`
- `extension_votes`
- `monitors`
- `activation_delay_ms`
- `call_duration_ms`
- `extension_duration_ms`
- `extension_response_timeout_ms`

On init, it creates a `Randos.Comms.CallSession` with `create_connecting_call`, monitors both participant LiveView pids, and schedules `:activate_call`.

Important API functions:

- `start_match/2`
- `hang_up/2`
- `vote_extension/3`
- `relay_signal/4`
- `force_time_up/1` for tests and mock UI

Important internal events:

- `:activate_call`
- `:call_time_limit_reached`
- `:extension_response_timeout`
- `{:DOWN, ref, :process, pid, reason}`

When the call activates, it marks the Ash resource active, schedules the segment timeout, sets `call_deadline_unix_ms`, and broadcasts `{:mock_call_active, public_call_state}`.

When a segment expires, it marks the Ash resource `extension_pending`, schedules the response timeout, sets `extension_deadline_unix_ms`, clears extension votes, and broadcasts `{:mock_call_extension_pending, public_call_state}`.

When the call ends, it updates the Ash resource through `end_call`, broadcasts `{:mock_call_ended, public_call_state}`, demonitors participants, and stops.

## 5. LiveView state and UI flow

`RandosWeb.HomeLive` is currently the main UI. It uses these UI states:

- `:idle`
- `:looking`
- `:connecting`
- `:in_call`
- `:extension_pending`

`Randos.ConversationFlow` defines the explicit UI transition table, although process-driven events can assign direct states when a match or call update arrives.

Important LiveView assigns include:

- `:ui_state`
- `:preferences`
- `:form`
- `:participant_id`
- `:match_topic`
- `:matchmaking_error`
- `:match`
- `:match_role`
- `:webrtc_role`
- `:call_pid`
- `:call_status`
- `:call_ended_reason`
- `:call_deadline_unix_ms`
- `:extension_deadline_unix_ms`
- `:extension_count`
- `:stop_after_call?`

On mount, the LiveView generates an anonymous participant id and a PubSub topic:

```elixir
"matchmaking:participant:#{participant_id}"
```

When connected, it subscribes to that topic.

The main browser events are:

- `"find"`: normalize preferences and call `Matchmaker.join/1`
- `"transition"`: local UI transitions and explicit queue leave
- `"toggle_stop_after_call"`: toggles the auto-requeue behavior
- `"hang_up"`: calls `CallCoordinator.hang_up/2`
- `"mock_time_up"`: calls `CallCoordinator.force_time_up/1`
- `"extension_vote"`: calls `CallCoordinator.vote_extension/3`
- `"signal"`: the future browser WebRTC signaling event boundary

The LiveView handles process messages:

- `{:randos_match, match}`
- `{:mock_call_active, call}`
- `{:mock_call_extension_pending, call}`
- `{:mock_call_extended, call}`
- `{:mock_call_ended, call}`
- `{:signaling, message}`

`{:signaling, message}` is pushed to the browser as `"randos:signal"`.

## 6. Timer and deadline handling

The call coordinator owns all authoritative timers and deadlines.

Active call segments are scheduled in `schedule_call_timeout/2`, which stores:

```elixir
call_deadline_unix_ms = System.system_time(:millisecond) + duration_ms
```

The server sends that deadline to both LiveViews in `public_call_state/1`. The browser renders the countdown locally through the `CallCountdown` hook in `assets/js/app.js`.

Extension decision windows are scheduled when the coordinator enters `extension_pending`. It stores:

```elixir
extension_deadline_unix_ms =
  System.system_time(:millisecond) + state.extension_response_timeout_ms
```

The UI shows:

- active call countdown only during `:in_call`
- extension decision countdown only during `:extension_pending`
- no countdown during `:idle`, `:looking`, `:connecting`, or after call end

The browser never enforces duration. It only renders countdowns from server-provided deadlines and cleans intervals up when LiveView removes the timer DOM nodes.

## 7. Mutual extension flow

When `:call_time_limit_reached` fires:

1. `CallCoordinator` marks the Ash `CallSession` as `:extension_pending`.
2. It starts `extension_timeout_ref`.
3. It sets `extension_deadline_unix_ms`.
4. It broadcasts `{:mock_call_extension_pending, call}`.
5. The LiveViews show the extension prompt and decision timer.

Participants send `"extension_vote"` from the UI. The LiveView converts:

- `"continue"` -> `:continue`
- `"end"` -> `:end`

`CallCoordinator.vote_extension/3` stores votes in `extension_votes`, keyed by participant id.

If either participant votes `:end`, the coordinator ends the call with `:extension_declined`.

If both participants vote `:continue`, `extend_call/1` updates the Ash resource with `extend_call`, increments `extension_count`, returns to `:active`, schedules a new segment timeout, sets a new `call_deadline_unix_ms`, and broadcasts `{:mock_call_extended, call}`.

If `:extension_response_timeout` fires first, the coordinator ends the call with `:extension_timeout`.

`CallSession.ensure_extension_available/2` prevents extension beyond `max_extension_count`.

## 8. Important message/event types

Process-to-LiveView PubSub messages:

- `{:randos_match, match}`
- `{:mock_call_active, call}`
- `{:mock_call_extension_pending, call}`
- `{:mock_call_extended, call}`
- `{:mock_call_ended, call}`
- `{:signaling, message}`

Client-to-LiveView events:

- `"find"`
- `"transition"`
- `"toggle_stop_after_call"`
- `"hang_up"`
- `"mock_time_up"`
- `"extension_vote"`
- `"signal"`

`Randos.Signaling` supports these future signaling types:

- `:offer`
- `:answer`
- `:ice_candidate`
- `:hangup`
- `:peer_disconnected`
- `:connection_failed`
- `:connection_established`
- `:time_limit_reached`
- `:extension_requested`
- `:extension_accepted`
- `:extension_declined`
- `:extension_confirmed`
- `:extension_timeout`

Signaling messages are maps with:

- `call_id`
- `type`
- `from_participant_id`
- `to_participant_id`
- `payload`
- `sent_at_unix_ms`

The LiveView `"signal"` event special-cases `extension_accepted` and `extension_declined` so the coordinator remains the owner of extension state. Other supported signaling types are relayed through `CallCoordinator.relay_signal/4`.

## 9. What is intentionally not implemented yet

The code still intentionally avoids:

- WebRTC `RTCPeerConnection`
- SDP offer or answer generation in the browser
- ICE gathering or candidate exchange from real browser APIs
- `getUserMedia`
- microphone permission prompts
- audio playback
- waveform visualization from real audio
- TURN or dynamic ICE configuration
- Membrane, SFU, media server, or server-side audio access
- recording
- admin listening or eavesdropping
- accounts, usernames, profiles, contacts, chat, followers, feeds, or durable social graph
- Postgres or durable persistence

Phoenix is currently prepared to be matchmaking coordinator, call lifecycle coordinator, and signaling relay only.

## 10. Potential weak spots or cleanup opportunities

`RandosWeb.HomeLive` is carrying a lot of UI and event logic. The current code is still manageable, but future WebRTC JavaScript and signaling UI may justify extracting helper modules or components.

`auto_requeue` is represented in the Ash `AnonymousSession` resource, but the current LiveView uses `stop_after_call?` directly and does not persist or hydrate an `AnonymousSession` record for the browser session. That keeps the current flow simple, but the naming should be reconciled later.

`CallCoordinator.force_time_up/1` is useful for tests and mock UI, but it should stay clearly outside real production timing once browser WebRTC exists.

ETS-backed Ash resources are transient and suitable for this stage. If later operational persistence is needed, it should be introduced carefully for abuse prevention, rate limiting, aggregate metrics, TURN usage stats, or language demand stats, not for profiles or social graph state.

The matchmaker currently starts the call process synchronously during `join_queue/2` and pattern matches on `{:ok, call_pid}`. A future hardening pass could return a clean error if call startup fails.

The current process model assumes each participant is represented by one LiveView pid. That is right for the current no-account browser-session model, but reconnect semantics will need careful design when real WebRTC and browser refreshes are introduced.

The signaling boundary is intentionally minimal. It defines message shape and relay behavior, but does not yet validate SDP, candidate payload shape, ordering, replay, or call membership beyond participant id lookup.

The countdown hook is local and simple. It renders from server-provided deadlines and cleans up intervals, but browser clock skew can affect display. Enforcement remains server-side, which is the important invariant.
