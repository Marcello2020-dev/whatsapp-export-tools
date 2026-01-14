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
- Tagging plan (monorepo):
  - Tag the commit that contains the frozen AIGlow API/behavior as `aiglow/v0.2.0` (and future versions as `aiglow/vX.Y.Z`).
  - For patch-level fixes (e.g., `v0.2.1`), tag the commit that closes the fix with the new tag while keeping earlier tags untouched.
  - Minor bumps (e.g., `v0.3.0`) reference commits introducing new capability even though the code lives inside the WET repo.
  - Tags are additive; do not rewrite history. Always tag the monorepo commit that matches the documented version.

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
- **Host-driven style object:** `AIGlowStyle` aggregates palette, component toggles, fill mode, geometry tuning, timing scalars, and intensity clamps. It is cheap-to-copy, Equatable, and Sendable-friendly.
- **Canonical SwiftUI modifier:** `View.aiGlow(active:isRunning:cornerRadius:style:debugTag:)` is the central entry point; any shortcuts must delegate without adding inference logic.
- **Component/Fills:** `AIGlowComponents` (OptionSet with `.aura`, `.ring`, `.shimmer`, `.all`) and `AIGlowFillMode` (`outlineOnly` default, optional `innerGlow`) live inside `AIGlowStyle`.
- **Palette system:** Deterministic `AIGlowPalette` + `AIGlowGradientStop` support built-in Apple-like defaults and host-owned custom palettes (e.g., WhatsApp Green) with Light/Dark variants.
- **Timing & ticker:** A shared `AIGlowTicker` timebase provides global + per-instance speed scalars, phase offsets, and Reduce Motion scaling; normalizing helpers clamp this data to safe ranges.

### Behavior
- **Active/style contract:** The host only drives glow through `active` and `style`; AIGlowKit renders but never infers meaning. Suggested-vs-user-owned state stays in the host, and glow stays on only when the suggested value is showing.
- **Host gating:** `active` transitions to `false` when the user edits away from a suggestion or when the control is disabled; it transitions back to `true` only when the suggestion is restored.
- **Overlay semantics:** Glow overlays remain non-interactive (`allowsHitTesting(false)`), do not affect layout, and respect the host-provided `cornerRadius`, palette, and fill settings.

### Performance/gating changes
- **Shared ticker lifecycle:** All instances share a single ticker; `onAppear`/`onDisappear` gating prevents List/Table leaks and detaches subscriptions immediately when `active == false`.
- **Disabled controls:** When hosts set `active = false` or `components = []`, no ticker subscription or rendering occurs, preventing unnecessary CPU/GPU work.
- **Determinism:** Palettes, geometry clamps, and screenshot outputs remain deterministic. No randomness is introduced inside AIGlowKit or harness runs.

### Accessibility considerations
- **Reduce Motion:** Slows shimmer, lowers ring intensity, and caps shimmer opacity while keeping a pleasant but calmer glow.
- **Reduce Transparency:** Lowers aura opacity and saturation while increasing contrast so the glow remains legible.
- **Increase Contrast:** Adjusts shimmer and aura tuning to keep the glow visible under high-contrast system settings without altering layout.

### Validation evidence
- Screenshots/harness:
  - `_local/aiglow-snapshots/AG-032` (Reduce Motion/Transparency/Contrast)
  - `_local/aiglow-snapshots/AG-033` (offscreen gating)
  - `_local/aiglow-snapshots/AG-040` (PII-safe harness)
  - `_local/aiglow-snapshots/AG-053` (dropdown interaction)
  - Unit/test harness logs for deterministic normalization/clamping (see `AIGlowKit/Tests`)
- AG-061 validation matrix run: unable to execute on this machine because `swift run` cannot write its Xcode cache files and module cache under `/var/folders/*` (Operation not permitted), so no `_local/ai-glow-screenshots/AG-061` outputs were produced.
- Legacy drift gate policy: any change to `AIGlowStyle.default` now requires this changelog entry plus deterministic screenshot/evidence captured via the AI Glow harness (`docs/specs/AIGlow/POLICY_legacy-drift-gate_v0.2.md`).

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
- **Legacy drift gate policy introduced:** `AIGlowStyle.default` retains the v0.1 baseline unless this policy’s requirements (changelog entry + evidence) are satisfied (`docs/specs/AIGlow/POLICY_legacy-drift-gate_v0.2.md`).

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
