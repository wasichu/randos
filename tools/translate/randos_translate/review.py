"""Combines the runs in results/ into results/review.json, the file the
review page (`/dev/translations`, `RandosDev.TranslationReviewLive`) shows.

For each locale and string it puts every model's translation side by side
and works out:

- **disagreement** (0 to 1): how differently the models translated it, as
  1 - the mean pairwise chrF between their translations (in both
  directions, since chrF isn't symmetric). Strings are sorted by it, so
  the ones to look at come first;
- **evaluator conflict**: whether the scorers disagree on which model did
  best, i.e. some model is ranked first by one scorer and last by another.
  It needs at least two scorers with scores;
- **best**: the translation that ships (`pick`): among those passing every
  check, the best mean rank over MetricX and COMET-Kiwi, the judge breaking
  ties; `fill --best` writes these, string by string. When nothing
  passes only because of a final full stop the English lacks, the best of
  those with it removed (`candidates`). A lone candidate either judge
  rates at the veto line or below ships nothing (the English shows);
- per locale, the **winner**: only a summary now, the model picked for the
  most strings.

The latest run wins when a model translated the same string for the same
locale more than once. The checks are run again here (they're cheap and
need no model), so a check improved since a run applies to it too.
"""

from __future__ import annotations

import json
from itertools import combinations
from pathlib import Path

from sacrebleu.metrics import CHRF

from . import checks, po
from .runs import stamp
from .scoring import JUDGE_SCORES

# Which way each score points (MetricX is an error score: lower is better).
SCORERS = {
    "chrf": {"label": "Back-translation chrF", "higher_is_better": True},
    "metricx": {"label": "MetricX-24", "higher_is_better": False},
    "comet_kiwi": {"label": "COMET-Kiwi", "higher_is_better": True},
    "judge": {"label": "Tone judge (Mistral)", "higher_is_better": True},
    "judge_qwen": {"label": "Tone judge (Qwen)", "higher_is_better": True},
}
# The judges' scores (`scoring.JUDGE_SCORES`): either can veto, and their
# mean breaks ties.
JUDGES = tuple(JUDGE_SCORES.values())

_chrf = CHRF()


def _score(entry: dict, scorer: str) -> float | None:
    value = entry["scores"].get(scorer)
    return value.get("score") if isinstance(value, dict) else value


def _judged(entry: dict) -> float | None:
    """The mean of the judges' ratings that an entry has, or None."""
    scores = [s for j in JUDGES if (s := _score(entry, j)) is not None]
    return sum(scores) / len(scores) if scores else None


def similarity(a: str, b: str) -> float:
    """Mean chrF of a against b and b against a, from 0 to 1."""
    if not a and not b:
        return 1.0
    return (_chrf.sentence_score(a, [b]).score + _chrf.sentence_score(b, [a]).score) / 200


def disagreement(texts: list[str]) -> float:
    pairs = list(combinations(texts, 2))
    if not pairs:
        return 0.0
    return round(1 - sum(similarity(a, b) for a, b in pairs) / len(pairs), 3)


def ranks(entries: dict[str, dict]) -> dict[str, dict[str, float]]:
    """scorer -> model -> rank (1 is best, ties averaged), for the scorers
    that scored every model."""
    out = {}
    for scorer, meta in SCORERS.items():
        scores = {model: _score(e, scorer) for model, e in entries.items()}
        if len(scores) < 2 or any(s is None for s in scores.values()):
            continue
        out[scorer] = average_ranks(scores, meta["higher_is_better"])
    return out


def conflict(scorer_ranks: dict[str, dict[str, int]]) -> dict | None:
    """Some model ranked first by one scorer and last by another."""
    if len(scorer_ranks) < 2:
        return None
    for model in next(iter(scorer_ranks.values())):
        last = len(next(iter(scorer_ranks.values())))
        firsts = [s for s, r in scorer_ranks.items() if r[model] == 1]
        lasts = [s for s, r in scorer_ranks.items() if r[model] == last]
        if firsts and lasts:
            return {"model": model, "first_by": firsts, "last_by": lasts}
    return None


def _passes(entry: dict) -> bool:
    return all(c["ok"] for c in entry["checks"].values())


# The two independent quality estimators decide, with equal weight; the
# judge's 1-10 is too coarse to lead, so it breaks their ties, or stands in
# beside MetricX when COMET-Kiwi has no score. MetricX alone never decides:
# TranslateGemma was trained against it (translation_models.md).
QUALITY = ("metricx", "comet_kiwi")


