# AI Glow — CHANGELOG

This changelog follows **Keep a Changelog** style and **Semantic Versioning**.

- **Module name:** AIGlowKit (AI Glow rendering module)
- **Repo context:** WhatsApp Export Tools (monorepo)
- **Document location (this file):** `docs/specs/AIGlow/CHANGELOG_aiglow.md`
- **Docs source of truth:** `docs/specs/AIGlow/ai-glow-implementation-spec-v0.2.md` and `docs/specs/AIGlow/ai-glow-technical-notes-v0.1.md`

## Changelog rules (hard)

- **Apple-fidelity baseline is the default.** `AIGlowStyle.default` must remain visually identical to the legacy v0.1 look unless an explicit change is documented here **with evidence**.
- Any change that affects **visuals, timing, gating, accessibility behavior, or style/palette processing** must be documented here.
- Any **intentional visual drift** requires:
  1) a changelog entry (what + why), and
  2) recorded visual evidence (PII-safe screenshot set / preview captures).
- **Accessibility wins** over host styling preferences.

## Tags (recommended)

When a version is considered stable, tag the **monorepo commit** as:

- `aiglow/vX.Y.Z`

---

## [Unreleased]

### Added
- (Reserved)

### Changed
- (Reserved)

### Fixed
- (Reserved)

---

## [0.2.0] — 2026-01-11 (Spec freeze / implementation pending)

This entry reflects the **v0.2 specification baseline**. Code changes implementing v0.2 must update this section with concrete details and evidence links (commit hashes + screenshot set paths).

### API changes
- (Placeholder)

### Visual/timing changes
- Accessibility overrides: Reduce Motion slows shimmer and dims shimmer intensity; Reduce Transparency/Increase Contrast reduce aura intensity and clamp saturation/contrast for readability.

### Performance/gating changes
- Offscreen lifecycle gating: detach from the shared ticker when views disappear to prevent lingering background work (AG-033).

### Validation evidence
- Screenshots: `_local/aiglow-snapshots/AG-032` (Reduce Motion/Transparency/Contrast), `_local/aiglow-snapshots/AG-033` (offscreen gating)

### Added
- **Host-driven, data-only styling API:** `AIGlowStyle` as the **single** host options object (palette, components, fill mode, geometry/intensity, timing, tuning).
- **Canonical SwiftUI integration API** (single source of truth):  
  `View.aiGlow(active:isRunning:cornerRadius:style:debugTag:)`
- **Component toggles:** externally configurable rendering of **Aura / Ring / Shimmer** (e.g., via `AIGlowComponents`).
- **Fill mode support:** outline-only default plus optional **inner glow** mode (host-selected).
- **Palette system:** deterministic `AIGlowPalette` supporting built-in presets and fully **custom palettes** supplied by the host (product branding stays host-owned).
- **Runtime color tuning hooks:** optional saturation/brightness/contrast multipliers with defensive clamping (exact clamp ranges to be finalized during implementation).
- **Timing model definitions:** shared ticker/timebase with **global** and **per-instance** shimmer speed scalars and per-instance phase offsets; explicit sync vs async semantics.

### Changed
- **Module boundary contract (hard):** Host owns meaning/state; AIGlowKit renders only. No inference from strings/focus/content inside AIGlowKit.
- **Architecture & extraction readiness:** v0.2 requires strict “no WET dependencies” discipline and an extraction roadmap (monorepo → local Swift Package → optional dedicated repo).

### Fixed
- (Reserved for implementation)

### Validation / Evidence requirements (hard)
- Any implementation work under v0.2 must be accompanied by **PII-safe screenshot evidence** produced via an AI Glow–owned harness/scraper.
- Screenshots must use **synthetic fixtures only** (no WhatsApp exports, no names, no phone numbers, no message content).

---

## [0.1.0] — (Baseline / legacy)

### Added
- Initial SwiftUI glow implementation (Aura + Ring + Shimmer) with hard-coded Apple-fidelity constants.
- Ad-hoc internal timing/phase logic as implemented in the v0.1 codebase.

### Notes
- v0.1 values are the **visual baseline**. v0.2 refactoring must migrate these constants into `AIGlowStyle.default` **without drift** unless explicitly documented as a deliberate change.

---

## Links

- Keep a Changelog: https://keepachangelog.com/en/1.1.0/
- Semantic Versioning: https://semver.org/
