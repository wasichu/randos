"""Pinned native research build; isolated from all product dependencies."""

import hashlib
import json
import subprocess
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "tmp/fargan"
SOURCE = OUT / "opus"
PINS = json.loads((HERE / "pins.json").read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    if not SOURCE.exists():
        subprocess.run(
            ["git", "clone", "--no-checkout", PINS["repository"], SOURCE], check=True
        )
        subprocess.run(
            ["git", "-C", SOURCE, "checkout", "--detach", PINS["commit"]], check=True
        )
    head = subprocess.check_output(
        ["git", "-C", SOURCE, "rev-parse", "HEAD"], text=True
    ).strip()
    if head != PINS["commit"]:
        raise ValueError(
            "Existing FARGAN source is not at the pin; do not replace it silently"
        )
    subprocess.run(["git", "-C", SOURCE, "diff", "--exit-code", "HEAD"], check=True)
    archive = OUT / ("opus_data-" + PINS["archive_sha256"] + ".tar.gz")
    if not archive.exists():
        subprocess.run(
            ["curl", "--fail", "--location", "--output", archive, PINS["archive_url"]],
            check=True,
        )
    if digest(archive) != PINS["archive_sha256"]:
        raise ValueError("Opus model archive checksum mismatch")
    with tarfile.open(archive) as stream:
        stream.extractall(SOURCE, filter="data")
    configure = [
        "./configure",
        "--enable-deep-plc",
        "--disable-shared",
        "--disable-doc",
        "--enable-extra-programs",
        "CFLAGS=-O3",
    ]
    for args in [
        ["autoreconf", "-isf"],
        configure,
        ["make", "clean"],
        ["make", "-j4", "libopus.la"],
    ]:
        subprocess.run(args, cwd=SOURCE, check=True)
    command = [
        "clang",
        "-O3",
        "-std=c11",
        "-D_DARWIN_C_SOURCE",
        *[f"-I{SOURCE / part}" for part in [".", "include", "dnn", "celt"]],
        HERE / "probe.c",
        SOURCE / ".libs/libopus.a",
        "-lm",
        "-pthread",
        "-o",
        OUT / "probe",
    ]
    subprocess.run(command, check=True)
    with subprocess.Popen(
        [OUT / "probe", "--wait-for-eof"], stdin=subprocess.PIPE
    ) as child:
        child.stdin.close()
        try:
            if child.wait(timeout=5) != 72:
                raise RuntimeError("FARGAN probe did not honor parent-pipe EOF")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    identity = {
        "pins": PINS,
        "archive_bytes": archive.stat().st_size,
        "configure": configure,
        "compiler": subprocess.check_output(
            ["clang", "--version"], text=True
        ).splitlines()[0],
        "executable_bytes": (OUT / "probe").stat().st_size,
        "fargan_model_object_bytes": (SOURCE / "dnn/fargan_data.o").stat().st_size,
        "files": {
            str(p.relative_to(ROOT)): digest(p)
            for p in [
                HERE / "pins.json",
                Path(__file__),
                HERE / "probe.c",
                OUT / "probe",
                SOURCE / "config.h",
                SOURCE / "COPYING",
                SOURCE / "dnn/fargan_data.c",
                SOURCE / "dnn/pitchdnn_data.c",
                SOURCE / "dnn/fargan.c",
                SOURCE / "dnn/fargan_demo.c",
                SOURCE / "dnn/lpcnet_enc.c",
                SOURCE / "dnn/freq.c",
            ]
        },
    }
    (OUT / "build.json").write_text(json.dumps(identity, indent=2) + "\n")


if __name__ == "__main__":
    build()
