"""The benchmark's numbers, as pure functions (tested offline in tests/).

- EER (equal error rate) of a speaker-verification system: the threshold
  where false accepts equal false rejects. 0 means voices are told apart
  perfectly; 0.5 means the system is guessing. Anonymization wants it high.
- Identification accuracy: how often the closest enrolled speaker is the
  right one (chance is 1 / speakers).
- WER (word error rate) of speech recognition against the dataset's
  transcripts. Intelligibility wants it close to the original's.
"""

import re

import jiwer
import numpy as np


def eer(scores, is_target):
    """Equal error rate of `scores` (higher means "same speaker") for trials
    whose truth is `is_target`. Interpolates between the two thresholds
    where the false-accept and false-reject rates cross."""
    scores = np.asarray(scores, dtype=float)
    is_target = np.asarray(is_target, dtype=bool)
    targets, nontargets = is_target.sum(), (~is_target).sum()
    if targets == 0 or nontargets == 0:
        raise ValueError("EER needs both target and non-target trials")

    # Sweep the threshold down through every score: accept everything at or
    # above it.
    order = np.argsort(-scores, kind="stable")
    hits = np.cumsum(is_target[order])
    false_accepts = np.cumsum(~is_target[order])
    far = np.concatenate([[0.0], false_accepts / nontargets])
    frr = np.concatenate([[1.0], 1.0 - hits / targets])

    # The first point where FAR >= FRR, and the one before it.
    crossing = int(np.argmax(far >= frr))
    if crossing == 0:
        return float(far[0])
    a, b = crossing - 1, crossing
    gap_a, gap_b = frr[a] - far[a], far[b] - frr[b]
    weight = gap_a / (gap_a + gap_b) if gap_a + gap_b > 0 else 0.5
    return float(far[a] + weight * (far[b] - far[a]))


def identification_accuracy(score_matrix, true_index):
    """`score_matrix[trial][speaker]`; the fraction of trials whose best
    score is their own speaker's."""
    best = np.argmax(np.asarray(score_matrix, dtype=float), axis=1)
    return float(np.mean(best == np.asarray(true_index)))


def normalize(text):
    """Lowercase words, no punctuation: LibriSpeech's transcripts and
    Whisper's output compared on the words alone."""
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    return " ".join(text.split())


def wer(references, hypotheses):
    """Word error rate over all utterances (corpus level)."""
    refs = [normalize(r) for r in references]
    hyps = [normalize(h) for h in hypotheses]
    return float(jiwer.wer(refs, hyps))
