#!/usr/bin/env bash
# Renders the Homebrew formula for VERSION from the template, with the
# archives' SHA-256 sums from the GitHub release v$VERSION (or, with
# --local, from dist/, for checking the formula before a release exists).
#
#   packaging/homebrew/render.sh 0.1.0 > Formula/randos.rb
#   packaging/homebrew/render.sh 0.1.0 --local
set -euo pipefail

version="${1:?usage: render.sh VERSION [--local]}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

sum() {
  local target="$1"
  local file="randos-${version}-${target}.tar.gz.sha256"
  if [ "${2:-}" = "--local" ]; then
    if [ -f "$root/dist/$file" ]; then cut -d' ' -f1 "$root/dist/$file"; else echo "MISSING"; fi
  else
    gh release download "v${version}" --repo wasichu/randos --pattern "$file" --output - | cut -d' ' -f1
  fi
}

sed -e "s/@VERSION@/${version}/g" \
    -e "s/@SHA256_MACOS_ARM64@/$(sum macos-arm64 "${2:-}")/" \
    -e "s/@SHA256_LINUX_X86_64@/$(sum linux-x86_64 "${2:-}")/" \
    "$here/randos.rb.template"
