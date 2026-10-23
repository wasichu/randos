"""What every results file write shares: its time stamp, how long each
scorer took, and a write that a stop can't leave half done."""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path


def stamp() -> str:
    """Now, as results files name and note times."""
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def note_scored(run: dict, score: str, seconds: float) -> None:
    """Adds `seconds` to how long `score` has taken over this run (scoring
    resumes after a stop, so the time adds up across sessions)."""
    done = run.setdefault("scored", {}).get(score, {})
    run["scored"][score] = {"at": stamp(), "seconds": round(done.get("seconds", 0) + seconds, 1)}


def write_atomically(path: Path, data: dict) -> None:
    """A temp file beside it, then a rename: a stop mid-write never leaves
    half a results file."""
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.replace(tmp, path)
