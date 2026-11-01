"""Current helper's SYNTHETIC/null-device loopback estimates, not acoustic latency."""

import argparse
import hashlib
import json
import os
import selectors
import struct
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def collect(style):
    binary = ROOT / "target/release/randos_media"
    with subprocess.Popen(
        [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ) as child:
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ)
        records = []
        buffer = bytearray()
        deadline = time.monotonic() + 12
        request = {"id": 1, "cmd": "loopback_start", "in": "sine", "out": "null"}
        if style is not None:
            request["masking"] = style
        body = json.dumps(request).encode()
        child.stdin.write(struct.pack(">I", len(body)) + body)
        child.stdin.flush()
        try:
            while len(records) < 3 and time.monotonic() < deadline:
                for key, _ in selector.select(timeout=1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        raise ValueError("Helper stopped before statistics")
                    buffer.extend(chunk)
                    while len(buffer) >= 4:
                        n = struct.unpack(">I", buffer[:4])[0]
                        if n > 1024 * 1024:
                            raise ValueError("Unbounded helper frame")
                        if len(buffer) < 4 + n:
                            break
                        item = json.loads(buffer[4 : 4 + n])
                        del buffer[: 4 + n]
                        if "error" in item:
                            raise ValueError(str(item["error"]))
                        if item.get("event") == "loopback_stats":
                            records.append(item)
            if len(records) < 3:
                raise ValueError("Synthetic helper statistics deadline")
            return records
        finally:
            selector.close()
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--after", action="store_true")
    args = parser.parse_args()
    binary = ROOT / "target/release/randos_media"
    report = {
        "scope": "Release helper, sine input/null output, no physical device or AEC/call/network. Latency fields are the helper internal estimates: voice_ms is configured frame offset, codec_ms includes one capture frame and Opus lookahead; not measured acoustic mouth-to-ear.",
        "helper_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "cases": [],
    }
    for style in [None, "lower_resonance_pitch", "higher_resonance_pitch"]:
        rows = collect(style)
        report["cases"].append({"style": style, "rows": rows})
        print(style, rows[-1], flush=True)
    out = ROOT / (
        "tools/voice-dsp/results/latency-helper-after.json"
        if args.after
        else "tools/voice-dsp/results/latency-helper.json"
    )
    out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
