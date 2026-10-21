"""The shootout's command line.

  uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
  uv run python -m randos_translate.cli fill results/<run>.json --locale es [--redo]

`run` translates the source strings, back-translates them, runs every check
and score, and writes results/<model>-<date>.json (what the results page
is built from). It never touches the .po files. `fill` writes one run's
translations into a locale's .po, filling only empty entries (`--redo`:
also entries the machine wrote and nobody has changed since).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from . import checks, po, scoring
from . import models as contestants

RESULTS = Path(__file__).resolve().parents[1] / "results"


def run(model_name: str, locales: list[str], limit: int | None) -> Path:
    model = contestants.get(model_name)
    sources = po.sources()[:limit] if limit else po.sources()
    unsupported = [loc for loc in locales if loc not in model.locales]
    if unsupported:
        sys.exit(f"{model_name} has no pair wired for {unsupported} (wired: {model.locales})")

    entries, started = [], time.monotonic()
    for locale in locales:
        texts = model.translate([s.msgid for s in sources], locale)
        backs = model.back_translate(texts, locale)
        for source, text, back in zip(sources, texts, backs):
            entries.append(
                {
                    "key": source.key,
                    "msgid": source.msgid,
                    "msgctxt": source.msgctxt,
                    "locale": locale,
                    "text": text,
                    "back_translation": back,
                    "checks": checks.run_all(locale, source.msgid, text, button=source.msgctxt == "button"),
                    "scores": {"chrf": scoring.back_translation_chrf(source.msgid, back)} | scoring.pending_scores(),
                }
            )

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
    out = RESULTS / f"{model_name}-{stamp}.json"
    out.write_text(
        json.dumps(
            {
                "run": {
                    "model": model_name,
                    "locales": locales,
                    "strings": len(sources),
                    "at": stamp,
                    "seconds": round(time.monotonic() - started, 1),
                },
                "summary": summary,
                "entries": entries,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )
    return out


def fill(results: Path, locale: str, redo: bool) -> dict[str, int]:
    data = json.loads(results.read_text())
    translations = {
        e["key"]: e["text"]
        for e in data["entries"]
        if e["locale"] == locale and all(c["ok"] for c in e["checks"].values())
    }
    return po.fill(locale, translations, data["run"]["model"], redo=redo)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="randos_translate")
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--locales", required=True, help="comma-separated, e.g. es,fr")
    r.add_argument("--limit", type=int, help="only the first N strings (for a quick proof)")
    f = sub.add_parser("fill")
    f.add_argument("results", type=Path)
    f.add_argument("--locale", required=True)
    f.add_argument("--redo", action="store_true")
    args = parser.parse_args(argv)

    if args.command == "run":
        print(run(args.model, args.locales.split(","), args.limit))
    else:
        print(fill(args.results, args.locale, args.redo))


if __name__ == "__main__":
    main()
