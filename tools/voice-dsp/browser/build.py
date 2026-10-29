"""Pinned research-only C++ builds, native and Emscripten. Downloads on setup only."""

import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
PINS = json.loads((HERE / "sources.json").read_text())
OUT = ROOT / "tmp/voice-dsp/browser"


def run(*args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)


def checkout(folder, url, commit):
    path = ROOT / "tmp" / folder
    if not path.exists():
        run("git", "clone", url, path)
    run("git", "-C", path, "checkout", "--detach", commit)
    run("git", "-C", path, "diff", "--exit-code", "HEAD")
    return path


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sdk = checkout(
        "emsdk", "https://github.com/emscripten-core/emsdk.git", PINS["emsdk"]
    )
    if not (sdk / "upstream/emscripten/em++").exists():
        run(sdk / "emsdk", "install", PINS["emscripten"])
    run(sdk / "emsdk", "activate", PINS["emscripten"], "--embedded")
    stretch = checkout(
        "signalsmith-stretch",
        "https://github.com/Signalsmith-Audio/signalsmith-stretch.git",
        PINS["stretch"],
    )
    linear = checkout(
        "signalsmith-linear",
        "https://github.com/Signalsmith-Audio/linear.git",
        PINS["linear"],
    )
    include = OUT / "include"
    include.mkdir(exist_ok=True)
    link = include / "signalsmith-linear"
    if not link.exists():
        link.symlink_to(linear, target_is_directory=True)
    world = ROOT / "tmp/voice-dsp/world"
    archive = OUT / "pyworld.tar.gz"
    if not archive.exists():
        with urllib.request.urlopen(PINS["world_sdist"]) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PINS["world_sdist_sha256"]:
        raise ValueError("WORLD archive hash mismatch")
    unpack = OUT / "source"
    with tarfile.open(archive) as tar:
        tar.extractall(unpack, filter="data")
    source = next(unpack.glob("pyworld-*/lib/World"))
    shutil.copytree(source / "src", world / "src", dirs_exist_ok=True)
    shutil.copyfile(source / "LICENSE.txt", world / "LICENSE.txt")
    exports = [
        "_dsp_new",
        "_dsp_input",
        "_dsp_output",
        "_dsp_process",
        "_dsp_flush",
        "_dsp_input_latency",
        "_dsp_output_latency",
        "_dsp_close",
    ]
    for name in ["world", "spectral"]:
        sources = [HERE / f"{name}.cpp"]
        includes = [f"-I{stretch}", f"-I{include}"]
        if name == "world":
            sources += [
                world / "src" / f"{n}.cpp"
                for n in [
                    "harvest",
                    "cheaptrick",
                    "d4c",
                    "common",
                    "fft",
                    "matlabfunctions",
                    "synthesis",
                ]
            ]
            includes = [f"-I{world / 'src'}"]
        common = ["-O3", "-std=c++17", "-ffp-contract=off", *includes, *sources]
        run("clang++", *common, "-shared", "-fPIC", "-o", OUT / f"{name}.dylib")
        run(
            sdk / "upstream/emscripten/em++",
            *common,
            "-sMODULARIZE=1",
            "-sEXPORT_ES6=1",
            "-sENVIRONMENT=worker",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sINITIAL_MEMORY=33554432",
            "-sMAXIMUM_MEMORY=134217728",
            "-sSTACK_SIZE=2097152",
            "-sEXPORTED_FUNCTIONS=" + json.dumps(exports),
            '-sEXPORTED_RUNTIME_METHODS=["HEAPU8"]',
            "-sDISABLE_EXCEPTION_CATCHING=0",
            "-o",
            OUT / f"{name}.mjs",
        )
        print(f"Built {name}", flush=True)


def vendor():
    destination = ROOT / "assets/vendor/voice_dsp"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ["world.mjs", "world.wasm", "spectral.mjs", "spectral.wasm"]:
        shutil.copyfile(OUT / name, destination / name)
    for source, name in [
        (ROOT / "tmp/emsdk/upstream/emscripten/LICENSE", "EMSCRIPTEN-LICENSE.txt"),
        (ROOT / "tmp/voice-dsp/world/LICENSE.txt", "WORLD-LICENSE.txt"),
        (
            ROOT / "tmp/signalsmith-stretch/LICENSE.txt",
            "SIGNALSMITH-STRETCH-LICENSE.txt",
        ),
        (ROOT / "tmp/signalsmith-linear/LICENSE.txt", "SIGNALSMITH-LINEAR-LICENSE.txt"),
    ]:
        shutil.copyfile(source, destination / name)

    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    manifest = {
        "pins_sha256": sha(HERE / "sources.json"),
        "wrappers": {name: sha(HERE / name) for name in ["world.cpp", "spectral.cpp"]},
        "files": {
            path.name: sha(path)
            for path in destination.iterdir()
            if path.suffix in [".mjs", ".wasm", ".txt"]
        },
    }
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
    if "--vendor" in sys.argv:
        vendor()
