# Randos Step 3: In-Memory Matchmaking Only

Implement anonymous matchmaking without WebRTC.

Goal:

Two browser sessions can enter the queue and get matched based on complementary language preferences.

This step should focus only on matchmaking.

Do not implement real audio yet.

Do not implement full call lifecycle yet beyond notifying matched users.

## Matching Rule

Each user has:

```elixir
%{
  speaks_language: "en",
  listens_language: "es"
}
```

A compatible match is:

```elixir
user_a.speaks_language == user_b.listens_language and
user_b.speaks_language == user_a.listens_language
```

Example:

```text
A speaks English, wants Spanish
B speaks Spanish, wants English
```

This is a match.

## Adult Terms Requirement

Only allow users to enter the queue if they have accepted the 18+ acknowledgment.

If accepted_adult_terms is false, remain in idle state and show a validation message.

Do not add invasive verification.

## Queue Structure

Use an in-memory Matchmaker GenServer.

Do not persist queues.

Do not use Ash resources as the queue implementation.

Queue users by tuple:

```elixir
{speaks_language, listens_language}
```

When a user joins:

```elixir
own_key = {speaks_language, listens_language}
compatible_key = {listens_language, speaks_language}
```

First look for someone in the compatible queue.

If found:

- remove compatible user from queue
- emit a match event for both users
- transition both users to connecting
- assign deterministic participant roles

If not found:

- add user to own queue
- remain in looking state

## Role Assignment

When a match is made, assign:

- participant_a
- participant_b
- offerer
- answerer

No WebRTC should be implemented in this step.

## Required Behavior

Implement:

- join queue
- leave queue
- match compatible users
- prevent double queueing
- cleanup on disconnect
- notify both LiveViews when matched
- assign offerer and answerer roles

Use:

- GenServer
- PubSub
- process monitoring where appropriate

## Tests

Add tests for:

- compatible matching
- incompatible users not matching
- users cannot queue without accepting 18+ acknowledgment
- double queue prevention
- leaving queue
- disconnect cleanup
- deterministic role assignment
- race conditions during matching
