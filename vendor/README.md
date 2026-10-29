# Vendored dependencies

## Signalsmith headers (`signalsmith/`)

Unmodified MIT headers/licenses for the native voice bridge, not a crates.io
patch. Stretch commit `88061fd4eda56a2353c5d65c74aa3f4ccf76f9da` from
https://github.com/Signalsmith-Audio/signalsmith-stretch; Linear commit
`7bb1c8f36794d6980080ce817c91f8da8fe56a66` from
https://github.com/Signalsmith-Audio/linear. These match the browser's pinned
WASM build. `signalsmith/manifest.json` records SHA-256 for every copied file;
`tools/voice-dsp/browser/check_vendor.py` verifies it and the shared pins.
The native bridge README documents build, license and FFI safety. Review upstream
diffs and rerun native/browser parity before changing either version.

## Patched crates

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


## `ex_ratatui` 0.17.1 (terminal renderer)

Pinned Hex package, MIT (`ex_ratatui/LICENSE`); provenance and original file
hashes are in `ex_ratatui.upstream.json`. No upstream message/issue has been sent.
The upstream package's `erl_crash.dump` is intentionally omitted; its hash and
exclusion reason are recorded separately from the vendored source inventory.
The renderer patch adds local transition `full_redraw?: true`: keep a request
pending across render coalescing, then call Ratatui Terminal::clear before the
next draw. That erases the physical terminal and resets the retained frame
together. Plain logical buffer cleanup passes TestBackend but leaves Hindi/Bangla
suffixes on actual terminal emulators after dismissing a multilingual popup.
Raw ANSI erasure alone loses unchanged UI because Ratatui still thinks it is drawn.

Rustler is now an explicit build-only Mix dependency in the site dev/test and
TUI projects. This copy always compiles its NIF from source; upstream prebuilt
binaries lack the added function. Runtime dependencies and endonyms are retained;
the native Cargo.lock is pinned. Build output is ignored. `tools/check_renderer.py`
guards unmodified upstream files and the native lock. The archive includes MIT
notices. Review this patch separately from upstream; remove it when the upstream
runtime supports atomic clear/invalidate. Linux and macOS release builds must
qualify this source-built NIF before release.

Native manifest metadata explicitly identifies the package MIT license and pins
the two already-vendored 3D path packages at 0.1.0 for the existing cargo-deny
policy. Their code/features are unchanged.

The upstream native lock was retained except pulldown-cmark 0.13.3 → 0.13.5,
fixing RUSTSEC-2026-0414 found by the new audit. Bincode 1.3 and yaml-rust are
upstream transitive unmaintained notices, not vulnerability waivers. Renderer
checks retain them at warning level; actual vulnerabilities and licensing/source
violations fail precommit. Track their upstream replacements; no vulnerability waiver was added.
