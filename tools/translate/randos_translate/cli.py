"""The shootout's command line.

  uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
  uv run python -m randos_translate.cli fill results/<run>.json --locale es [--redo]
  uv run --group models python -m randos_translate.cli score --scorer metricx results/*.json
  uv run python -m randos_translate.cli review

`run` translates the source strings, back-translates them, runs every check
and score, and writes results/<model>-<date>.json (what the results page
is built from). It never touches the .po files. `score` runs one model-based scorer
(scoring.SCORERS) over runs already made, filling in its pending scores
(the judge last, given every run: it sees only the finalists, `judge`). `fill` writes one run's
translations into a locale's .po, filling only empty entries (`--redo`:
also entries the machine wrote and nobody has changed since).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import unicodedata
from datetime import UTC, datetime
from pathlib import Path

from . import checks, po, review, scoring
from . import models as contestants

RESULTS = Path(__file__).resolve().parents[1] / "results"
JUDGE_CACHE = RESULTS / "judge-cache.json"


def run(model_name: str, locales: list[str], limit: int | None, append: Path | None = None) -> Path:
    """Translates the template's strings into `locales`. With `append`, an
    earlier run of the same model: only the strings it lacks (the template
    changed since) and, for a model that takes context, those whose context
    changed, written into that file."""
    model = contestants.get(model_name)
    sources = po.sources()[:limit] if limit else po.sources()
    earlier = json.loads(append.read_text()) if append else None
    have: dict[tuple[str, str], str] = {}
    if earlier:
        if earlier["run"]["model"] != model_name:
            sys.exit(f"{append} is a run of {earlier['run']['model']}, not {model_name}")
        have = {(e["locale"], e["key"]): e.get("context", "") for e in earlier["entries"]}
    takes_context = getattr(model, "takes_context", False)

    def stale(locale: str, source: po.Source) -> bool:
        if (locale, source.key) not in have:
            return True
        return takes_context and have[(locale, source.key)] != source.context

    unsupported = [loc for loc in locales if loc not in model.locales]
    if unsupported:
        sys.exit(f"{model_name} has no pair wired for {unsupported} (wired: {model.locales})")

    entries, started = [], time.monotonic()
    for locale in locales:
        began = time.monotonic()
        todo = [s for s in sources if stale(locale, s)]
        texts = model.translate([s.msgid for s in todo], locale, [s.context for s in todo]) if todo else []
        texts = [contestants.tidy(s.msgid, t) for s, t in zip(todo, texts)]
        backs = model.back_translate(texts, locale) if todo else []
        print(f"{model_name}: {locale}: {len(texts)} strings in {time.monotonic() - began:.0f} s", file=sys.stderr, flush=True)
        for source, text, back in zip(todo, texts, backs):
            entries.append(
                {
                    "key": source.key,
                    "msgid": source.msgid,
                    "msgctxt": source.msgctxt,
                    "context": source.context if takes_context else "",
                    "locale": locale,
                    "text": text,
                    "back_translation": back,
                    "checks": checks.run_all(locale, source.msgid, text, button=source.msgctxt == "button"),
                    "scores": {"chrf": scoring.back_translation_chrf(source.msgid, back)} | scoring.pending_scores(),
                }
            )

    seconds = round(time.monotonic() - started, 1)
    if earlier:
        keys, redone = {s.key for s in sources}, {(e["locale"], e["key"]) for e in entries}
        kept = [e for e in earlier["entries"] if e["key"] in keys and (e["locale"], e["key"]) not in redone]
        entries = kept + entries
        # New locales join the run's list (and its summary).
        locales = earlier["run"]["locales"] + [loc for loc in locales if loc not in earlier["run"]["locales"]]

    summary = {}
    for locale in locales:
        mine = [e for e in entries if e["locale"] == locale]
        summary[locale] = {
            "strings": len(mine),
            "all_checks_pass": sum(all(c["ok"] for c in e["checks"].values()) for e in mine),
            "failed": {
                name: sum(not e["checks"][name]["ok"] for e in mine) for name in mine[0]["checks"]
            }
            if mine
            else {},
            "mean_chrf": round(sum(e["scores"]["chrf"] for e in mine) / len(mine), 1) if mine else None,
        }

    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    RESULTS.mkdir(exist_ok=True)
    meta = {"model": model_name, "locales": locales, "strings": len(sources), "at": stamp, "seconds": seconds}
    if earlier:
        # The first run's time stays (it's the comparable one); top-ups are noted.
        meta |= {k: v for k, v in earlier["run"].items() if k in ("seconds", "scored")}
        meta["appended"] = earlier["run"].get("appended", []) + [{"at": stamp, "seconds": seconds}]
    out = append or RESULTS / f"{model_name}-{stamp}.json"
    out.write_text(
        json.dumps(
            {
                "run": meta,
                "summary": summary,
                "entries": entries,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )
    return out


def score(scorer_name: str, paths: list[Path], redo: bool) -> dict[str, int]:
    """Fills in one scorer's scores in each results file, locale by locale
    (the judge: `judge`)."""
    if scorer_name == "judge":
        return judge(paths, redo)
    scorer = scoring.SCORERS[scorer_name]()
    counts = {}
    for path in paths:
        data = json.loads(path.read_text())
        if "entries" not in data:  # the summary, not a run
            continue
        todo = [e for e in data["entries"] if redo or (e["scores"].get(scorer_name) or {}).get("score") is None]
        for locale in sorted({e["locale"] for e in todo}):
            mine = [e for e in todo if e["locale"] == locale]
            began = time.monotonic()
            for entry, result in zip(mine, scorer.score(locale, mine)):
                entry["scores"][scorer_name] = result
            seconds = time.monotonic() - began
            # Saved after every locale, so a stopped run (the judge takes
            # hours) resumes with the next one: the time adds up across runs.
            done = data["run"].setdefault("scored", {}).get(scorer_name, {})
            data["run"]["scored"][scorer_name] = {
                "at": datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ"),
                "seconds": round(done.get("seconds", 0) + seconds, 1),
            }
            _write_atomically(path, data)
            print(f"{scorer_name}: {path.name}: {locale}: {len(mine)} scored in {seconds:.0f} s", file=sys.stderr, flush=True)
        counts[path.name] = len(todo)
        print(f"{scorer_name}: {path.name}: {len(todo)} scored", file=sys.stderr, flush=True)
    return counts


def judge(paths: list[Path], redo: bool) -> dict[str, int]:
    """The tone judges over every run at once, since what a judge must see
    depends on all the models' translations of a string: only the ones
    passing every check, of strings still in the template, and of those
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
    cache = scoring.JudgeCache(JUDGE_CACHE)
    contexts = scoring.current_contexts()
    runs = {path: data for path in paths if "entries" in (data := json.loads(path.read_text()))}
    # latest_entries copies each entry but shares its "scores" dict, so a
    # verdict set on the table lands in the run it came from.
    table = review.latest_entries(list(runs.values()), {s.key for s in po.sources()})
    owner = {id(e["scores"]): path for path, data in runs.items() for e in data["entries"]}
    if redo:
        # Afresh: an old verdict on a translation that isn't a finalist now
        # would still veto or break ties.
        for entries in table.values():
            for entry in entries.values():
                for score in scoring.JUDGE_SCORES.values():
                    entry["scores"][score] = scoring.pending_scores()[score]
    counts = {path.name: 0 for path in runs}
    for name in scoring.JUDGES:
        mine = {k: v for k, v in table.items() if name in scoring.judges_for(k[0])}
        if mine:
            _judge_rounds(name, mine, runs, owner, cache, contexts, redo, counts)
    return counts


