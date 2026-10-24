"""The shootout's command line.

  uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
  uv run python -m randos_translate.cli fill results/<run>.json --locale es [--redo]
  uv run --group models python -m randos_translate.cli score --scorer metricx results/*.json
  uv run python -m randos_translate.cli review
  uv run python -m randos_translate.cli plan


`run` translates the source strings, back-translates them, runs every check
and score, and writes results/<model>-<date>.json (what the results page
is built from). It never touches the .po files. `score` runs one model-based scorer
(scoring.SCORERS) over runs already made, filling in its pending scores
(the judge last, given every run: it sees only the finalists, `judge`). `fill` writes one run's
translations into a locale's .po, filling only empty entries (`--redo`:
also entries the machine wrote and nobody has changed since). `plan` lists
the shootout runs the template has outgrown, for `just translate-update`.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from . import checks, judging, po, review, scoring
from . import models as contestants
from .runs import note_scored, stamp, write_atomically

RESULTS_ROOT = Path(__file__).resolve().parents[1] / "results"
# One catalog's runs and review (`--catalog`: the site's here, others in a
# folder of their own); the judge's verdicts are shared (keyed by all it saw).
RESULTS = RESULTS_ROOT
JUDGE_CACHE = RESULTS_ROOT / "judge-cache.json"


def shootout_runs() -> list[Path]:
    """The catalog's shootout: one run per model (results/shootout-<model>.json)."""
    return sorted(p for p in RESULTS.glob("shootout-*.json") if p.name != "shootout-summary.json")


def stale(earlier: dict | None, sources: list[po.Source], locale: str, takes_context: bool) -> list[po.Source]:
    """The sources an earlier run (None: there is none) lacks in `locale`,
    and for a model that takes context, those whose context changed since."""
    if earlier is None:
        return list(sources)
    have = {e["key"]: e.get("context", "") for e in earlier["entries"] if e["locale"] == locale}
    return [s for s in sources if s.key not in have or (takes_context and have[s.key] != s.context)]


def plan() -> list[tuple[str, str, list[str], Path, int]]:
    """Each shootout run with strings to top up (`run --append`): its
    model's uv group, the model, its locales, the run, how many strings.
    No model is loaded."""
    sources, todo = po.sources(), []
    for path in shootout_runs():
        data = json.loads(path.read_text())
        model, locales = data["run"]["model"], data["run"]["locales"]
        count = sum(len(stale(data, sources, loc, contestants.takes_context(model))) for loc in locales)
        if count:
            todo.append((contestants.uv_group(model), model, locales, path, count))
    return todo


def run(model_name: str, locales: list[str], limit: int | None, append: Path | None = None) -> Path:
    """Translates the template's strings into `locales`. With `append`, an
    earlier run of the same model: only the strings it lacks (the template
    changed since) and, for a model that takes context, those whose context
    changed, written into that file."""
    model = contestants.get(model_name)
    sources = po.sources()[:limit] if limit else po.sources()
    earlier = json.loads(append.read_text()) if append else None
    if earlier and earlier["run"]["model"] != model_name:
        sys.exit(f"{append} is a run of {earlier['run']['model']}, not {model_name}")
    takes_context = getattr(model, "takes_context", False)

    unsupported = [loc for loc in locales if loc not in model.locales]
    if unsupported:
        sys.exit(f"{model_name} has no pair wired for {unsupported} (wired: {model.locales})")

    entries, started = [], time.monotonic()
    for locale in locales:
        began = time.monotonic()
        todo = stale(earlier, sources, locale, takes_context)
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

    at = stamp()
    RESULTS.mkdir(exist_ok=True)
    meta = {"model": model_name, "locales": locales, "strings": len(sources), "at": at, "seconds": seconds}
    if earlier:
        # The first run's time stays (it's the comparable one); top-ups are noted.
        meta |= {k: v for k, v in earlier["run"].items() if k in ("seconds", "scored")}
        meta["appended"] = earlier["run"].get("appended", []) + [{"at": at, "seconds": seconds}]
    out = append or RESULTS / f"{model_name}-{at}.json"
    # Atomically: with `append`, it rewrites a run that took hours.
    write_atomically(out, {"run": meta, "summary": summary, "entries": entries})
    return out