def average_ranks(scores: dict[str, float], higher_is_better: bool) -> dict[str, float]:
    """model -> rank (1 is best); tied scores share the mean of their places,
    so no model wins a tie by its name."""
    ordered = sorted(scores.values(), reverse=higher_is_better)
    places: dict[float, list[int]] = {}
    for place, value in enumerate(ordered, start=1):
        places.setdefault(value, []).append(place)
    return {model: sum(places[v]) / len(places[v]) for model, v in scores.items()}


def candidates(entries: dict[str, dict]) -> dict[str, dict]:
    """The translations of one string `pick` chooses among and the judges
    see (`to_judge`): those passing every check; when none does, those
    whose one fault was a final full stop the English lacks, with it
    removed (`_without_final_stops`)."""
    passing = {m: e for m, e in entries.items() if _passes(e)}
    if passing:
        return passing
    return {m: e for m, e in _without_final_stops(entries).items() if _passes(e)}


def pick(entries: dict[str, dict]) -> dict | None:
    """The translation of one string to ship: among the `candidates`, the
    best mean rank over MetricX and COMET-Kiwi (ranked among them only);
    ties go to the judge's rank, then back-translation chrF, then the
    shorter text, then the text itself (never the model's name). None when
    there is no candidate, or the only one is one a judge rates at the veto
    line or below (`VETO_AT_MOST`): with nothing to compare it to, that
    rating alone decides ("rando 无法找到页面", "rando: page not found",
    for "not looking for a rando")."""
    passing = candidates(entries)
    if not passing:
        return None
    vetoed = _vetoed(passing)
    # Each judge vetoing the other's favourite can leave nothing: they all
    # passed every check and the judges simply disagree, so no veto stands.
    vetoed = vetoed if len(vetoed) < len(passing) else set()
    passing = {m: e for m, e in passing.items() if m not in vetoed}
    if len(passing) == 1 and vetoed:
        model = next(iter(passing))
        return {"model": model, "why": f"the only one left after the judge's veto of {', '.join(sorted(vetoed))}"}
    if len(passing) == 1:
        model, only = next(iter(passing.items()))
        if any((s := _score(only, judge)) is not None and s <= VETO_AT_MOST for judge in JUDGES):
            return None
        return {"model": model, "why": "the only translation passing every check"}

    def ranked(scorer: str) -> dict[str, float] | None:
        scores = {m: _score(e, scorer) for m, e in passing.items()}
        if any(s is None for s in scores.values()):
            return None
        return average_ranks(scores, SCORERS[scorer]["higher_is_better"])

    deciding = {s: r for s in QUALITY if (r := ranked(s)) is not None}
    if set(deciding) == {"metricx"}:
        judged = {m: _judged(e) for m, e in passing.items()}
        judge = None if None in judged.values() else average_ranks(judged, True)
        deciding = {"metricx": deciding["metricx"], "judge": judge} if judge else {}
    tiebreak = _judge_ranks(passing)

    def key(m: str) -> tuple:
        primary = sum(r[m] for r in deciding.values()) / len(deciding) if deciding else 0
        chrf = _score(passing[m], "chrf") or 0
        return (primary, tiebreak[m], -chrf, len(passing[m]["text"]), passing[m]["text"])

    model = min(passing, key=key)
    by = " and ".join(SCORERS[s]["label"] for s in deciding) or "the tie-breaks alone"
    veto = f", after the judge's veto of {', '.join(sorted(vetoed))}" if vetoed else ""
    return {"model": model, "why": f"best of {len(passing)} passing translations by {by}{veto}"}


# The judge sees each string's context, which MetricX and COMET-Kiwi don't:
# a translation it rates this low ("Lenguaje" for the interface "Language")
# is dropped when it rates another this high ("Idioma").
VETO_AT_MOST, VETO_IF_ANOTHER_AT_LEAST = 4, 7


def _vetoed(passing: dict[str, dict]) -> set[str]:
    """The passing translations a judge vetoes: either judge, each on its
    own ratings. Only judged ones count on either side: a missing
    judgement never vetoes, nor is vetoed."""
    vetoed: set[str] = set()
    for judge in JUDGES:
        judged = {m: s for m, e in passing.items() if (s := _score(e, judge)) is not None}
        if any(s >= VETO_IF_ANOTHER_AT_LEAST for s in judged.values()):
            vetoed |= {m for m, s in judged.items() if s <= VETO_AT_MOST}
    return vetoed


