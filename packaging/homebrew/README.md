# Homebrew (Phase 4.5)

Goal: `brew install wasichu/randos/randos`, then `randos` just works.

The formula installs the release archives that `.github/workflows/release.yml`
attaches to a GitHub release (macOS arm64 and Linux x86_64); nothing is
built on the user's machine. `randos.rb.template` is the source;
`render.sh` fills in a version and the archives' SHA-256 sums.

**Checked (2026-10-21):** the rendered formula installs through a local tap
pointed at a locally built archive, links `bin/randos`, and passes
`brew test` (`randos --version`, `randos --check`). Linux is checked only as
far as its archive: it builds and runs in CI, and its libraries are listed
in the formula; `brew install` on Linux is untested.

## What's left for the owner

These need you: a new repository, a release, and (optionally) a token.

1. **Pick a license** for randos and add a `LICENSE` file (the repo has
   none, so it isn't legally open source yet, whatever the About page
   says); then add `license "…"` to the template.
2. **Create the tap repository** `wasichu/homebrew-randos` on GitHub
   (public; Homebrew finds `wasichu/randos/…` there by that name).
3. **Release:** bump `version` in `clients/tui/mix.exs` if needed, commit,
   then `git tag v0.1.0 && git push origin v0.1.0`. CI builds both
   archives and creates the GitHub release.
4. **Render and publish the formula**, once the release exists:

   ```bash
   just homebrew-formula 0.1.0 > ~/src/homebrew-randos/Formula/randos.rb
   cd ~/src/homebrew-randos && git add Formula/randos.rb && git commit -m "randos 0.1.0" && git push
   ```

5. **Try it:** `brew install wasichu/randos/randos && brew test randos`.

Later, optional: automate step 4 from the release workflow. That needs a
token that can push to the tap repo, stored as a repository secret in
randos; the workflow step is then a few lines (render, commit, push).
