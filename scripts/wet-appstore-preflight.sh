#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/whatsapp-export-tools.xcodeproj"
SCHEME_NAME="whatsapp-export-tools"
DERIVED_DATA_PATH="$ROOT_DIR/.tmp/DerivedData-AppStore"
ARCHIVE_PATH="$ROOT_DIR/.tmp/archives/Chat Export Studio.xcarchive"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Chat Export Studio.app"
ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/Chat Export Studio.app"
SOURCE_ENTITLEMENTS="$ROOT_DIR/whatsapp-export-tools/whatsapp-export-tools.entitlements"
SOURCE_PRIVACY_MANIFEST="$ROOT_DIR/whatsapp-export-tools/PrivacyInfo.xcprivacy"
SERVICE_FILE="$ROOT_DIR/whatsapp-export-tools/WhatsAppExportService.swift"

DO_BUILD=1
DO_ARCHIVE=1

usage() {
  cat <<'EOF'
Usage: scripts/wet-appstore-preflight.sh [--skip-build] [--skip-archive]

Checks App Store readiness for:
- Point 2: App Privacy / privacy manifest / entitlements consistency
- Point 3: Release archive readiness and signing preflight

Options:
  --skip-build     Skip Release build step
  --skip-archive   Skip Archive step
EOF
}

while (($#)); do
  case "$1" in
    --skip-build)
      DO_BUILD=0
      ;;
    --skip-archive)
      DO_ARCHIVE=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

errors=0
warnings=0

pass() {
  echo "PASS: $*"
}

warn() {
  echo "WARN: $*"
  warnings=$((warnings + 1))
}

fail() {
  echo "FAIL: $*"
  errors=$((errors + 1))
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "Missing file: $path"
    return 1
  fi
  pass "Found file: $path"
  return 0
}

run_build() {
  echo "== Release build =="
  mkdir -p "$ROOT_DIR/.tmp"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build
}

run_archive() {
  echo "== Release archive =="
  mkdir -p "$(dirname "$ARCHIVE_PATH")"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    archive
}

check_privacy_manifest() {
  echo "== Privacy manifest checks =="
  if ! require_file "$SOURCE_PRIVACY_MANIFEST"; then
    return
  fi

  if plutil -extract NSPrivacyAccessedAPITypes raw -o - "$SOURCE_PRIVACY_MANIFEST" >/dev/null 2>&1; then
    pass "NSPrivacyAccessedAPITypes exists"
  else
    fail "NSPrivacyAccessedAPITypes missing in PrivacyInfo.xcprivacy"
  fi

  for category in \
    NSPrivacyAccessedAPICategoryUserDefaults \
    NSPrivacyAccessedAPICategoryFileTimestamp \
    NSPrivacyAccessedAPICategorySystemBootTime; do
    if rg -q "$category" "$SOURCE_PRIVACY_MANIFEST"; then
      pass "Declared required-reason category: $category"
    else
      fail "Missing required-reason category: $category"
    fi
  done
}

check_entitlements_source() {
  echo "== Source entitlements checks =="
  if ! require_file "$SOURCE_ENTITLEMENTS"; then
    return
  fi

  for key in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    if rg -q "$key" "$SOURCE_ENTITLEMENTS"; then
      pass "Declared entitlement: $key"
    else
      fail "Missing entitlement: $key"
    fi
  done

  if rg -q "com\\.apple\\.security\\.temporary-exception" "$SOURCE_ENTITLEMENTS"; then
    fail "Temporary exception entitlements found (not App Store friendly)"
  else
    pass "No temporary exception entitlements found"
  fi
}

select_app_path() {
  if [[ -d "$APP_PATH" ]]; then
    echo "$APP_PATH"
    return
  fi
  if [[ -d "$ARCHIVE_APP_PATH" ]]; then
    echo "$ARCHIVE_APP_PATH"
    return
  fi
  echo ""
}

check_built_app() {
  echo "== Built app checks =="
  local resolved_app
  resolved_app="$(select_app_path)"
  if [[ -z "$resolved_app" ]]; then
    if [[ "$DO_BUILD" -eq 0 && "$DO_ARCHIVE" -eq 0 ]]; then
      warn "Built app not found (source-only mode with --skip-build --skip-archive)"
      return
    fi
    fail "Built app not found (run build/archive first)"
    return
  fi
  pass "Using app: $resolved_app"

  local app_privacy_manifest="$resolved_app/Contents/Resources/PrivacyInfo.xcprivacy"
  if [[ -f "$app_privacy_manifest" ]]; then
    pass "Privacy manifest embedded in app bundle"
  else
    fail "Privacy manifest missing in app bundle"
  fi

  local ents
  if ! ents="$(codesign --display --entitlements - "$resolved_app" 2>/dev/null)"; then
    fail "Unable to read built-app entitlements"
    return
  fi

  for key in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope; do
    if grep -q "$key" <<<"$ents"; then
      pass "Built app entitlement present: $key"
    else
      fail "Built app entitlement missing: $key"
    fi
  done

  if grep -q "com.apple.security.get-task-allow" <<<"$ents"; then
    fail "Built app contains get-task-allow (must not be present for App Store submission)"
  else
    pass "Built app has no get-task-allow entitlement"
  fi
}

check_known_risks() {
  echo "== Known risk checks =="
  if rg -n 'proc\.executableURL = URL\(fileURLWithPath: "/usr/bin/' "$SERVICE_FILE" >/dev/null 2>&1; then
    warn "ZIP extraction still uses external /usr/bin tools (Review risk until in-process extractor is implemented)"
  else
    pass "No external /usr/bin process launch found in ZIP extraction path"
  fi
}

main() {
  echo "WET App Store Preflight"
  echo "Repo: $ROOT_DIR"
  echo

  if [[ "$DO_BUILD" -eq 1 ]]; then
    run_build
  else
    echo "== Release build =="
    warn "Skipped Release build (--skip-build)"
  fi

  if [[ "$DO_ARCHIVE" -eq 1 ]]; then
    run_archive
  else
    echo "== Release archive =="
    warn "Skipped Release archive (--skip-archive)"
  fi

  check_privacy_manifest
  check_entitlements_source
  check_built_app
  check_known_risks

  echo
  echo "Summary: errors=$errors warnings=$warnings"
  if [[ "$errors" -ne 0 ]]; then
    echo "WET-APPSTORE-PREFLIGHT: FAIL"
    exit 1
  fi
  echo "WET-APPSTORE-PREFLIGHT: PASS"
}

main
