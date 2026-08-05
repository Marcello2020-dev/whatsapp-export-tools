# Chat Export Studio

Chat Export Studio is a macOS SwiftUI app that turns user-selected chat exports (`_chat.txt` or `Chat.txt`) into **readable HTML archives** and **Markdown** that open in standard browsers.

---

## Overview

- Parses common chat TXT export formats (DE/EN variants).
- Preserves multi-line messages and system notices.
- Produces HTML archives and Markdown summaries for long-term reading.

## Features

- Clean HTML layout with day separators, timestamps, and link previews.
- Attachment handling with optional embedding, thumbnails, or sidecar references.
- Sidecar export for faster loading and smaller HTML files.
- macOS GUI with export presets and best-effort participant detection.

## Output formats

HTML variants (suffixes are part of the filename):
- `-max` — single HTML file with all media embedded (best offline portability).
- `-mid` — HTML with embedded thumbnails, large media kept external.
- `-min` — text-only HTML (smallest, email-friendly).
- `-sdc` — sidecar HTML that references media files in a folder for fast loading.

Markdown:
- One `.md` file grouped by day with timestamps and attachment references.

## Interface

The macOS interface uses a calm document-export visual language with clear local-processing and export controls.

## Status (legacy Python)

A legacy Python script remains in the repo for reference/backward compatibility, but it is **not actively developed**. The actively maintained implementation is the macOS SwiftUI app.

- Legacy script: `chat_export_to_md_html.py`

## Build & Run (macOS)

1. Open the Xcode project.
2. Select the Chat Export Studio scheme.
3. Build & Run.

### Use

1. **Chat-Export auswählen**: select the exported chat TXT file (typically `_chat.txt`).
2. **Zielordner auswählen**: choose where the exports should be written.
3. **Chat-Partner**: select the counterparty (auto-detected when possible).
4. Choose the desired output variants (HTML + Markdown + Sidecar).
5. Click **Exportieren**.

## Notes

- Keep the chat export TXT and its attachment files in the same folder during export.
- Some URLs (notably Google services) may show consent/interstitial pages; link preview handling is best-effort.

## License

Proprietary License – see `LICENSE`.

## Privacy

- Privacy Policy source: `docs/privacy-policy.md`
- Privacy Choices source: `docs/privacy-choices.md`
