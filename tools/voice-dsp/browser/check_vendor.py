"""Offline integrity guard; rebuilding the pinned SDK is an explicit research step."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
VENDOR = ROOT / "assets/vendor/voice_dsp"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest = json.loads((VENDOR / "manifest.json").read_text())
    assert digest(HERE / "sources.json") == manifest["pins_sha256"], (
        "DSP source pins changed: rebuild and review vendor outputs"
    )
    for name, expected in manifest["wrappers"].items():
        assert digest(HERE / name) == expected, (
            "DSP wrapper changed: rebuild with build.py --vendor"
        )
    for name, expected in manifest["files"].items():
        assert digest(VENDOR / name) == expected, f"DSP vendor bytes changed: {name}"
    native = ROOT / "vendor/signalsmith"
    pinned = json.loads((native / "manifest.json").read_text())
    sources = json.loads((HERE / "sources.json").read_text())
    for key in ["stretch", "linear"]:
        assert pinned[key] == sources[key], "Native/browser Signalsmith pins differ"
    expected_files = {
        "stretch/signalsmith-stretch.h",
        "stretch/LICENSE.txt",
        "signalsmith-linear/approx.h",
        "signalsmith-linear/fft.h",
        "signalsmith-linear/linear.h",
        "signalsmith-linear/stft.h",
        "signalsmith-linear/LICENSE.txt",
    }
    assert set(pinned["files"]) == expected_files, "Native source inventory changed"
    for name, expected in pinned["files"].items():
        assert digest(native / name) == expected, (
            f"Native Signalsmith bytes changed: {name}"
        )
    worker = (ROOT / "assets/js/randos/voice/masking_worker.js").read_text()
    notices = worker.split("*/", 1)[0]
    assert notices.startswith("/*!"), "Production worker must preserve upstream notices"
    for license_file in [native / "stretch/LICENSE.txt", native / "signalsmith-linear/LICENSE.txt"]:
        assert license_file.read_text().strip() in notices, "Production worker lacks upstream license"
    assert "Emscripten" in notices, "Production worker lacks runtime license notice"
    print("Pinned DSP assets, native headers and production notices passed")


if __name__ == "__main__":
    main()
