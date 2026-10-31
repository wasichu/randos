"""Isolated FARGAN pitch/envelope edits, reusing the accepted quality control."""

import hashlib
import json
import re
import subprocess
from datetime import UTC, datetime

import numpy as np
import soundfile as sf
from bootstrap import HERE, OUT, ROOT, SOURCE, digest
from features import BANDS, COMPENSATION, edit, periods
from probe import atomic_json, match_levels, run, save_audio
from scipy.signal import resample_poly

WORK = OUT / "masking"
VARIANTS = [
    ("control", "Unchanged FARGAN"),
    ("pitch", "FARGAN · pitch only"),
    ("envelope", "FARGAN · resonance only"),
]


def c_dct(values, label):
    source, target = WORK / f"{label}.in", WORK / f"{label}.out"
    np.asarray(values, dtype="<f4").tofile(source)
    with subprocess.Popen(
        [WORK / "check_transform", source, target], stdin=subprocess.PIPE
    ) as child:
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
            raise RuntimeError(f"Pinned C DCT check failed: {status}")
    result = np.fromfile(target, dtype="<f4")
    if result.size != np.asarray(values).size or not np.isfinite(result).all():
        raise ValueError("Incomplete native DCT output")
    return result.reshape(-1, 18)


def setup_transform():
    WORK.mkdir(exist_ok=True)
    subprocess.run(
        [
            "clang",
            "-O2",
            "-std=c11",
            "-D_DARWIN_C_SOURCE",
            "-Wall",
            "-Wextra",
            "-Werror",
            *[f"-I{SOURCE / p}" for p in [".", "include", "dnn", "celt"]],
            HERE / "check_transform.c",
            SOURCE / ".libs/libopus.a",
            "-lm",
            "-pthread",
            "-o",
            WORK / "check_transform",
        ],
        check=True,
    )
    text = (SOURCE / "dnn/freq.c").read_text()

    def array(name):
        match = re.search(r"\b" + name + r"\[\]\s*=\s*\{(.*?)\}", text, re.DOTALL)
        body = re.sub(r"/\*.*?\*/", "", match.group(1), flags=re.DOTALL)
        return np.array(
            [float(x.strip().removesuffix("f")) for x in body.split(",") if x.strip()]
        )

    if not np.array_equal(array("eband5ms") * 200, BANDS):
        raise ValueError("Pinned band centers changed")
    if not np.array_equal(
        array("compensation").astype("<f4"), COMPENSATION.astype("<f4")
    ):
        raise ValueError("Pinned band compensation changed")
    basis = c_dct(np.eye(18), "basis").astype(float)
    error = float(np.max(np.abs(basis @ basis.T - np.eye(18))))
    if error > 2e-6:
        raise ValueError("Native DCT is not the expected orthonormal transform")
    constants = np.ones((1, 18), dtype="<f4")
    if np.max(np.abs(c_dct(constants, "constant")[:, 1:])) > 2e-6:
        raise ValueError("Constant-vector DCT orientation check failed")
    return basis, error


def transformed(x, basis, pitch, scale):
    y = edit(x, basis, pitch=pitch, scale=scale)
    np.testing.assert_array_equal(y[:20], x[:20])
    np.testing.assert_array_equal(y[-20:], x[-20:])
    np.testing.assert_array_equal(y[:, 19], x[:, 19])
    if pitch:
        np.testing.assert_array_equal(y[:, :18], x[:, :18])
    if scale != 1:
        np.testing.assert_array_equal(y[:, 18:], x[:, 18:])
        np.testing.assert_array_equal(y[:, 0], x[:, 0])
    old_period, new_period = periods(x), periods(y)
    if np.any((new_period < 32) | (new_period > 256)):
        raise ValueError("Edited pitch period would require decoder clamping")
    return y, {
        "changed_pitch_frames": int(np.sum(x[:, 18] != y[:, 18])),
        "unchanged_bound_frames": int(len(x) - 40 - np.sum(x[:, 18] != y[:, 18]))
        if pitch
        else 0,
        "original_period_range": [float(old_period.min()), float(old_period.max())],
        "edited_period_range": [float(new_period.min()), float(new_period.max())],
        "max_abs_coefficient_delta": np.max(
            np.abs(y.astype(float) - x), axis=0
        ).tolist(),
    }


def render_case(x, basis, key, pitch=0, scale=1):
    features, diagnostics = transformed(x, basis, pitch, scale)
    input_path, output_path = WORK / f"{key}.features", WORK / f"{key}.f32"
    features.astype("<f4").tofile(input_path)
    metrics = run("synthesize", input_path, output_path)
    y = np.fromfile(output_path, dtype="<f4")
    if len(y) != len(x) * 160 or not np.isfinite(y).all():
        raise ValueError("Masking synthesis is incomplete or nonfinite")
    return y, {
        **diagnostics,
        "settings": {"pitch": pitch, "scale": scale},
        "synthesis": metrics,
        "features_sha256": digest(input_path),
        "output_sha256": digest(output_path),
        "raw_peak": float(np.max(np.abs(y))),
        "above_full_scale_samples": int(np.sum(np.abs(y) >= 1)),
    }


