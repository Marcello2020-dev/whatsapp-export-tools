---
title: "Legacy Drift Gate Policy"
---

# AG-062 — Legacy Drift Gate Policy (v0.2)

## Purpose
- Enforce that `AIGlowStyle.default` and the v0.1 visual baseline remain stable unless any deviation is explicitly documented, reviewed, and evidenced.

## Scope
- Applies to any code or data change that affects:
  - `AIGlowStyle.default` (packaged default style)
  - Rendering constants that determine the glow’s look/feel (palette, timing, geometry, intensity, fill mode defaults)
  - Accessibility behavior that changes the baseline visuals for `active == true` states.

## What counts as "default visual drift"
- Any change that alters the way the default glow looks without the host explicitly overriding the style (e.g., palette values, ring blur, shimmer intensity, `fillMode`, `outerPadding`).
- Turning on/off components or introducing new host-only styles is acceptable if confined to new APIs and documented, but the baseline `AIGlowStyle.default` must remain untouched or accompanied by this policy’s artifacts.

## Required artifacts for any drift
1. **CHANGELOG entry:** Add/update an entry under `docs/specs/AIGlow/CHANGELOG_aiglow.md` (usually in `[0.2.0]` or `[Unreleased]`) describing:
   - API surface/behavior that changed.
   - Performance/gating/accessibility impact.
   - Validation evidence location.
2. **Evidence pointer:** Provide deterministic, PII-safe screenshots (via `_local/ai-glow-snapshots/...` or `_local/ai-glow-screenshots/...`) plus the exact command used to capture them.
3. **Review note:** Mention the policy doc in PR description for reviewer awareness (link to `LEGACY_DRIFT_POLICY_v0.2.md`).

## Evidence locations
- Screenshots: `_local/ai-glow-snapshots/<AG-XYZ>` (existing harness) or `_local/ai-glow-screenshots/<AG-XYZ>` (validation matrix).
- Commands: `swift run --package-path AIGlowKit --configuration release AIGlowHarness -- --snapshot --output <dir>` (or `xcodebuild` harness target).
- Document the screenshot folder path and command in CHANGELOG entry (see `[0.2.0] Validation evidence` section).

## Reviewer checklist
- [ ] Does the change leave `AIGlowStyle.default` untouched? If not, confirm a corresponding changelog entry exists.
- [ ] Is there evidence (screenshot folder + command) referenced in the changelog?
- [ ] Are the screenshots synthetic/PII-safe and produced via the AI Glow harness/scraper?
- [ ] Does the PR mention this policy when default visuals change?

## CI guidance
- CI should fail any submission that modifies AIGlowStyling defaults without:
  1. A changelog entry (covered by this policy).
  2. A deterministic screenshot folder recorded near `_local/ai-glow-snapshots/` or `_local/ai-glow-screenshots/`.
- Optional: add a lint step that ensures changelog sections reference this policy when `AIGlowStyle.default` is touched (future work).
