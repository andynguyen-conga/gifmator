# Gifmator

A super-lightweight macOS app that converts a product walkthrough recording into an animated GIF — trim, preview, export. Built for pasting demos cleanly into decks, docs, and Slack.

> Native macOS, no SwiftUI (so it builds on Command Line Tools alone — Xcode not required). Pure AppKit + AVFoundation, with `ffmpeg` doing the two-pass palette encode.

## Features

- Drag-and-drop or Open a `.mov` / `.mp4` / `.m4v`
- `AVPlayer`-backed preview that loops only the trimmed range
- Timeline trimmer with two draggable handles, independent playhead with top/bottom flag grips, and keyboard nudging
- Export presets from Standard (960 × 15 fps) up to Ultra (2560 × 30 fps), plus a Custom mode (320–3840 wide, 10–30 fps)
- Live export-size estimate with warnings when things get big
- Single **Export GIF…** button → system Save panel → animated `.gif` on disk. No clipboard, no PowerPoint integration — paste it wherever you want yourself.

## Requirements

- macOS 13 or newer
- Swift 5.9+ (ships with Xcode Command Line Tools — no full Xcode needed)
- `ffmpeg` on your `PATH`:

  ```bash
  brew install ffmpeg
  ```

## Quickstart

```bash
git clone https://github.com/andynguyen-conga/gifmator.git
cd gifmator
swift run
```

That's it. First build takes ~30–45 seconds; subsequent runs are instant.

To open in Xcode (optional): `open Package.swift` and hit Run.

## Run as a .app

Prefer double-clicking over `swift run`? Build an app bundle:

```bash
./scripts/bundle.sh
```

That produces `Gifmator.app` in the repo root. Drag it into `/Applications`, pin it to the Dock, or launch it from Spotlight.

The bundle is unsigned (no Apple Developer account tied to this project), so Gatekeeper may ask you to confirm on the first launch — right-click the app, pick **Open**, and macOS will remember the exception.

Rebuild the bundle any time by re-running the script.

## Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play / pause |
| `I` | Set in-point to playhead |
| `O` | Set out-point to playhead |
| `[` / `]` | Nudge in / out handle by one frame (hold Shift to reverse) |
| `⌘O` | Open video… |
| `Return` | Export GIF… |

## Roadmap

Planned features live in [`docs/ideas.md`](docs/ideas.md): crop region selector, animated zoom in / zoom out, spotlight effect.

## How the encode works

Two-pass ffmpeg: `palettegen` builds an optimized 256-colour palette for the trimmed range, then `paletteuse` encodes the GIF against that palette with Sierra 2-4A dither and `diff_mode=rectangle` for better compression on screen recordings. Trim is applied as `-ss <in>` and `-to <out>` on **both** passes so the palette only sees frames in your selection.

## Credits

Encoding by [ffmpeg](https://ffmpeg.org/). Everything else is Swift + AppKit + AVFoundation.
