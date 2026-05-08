#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/.tmp/DerivedData/Build/Products/Debug/Chat Export Studio.app}"
OUT_DIR="${2:-$ROOT_DIR/docs}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  echo "Build first or pass app path as arg1." >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

INPUT_PNG="$OUT_DIR/screenshot-tab-input-1440x900.png"
OUTPUT_PNG="$OUT_DIR/screenshot-tab-output-1440x900.png"

osascript -e 'tell application "Chat Export Studio" to quit' >/dev/null 2>&1 || true
sleep 1

open -a "$APP_PATH"
sleep 2

dismiss_intrusions() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Chat Export Studio"
    set frontmost to true
    repeat 5 times
      try
        if (exists sheet 1 of window 1) then
          try
            click button 1 of sheet 1 of window 1
          on error
            try
              keystroke return
            end try
          end try
          delay 0.3
        else
          exit repeat
        end if
      on error
        exit repeat
      end try
    end repeat
  end tell
end tell
APPLESCRIPT
}

focus_and_size() {
  osascript <<'APPLESCRIPT'
tell application "Chat Export Studio" to activate
delay 0.6
tell application "System Events"
  tell process "Chat Export Studio"
    set frontmost to true
    set win to window 1
    set position of win to {80, 60}
    set size of win to {1440, 900}
  end tell
end tell
APPLESCRIPT
}

select_tab() {
  local label_a="$1"
  local label_b="$2"
  local idx="$3"
  osascript <<APPLESCRIPT
tell application "System Events"
  tell process "Chat Export Studio"
    set frontmost to true
    set win to window 1
    set p to position of win
    set wx to item 1 of p
    set wy to item 2 of p

    if $idx is 1 then
      set cx to wx + 106
    else
      set cx to wx + 180
    end if
    set cy to wy + 128
    click at {cx, cy}
  end tell
end tell
APPLESCRIPT
}

capture_window() {
  local out_png="$1"
  local rect
  rect="$(osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Chat Export Studio"
    set win to window 1
    set p to position of win
    set s to size of win
    set x to item 1 of p
    set y to item 2 of p
    set w to item 1 of s
    set h to item 2 of s
    return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)
  end tell
end tell
APPLESCRIPT
)"
  screencapture -x -o -R "$rect" "$out_png"
  sips -z 900 1440 "$out_png" >/dev/null
}

focus_and_size
sleep 0.5
dismiss_intrusions
sleep 0.4

select_tab "Eingabe" "Input" 1
sleep 0.6
capture_window "$INPUT_PNG"

dismiss_intrusions
sleep 0.2
select_tab "Ausgabe" "Output" 2
sleep 0.6
capture_window "$OUTPUT_PNG"

sips -g pixelWidth -g pixelHeight "$INPUT_PNG" "$OUTPUT_PNG"

echo "Captured:"
echo " - $INPUT_PNG"
echo " - $OUTPUT_PNG"
