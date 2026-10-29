"""Paired, deterministic scoring for known-parameter and search attackers."""

import random

import numpy as np

from randos_voice_eval import metrics


def configuration(key, how, call_id):
    """A call's setting stays fixed, independent of iteration/subset order."""
    return how(random.Random(f"randos-voice-eval:{key}:{call_id}"))


def prototypes(enrollment, speakers):
    vectors = np.stack([np.mean(enrollment[s], axis=0) for s in speakers])
    return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)


def summarize(matrix, trial_speakers, speakers):
    """Identical score construction for genuine and impostor comparisons."""
    matrix = np.asarray(matrix)
    truth = np.array([speakers.index(s) for s in trial_speakers])
    labels = np.arange(len(speakers))[None, :] == truth[:, None]
    return metrics.eer(matrix.ravel(), labels.ravel()), metrics.identification_accuracy(matrix, truth)


def bank_scores(trial_vectors, reference_banks):
    """Keep parameter-specific prototypes separate, maximizing each speaker's
    score. Averaging differently transformed enrollment weakens an attacker."""
    trials = np.asarray(trial_vectors)
    return np.stack([np.max(trials @ bank.T, axis=1) for bank in reference_banks], axis=1)


def verification(enrollment, trial_vectors, trial_speakers, speakers):
    models = prototypes(enrollment, speakers)
    matrix = np.stack([np.max(np.atleast_2d(t) @ models.T, axis=0) for t in trial_vectors])
    return summarize(matrix, trial_speakers, speakers)
