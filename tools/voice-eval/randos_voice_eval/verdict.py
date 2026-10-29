"""A one-line verdict per processor setting, from its numbers and the
original audio's. The thresholds are provisional, chosen to be readable,
not standard: VoicePrivacy reports EERs and WERs without a pass mark.

- An EER of 0.3 or more means the speaker model is mostly confused
  (0.5 is guessing).
- Intelligibility holds while WER is within 10 points of the original's.
"""

HIDDEN_EER = 0.30
WER_MARGIN = 0.10


def defective(processing):
    return (processing.get("failed_frames", 0) > 0
            or processing.get("clipped_samples", 0) / max(processing.get("samples", 1), 1) > 0.001)


def of(result, baseline):
    """`result`: `eer_ignorant`, `eer_informed`, `wer`; `baseline`: the
    original audio's `eer` and `wer`. Returns `{kind, text}`."""
    intelligible = result["wer"] <= baseline["wer"] + WER_MARGIN
    ignorant = result["eer_ignorant"] >= HIDDEN_EER
    informed = result["eer_informed"] >= HIDDEN_EER
    # Only measured where there's a transformation to undo (pitch shifts).
    undo = result.get("eer_adaptive", result.get("eer_undo"))
    survives_undo = undo is not None and undo >= HIDDEN_EER
    # Check each reference configuration separately; aggregating could hide
    # a broken attack behind many clean reference clips.
    bad_attack = (defective(result.get("attack_processing", {}))
                  or any(defective(item["processing"]) for item in result.get("reference_processing", [])))

    if defective(result.get("processing", {})):
        kind, text = "processing_defect", "Processing failures or clipping disqualify this setting."
    elif not intelligible:
        kind, text = "hurts_intelligibility", "Speech recognition suffers too much to count as usable."
    elif ignorant and informed and survives_undo and bad_attack:
        kind, text = "invalid_attack", "Attack audio has processing defects; privacy evidence is inconclusive."
    elif ignorant and informed and survives_undo:
        kind, text = "needs_review", "Confuses tested attacks and preserves transcription; inspect identification accuracy and listen before drawing conclusions."
    elif ignorant and informed and undo is None:
        kind, text = "untested_attack", "Looks promising, but an adaptive attack has not been measured."
    elif ignorant and informed:
        kind, text = (
            "undone",
            "Confuses the first comparisons, but the adaptive attack still identifies speakers.",
        )
    elif ignorant:
        kind, text = (
            "fools_ignorant_only",
            "Fools an attacker who doesn't know the processor; one who does still identifies the speaker.",
        )
    else:
        kind, text = "keeps_identity", "The speaker is still identified."
    return {"kind": kind, "text": text}
