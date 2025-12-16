# WhatsApp Export Tools

Tools to convert exported WhatsApp chat logs (TXT) into readable, well-structured Markdown reports (iOS/a-Shell friendly).

## What this does

- Parses WhatsApp TXT exports in the common format:
  - `[DD.MM.YY, HH:MM:SS] Sender: Message`
- Handles multi-line messages (lines without a new timestamp are appended to the previous message).
- Writes a timestamped Markdown report grouped by date.
- Optional: right-align your own messages (GitHub-rendered Markdown via embedded HTML).

## Files

- `whatsapp_export_to_md.py` — converter script

## Usage (a-Shell / iOS)

1) Put the exported chat file next to the script (example: `_chat.txt`).

2) Run:

```sh
python3 -u whatsapp_export_to_md.py _chat.txt --me "YOUR_NAME"