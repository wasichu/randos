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
  It needs at least two scorers with scores (only back-translation chrF
  runs today, so none conflict yet);
- **best**: among translations that pass every check, the one with the
  best mean rank across the scorers that ran;
- per locale, the **winner**: the model passing every check most often,
  then the best mean rank.

The latest run wins when a model translated the same string for the same
locale more than once. The checks are run again here (they're cheap and
need no model), so a check improved since a run applies to it too.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from itertools import combinations
from pathlib import Path

from sacrebleu.metrics import CHRF

from . import checks, po

# Which way each score points (MetricX is an error score: lower is better).
SCORERS = {
    "chrf": {"label": "Back-translation chrF", "higher_is_better": True},
    "metricx": {"label": "MetricX-24", "higher_is_better": False},
    "comet_kiwi": {"label": "COMET-Kiwi", "higher_is_better": True},
    "judge": {"label": "Tone judge", "higher_is_better": True},
}

_chrf = CHRF()


def _score(entry: dict, scorer: str) -> float | None:
    value = entry["scores"].get(scorer)
    return value.get("score") if isinstance(value, dict) else value


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


def ranks(entries: dict[str, dict]) -> dict[str, dict[str, int]]:
    """scorer -> model -> rank (1 is best), for the scorers that scored every model."""
    out = {}
    for scorer, meta in SCORERS.items():
        scores = {model: _score(e, scorer) for model, e in entries.items()}
        if len(scores) < 2 or any(s is None for s in scores.values()):
            continue
        ordered = sorted(scores, key=lambda m: scores[m], reverse=meta["higher_is_better"])
        out[scorer] = {model: ordered.index(model) + 1 for model in scores}
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


def _mean_rank(model: str, scorer_ranks: dict[str, dict[str, int]]) -> float:
    mine = [r[model] for r in scorer_ranks.values()]
    return sum(mine) / len(mine) if mine else float("inf")


def _passes(entry: dict) -> bool:
    return all(c["ok"] for c in entry["checks"].values())


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
        passing = [m for m, e in entries.items() if _passes(e)]
        best = min(passing, key=lambda m: _mean_rank(m, scorer_ranks)) if passing and scorer_ranks else None
        row = {
            "key": first["key"],
            "msgid": first["msgid"],
            "msgctxt": first["msgctxt"],
            "disagreement": disagreement([e["text"] for e in entries.values()]),
            "conflict": conflict(scorer_ranks),
            "best": best,
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
        "generated_at": datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ"),
        "runs": [
            {k: r["run"][k] for k in ("model", "locales", "strings", "at")}
            for r in sorted(runs, key=lambda r: r["run"]["at"])
        ],
        "scorers": SCORERS,
        "locales": dict(sorted(locales.items())),
    }


def _winner(summary: dict[str, dict]) -> dict | None:
    if len(summary) < 2:
        return None

    def share(m):
        return summary[m]["all_checks_pass"] / max(summary[m]["strings"], 1)

    def rank(m):
        r = summary[m]["mean_rank"]
        return r if r is not None else float("inf")

    model = sorted(summary, key=lambda m: (-share(m), rank(m)))[0]
    return {
        "model": model,
        "why": f"passes every check on {summary[model]['all_checks_pass']}/{summary[model]['strings']} strings, "
        f"mean rank {summary[model]['mean_rank']}",
    }


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
