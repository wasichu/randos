"""One final combined preset vs the accepted FARGAN and Signalsmith references."""

import hashlib
import json
from datetime import UTC, datetime

import numpy as np
import soundfile as sf
from bootstrap import HERE, OUT, ROOT, digest
from combined_features import combined as apply_combined
from combined_features import strong_envelope, strong_lookup
from features import BANDS, edit, periods
from masking import c_dct
from probe import atomic_json, match_levels, run, save_audio
from scipy.signal import resample_poly

WORK = OUT / "combined"


def synthesize(x, basis, key, pitch=0, scale=1):
    y = apply_combined(x, basis, pitch, scale)
    np.testing.assert_array_equal(y[:20], x[:20])
    np.testing.assert_array_equal(y[-20:], x[-20:])
    np.testing.assert_array_equal(y[:, 19], x[:, 19])
    np.testing.assert_array_equal(y[:, 0], x[:, 0])
    np.testing.assert_array_equal(y[:, 18], edit(x, basis, pitch=pitch)[:, 18])
    np.testing.assert_array_equal(y[:, :18], strong_envelope(x, basis, scale)[:, :18])
    p = periods(y)
    if np.any((p < 32) | (p > 256)):
        raise ValueError("Combined pitch would require decoder clamping")
    source, target = WORK / f"{key}.features", WORK / f"{key}.f32"
    y.astype("<f4").tofile(source)
    metrics = run("synthesize", source, target)
    audio = np.fromfile(target, dtype="<f4")
    if len(audio) != len(x) * 160 or not np.isfinite(audio).all():
        raise ValueError("Combined output is incomplete or nonfinite")
    return audio, {
        "settings": {"pitch": pitch, "scale": scale},
        "band_lookup_hz": strong_lookup(BANDS, scale).tolist(),
        "feature_sha256": digest(source),
        "output_sha256": digest(target),
        "changed_pitch_frames": int(np.sum(y[:, 18] != x[:, 18])),
        "bound_skip_frames": int(len(x) - 40 - np.sum(y[:, 18] != x[:, 18]))
        if pitch
        else 0,
        "max_abs_coefficient_delta": np.max(
            np.abs(y.astype(float) - x), axis=0
        ).tolist(),
        "raw_peak": float(np.max(np.abs(audio))),
        "above_full_scale_samples": int(np.sum(np.abs(audio) >= 1)),
        "metrics": metrics,
    }


