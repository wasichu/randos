#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ ! -x tmp/voice-dsp/.venv/bin/python ]]; then
  uv venv --python 3.11.17 tmp/voice-dsp/.venv
fi
uv pip sync --python tmp/voice-dsp/.venv/bin/python --require-hashes tools/voice-dsp/requirements.lock
tmp/voice-dsp/.venv/bin/python tools/voice-dsp/probe.py
