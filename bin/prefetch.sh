#!/bin/sh
# Fetches with curl what the build would otherwise download from GitHub
# releases with Erlang's :httpc, which refuses their responses (over 10 KB
# of headers since 2026-10-24: header_too_long). Each file goes where its
# installer looks first, so the installer finds it and skips the download;
# the NIFs are still checked against their packages' checksums when used.
#
#   bin/prefetch.sh nifs       ex_ratatui (server and TUI deps) and lazy_html
#   bin/prefetch.sh tailwind   the Tailwind binary for config/config.exs's version
#
# Run from the repo root after `mix deps.get` (nifs) and before anything
# compiles; `just prefetch` does both. The Dockerfile runs `tailwind`.
set -eu

os="$(uname -s)"
arch="$(uname -m)"

# curl into a temporary file, then move it: an interrupted download never
# looks finished.
fetch() {
  [ -s "$2" ] && return 0
  mkdir -p "$(dirname "$2")"
  curl -fsSL -o "$2.part" "$1"
  mv "$2.part" "$2"
}

user_cache() {
  # Erlang's own user_cache directory, as the installers ask for it
  # (MIX_XDG makes them use the Linux layout everywhere).
  if [ -n "${MIX_XDG:-}" ]; then opts="#{os => linux}"; else opts="#{}"; fi
  erl -noshell -eval "io:format(\"~s\", [filename:basedir(user_cache, \"$1\", $opts)]), halt()."
}

# Every file a package's checksum file lists for this target.
listed() {
  sed -n "s/^ *\"\($1\)\".*/\1/p" "$2"
}

nifs() {
  case "$os" in
    Darwin) rust_target="$(echo "$arch" | sed 's/arm64/aarch64/')-apple-darwin"; c_target="$rust_target" ;;
    Linux) rust_target="$arch-unknown-linux-gnu"; c_target="$arch-linux-gnu" ;;
    *) echo "prefetch: unknown OS $os" >&2; exit 1 ;;
  esac
  found=0

  rust_cache="${RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH:-$(user_cache rustler_precompiled/precompiled_nifs)}"
  for dep in deps/ex_ratatui clients/tui/deps/ex_ratatui; do
    [ -f "$dep/mix.exs" ] || continue
    found=1
    version="$(sed -n 's/^ *@version "\(.*\)"$/\1/p' "$dep/mix.exs" | head -1)"
    files="$(listed "libex_ratatui-v$version-nif-[0-9.]*-$rust_target\.so\.tar\.gz" "$dep"/checksum-*.exs)"
    [ -n "$files" ] || { echo "prefetch: no ex_ratatui $version NIF for $rust_target" >&2; exit 1; }
    for file in $files; do
      fetch "https://github.com/mcass19/ex_ratatui/releases/download/v$version/$file" "$rust_cache/$file"
    done
  done

  make_cache="${ELIXIR_MAKE_CACHE_DIR:-$(user_cache elixir_make)}"
  for dep in deps/lazy_html; do
    [ -f "$dep/mix.exs" ] || continue
    found=1
    version="$(sed -n 's/^ *@version "\(.*\)"$/\1/p' "$dep/mix.exs" | head -1)"
    for file in $(listed "lazy_html-nif-[0-9.]*-$c_target-$version\.tar\.gz" "$dep/checksum.exs"); do
      fetch "https://github.com/dashbitco/lazy_html/releases/download/v$version/$file" "$make_cache/$file"
    done
  done

  [ "$found" = 1 ] || { echo "prefetch: no deps fetched yet (mix deps.get first)" >&2; exit 1; }
}

tailwind() {
  version="$(awk '/^config :tailwind,/ {on=1} on && /version:/ {gsub(/[^0-9.]/, "", $2); print $2; exit}' config/config.exs)"
  [ -n "$version" ] || { echo "prefetch: no Tailwind version in config/config.exs" >&2; exit 1; }
  case "$os-$arch" in
    Darwin-arm64) target=macos-arm64 ;;
    Darwin-x86_64) target=macos-x64 ;;
    Linux-x86_64) target=linux-x64 ;;
    Linux-aarch64) target=linux-arm64 ;;
    *) echo "prefetch: no Tailwind binary for $os-$arch" >&2; exit 1 ;;
  esac
  fetch "https://github.com/tailwindlabs/tailwindcss/releases/download/v$version/tailwindcss-$target" "_build/tailwind-$target-$version"
  chmod +x "_build/tailwind-$target-$version"
}

[ "$#" -gt 0 ] || { echo "usage: bin/prefetch.sh nifs|tailwind ..." >&2; exit 2; }
for what in "$@"; do
  case "$what" in
    nifs) nifs ;;
    tailwind) tailwind ;;
    *) echo "prefetch: unknown $what" >&2; exit 2 ;;
  esac
done
