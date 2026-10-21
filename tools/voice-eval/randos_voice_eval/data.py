"""The speech the benchmark uses: a small, balanced subset of LibriSpeech
test-clean (CC-BY 4.0, public-domain audiobooks read by volunteers; Panayotov
et al. 2015). Downloaded once into a cache outside the repository and never
committed.
"""

import tarfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import soundfile

URL = "https://www.openslr.org/resources/12/test-clean.tar.gz"
CACHE = Path.home() / ".cache" / "randos" / "voice-eval"


@dataclass(frozen=True)
class Utterance:
    id: str
    speaker: str
    sex: str
    path: Path
    text: str


def ensure_downloaded(cache=CACHE):
    """LibriSpeech test-clean under `cache` (346 MB download, once)."""
    root = cache / "LibriSpeech"
    if (root / "test-clean").is_dir():
        return root
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "test-clean.tar.gz"
    if not archive.exists():
        print(f"downloading {URL} (346 MB) into {cache}")
        partial = archive.with_suffix(".partial")
        urllib.request.urlretrieve(URL, partial)
        partial.rename(archive)
    with tarfile.open(archive) as tar:
        tar.extractall(cache, filter="data")
    archive.unlink()
    return root


def speakers_by_sex(root):
    """{speaker id: "F" | "M"} from SPEAKERS.TXT, test-clean only."""
    sexes = {}
    for line in (root / "SPEAKERS.TXT").read_text().splitlines():
        if line.startswith(";"):
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) >= 3 and fields[2] == "test-clean":
            sexes[fields[0]] = fields[1]
    return sexes


def select(root, per_sex=10, per_speaker=5, min_seconds=4.0, max_seconds=15.0):
    """`per_sex` speakers of each sex (lowest ids first, so the subset is
    the same every run), `per_speaker` utterances each between the two
    lengths. Returns {speaker: [Utterance]}."""
    sexes = speakers_by_sex(root)
    chosen = {}
    for sex in ("F", "M"):
        ids = sorted((s for s, x in sexes.items() if x == sex), key=int)
        for speaker in ids:
            if sum(1 for s in chosen if sexes[s] == sex) >= per_sex:
                break
            utterances = _utterances(root / "test-clean" / speaker, speaker, sex, min_seconds, max_seconds)
            if len(utterances) >= per_speaker:
                chosen[speaker] = utterances[:per_speaker]
    return chosen


def _utterances(speaker_dir, speaker, sex, min_seconds, max_seconds):
    found = []
    for chapter in sorted(speaker_dir.iterdir()):
        transcripts = {}
        for trans in chapter.glob("*.trans.txt"):
            for line in trans.read_text().splitlines():
                key, _, text = line.partition(" ")
                transcripts[key] = text
        for flac in sorted(chapter.glob("*.flac")):
            seconds = soundfile.info(flac).duration
            if min_seconds <= seconds <= max_seconds and flac.stem in transcripts:
                found.append(Utterance(flac.stem, speaker, sex, flac, transcripts[flac.stem]))
    return found
