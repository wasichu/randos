# Randos Step 2: Ash Domain Structure Without Persistence

Add Ash domain structure for Randos.

Ash should organize the domain, but should not drive realtime orchestration.

Important principle:

Ash defines the domain.
Processes run the realtime system.
Browsers will eventually carry audio.

Do not add Postgres or AshPostgres yet.

The app should run without durable persistence for now.

If the server restarts:

- queues disappear
- calls disappear
- anonymous sessions disappear

This is acceptable.

## Dependencies

Use:

- ash
- ash_phoenix
- ash_state_machine

Do not add:

- ash_postgres
- ecto persistence
- background job systems

## Domain

Create:

```elixir
Randos.Comms
```

## Resources

Create initial Ash resources using an in-memory or lightweight approach.

### AnonymousSession

Represents an anonymous visitor.

Fields:

- id
- speaks_language
- listens_language
- auto_requeue
- accepted_adult_terms
- inserted_at

Actions:

- create_session
- update_language_preferences
- update_auto_requeue
- accept_adult_terms

Validations:

- speaks_language must exist in supported language list
- listens_language must exist in supported language list
- accepted_adult_terms must be true before entering matchmaking

Important:

This represents an anonymous app session, not a user account.

Do not add:

- accounts
- usernames
- profiles
- identities
- contacts

## CallSession

Represents the domain concept of a matched call lifecycle.

Even though it is not persisted yet, model it clearly.

Use `ash_state_machine` for lifecycle management.

The state machine should validate all allowed transitions.

### Fields

- id
- status
- speaks_language_a
- listens_language_a
- speaks_language_b
- listens_language_b
- started_at
- ended_at
- ended_reason
- max_duration_seconds
- extension_count

### Status Field

Use:

```elixir
:status
```

### Statuses

- connecting
- active
- extension_pending
- ended

### Allowed Transitions

- connecting -> active
- connecting -> ended
- active -> extension_pending
- active -> ended
- extension_pending -> active
- extension_pending -> ended

### Invalid Transitions

- ended -> active
- ended -> extension_pending
- extension_pending -> connecting

Do not manually mutate the status field.

Use Ash state machine transition actions.

### Actions

Implement actions using Ash state machine transitions:

- create_connecting_call
- mark_active
- mark_extension_pending
- extend_call
- end_call

The call coordination process should invoke these actions.

Do not let browser clients directly mutate state.

## Call Duration

Initial call duration:

```elixir
@default_max_call_duration_seconds 300
```

Extension duration:

```elixir
@extension_duration_seconds 300
```

Extension response grace period:

```elixir
@extension_response_timeout_seconds 20
```

The timeout should eventually be enforced by the call coordination process, not by the browser.

## Important Architectural Boundary

Use Ash state machines for:

- domain lifecycle validation
- valid call state transitions

Do not use Ash state machines for:

- live queue membership
- active socket presence
- ICE state
- SDP signaling
- WebRTC negotiation
- timeout ownership
- extension vote collection
- waveform state
- audio transport

Those belong to GenServers, PubSub, and browser-side WebRTC logic.

## Future Persistence Note

Do not implement persistence now.

If persistence is added later, it should be for operational facts only:

- abuse prevention
- temporary bans
- rate limiting
- aggregated metrics
- TURN usage stats
- language demand stats

Do not design toward:

- accounts
- profiles
- saved contacts
- message history
- permanent social graph

## Important Constraints

Do not use Ash resources for:

- live queues
- active socket storage
- ICE candidates
- WebRTC offers
- WebRTC answers
- audio streams
- waveform data

Those belong to process state and browser code later.

## Done Criteria

By the end of this step:

- Ash domain exists
- AnonymousSession resource exists
- CallSession resource exists
- ash_state_machine is integrated
- valid call lifecycle transitions are enforced
- invalid transitions fail cleanly
- no persistence layer exists yet
- no matchmaking exists yet
- no WebRTC exists yet
