"""Offline ABI sanitizer checks, with parent-pipe ownership and a deadline."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    binary = ROOT / "tmp/voice-bridge-sanitize"
    binary.parent.mkdir(exist_ok=True)
    subprocess.run(
        [
            "c++",
            "-std=c++17",
            "-O1",
            "-g",
            "-pthread",
            "-ffp-contract=off",
            "-fsanitize=address,undefined",
            "-fno-sanitize-recover=all",
            "-fno-omit-frame-pointer",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Ivendor/signalsmith",
            "-Ivendor/signalsmith/stretch",
            "voice-native/src/bridge.cpp",
            "voice-native/tests/bridge_sanitize.cpp",
            "-o",
            str(binary),
        ],
        cwd=ROOT,
        check=True,
    )
    with subprocess.Popen([str(binary)], stdin=subprocess.PIPE, cwd=ROOT) as child:
        try:
            status = child.wait(timeout=15)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if status:
            raise RuntimeError(f"C++ bridge sanitizer check failed: {status}")
    print(
        "Owned C++ ABI: fatal ASan/UBSan, independent owners, bounds and sticky failures passed"
    )


if __name__ == "__main__":
    main()
