# Vendored crates

Patched copies of dependencies, used in place of the published ones through
`[patch.crates-io]` in the root `Cargo.toml`. Each is the published crate
plus the smallest change we need, marked `// randos:` in the source. Remove
a copy (and its patch entry) once upstream has the change.

## `is` 0.11.1 (str0m's ICE agent)

- **Source:** crates.io `is` 0.11.1, from the str0m project
  (https://github.com/algesten/str0m), MIT OR Apache-2.0; we use it under
  MIT (`is/LICENSE-MIT.txt`, from str0m). No C, no new dependencies.
- **The change:** `RECENT_BINDING_REQUEST` in `src/pair.rs` is 4 s instead
  of 15 s. A candidate pair counts as still possible for that long after
  the peer's last binding request, whatever our own unanswered requests
  say (a guard for asymmetric peers), so it set a ~15 s floor on noticing
  a dead path. With it at 4 s, and the helper's STUN timing tightened
  (`set_max_stun_rto` 750 ms, `set_max_stun_retransmits` 5, in
  `clients/tui/native/src/call.rs`), the helper reports `disconnected`
  about 4 s after the path dies, like browsers. Measured, and guarded by
  `a_dead_path_is_noticed_within_seconds` (`clients/tui/native/tests/restart.rs`).
- **Upstream:** making the window configurable (default 15 s) is the proper
  fix; not filed yet (the owner's call).
