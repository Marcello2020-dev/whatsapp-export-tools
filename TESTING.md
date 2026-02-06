# Chat Export Studio Testing Guide

This guide defines a repeatable testing workflow for `whatsapp-export-tools` (WET).
It is optimized for fast local validation plus release gating.

## 1. Test Levels

- `Smoke`: fast confidence after code changes.
- `Regression`: verify known bug-prone flows.
- `Performance`: detect runtime or throughput regressions.
- `Release`: final gate before shipping.

## 2. Prerequisites

- macOS with Xcode installed.
- Valid project checkout at repo root.
- Test fixtures available:
  - folder export input
  - zip export input
  - standalone `_chat.txt` input (without media)
  - large media-heavy chat input

## 3. Deterministic Build Setup

Run from repo root:

```bash
mkdir -p .tmp/xcodebuild-tmp .tmp/clang-module-cache
DERIVED_DATA="$PWD/.tmp/DerivedData"

TMPDIR="$PWD/.tmp/xcodebuild-tmp" \
CLANG_MODULE_CACHE_PATH="$PWD/.tmp/clang-module-cache" \
xcodebuild \
  -project whatsapp-export-tools.xcodeproj \
  -scheme whatsapp-export-tools \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_BIN="$DERIVED_DATA/Build/Products/Debug/Chat Export Studio.app/Contents/MacOS/Chat Export Studio"
echo "$APP_BIN"
```

## 4. Smoke Suite (5-10 min)

Run this after every meaningful change:

1. Build succeeds (section 3 command).
2. Launch app manually from Xcode or binary.
3. Folder input export completes.
4. ZIP input export completes.
5. Standalone `_chat.txt` export completes.
6. `Sources` folder is present when raw archive copy is enabled.
7. Help menu opens the in-app help window.
8. Diagnostics window opens and copy/save/clear works.

## 5. Automated Gate Checks

Each check is triggered by one env var and prints `PASS` or `FAIL` in stdout.

```bash
run_check() {
  local key="$1"
  echo "=== $key ==="
  local out
  out="$(env "$key"=1 "$APP_BIN" 2>&1)"
  echo "$out"
  echo "$out" | rg -q "FAIL" && return 1
}

run_check WET_LINK_PREVIEW_CHECK
run_check WET_LINKIFY_CHECK
run_check WET_SYSTEM_CHECK
run_check WET_EXPORTER_PLACEHOLDER_CHECK
run_check WET_REPLACE_CHECK
run_check WET_EXTERNAL_ASSETS_CHECK
run_check WET_DETERMINISM_CHECK
run_check WET_PARALLEL_CHECK
run_check WET_REPLAY_GUARDRAILS_CHECK
run_check WET_OUTPUT_STRUCTURE_DEDUP_CHECK
run_check WET_DELETE_ORIGINALS_GATE_CHECK
run_check WET_ZIP_TS_CHECK
```

Optional fixture-based zip timestamp check:

```bash
env \
  WET_ZIP_TS_FIXTURE_CHECK=1 \
  WET_ZIP_TS_FIXTURE_ZIP="/absolute/path/to/input.zip" \
  WET_ZIP_TS_FIXTURE_REF="/absolute/path/to/reference/folder" \
  "$APP_BIN"
```

## 6. Regression Matrix

Run these scenarios after pipeline, source handling, timestamp, or naming changes.

1. Folder pipeline vs ZIP pipeline produce identical payload files.
2. Ignore macOS noise during compare (`.DS_Store`, `__MACOSX`, `._*`).
3. Timestamp drift (`+3600s`) is treated as advisory, not a delete-gate blocker.
4. Byte mismatch blocks delete originals.
5. Missing sibling ZIP in folder mode is handled gracefully.
6. If sibling ZIP exists and is authorized, it is copied into `Sources`.
7. Replace flow deletes only selected variants.
8. Replay guardrails reject legacy output roots without `Sources`.

## 7. Manual Forensic Compare (Folder vs ZIP)

Given two manifest TSV files:

```bash
FOLDER_TSV="/absolute/path/FOLDERPIPELINE_..._manifest.tsv"
ZIP_TSV="/absolute/path/ZIPPIPELINE_..._manifest.tsv"

filter_manifest() {
  awk -F'\t' '
    NR==1 { print; next }
    $0 ~ /(^|\/)__MACOSX(\/|$)/ { next }
    $0 ~ /(^|\/)\.DS_Store$/ { next }
    $0 ~ /(^|\/)\._[^\/]+$/ { next }
    { print }
  ' "$1"
}

diff -u \
  <(filter_manifest "$FOLDER_TSV" | sort) \
  <(filter_manifest "$ZIP_TSV" | sort)
```

Expected: no payload diffs after noise filtering.

## 8. Performance Checks

Track runtime and throughput on at least two fixtures:

- small/no-media chat
- large/media-heavy chat

Collect:

- total runtime (`Start` to end in diagnostics log)
- input size vs output size
- rough throughput (`input bytes / runtime`)

Use this env var for extra perf diagnostics:

```bash
env WET_PERF=1 "$APP_BIN"
```

Optional concurrency tuning experiments:

```bash
env WET_PERF=1 WET_MAX_CPU=4 WET_MAX_IO=6 "$APP_BIN"
```

## 9. Release Gate (must pass)

1. `Debug` build succeeds.
2. `Release` build succeeds.
3. Smoke suite passes.
4. Automated gate checks pass.
5. Regression matrix spot-check passes for current change area.
6. No known high-severity bugs open for changed flows.

Release build command:

```bash
xcodebuild \
  -project whatsapp-export-tools.xcodeproj \
  -scheme whatsapp-export-tools \
  -configuration Release \
  build
```

## 10. Bug Report Template

When reporting a bug, always include:

- app version or commit hash
- exact input path(s)
- exact output path
- selected options/toggles
- expected result
- actual result
- diagnostics log excerpt
- forensic manifest/audit files if applicable

