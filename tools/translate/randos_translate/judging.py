"""The tone judges over every run (`cli score --scorer judge`): which
translations each judge sees, in rounds of finalists, with verdicts it
gave before reused (`scoring.JudgeCache`)."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from . import po, review, scoring
from .runs import note_scored, write_atomically


def judge(paths: list[Path], redo: bool, judges: list[str] | None, cache_path: Path) -> dict[str, int]:
    """The tone judges over every run at once, since what a judge must see
    depends on all the models' translations of a string: its candidates
    (`review.candidates`: those passing every check, or the stop-stripped
    fallback; a lone one too), of strings still in the template, and of those
    only the finalists (`review.to_judge`), in rounds until no string needs
    more. Each locale has its judges (`scoring.judges_for`), each filling
    its own score and choosing its own finalists; one is loaded at a time,
    and only when something isn't in the cache. MetricX and
    COMET-Kiwi must have scored first, or every passing translation is a
    finalist. A verdict already given for the same thing
    (`scoring.JudgeCache`) is reused; `--redo` judges them afresh. A
    judgement made with a context the template has since changed, or by
    another judge, counts as none. Saved after every locale of every
    round, so a stop loses little."""
    cache = scoring.JudgeCache(cache_path)
    contexts = scoring.current_contexts()
    runs = {path: data for path in paths if "entries" in (data := json.loads(path.read_text()))}
    # latest_entries copies each entry but shares its "scores" dict, so a
    # verdict set on the table lands in the run it came from.
    table = review.latest_entries(list(runs.values()), {s.key for s in po.sources()})
    owner = {id(e["scores"]): path for path, data in runs.items() for e in data["entries"]}
    judges = judges or list(scoring.JUDGES)
    if redo:
        # Afresh: an old verdict on a translation that isn't a finalist now
        # would still veto or break ties. Only these judges' verdicts: the
        # others' stand.
        for entries in table.values():
            for entry in entries.values():
                for score in (scoring.JUDGE_SCORES[name] for name in judges):
                    entry["scores"][score] = scoring.pending_scores()[score]
    counts = {path.name: 0 for path in runs}
    for name in judges:
        mine = {k: v for k, v in table.items() if name in scoring.judges_for(k[0])}
        if mine:
            _rounds(name, mine, runs, owner, cache, contexts, redo, counts)
    return counts


def _rounds(name, table, runs, owner, cache, contexts, redo, counts) -> None:
    """One judge's rounds over its locales' strings (`judge`)."""
    scorer, score = None, scoring.JUDGE_SCORES[name]
    tried: set[int] = set()
    given: dict[str, dict] = {}  # this session's verdicts, parsed or not, by JudgeCache.key

    def context(entry: dict) -> str:
        return scoring.judge_context(entry["msgctxt"], contexts.get(entry["key"], ""))

    def settled(entry: dict) -> bool:
        if id(entry["scores"]) in tried:
            return True
        verdict = entry["scores"].get(score) or {}
        # A rating counts for the text it was given (a stop-stripped
        # candidate's isn't the stored text's; verdicts from before this
        # carry no text and count as given for it).
        return (
            verdict.get("score") is not None
            and scoring.judged_context(entry, score) == context(entry)
            and verdict.get("text", entry["text"]) == entry["text"]
        )

    try:
        # What each string's pick chooses among (copies share their "scores").
        cands = {k: review.candidates(entries) for k, entries in table.items()}
        while due := [(loc, c[m]) for (loc, _key), c in cands.items() for m in review.to_judge(c, settled, score)]:
            for locale in sorted({loc for loc, _ in due}):
                mine = [e for loc, e in due if loc == locale]
                began = time.monotonic()
                # One judgement for each thing the judge would see (models often agree).
                keys = {id(e["scores"]): scoring.JudgeCache.key(locale, e, context(e), name) for e in mine}
                fresh = {}
                for e in mine:
                    if not cache.get(locale, e, context(e), name, only_new=redo):
                        fresh.setdefault(keys[id(e["scores"])], e)
                if fresh and scorer is None:
                    scorer = scoring.SCORERS["judge"](name)
                for key, verdict in zip(fresh, scorer.score(locale, list(fresh.values())) if fresh else []):
                    cache.put(locale, fresh[key], verdict)
                    given[key] = verdict
                seconds = time.monotonic() - began
                touched: dict[Path, int] = {}
                for e in mine:
                    verdict = given.get(keys[id(e["scores"])]) or cache.get(locale, e, context(e), name)
                    e["scores"][score] = verdict and verdict | {"text": e["text"]}
                    tried.add(id(e["scores"]))
                    touched[owner[id(e["scores"])]] = touched.get(owner[id(e["scores"])], 0) + 1
                for path, n in touched.items():
                    counts[path.name] += n
                    # The judging time, shared out by how many of each run's entries it judged.
                    note_scored(runs[path]["run"], score, seconds * n / len(mine))
                    write_atomically(path, runs[path])
                cache.save()
                print(
                    f"judge ({name}): {locale}: {len(fresh)} judged, "
                    f"{len(mine) - len(fresh)} from the cache or a twin, in {seconds:.0f} s",
                    file=sys.stderr,
                    flush=True,
                )
    finally:
        if scorer is not None and hasattr(scorer, "close"):
            scorer.close()
