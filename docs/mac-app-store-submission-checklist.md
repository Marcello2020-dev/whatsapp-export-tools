# Chat Export Studio - Mac App Store Submission Checklist

This checklist covers release blockers for:

- Point 2: App Privacy / App Store Connect declarations
- Point 3: Release archive and upload readiness

It intentionally excludes ZIP extractor refactoring (tracked separately).

## 1) App Privacy in App Store Connect (Point 2)

### Required fields

- Privacy Policy URL: required for macOS apps.
- User Privacy Choices URL: optional (recommended if available).

References:

- https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy/
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy

### Current WET data behavior

- The app can request link preview metadata/images from third-party URLs found in chat content.
- This happens via in-app network requests (`URLSession` / `LinkPresentation`) when preview-enabled variants are exported.
- No analytics SDK, ad SDK, crash SDK, or custom telemetry endpoint is configured in this repo.

### Conservative App Privacy declaration template (recommended)

Use this if online previews stay enabled in release builds:

1. Data Collection: **Yes, we collect data from this app**
2. Data Type: **User Content** (URL/link content used to build previews)
3. Purpose: **App Functionality**
4. Linked to user: **No** (if you do not persist identity-linked backend records)
5. Used for tracking: **No**

Notes:

- This is a conservative submission posture to reduce review friction.
- If you fully disable online preview fetching in release and remove networking behavior, you can reassess and potentially answer "No data collected".

### Privacy manifest

Ensure `PrivacyInfo.xcprivacy` exists and is bundled in release artifacts.

Current file:

- `whatsapp-export-tools/PrivacyInfo.xcprivacy`

## 2) Release Archive + Preflight (Point 3)

### Run automated preflight

From repo root:

```bash
bash scripts/wet-appstore-preflight.sh
```

What it checks:

- Release build + archive
- sandbox entitlements in source and built app
- no `get-task-allow` in built app
- privacy manifest presence + required-reason categories
- known risk warning if ZIP extraction still launches `/usr/bin/*`

### Manual archive command (if needed)

```bash
xcodebuild \
  -project whatsapp-export-tools.xcodeproj \
  -scheme whatsapp-export-tools \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath ".tmp/archives/Chat Export Studio.xcarchive" \
  archive
```

### Upload path

Preferred for first submissions:

1. Open Organizer in Xcode.
2. Select latest archive.
3. Distribute App -> App Store Connect -> Upload.
4. Resolve any signing/provisioning warnings before submit.

## 3) Release notes for App Review

Use clear reviewer notes:

- "App converts user-selected WhatsApp exports into local HTML/Markdown artifacts."
- "No background services, no hidden telemetry."
- "Network access is used only for optional link preview enrichment."
- "All file access is user-selected via sandbox panels/bookmarks."

## 4) Fast go/no-go gate

Ship only if all are true:

1. `bash scripts/wet-appstore-preflight.sh` returns `PASS`
2. App Privacy fields completed in App Store Connect
3. Privacy Policy URL reachable publicly
4. Archive upload succeeds in Organizer without entitlement/privacy errors
