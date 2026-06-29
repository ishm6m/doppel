# DESIGN_SYSTEM.md — Design System

> **Purpose:** Define the visual language — tokens, materials, components states, motion — so every screen is consistent and first-party-feeling.
> **Scope:** Color, typography, spacing, radius, shadow, materials/vibrancy, iconography, states, motion, haptics, a11y hooks.
> **Dependencies:** `UI_SPEC.md`, `COMPONENTS.md`, `ACCESSIBILITY.md`.

**Principle:** Lean on **system semantics**, not hard-coded values. A first-party feel comes from using Apple's materials, dynamic colors, and SF fonts — not from a bespoke palette. Define tokens as thin semantic wrappers over system values so they adapt to light/dark, accent color, and accessibility settings automatically.

---

## 1. Color tokens (semantic, system-backed)

Define in an enum/asset catalog; **prefer system dynamic colors**.

| Token | Source | Use |
|---|---|---|
| `accent` | system accent color | primary actions, selection |
| `textPrimary` | `Color.primary` | titles, body |
| `textSecondary` | `Color.secondary` | metadata, captions |
| `bgWindow` | window material | base |
| `bgElevated` | `.regularMaterial` | cards, sheets |
| `separator` | `Color(nsColor: .separatorColor)` | dividers |
| `destructive` | `Color.red` (system) | delete actions |
| Match-type badges | semantic set | exact = `.gray`, nearText = `.blue`, nearImage = `.teal`, semantic = `.purple` |
| Diff highlights | semantic | insert = green tint, delete = red tint, change = yellow/orange tint (all at low opacity over text) |

Never hard-code hex except where a brand asset requires it. All colors must pass contrast in both appearances (see `ACCESSIBILITY.md`).

---

## 2. Materials, vibrancy & "glass"

Use native materials for translucency; **do not fake blur with custom views**.
- **Sidebar:** sidebar material (`.background(.ultraThinMaterial)` via the system sidebar; prefer the built-in `List` sidebar style which is already vibrant).
- **Toolbar:** unified, system material.
- **Cards / sheets / inspector:** `.regularMaterial` / `.thinMaterial` as elevation rises.
- **Vibrancy:** text over materials uses `.foregroundStyle(.secondary)`/system vibrancy, not manual opacity.

**Liquid Glass / newest design language:** Apple's latest glass effects (rounded, light-refracting surfaces) are available only on newer macOS. **Gate them behind `if #available`** and provide a material-based fallback for the macOS 14 baseline. Do **not** assume a specific Liquid Glass API name without verifying it compiles on the target SDK — wrap usage in availability checks and a `GlassBackground` component that degrades to `.regularMaterial`. (See `CLAUDE.md` §3 note about verifying current-OS APIs.) Glassmorphism is a *progressive enhancement*, never a requirement for core legibility.

---

## 3. Typography (SF, Dynamic Type)

Use system text styles — never fixed point sizes — so Dynamic Type works for free.

| Role | Style |
|---|---|
| Screen title | `.largeTitle` / `.title` |
| Section header | `.headline` |
| Group explanation | `.body` |
| Metadata (size, date, path) | `.callout` / `.caption`, `.secondary` |
| Monospace (paths, diff) | `.system(.body, design: .monospaced)` |

Numerals in counters: `.monospacedDigit()` to prevent jitter.

---

## 4. Spacing scale (pt)
`xs=4, sm=8, md=12, lg=16, xl=24, xxl=32`. Card padding = `lg`. List row vertical = `sm`–`md`. Use the scale exclusively; no magic numbers.

## 5. Corner radius
`small=6, medium=10, large=14, card=12, sheet=16`. Match system rounding; use `.cornerRadius`/`clipShape(RoundedRectangle(cornerRadius:style:.continuous))`.

## 6. Shadows / elevation
Minimal, system-like. Cards: subtle shadow (`radius 8, y 2, ~8% black`) only on hover/elevation; rest flat on material. Avoid heavy drop shadows (un-Apple).

## 7. Iconography
**SF Symbols only.** Examples: scan = `magnifyingglass`, folder source = `folder`, exact = `equal.circle`, near text = `doc.on.doc`, semantic = `sparkles`/`brain`, compare = `rectangle.split.2x1`, trash = `trash`, undo = `arrow.uturn.backward`, keeper = `star.fill`, OCR = `text.viewfinder`, ignore = `eye.slash`. Use hierarchical/multicolor rendering where it aids meaning. Provide accessibility labels for every symbol.

---

## 8. Component states (apply to all interactive components)
Define for each: **default, hover, pressed, focused (keyboard), selected, disabled, loading, error, empty (where applicable).**
- Hover: subtle bg tint / action reveal.
- Focus: visible focus ring (system) — never removed.
- Selected: accent tint, vibrancy-aware.
- Disabled: reduced opacity + non-interactive.
- Loading: skeleton or progress, never a frozen UI.

---

## 9. Motion
- **Durations:** micro 120ms, standard 200ms, emphasis 320ms. Easing: system spring for interactive, `.easeInOut` for fades.
- **Use:** group insertion fade/scale, sheet present, inspector slide, progress updates.
- **Reduced Motion:** when enabled, replace slides/scales with cross-fades or instant changes; never animate large layout moves. Read `accessibilityReduceMotion`.

## 10. Haptics
macOS: use `NSHapticFeedbackManager` sparingly — on successful destructive confirmation and undo. Never gratuitous.

## 11. Density & hit targets
Min hit target 28×28 pt (mouse) / respect pointer; rows comfortable not cramped. Support compact via Dynamic Type but keep targets accessible.

## Open Questions
- Final accent strategy: follow system accent (recommended) vs. a fixed brand accent. Default: follow system.

## Future Improvements
- A documented Liquid Glass theme once the baseline OS is raised.

## Related Documents
- `UI_SPEC.md`, `COMPONENTS.md`, `ACCESSIBILITY.md`.
