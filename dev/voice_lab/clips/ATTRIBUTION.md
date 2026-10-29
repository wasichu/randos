# Voice lab clips

Four 6-second excerpts of LibriVox recordings, which are in the **public
domain** (archive.org marks the item with the Public Domain Mark 1.0,
http://creativecommons.org/publicdomain/mark/1.0/). The original three were chosen by measured median pitch to span low to high
voices, where anonymization quality diverges. The owner requested the
additional Wasichu excerpt from his 2009 Mencken recording. Dev only: served by the voice lab at `/dev/voice-lab`,
never in production. Thanks to the volunteer readers.

| File | Pitch (median F0) | Excerpt | Reader | Source |
| --- | --- | --- | --- | --- |
| `low_voice.wav` | ~96 Hz | 47–53 s of "Love and Alchemy" (Robert Kennaway Douglas) | NickT0708 | track 13 |
| `mid_voice.wav` | ~165 Hz | 42–48 s of "Akin to Love" (Lucy Maud Montgomery) | Yoganandh T | track 06 |
| `high_voice.wav` | ~232 Hz | 21–27 s of "Going to Shrewsbury" (Sarah Orne Jewett) | Elsie Selwyn | track 11 |

Source: LibriVox, *Short Story Collection Vol. 109*,
https://librivox.org/short-story-collection-vol-109-by-various/ (audio:
https://archive.org/details/shortstorycollection109_2405_librivox, the
64 kb/s MP3s). Converted to 24 kHz mono 16-bit WAV with 20 ms fades
(ffmpeg); nothing else changed.

## Wasichu / Mencken (added 2026-10-24)

`mencken_wasichu.wav`: 60–66 seconds of part 1 of H. L. Mencken’s
*Damn! A Book of Calumny*, read by **Wasichu**, cataloged by LibriVox on
2009-01-22. Median pitch has not been measured; this is an additional
listening reference, not a replacement for a benchmark dataset.

- Catalog: https://librivox.org/damn-a-book-of-calumny-by-hl-mencken/
- Audio: https://archive.org/download/damn_0901_librivox/damn_01_mencken.mp3
- Archive item: https://archive.org/details/damn_0901_librivox

LibriVox marks its recordings public domain in the USA. Extracted locally,
with no runtime request to LibriVox or Internet Archive. Same preparation as
the other clips: 24 kHz mono, signed 16-bit PCM WAV, 20 ms fades at each edge.

```bash
ffmpeg -ss 60 -i damn_01_mencken.mp3 -t 6 -ac 1 -ar 24000 \
  -af 'afade=t=in:d=0.02,afade=t=out:st=5.98:d=0.02' \
  -c:a pcm_s16le -map_metadata -1 mencken_wasichu.wav
```