def _judge_rounds(name, table, runs, owner, cache, contexts, redo, counts) -> None:
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
        return verdict.get("score") is not None and scoring.judged_context(entry, score) == context(entry)

    try:
        while due := [
            (loc, entries[m]) for (loc, _key), entries in table.items() for m in review.to_judge(entries, settled, score)
        ]:
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
                    e["scores"][score] = given.get(keys[id(e["scores"])]) or cache.get(locale, e, context(e), name)
                    tried.add(id(e["scores"]))
                    touched[owner[id(e["scores"])]] = touched.get(owner[id(e["scores"])], 0) + 1
                for path, n in touched.items():
                    counts[path.name] += n
                    # The judging time, shared out by how many of each run's entries it judged.
                    done = runs[path]["run"].setdefault("scored", {}).get(score, {})
                    runs[path]["run"]["scored"][score] = {
                        "at": datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ"),
                        "seconds": round(done.get("seconds", 0) + seconds * n / len(mine), 1),
                    }
                    _write_atomically(path, runs[path])
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


def _write_atomically(path: Path, data: dict) -> None:
    """A temp file beside it, then a rename: a stop mid-write never leaves
    half a results file."""
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.replace(tmp, path)


def fill(results: Path, locale: str, redo: bool) -> dict[str, int]:
    data = json.loads(results.read_text())
    # The checks run again, as in review, so an improved check applies to an old run.
    translations = {
        e["key"]: e["text"]
        for e in data["entries"]
        if e["locale"] == locale
        and all(
            c["ok"] for c in checks.run_all(locale, e["msgid"], e["text"], button=e["msgctxt"] == "button").values()
        )
    }
    return po.fill(locale, translations, data["run"]["model"], redo=redo)