def diagnostics(basis):
    results = []
    for name in ["silence", "onset", "ending"]:
        pcm = np.zeros(19200, dtype="<i2")
        if name != "silence":
            start = 3200 if name == "onset" else 12800
            pulse = (
                np.sin(2 * np.pi * 200 * np.arange(1600) / 16000)
                * np.hanning(1600)
                * 0.1
            )
            pcm[start : start + 1600] = np.rint(pulse * 32768).astype("<i2")
        path, feature_path = WORK / f"{name}.pcm", WORK / f"{name}.features"
        pcm.tofile(path)
        run("features", path, feature_path)
        x = np.fromfile(feature_path, dtype="<f4").reshape(-1, 20)
        for variant, pitch, scale in [
            ("control", 0, 1),
            ("down", -1, 1),
            ("up", 1, 1),
            ("lower", 0, 0.9),
            ("higher", 0, 1.1),
        ]:
            y, row = render_case(x, basis, name + "_" + variant, pitch, scale)
            if name == "silence" and row["raw_peak"] > 0.001:
                raise ValueError(
                    "Feature edits generated audible output from full silence"
                )
            results.append(
                {
                    "fixture": name,
                    "variant": variant,
                    **row,
                    "tail_rms": float(np.sqrt(np.mean(y[-1600:] ** 2))),
                }
            )
    return results


