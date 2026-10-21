# Voice lab clips

Three 6-second excerpts of LibriVox recordings, which are in the **public
domain** (archive.org marks the item with the Public Domain Mark 1.0,
http://creativecommons.org/publicdomain/mark/1.0/). Chosen by measured
median pitch so the lab spans low to high voices, where anonymization
quality diverges. Dev only: served by the voice lab at `/dev/voice-lab`,
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
