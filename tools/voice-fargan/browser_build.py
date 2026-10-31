"""Separate portable/native and WASM builds. Accepted native evidence stays intact."""

import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile

from bootstrap import HERE, OUT, PINS, ROOT, SOURCE, digest

BROWSER = OUT / "browser"
SDK = ROOT / "tmp/emsdk/upstream/emscripten"


def main():
    BROWSER.mkdir(exist_ok=True)
    pinned = json.loads((ROOT / "tools/voice-dsp/browser/sources.json").read_text())
    head = subprocess.check_output(
        ["git", "-C", ROOT / "tmp/emsdk", "rev-parse", "HEAD"], text=True
    ).strip()
    if head != pinned["emsdk"]:
        raise ValueError("Use the pinned existing Emscripten SDK")
    if (
        subprocess.check_output(
            ["git", "-C", SOURCE, "rev-parse", "HEAD"], text=True
        ).strip()
        != PINS["commit"]
    ):
        raise ValueError("Wrong Opus source pin")
    subprocess.run(["git", "-C", SOURCE, "diff", "--exit-code", "HEAD"], check=True)
    source = BROWSER / "source"
    source_receipt = BROWSER / "source.json"
    if source.exists() and not source_receipt.exists():
        shutil.rmtree(
            source
        )  # Only this disposable, separately exported research tree.
    if not source.exists():
        source.mkdir()
        archive = subprocess.check_output(["git", "-C", SOURCE, "archive", "HEAD"])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(source, filter="data")
        subprocess.run(["autoreconf", "-isf"], cwd=source, check=True)
        source_receipt.write_text(
            json.dumps(
                {
                    str(p.relative_to(source)): digest(p)
                    for p in source.rglob("*")
                    if p.is_file()
                }
            )
        )
    for path, wanted in json.loads(source_receipt.read_text()).items():
        if digest(source / path) != wanted:
            raise ValueError("Exported source changed: " + path)
    for model in ["fargan", "pitchdnn", "plc"]:
        for ext in ["c", "h"]:
            shutil.copyfile(
                SOURCE / f"dnn/{model}_data.{ext}", source / f"dnn/{model}_data.{ext}"
            )
    for path in [
        *(SOURCE / "dnn").glob("*_data.h"),
        SOURCE / "dnn/dred_rdovae_constants.h",
    ]:
        shutil.copyfile(path, source / "dnn" / path.name)
    env = {**os.environ, "EM_CACHE": str(BROWSER / "em-cache")}
    configure = [
        "--enable-deep-plc",
        "--disable-shared",
        "--disable-extra-programs",
        "--disable-doc",
        "--disable-intrinsics",
        "--disable-rtcd",
        "--disable-asm",
    ]
    ingredients = {
        str(p.relative_to(source)): digest(p)
        for p in source.rglob("*")
        if p.is_file() and (p.suffix in [".c", ".h"] or p.name == "configure")
    }
    for kind in ["native", "wasm"]:
        build = BROWSER / kind
        build.mkdir(exist_ok=True)
        flags = "-O3 -ffp-contract=off" + (" -msimd128" if kind == "wasm" else "")
        compiler = SDK / "emcc" if kind == "wasm" else "clang"
        key = hashlib.sha256(
            json.dumps(
                {
                    "files": ingredients,
                    "configure": configure,
                    "flags": flags,
                    "compiler": subprocess.check_output(
                        [compiler, "--version"], text=True
                    ),
                    "pins": PINS,
                },
                sort_keys=True,
            ).encode()
        ).hexdigest()
        receipt = build / "receipt.json"
        library = build / ".libs/libopus.a"
        cached = json.loads(receipt.read_text()) if receipt.exists() else {}
        if (
            cached.get("key") != key
            or not library.exists()
            or cached.get("library") != digest(library)
        ):
            shutil.rmtree(build)
            build.mkdir()
            args = [str(source / "configure"), *configure, "CFLAGS=" + flags]
            if kind == "wasm":
                args = [str(SDK / "emconfigure"), *args]
            else:
                args.append("CC=clang")
            subprocess.run(args, cwd=build, env=env, check=True)
            args = ["make", "-j4", "libopus.la"]
            if kind == "wasm":
                args = [str(SDK / "emmake"), *args]
            subprocess.run(args, cwd=build, env=env, check=True)
            receipt.write_text(
                json.dumps({"key": key, "library": digest(library)}, indent=2) + "\n"
            )
        includes = [
            f"-I{build}",
            *[f"-I{source / p}" for p in [".", "include", "dnn", "celt"]],
        ]
        common = [
            "-O3",
            "-ffp-contract=off",
            *includes,
            HERE / "browser_core.c",
            build / ".libs/libopus.a",
            "-lm",
        ]
        if kind == "native":
            subprocess.run(
                ["clang", "-shared", "-fPIC", *common, "-o", BROWSER / "fargan.dylib"],
                check=True,
            )
        else:
            exports = [
                "fg_new",
                "fg_close",
                "fg_input",
                "fg_output",
                "fg_process",
                "fg_finish",
                "fg_feature_input",
                "fg_feature_output",
                "fg_edit",
                "fg_skipped",
                "fg_down_delay",
                "fg_up_delay",
            ]
            subprocess.run(
                [
                    SDK / "emcc",
                    *common,
                    "-msimd128",
                    "-sMODULARIZE=1",
                    "-sEXPORT_ES6=1",
                    "-sENVIRONMENT=worker",
                    "-sALLOW_MEMORY_GROWTH=0",
                    "-sINITIAL_MEMORY=16777216",
                    "-sSTACK_SIZE=1048576",
                    "-sEXPORTED_FUNCTIONS=" + json.dumps(["_" + x for x in exports]),
                    '-sEXPORTED_RUNTIME_METHODS=["HEAPU8"]',
                    "-o",
                    BROWSER / "fargan-core.mjs",
                ],
                env=env,
                check=True,
            )
    paths = [
        HERE / "browser_build.py",
        HERE / "browser_core.c",
        BROWSER / "fargan.dylib",
        BROWSER / "fargan-core.mjs",
        BROWSER / "fargan-core.wasm",
        *[BROWSER / k / "config.h" for k in ["native", "wasm"]],
        *[source / f"dnn/{n}_data.c" for n in ["fargan", "pitchdnn", "plc"]],
    ]
    paths += [
        source_receipt,
        *[
            BROWSER / k / p
            for k in ["native", "wasm"]
            for p in ["receipt.json", ".libs/libopus.a"]
        ],
    ]
    notices = BROWSER / "licenses.txt"
    notices.write_text(
        "Opus / FARGAN\n\n"
        + (SOURCE / "COPYING").read_text()
        + "\n\nEmscripten SDK\n\n"
        + (ROOT / "tmp/emsdk/LICENSE").read_text()
    )
    paths.append(notices)
    (BROWSER / "build.json").write_text(
        json.dumps(
            {
                "opus": PINS,
                "emscripten": pinned,
                "files": {str(p.relative_to(ROOT)): digest(p) for p in paths},
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
