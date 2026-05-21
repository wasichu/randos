## Maximum Call Duration

Randos calls are intentionally bounded.

Initial call duration:

```elixir
@default_call_duration_seconds 300
```

Extension duration:

```elixir
@extension_duration_seconds 300
```

Maximum total call duration:

```elixir
@max_call_duration_seconds 1_800
```

Maximum extension count:

```elixir
@max_extension_count 5
```

This means:

```text
initial 5 minutes
plus up to 5 mutual extensions
equals 30 minutes maximum
```

When a call reaches the maximum duration, it should end with:

```elixir
:max_duration_reached
```

Do not allow indefinite calls.

The call coordinator will enforce this later. For now, model the fields and constants clearly.