def main():
    WORK.mkdir(exist_ok=True)
    quality_path, isolated_path = (
        HERE / "results/quality.json",
        HERE / "results/masking.json",
    )
    quality_bytes, isolated_bytes = (
        quality_path.read_bytes(),
        isolated_path.read_bytes(),
    )
    quality, isolated = json.loads(quality_bytes), json.loads(isolated_bytes)
    for path, expected in quality["identity"]["build"]["files"].items():
        if digest(ROOT / path) != expected:
            raise ValueError("Accepted native build changed: " + path)
    for path, expected in isolated["identity"]["sources"].items():
        if digest(ROOT / path) != expected:
            raise ValueError("Accepted isolated transform build changed: " + path)
    basis = c_dct(np.eye(18), "final_combined_basis").astype(float)
    if np.max(np.abs(basis @ basis.T - np.eye(18))) > 2e-6:
        raise ValueError("Native DCT basis changed")
    boundary = []
    for fixture in ["silence", "onset", "ending"]:
        path = OUT / "masking" / f"{fixture}.features"
        expected_fixture = next(
            row
            for row in isolated["identity"]["boundary_checks"]
            if row["fixture"] == fixture and row["variant"] == "control"
        )
        if digest(path) != expected_fixture["features_sha256"]:
            raise ValueError("Accepted boundary feature cache changed")
        x = np.fromfile(path, dtype="<f4").reshape(-1, 20)
        for label, pitch, scale in [
            ("control", 0, 1),
            ("fuller", -1, 0.8),
            ("brighter", 1, 1.25),
        ]:
            audio, row = synthesize(x, basis, fixture + "_" + label, pitch, scale)
            if fixture == "silence" and row["raw_peak"] > 0.001:
                raise ValueError("Combined preset exceeds the silence guard")
            boundary.append(
                {
                    "fixture": fixture,
                    "variant": label,
                    **row,
                    "tail_rms": float(np.sqrt(np.mean(audio[-1600:] ** 2))),
                }
            )
    stamp = datetime.now(UTC).isoformat()
    cases, checks, candidates = {}, [], {"fargan_combined": {}}
    for sample, old in quality["cases"].items():
        clip = old["context"]["sample"]
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if digest(source) != old["context"]["source_id"]:
            raise ValueError("Accepted source changed")
        expected = next(
            row for row in quality["identity"]["checks"] if row["sample"] == clip
        )
        feature_path, pcm_path = OUT / f"{clip}.features", OUT / f"{clip}.pcm"
        if (
            digest(feature_path) != expected["features_sha256"]
            or digest(pcm_path) != expected["input_pcm_sha256"]
        ):
            raise ValueError("Accepted model input cache changed")
        x = np.fromfile(feature_path, dtype="<f4").reshape(-1, 20)
        coeff = x[:, :18].astype(float).copy()
        coeff[:, 0] += 4
        bands = coeff @ basis.T
        error = float(np.max(np.abs(c_dct(bands, "final_" + clip) - bands @ basis)))
        if error > 5e-5:
            raise ValueError("Native transform disagreement")
        control, control_row = synthesize(x, basis, clip + "__control")
        if control_row["output_sha256"] != expected["output_float_sha256"]:
            raise ValueError("Final unchanged control does not match accepted quality")
        pitch, scale = (
            (1, 1.25) if clip in ["low_voice", "mencken_wasichu"] else (-1, 0.8)
        )
        changed, row = synthesize(x, basis, clip + "__combined", pitch, scale)
        if row["output_sha256"] == control_row["output_sha256"]:
            raise ValueError("Combined output did not change")
        pcm = np.fromfile(pcm_path, dtype="<i2")
        if len(pcm) != len(control):
            raise ValueError("Input/output frame count differs")
        ref_path = ROOT / "tmp/voice-model" / old["audio"]["reference"]
        if digest(ref_path) != ref_path.stem.split("__")[-1]:
            raise ValueError("Signalsmith playback changed")
        reference, rate = sf.read(ref_path, dtype="float32")
        if rate != 48000:
            raise ValueError("Wrong playback rate")
        waves = {
            "original": resample_poly(pcm[3200:-3200].astype(float) / 32768, 3, 1),
            "control": resample_poly(control[3200:-3200], 3, 1),
            "combined": resample_poly(changed[3200:-3200], 3, 1),
            "reference": reference / old["gains"]["reference"],
        }
        if len({len(y) for y in waves.values()}) != 1:
            raise ValueError("Playback lengths differ")
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(clip, "fargan_final_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        context = {
            "view": "round",
            "mode": "fargan_combined_1",
            "processor": "fargan",
            "sample": clip,
            "case_id": clip,
            "source_id": digest(source),
            "run_id": stamp,
            "build_id": None,
        }
        descriptions = {
            "original": "Original · 16 kHz, matched to the model input",
            "control": "The unchanged FARGAN quality control you reviewed",
            "combined": f"Pitch {pitch:+d} semitone · resonance scale ×{scale:.2f} below 4 kHz",
            "reference": f"Signalsmith · same nominal pitch {pitch:+d} and resonance ×{scale:.2f}; different processing",
        }
        note = "Final combined preset. Compare useful disguise and clear speech directly with Signalsmith. Matching numbers does not mean the two engines make identical changes."
        if clip == "test_tone":
            note = "Synthetic tone diagnostic only; judge disguise on speech."
        cases[sample] = {
            "context": context,
            "audio": audio,
            "gains": gains,
            "settings": {"control": control_row, "combined": row},
            "descriptions": descriptions,
            "note": note,
        }
        candidates["fargan_combined"][sample] = {
            "audio": {"original": audio["original"], "converted": audio["combined"]},
            "description": descriptions["combined"],
            "note": note,
            "level_matched": True,
            "reference_title": "Original · 16 kHz",
            "reference_description": descriptions["original"],
            "context": {
                **context,
                "view": "model",
                "mode": "fargan_combined",
                "processor": "fargan_combined",
            },
        }
        checks.append(
            {
                "sample": clip,
                "control_byte_exact": True,
                "native_dct_max_error": error,
                "reference_pcm16_sha256": digest(ref_path),
                "combined": row,
                "control": control_row,
            }
        )
        print(
            f"Final FARGAN {clip}: pitch {pitch:+d}, resonance {scale:g}, accepted control exact",
            flush=True,
        )
    if (
        quality_path.read_bytes() != quality_bytes
        or isolated_path.read_bytes() != isolated_bytes
    ):
        raise ValueError("An earlier report changed during generation")
    identity = {
        "quality_sha256": hashlib.sha256(quality_bytes).hexdigest(),
        "isolated_sha256": hashlib.sha256(isolated_bytes).hexdigest(),
        "checks": checks,
        "boundary_checks": boundary,
        "sources": {
            str(p.relative_to(ROOT)): digest(p)
            for p in [
                HERE / "combined.py",
                HERE / "combined_features.py",
                HERE / "features.py",
                HERE / "masking.py",
                OUT / "masking/check_transform",
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
    for row in candidates["fargan_combined"].values():
        row["context"]["build_id"] = build
    atomic_json(
        HERE / "results/combined.json",
        {
            "identity": identity,
            "cases": cases,
            "candidates": candidates,
            "variants": [
                {"id": key, "label": label}
                for key, label in [
                    ("original", "Original · 16 kHz"),
                    ("control", "Unchanged FARGAN"),
                    ("combined", "FARGAN · combined"),
                    ("reference", "Signalsmith reference"),
                ]
            ],
            "title": "Final FARGAN comparison: stronger resonance + pitch",
            "intro": "Try one stronger combined preset against the unchanged FARGAN control and our Signalsmith reference. Does it provide a useful changed voice without losing too much clarity?",
            "details": [
                "Pitch is one semitone down with resonance ×0.80 for high/mid voices, and one up with ×1.25 for low/Wasichu. These match the reference direction and nominal low-frequency scale, not its waveform or complete transformation.",
                "Below 4 kHz the inverse envelope lookup is f/scale. Above 4 kHz it joins linearly to the unchanged 8 kHz endpoint. Both segments are monotonic; the derivative changes at 4 kHz. This changes the broad low/mid envelope more strongly than the earlier tapered edit.",
                "FARGAN uses only 18 envelope bands and learned synthesis, so the effect may differ from Signalsmith even with matching numbers. Original C0, voicing and fixed padding are preserved. Pitch frames outside the supported range remain unchanged and are counted.",
                "All four versions are RMS-matched with shared peak headroom. The original is the exact cached 16 kHz input; Signalsmith reuses its accepted quantized playback. Only the raw FARGAN control claims byte identity. No limiter or per-output correlation alignment is used.",
                "Earlier reports/reviews are retained. This is native prepared audio, not live/browser qualification. If this combined preset still offers little disguise or loses too much clarity, stop this FARGAN feature-edit approach rather than adding more tuning rounds.",
            ],
        },
    )


if __name__ == "__main__":
    main()
