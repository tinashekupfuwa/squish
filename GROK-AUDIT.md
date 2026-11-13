# Grok audit

Audited 13 Nov 2026 on `grok-ai`, which is `main` at 4359bf2 with no code changes. The installed app is still Squish 1.18. This is a review, not a fix.

The file this is written against is `/Volumes/LunchBox/NINJAU_S001_S001_T002.MOV`. Read with ffprobe only. Nothing was encoded and the file was not modified.

## What that file actually is

| | |
|---|---|
| Length | 3 h 3 min (11,028 s) |
| Size | 289 GB (310,629,474,816 bytes) |
| Video | HEVC, profile Rext, 3840×2160, 60 fps, progressive |
| Chroma | **yuv422p10le** (10-bit 4:2:2), Rec.709, limited range |
| Audio | First stream. pcm_s24le, 48 kHz, **4 channels, layout unknown**, 4,608 kb/s |
| Other | A timecode data track. No rotation tag. |

Squish's current defaults match the request from 12 Nov on container, preset, CRF, bit depth, frame rate, and channel count. They do not match the chroma, and the audio is a delivery encode of a 24-bit master, not a copy of it.

## Findings

### 1. High: 4:2:2 is silently converted to 4:2:0

`EncodeSettings.pixFmt` is `yuv420p10le` whenever Smooth gradients is on, and `Encoder.arguments` always passes that `pix_fmt`. There is no branch for 4:2:2.

For this Ninja file that discards half the vertical chroma. It is the same class of loss as the stereo mixdown was for audio: the file still plays, and it still says 10-bit, but a color edge is softer than the master. x265 can encode `yuv422p10le` (Main 4:2:2 10). QuickTime and Safari generally want Main 10, which is 4:2:0, so a 4:2:2 MP4 may not play on an iPhone.

This should be a choice, not a silent default. "Match the master (4:2:2)" for archive and grading, "Plays everywhere (4:2:0)" for delivery. The current default is the second one, with no note on the job.

### 2. High: a hand-set CRF does not survive relaunch

In `CompressModel.init`, saved settings load, then `quality` is assigned from `lastQuality`. That assignment's `didSet` calls `applyQuality()`, which overwrites `settings.crf` for every codec from the ruler.

So the Advanced CRF stepper saves, and the next launch puts it back to whatever the ruler maps to (50 → CRF 30 for H.265). The ruler and the stepper are two sources of truth, and the ruler wins on every start. `h265DefaultsApplied` already ran on this Mac, so this is the steady state, not a one-time migration.

Fix: apply the ruler only when the ruler moves, not when it is restored.

### 3. Medium: the 24-bit master becomes 512 kb/s AAC, and only the first track is kept

Default audio is AAC at 128 kb/s per channel (`-b:a 512k` for this file). That is above the rate listening tests treat as transparent, and an earlier 4.0 test kept each channel's level to 0.1 dB. It is still lossy. The source is 24-bit PCM at 4,608 kb/s. Fine for a delivery MP4. Wrong if this MP4 is the new master.

Two related gaps in `Codec.audioFlags`:

- Only `0:a:0` is mapped. A Ninja reel with extra mic tracks would drop them with no note. This file has one 4-channel track, so it is not hit.
- The layout tag is `unknown`. The H.265 path ignores layout and keeps the four channels, which is what you want. The VP9 path would relabel it to `quad` because `"unknown" != "quad"`. VP9 is off by default.

Auto audio still removes a track whose peak is ≤ -50 dBFS. A quiet room track can fall under that. For camera audio, Keep is the safer default than Auto.

The timecode data track is not copied. An editor that syncs by timecode will not find it in the MP4.

### 4. Medium: Scan & optimize does not use these defaults

`OptimizeOptions.encode` forces VP9 on and speed `.skill` (x265 `veryslow`). Compress defaults to H.265 only and `slow`. Opening Scan & optimize will make WebM files and run the slow preset. That contradicts "I don't use that format" if that screen gets used.

### 5. Low

- The speed enum case that means x265 `slow` is still named `.faster`. The label says Standard. The next edit will get this wrong.
- `Encoder.verify` accepts a height within 2 px of the expected size, so a slightly wrong scale can still pass.
- The HTML snippet does not escape the file name.
- Progress updates hop to the main actor in an unstructured `Task`, so a late line can write onto a job that already finished.
- `savedBytes` reports the smallest output against the source. Harmless while only one format is on.

## What is fine

- H.265, CRF 30, x265 `slow`, 10-bit, source frame rate, source size. Confirmed in `EncodeSettings` and with a generated 4K60 clip: the command was `libx265 -crf 30 -preset slow -pix_fmt yuv420p10le`, and the output stayed 3840×2160 at 60 fps.
- VP9 is off by default. The one-time migration key `h265DefaultsApplied` is set on this Mac; the saved settings read back as VP9 off, H.265 on, CRF 30, 10-bit, `faster` (which is `slow`).
- Four channels are kept, not mixed down. For this file the H.265 command will be `-c:a aac -b:a 512k` with no `-ac 2`.
- Audio-before-video ordering in the MOV does not matter. Mapping is by type (`0:v:0`, `0:a:0`).
- A 289 GB file crosses the 20 GB threshold, so the big meter is the fine green tick bar.
- Arguments are passed as an array, not a shell string.

## What a 1.19 fix would be

1. Detect 4:2:2 and either keep it or say, on the job, that chroma was reduced to 4:2:0 so it plays on iPhone.
2. Stop the quality ruler from overwriting a hand-set CRF on launch.
3. Optional: Keep as the audio default, and a lossless audio choice (ALAC or PCM in the MOV) for when the MP4 has to stand in for the master.

I have not made those changes. Say which ones to ship.