def _judge_ranks(passing: dict[str, dict]) -> dict[str, float]:
    """The judge's ranks among the judged translations; the unjudged ones
    (the judge sees only finalists, `to_judge`) rank after them. They are
    never tied with a winner on MetricX and COMET-Kiwi, so it only matters
    among those the judge saw."""
    judged = {m: s for m, e in passing.items() if (s := _judged(e)) is not None}
    ranked = average_ranks(judged, True) if judged else {}
    return {m: ranked.get(m, len(judged) + 1) for m in passing}


def to_judge(entries: dict[str, dict], settled, judge: str) -> list[str]:
    """The models whose translation of one string the judge must see next
    for `pick` to come out as if it had judged them all (`settled(entry)`:
    judged already, or tried). `entries` are the string's `candidates`; a
    lone one is judged too (a low rating vetoes it). With MetricX and COMET-Kiwi for every one, the
    finalists, best mean rank first, a tied group at a time: it stops at
    the first group holding one rated above the veto (it can't be vetoed),
    unless one rated at or below it came before and nothing yet rates high
    enough to veto it. Without them the judge stands in beside MetricX, so
    all of them. `judge` is the score of the judge in question: each judge
    finds its own finalists, so each can veto as if it judged alone."""
    passing = {m: e for m, e in entries.items() if _passes(e)}
    if len(passing) < 2:
        return [m for m, e in passing.items() if not settled(e)]
    if any(_score(e, s) is None for e in passing.values() for s in QUALITY):
        return sorted(m for m, e in passing.items() if not settled(e))
    primary: dict[str, float] = {m: 0 for m in passing}
    for scorer in QUALITY:
        ranked = average_ranks({m: _score(e, scorer) for m, e in passing.items()}, SCORERS[scorer]["higher_is_better"])
        primary = {m: primary[m] + ranked[m] for m in passing}
    low_before = high_seen = False
    for rank in sorted(set(primary.values())):
        group = sorted(m for m in passing if primary[m] == rank)
        if due := [m for m in group if not settled(passing[m])]:
            return due
        scores = [_score(passing[m], judge) for m in group]
        high_seen = high_seen or any(s is not None and s >= VETO_IF_ANOTHER_AT_LEAST for s in scores)
        if any(s is None or s > VETO_AT_MOST for s in scores) and (not low_before or high_seen):
            return []
        low_before = low_before or any(s is not None and s <= VETO_AT_MOST for s in scores)
    return []


def _without_final_stops(entries: dict[str, dict]) -> dict[str, dict]:
    """`candidates`' fallback when no translation of a string passes: each one
    with a final full stop the English lacks removed and checked again
    (`checks.without_final_stop`), so only those whose one fault was that
    stop can pass. Every model ended these Japanese and Korean clauses with
    "。" or "다."; English leaves a status line bare. The judges never saw
    them (they see only passing ones), so MetricX and COMET-Kiwi decide."""
    out = {}
    for model, e in entries.items():
        text = checks.without_final_stop(e["msgid"], e["text"])
        if text != e["text"]:
            current = checks.run_all(e["locale"], e["msgid"], text, button=e["msgctxt"] == "button")
            out[model] = e | {"text": text, "checks": current}
    return out


def latest_entries(runs: list[dict], keys: set[str] | None = None) -> dict[tuple[str, str], dict[str, dict]]:
    """(locale, key) -> model -> entry, the latest run winning; with `keys`,
    only those strings (the template's current ones)."""
    table: dict[tuple[str, str], dict[str, dict]] = {}
    for run in sorted(runs, key=lambda r: r["run"]["at"]):
        for entry in run["entries"]:
            if keys is not None and entry["key"] not in keys:
                continue
            current = checks.run_all(
                entry["locale"], entry["msgid"], entry["text"], button=entry["msgctxt"] == "button"
            )
            table.setdefault((entry["locale"], entry["key"]), {})[run["run"]["model"]] = entry | {"checks": current}
    return table


