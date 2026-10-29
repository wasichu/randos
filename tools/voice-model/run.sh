#!/usr/bin/env bash
# Separate Python environment: never re-sync the benchmark/translation venvs.
set -euo pipefail
cd "$(dirname "$0")/../.."
upstream=51383efd921027683c89e5348211d93ff12ac2a8
if [[ ! -d tmp/seed-vc ]]; then
  git clone https://github.com/Plachtaa/seed-vc.git tmp/seed-vc
  git -C tmp/seed-vc checkout --detach "$upstream"
fi
if [[ ! -x tmp/seed-vc/.venv/bin/python ]]; then
  uv venv --python 3.11.17 tmp/seed-vc/.venv
fi
uv pip sync --python tmp/seed-vc/.venv/bin/python tools/voice-model/requirements.lock
exec tmp/seed-vc/.venv/bin/python -u tools/voice-model/probe.py