def main():
    quality_path = HERE / "results/quality.json"
    quality_bytes = quality_path.read_bytes()
    quality_sha256 = hashlib.sha256(quality_bytes).hexdigest()
    quality = json.loads(quality_bytes)
    for path, expected in quality["identity"]["build"]["files"].items():
        if digest(ROOT / path) != expected:
            raise ValueError("Accepted native quality build changed: " + path)
    basis, basis_error = setup_transform()
    boundary = diagnostics(basis)
    stamp = datetime.now(UTC).isoformat()
    cases, checks = {}, []
    candidates = {"fargan_mask_" + name: {} for name, _ in VARIANTS}
    for sample, old in quality["cases"].items():
        clip = old["context"]["sample"]
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if digest(source) != old["context"]["source_id"]:
            raise ValueError("Accepted source changed")
        expected = next(x for x in quality["identity"]["checks"] if x["sample"] == clip)
        path = OUT / f"{clip}.features"
        if digest(path) != expected["features_sha256"]:
            raise ValueError("Accepted feature cache changed")
        x = np.fromfile(path, dtype="<f4").reshape(-1, 20)
        if not np.array_equal(edit(x, basis), x):
            raise ValueError("Identity features changed")
        c = x[:, :18].astype(float).copy()
        c[:, 0] += 4
        bands = c @ basis.T
        native = c_dct(bands, clip)
        forward_error = float(np.max(np.abs(native - bands @ basis)))
        roundtrip_error = float(np.max(np.abs(bands @ basis - c)))
        if max(forward_error, roundtrip_error) > 5e-5:
            raise ValueError("Native/Python DCT round-trip disagreement")
        direction = 1 if clip in ["low_voice", "mencken_wasichu"] else -1
        settings = {
            "control": (0, 1),
            "pitch": (direction, 1),
            "envelope": (0, 1.1 if direction > 0 else 0.9),
        }
        pcm_path = OUT / f"{clip}.pcm"
        if digest(pcm_path) != expected["input_pcm_sha256"]:
            raise ValueError("Accepted model-input PCM changed")
        pcm = np.fromfile(pcm_path, dtype="<i2")
        if len(pcm) != len(x) * 160:
            raise ValueError("Model input and feature lengths disagree")
        waves = {"original": resample_poly(pcm[3200:-3200].astype(float) / 32768, 3, 1)}
        wav = ROOT / "tmp/voice-model" / old["audio"]["reference"]
        if digest(wav) != wav.stem.split("__")[-1]:
            raise ValueError("Accepted Signalsmith playback WAV changed")
        y, rate = sf.read(wav, dtype="float32")
        if rate != 48000:
            raise ValueError("Wrong reference rate")
        # Reuse quantized playback, not a claim of raw reference reconstruction.
        waves["reference"] = y / old["gains"]["reference"]
        rows = {}
        for name, _ in VARIANTS:
            pitch, scale = settings[name]
            y, row = render_case(x, basis, clip + "__" + name, pitch, scale)
            if (
                name == "control"
                and row["output_sha256"] != expected["output_float_sha256"]
            ):
                raise ValueError(
                    "Unchanged synthesis no longer matches accepted quality control"
                )
            if (
                name != "control"
                and row["output_sha256"] == rows["control"]["output_sha256"]
            ):
                raise ValueError(
                    "Feature edit did not change the synthesized recording"
                )
            y = y[3200:-3200]
            waves[name] = resample_poly(y, 3, 1)
            rows[name] = row
        if len({len(y) for y in waves.values()}) != 1:
            raise ValueError("Masking comparison lengths differ")
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(clip, "fargan_mask_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        context = {
            "view": "round",
            "mode": "fargan_masking_1",
            "processor": "fargan",
            "source_id": digest(source),
            "sample": clip,
            "case_id": clip,
            "build_id": None,
            "run_id": stamp,
        }
        descriptions = {
            "original": "Original · 16 kHz, matched to the model input",
            "reference": "Released Signalsmith · strong resonance and one-semitone pitch shift",
            "control": "Unchanged FARGAN synthesis · no masking features edited",
            "pitch": f"Pitch {direction:+d} semitone where within model range · resonance features unchanged",
            "envelope": f"Gentle approximate resonance warp ×{settings['envelope'][1]:.2f} · pitch unchanged",
        }
        note = "Compare masking against the unchanged FARGAN control, and sound quality against the Signalsmith reference. Pitch and resonance are tested separately."
        if clip == "test_tone":
            note = "Tone diagnostic only; judge masking on the speech recordings."
        cases[sample] = {
            "context": context,
            "audio": audio,
            "gains": gains,
            "settings": rows,
            "descriptions": descriptions,
            "note": note,
        }
        for name, _ in VARIANTS:
            processor = "fargan_mask_" + name
            candidates[processor][sample] = {
                "audio": {"original": audio["original"], "converted": audio[name]},
                "description": descriptions[name],
                "note": note,
                "level_matched": True,
                "reference_title": "Original · 16 kHz",
                "reference_description": descriptions["original"],
                "context": {
                    **context,
                    "view": "model",
                    "mode": "fargan_masking",
                    "processor": processor,
                },
            }
        checks.append(
            {
                "sample": clip,
                "control_byte_exact": True,
                "native_dct_max_error": forward_error,
                "roundtrip_max_error": roundtrip_error,
                "variants": rows,
            }
        )
        print(
            f"FARGAN masking {clip}: exact accepted control, native DCT error {forward_error:.3g}",
            flush=True,
        )
    if digest(quality_path) != quality_sha256:
        raise ValueError("Quality reference changed during generation; retry serially")
    identity = {
        "quality_report_sha256": quality_sha256,
        "checks": checks,
        "boundary_checks": boundary,
        "dct_orthogonality_max_error": basis_error,
        "sources": {
            str(p.relative_to(ROOT)): digest(p)
            for p in [
                HERE / "masking.py",
                HERE / "features.py",
                HERE / "check_transform.c",
                WORK / "check_transform",
                SOURCE / ".libs/libopus.a",
                SOURCE / "dnn/lpcnet_tables.c",
                SOURCE / "dnn/freq.c",
            ]
        },
        "cases": {
            key: {k: v for k, v in row.items() if k != "context"}
            for key, row in cases.items()
        },
    }
    build = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    for row in cases.values():
        row["context"]["build_id"] = build
    for group in candidates.values():
        for row in group.values():
            row["context"]["build_id"] = build
    atomic_json(
        HERE / "results/masking.json",
        {
            "identity": identity,
            "cases": cases,
            "candidates": candidates,
            "variants": [
                {"id": key, "label": label}
                for key, label in [
                    ("original", "Original · 16 kHz"),
                    *VARIANTS,
                    ("reference", "Signalsmith reference"),
                ]
            ],
            "title": "Can compact FARGAN synthesis mask the voice?",
            "intro": "Compare unchanged FARGAN with pitch-only and resonance-only edits. Which gives useful disguise without losing too much clarity? Signalsmith remains the product reference.",
            "details": [
                "Pitch moves one semitone down for high/mid voices and up for low/Wasichu. Frames that would exceed the model pitch range are left unchanged and counted. Envelope coefficients and voicing are untouched.",
                "Resonance-only edits warp compensated log-band energies, then restore the original coefficient-zero value. This preserves average log-band level, not waveform loudness. Pitch, voicing and the fixed padding frames are untouched.",
                "The envelope warp is gentle and frequency dependent (0.9/1.1 near the low end), tapering to unchanged lookup at 8 kHz. It is not uniform formant scaling, and feature edits may be outside the model training distribution.",
                "All five versions share RMS matching and peak headroom. The original comes from the exact cached 16 kHz model-input PCM. Signalsmith reuses the accepted quantized playback reference with its old gain reversed approximately; it is not a raw-waveform identity claim. No output correlation alignment, limiter or live microphone is used.",
                "The accepted quality report and its reviews remain intact. This round adds no browser performance, streaming or privacy guarantee. Stop if neither isolated edit improves disguise enough to justify its quality cost.",
            ],
        },
    )


if __name__ == "__main__":
    main()
