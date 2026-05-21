# Explain the Current Randos Architecture

Please inspect the current codebase and explain the main architecture you implemented.

Put your output in a markdown file in `docs/architecture/take_five_summary.md`.

Focus on:

- major modules
- main data structures
- process ownership
- LiveView state
- Ash resources
- Ash state machine usage
- matchmaking flow
- call coordination flow
- timer/deadline handling
- extension handling
- PubSub/message flow
- where transient state lives
- where domain state lives

Please organize the explanation into these sections:

1. High-level architecture
2. Ash domain/resources
3. Matchmaker process
4. Call coordinator process
5. LiveView state and UI flow
6. Timer and deadline handling
7. Mutual extension flow
8. Important message/event types
9. What is intentionally not implemented yet
10. Potential weak spots or cleanup opportunities

Be specific. Reference actual module names, structs, maps, fields, and functions from the code.

Do not rewrite code yet.

Do not add new features.

This is an architecture explanation and review only.