def tidy(paths: list[Path]) -> dict[str, int]:
    """Applies `models.tidy` to the outputs of runs made before it (or one
    of its rules) existed; `run` applies it to every new one."""
    counts = {}
    for path in paths:
        data = json.loads(path.read_text())
        if "entries" not in data:
            continue
        changed = 0
        for entry in data["entries"]:
            fixed = contestants.tidy(entry["msgid"], entry["text"])
            if fixed != entry["text"]:
                entry["text"], changed = fixed, changed + 1
        if changed:
            _write_atomically(path, data)
        counts[path.name] = changed
    return counts


def fill_best(locale: str, redo: bool, results: Path = RESULTS) -> dict[str, int]:
    """Fills the locale string by string with each string's pick (review.json's
    "best", `review.pick`), recording which model wrote each one."""
    data = json.loads((results / "review.json").read_text())
    rows = [r for r in data["locales"][locale]["strings"] if r["best"]]
    translations = {r["key"]: r["translations"][r["best"]]["text"] for r in rows}
    return po.fill(locale, translations, {r["key"]: r["best"] for r in rows}, redo=redo)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="randos_translate")
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--locales", required=True, help="comma-separated, e.g. es,fr")
    r.add_argument("--limit", type=int, help="only the first N strings (for a quick proof)")
    r.add_argument("--append", type=Path, help="an earlier run of this model: translate only the strings it lacks")
    f = sub.add_parser("fill")
    f.add_argument("results", type=Path, nargs="?", help="one run to fill from (without --best)")
    f.add_argument("--best", action="store_true", help="each string's pick from results/review.json")
    f.add_argument("--locale", required=True, help="a locale, or all")
    f.add_argument("--redo", action="store_true")
    s = sub.add_parser("score", help="run one model-based scorer over results files")
    s.add_argument("--scorer", required=True, choices=sorted(scoring.SCORERS))
    s.add_argument("results", type=Path, nargs="+")
    s.add_argument("--redo", action="store_true", help="also rescore entries that already have a score")
    b = sub.add_parser("tidy", help="apply models.tidy (brand case, ellipsis, placeholders, NFC) to runs made before it")
    b.add_argument("results", type=Path, nargs="+")
    sub.add_parser(
        "review", help="combine results/*.json into results/review.json (the review page's data) and shootout-summary.json"
    )
    args = parser.parse_args(argv)

    if args.command == "run":
        print(run(args.model, args.locales.split(","), args.limit, args.append))
    elif args.command == "score":
        print(score(args.scorer, [p for p in args.results if p.name != "review.json"], args.redo))
    elif args.command == "tidy":
        print(tidy(args.results))
    elif args.command == "review":
        print(review.write(RESULTS))
        print(review.write_summary(RESULTS))
    else:
        locales = po.LOCALES if args.locale == "all" else [args.locale]
        if not args.best and not args.results:
            parser.error("fill needs a results file, or --best")
        for locale in locales:
            counts = fill_best(locale, args.redo) if args.best else fill(args.results, locale, args.redo)
            print(locale, counts)


if __name__ == "__main__":
    main()
