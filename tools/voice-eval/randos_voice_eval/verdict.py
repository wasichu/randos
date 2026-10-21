"""A one-line verdict per processor setting, from its numbers and the
original audio's. The thresholds are provisional, chosen to be readable,
not standard: VoicePrivacy reports EERs and WERs without a pass mark.

- An EER of 0.3 or more means the speaker model is mostly confused
  (0.5 is guessing).
- Intelligibility holds while WER is within 10 points of the original's.
"""

HIDDEN_EER = 0.30
WER_MARGIN = 0.10


def of(result, baseline):
    """`result`: `eer_ignorant`, `eer_informed`, `wer`; `baseline`: the
    original audio's `eer` and `wer`. Returns `{kind, text}`."""
    intelligible = result["wer"] <= baseline["wer"] + WER_MARGIN
    ignorant = result["eer_ignorant"] >= HIDDEN_EER
    informed = result["eer_informed"] >= HIDDEN_EER
    # Only measured where there's a transformation to undo (pitch shifts).
    undo = result.get("eer_undo")
    survives_undo = undo is None or undo >= HIDDEN_EER

    if not intelligible:
        kind, text = "hurts_intelligibility", "Speech recognition suffers too much to count as usable."
    elif ignorant and informed and survives_undo:
        kind, text = "hides", "Hides the speaker from every attacker tried and stays intelligible."
    elif ignorant and informed:
        kind, text = (
            "undone",
            "Fools both attackers, but shifting the voice back reveals the speaker.",
        )
    elif ignorant:
        kind, text = (
            "fools_ignorant_only",
            "Fools an attacker who doesn't know the processor; one who does still identifies the speaker.",
        )
    else:
        kind, text = "keeps_identity", "The speaker is still identified."
    return {"kind": kind, "text": text}