def build(runs: list[dict], keys: set[str] | None = None) -> dict:
    table = latest_entries(runs, keys)
    locales: dict[str, dict] = {}

    for (locale, _key), entries in table.items():
        scorer_ranks = ranks(entries)
        first = next(iter(entries.values()))
        chosen, shipped = pick(entries), candidates(entries)
        if chosen and shipped[chosen["model"]]["text"] != entries[chosen["model"]]["text"]:
            chosen["why"] += ", with the final full stop the English lacks removed (none passed with it)"
        row = {
            "key": first["key"],
            "msgid": first["msgid"],
            "msgctxt": first["msgctxt"],
            "disagreement": disagreement([e["text"] for e in entries.values()]),
            "conflict": conflict(scorer_ranks),
            "best": chosen and chosen["model"],
            "best_why": chosen and chosen["why"],
            # What ships: the pick's text, or its fallback's (no final stop).
            "best_text": chosen and shipped[chosen["model"]]["text"],
            "translations": {
                model: {
                    "text": e["text"],
                    "back_translation": e["back_translation"],
                    "failed": [{"check": name, "detail": c["detail"]} for name, c in e["checks"].items() if not c["ok"]],
                    "scores": {s: _score(e, s) for s in SCORERS},
                    "ranks": {s: r[model] for s, r in scorer_ranks.items()},
                }
                for model, e in sorted(entries.items())
            },
        }
        locales.setdefault(locale, {"strings": []})["strings"].append(row)

    for locale, data in locales.items():
        rows = data["strings"]
        rows.sort(key=lambda r: (-r["disagreement"], r["msgid"]))
        models = sorted({m for r in rows for m in r["translations"]})
        summary = {}
        for model in models:
            mine = [r["translations"][model] for r in rows if model in r["translations"]]
            chrfs = [t["scores"]["chrf"] for t in mine if t["scores"]["chrf"] is not None]
            all_ranks = [rank for t in mine for rank in t["ranks"].values()]
            summary[model] = {
                "strings": len(mine),
                "all_checks_pass": sum(not t["failed"] for t in mine),
                "mean_chrf": round(sum(chrfs) / len(chrfs), 1) if chrfs else None,
                "mean_rank": round(sum(all_ranks) / len(all_ranks), 2) if all_ranks else None,
                "best_count": sum(r["best"] == model for r in rows),
            }
        data["models"] = models
        data["summary"] = summary
        data["winner"] = _winner(summary)
    return {
        "generated_at": stamp(),
        "runs": [
            {k: r["run"][k] for k in ("model", "locales", "strings", "at")}
            for r in sorted(runs, key=lambda r: r["run"]["at"])
        ],
        "scorers": SCORERS,
        "locales": dict(sorted(locales.items())),
    }


def _winner(summary: dict[str, dict]) -> dict | None:
    """The model picked for the most strings (a summary: each string ships
    its own pick, `pick`)."""
    if len(summary) < 2:
        return None
    model = max(summary, key=lambda m: (summary[m]["best_count"], summary[m]["all_checks_pass"]))
    picked = sum(s["best_count"] for s in summary.values())
    return {"model": model, "why": f"picked for {summary[model]['best_count']} of the {picked} strings filled"}


def _runs(results: Path) -> list[dict]:
    """Every run in results/ (review.json and the summary aren't runs)."""
    files = (json.loads(p.read_text()) for p in sorted(results.glob("*.json")))
    return [data for data in files if "entries" in data]


def write(results: Path) -> Path:
    out = results / "review.json"
    # Strings dropped from the template since a run don't count.
    keys = {s.key for s in po.sources()}
    out.write_text(json.dumps(build(_runs(results), keys), ensure_ascii=False, indent=2) + "\n")
    return out


def _mean(values: list) -> float | None:
    values = [v for v in values if v is not None]
    return round(sum(values) / len(values), 3) if values else None


def write_summary(results: Path) -> Path:
    """results/review.json -> results/shootout-summary.json: each locale's
    winner, and per model the pass count, mean rank and mean of every
    score; plus each shootout run's timings."""
    review = json.loads((results / "review.json").read_text())
    # Each model's latest run (the one review uses).
    runs = {
        r["run"]["model"]: {k: r["run"].get(k) for k in ("at", "seconds", "locales", "appended", "scored")}
        for r in sorted(_runs(results), key=lambda r: r["run"]["at"])
    }
    locales = {}
    for locale, data in review["locales"].items():
        models = {}
        for model in data["models"]:
            mine = [row["translations"][model] for row in data["strings"] if model in row["translations"]]
            means = {f"mean_{s}": _mean([t["scores"].get(s) for t in mine]) for s in SCORERS if s != "chrf"}
            models[model] = data["summary"][model] | means
        locales[locale] = {"winner": data["winner"], "models": models}
    out = results / "shootout-summary.json"
    summary = {"generated_at": review["generated_at"], "runs": runs, "locales": locales}
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return out
