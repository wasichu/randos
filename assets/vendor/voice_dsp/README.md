# Dev-only DSP experiment binaries

WORLD (BSD-3-Clause) and Signalsmith Stretch/Linear (MIT), compiled from the
exact revisions in `tools/voice-dsp/browser/sources.json` with Emscripten 4.0.22.
The first-party C++ wrappers are `world.cpp` and `spectral.cpp` in that folder.
Upstream and Emscripten runtime license texts accompany these generated modules. No neural weights,
Rust FFI dependency or production call processor is added.

Rebuild with `python3 tools/voice-dsp/browser/build.py --vendor` (downloads the
pinned local build SDK/sources on first setup). `check_vendor.py`, in precommit,
checks the committed asset, source-pin and wrapper hashes. Changes to these
binaries require review and rerunning the native/browser and live-stream probes.

The dev-only esbuild `voice_lab` entry bundles these loaders and their imported
WASM bytes into a same-origin module Worker. Factories receive `wasmBinary`
explicitly; no third-party CDN or runtime source/model download is used. The
normal application and `assets.deploy` do not import/build the voice-lab entries.