def score(scorer_name: str, paths: list[Path], redo: bool, judges: list[str] | None = None) -> dict[str, int]:
    """Fills in one scorer's scores in each results file, locale by locale
    (the judge: `judge`, all its judges or only `judges`). The scorer's
    model is loaded only when something needs it."""
    if scorer_name == "judge":
        return judging.judge(paths, redo, judges, JUDGE_CACHE)
    scorer, counts = None, {}
    for path in paths:
        data = json.loads(path.read_text())
        if "entries" not in data:  # the summary, not a run
            continue
        todo = [e for e in data["entries"] if redo or (e["scores"].get(scorer_name) or {}).get("score") is None]
        for locale in sorted({e["locale"] for e in todo}):
            mine = [e for e in todo if e["locale"] == locale]
            began = time.monotonic()
            if scorer is None:
                scorer = scoring.SCORERS[scorer_name]()
            for entry, result in zip(mine, scorer.score(locale, mine)):
                entry["scores"][scorer_name] = result
            seconds = time.monotonic() - began
            # Saved after every locale, so a stopped run (the judge takes
            # hours) resumes with the next one: the time adds up across runs.
            note_scored(data["run"], scorer_name, seconds)
            write_atomically(path, data)
            print(f"{scorer_name}: {path.name}: {locale}: {len(mine)} scored in {seconds:.0f} s", file=sys.stderr, flush=True)
        counts[path.name] = len(todo)
        print(f"{scorer_name}: {path.name}: {len(todo)} scored", file=sys.stderr, flush=True)
    return counts


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
            write_atomically(path, data)
        counts[path.name] = changed
    return counts


def use_catalog(catalog: str) -> None:
    """Every command works on one catalog's strings (`po.CATALOGS`)."""
    global RESULTS
    po.use(catalog)
    RESULTS = RESULTS_ROOT if catalog == "site" else RESULTS_ROOT / catalog
    RESULTS.mkdir(parents=True, exist_ok=True)


def fill_best(locale: str, redo: bool, results: Path | None = None) -> dict[str, int]:
    """Fills the locale string by string with each string's pick (review.json's
    "best", `review.pick`), recording which model wrote each one."""
    data = json.loads(((results or RESULTS) / "review.json").read_text())
    rows = [r for r in data["locales"][locale]["strings"] if r["best"]]
    translations = {r["key"]: r["best_text"] for r in rows}
    return po.fill(locale, translations, {r["key"]: r["best"] for r in rows}, redo=redo)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="randos_translate")
    parser.add_argument(
        "--catalog", choices=sorted(po.CATALOGS), default="site", help="which strings: the website's or the TUI's"
    )
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
    s.add_argument("results", type=Path, nargs="*", help="runs to score (default: the catalog's shootout)")
    s.add_argument("--redo", action="store_true", help="also rescore entries that already have a score")
    s.add_argument(
        "--judge", action="append", choices=sorted(scoring.JUDGES), help="with --scorer judge: only this judge (repeatable)"
    )
    b = sub.add_parser("tidy", help="apply models.tidy (brand case, ellipsis, placeholders, NFC) to runs made before it")
    b.add_argument("results", type=Path, nargs="+")
    sub.add_parser("plan", help="list the shootout runs with strings to top up (group, model, locales, run, count)")
    sub.add_parser(
        "review", help="combine results/*.json into results/review.json (the review page's data) and shootout-summary.json"
    )
    args = parser.parse_args(argv)
    use_catalog(args.catalog)

    if args.command == "run":
        print(run(args.model, args.locales.split(","), args.limit, args.append))
    elif args.command == "score":
        paths = [p for p in args.results if p.name != "review.json"] or shootout_runs()
        print(score(args.scorer, paths, args.redo, args.judge))
    elif args.command == "plan":
        for group, model, locales, path, count in plan():
            print(group, model, ",".join(locales), path, count, sep="\t")
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
