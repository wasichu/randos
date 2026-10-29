#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ ! -d tmp/tvtsyn ]]; then
  git clone https://github.com/PSI-TAMU/TVTSyn.git tmp/tvtsyn
  git -C tmp/tvtsyn checkout --detach 9aa67c0272620caaf43170fe98ec48438e1624e0
fi
if [[ ! -x tmp/tvtsyn/.venv/bin/python ]]; then
  uv venv --python 3.11.17 tmp/tvtsyn/.venv
fi
uv pip sync --python tmp/tvtsyn/.venv/bin/python tools/voice-browser/requirements.lock
uv pip install --python tmp/tvtsyn/.venv/bin/python --no-deps ./tmp/tvtsyn
npm ci --prefix tools/voice-browser --ignore-scripts
tmp/tvtsyn/.venv/bin/python tools/voice-browser/prepare.py
probe_status=0
node tools/voice-browser/run.mjs || probe_status=$?
tmp/tvtsyn/.venv/bin/python tools/voice-browser/report.py
tools/voice-browser/node_modules/.bin/esbuild tools/voice-browser/review.js --bundle --format=iife --outfile=tmp/voice-browser/review.js
cp tools/voice-browser/report.css tmp/voice-browser/report.css
exit "$probe_status"
