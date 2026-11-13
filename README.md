# Squish

A native macOS app for the [compress-video](https://github.com/pixel-point/skills) skill's four workflows, built on FFmpeg with the skill's own encoder settings.

| Screen | What it does |
| --- | --- |
| **Compress** | Drop files or folders. Each one becomes `name-h265.mp4` (CRF 30, 10-bit, x265 `slow`), with optional VP9 WebM (CRF 42) and AV1. Every audio channel is kept at a high bitrate. Silent audio is dropped automatically, the source frame rate is kept (or optionally capped at ~30 fps), odd dimensions are made even, and every output is checked with FFprobe and a full decode. You get the savings, the exact commands, and an HTML `<video>` snippet. |
| **Compare quality** | Cuts 1 s samples at 25/50/75 % into a lossless FFV1 reference, encodes 2–8 codec/CRF candidates, measures SSIM (and PSNR if you ask), estimates full-video sizes, and recommends one setting from the Pareto frontier. Includes preview links, stills, and a Markdown table in the skill's format. |
| **Audit** | Scans a source folder for video references, renders a page URL at mobile/tablet/laptop/desktop widths to measure the largest displayed picture (object-fit aware, 2× density), finds originals by name, duration, and aspect ratio, checks audio for silence, and reports resolution, compression, audio, and delivery issues. Nothing is changed. |
| **Scan & optimize** | Runs the audit, encodes full outputs from the best source at the measured size, replaces files only when they get meaningfully smaller, adds VP9 WebM `<source>` fallbacks in HTML/JSX/Vue/Svelte/Astro, converts `.mov` to `.mp4`, and never ships an H.265-only MP4 without a WebM fallback. It shows a plan with diffs first. Apply backs everything up to `~/Library/Application Support/Squish/Backups`, re-checks references and playback, and can restore. |

## Requirements

macOS 14+, and FFmpeg with libvpx, libx265, and SVT-AV1 (`brew install ffmpeg`). Building requires Xcode 15 or later.

## Build

```sh
./scripts/build-app.sh            # builds dist/Squish.app
./scripts/build-app.sh --install  # also copies it to ~/Applications
```

## Command line

The same binary runs headless:

```sh
Squish.app/Contents/MacOS/Squish compress clip.mov [--vp9] [--av1] [--cap-fps] [--faster]
Squish.app/Contents/MacOS/Squish compare clip.mov [--av1] [--psnr]
Squish.app/Contents/MacOS/Squish audit ./website http://localhost:3000 [--pages=N] [--originals=DIR]
Squish.app/Contents/MacOS/Squish optimize ./website http://localhost:3000 [--pages=N] [--apply]
Squish.app/Contents/MacOS/Squish restore "~/Library/Application Support/Squish/Backups/<run>"
```

"Standard" speed (the default) uses x265 `-preset slow`. "Extra compression" uses `-preset veryslow` and `-deadline best` for slightly smaller files at much longer encode times. Scan & optimize still makes VP9 WebM fallbacks for websites.
