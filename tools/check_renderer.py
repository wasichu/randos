"""Offline guard for the narrowly patched terminal renderer and native lock."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "vendor/ex_ratatui"


def main():
    manifest = json.loads((ROOT / "vendor/ex_ratatui.upstream.json").read_text())
    patched = set(manifest["patched_files"])
    assert patched <= manifest["files"].keys()
    for name, digest in manifest["files"].items():
        if name not in patched:
            assert hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() == digest, name
    lock = SOURCE / "native/ex_ratatui/Cargo.lock"
    assert hashlib.sha256(lock.read_bytes()).hexdigest() == manifest["native_lock_sha256"]
    print("Pinned renderer source, patch inventory and native lock passed")


if __name__ == "__main__":
    main()
