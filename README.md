# Clementine

A menu-bar file converter and toolbox for macOS, modeled on Tangerine.

- **Hold Shift while dragging files** anywhere (Finder, Desktop, any app that drags files) and a wheel of output formats opens around the pointer. Drop on a format to convert; results are saved beside the originals.
- **Hold Option + Shift** for the tools wheel: compress, metadata, crop, trim, redact, split, merge, normalize and more (27 tools).
- Both modifier combinations are configurable in Settings → General.
- Everything runs on your Mac. No free-use limit.

## Formats

182 conversions across images (JPG, PNG, WEBP, HEIC, TIFF, SVG, AVIF, BMP → PDF/DOCX too), documents (PDF ↔ DOCX/TXT/JPG/PNG, TXT → PDF/JPG/PNG/SRT/VTT), audio (MP3, M4A, WAV, FLAC, OGG, OPUS, AIFF, WMA), video (MP4, MOV, MKV, WEBM, AVI, WMV, GIF → also MP3), archives (ZIP, TAR, GZIP, RAR) and subtitles (SRT, VTT, TXT). The full table is in Settings → Compatibility.

## Requirements

- macOS 14 or later (Liquid Glass wheel on macOS 26).
- Homebrew `ffmpeg` (audio/video) and `webp` (WEBP output). Ghostscript (`gs`) makes PDF compression stronger. RAR output uses a built-in writer.

```bash
brew install ffmpeg webp ghostscript
```

## Build

```bash
scripts/build-app.sh            # release build into build/Clementine.app
scripts/build-app.sh --install  # also copies to /Applications and launches it
scripts/test-matrix.sh          # runs every conversion and checks each output
```

Debug entry points: `Clementine --convert <file> <format>`, `--matrix`, `--snapshot <view> <out.png>`, `--tool-test <tool> <files…> key=value`.
