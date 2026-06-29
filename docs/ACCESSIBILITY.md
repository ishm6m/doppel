# ACCESSIBILITY.md — Accessibility

> **Purpose:** Make Doppel fully usable with VoiceOver, keyboard only, large text, and reduced motion — a requirement, not a nicety, for a first-party-feeling app.
> **Scope:** VoiceOver, keyboard, Dynamic Type, reduced motion, contrast, focus, audit checklist.
> **Dependencies:** `UI_SPEC.md`, `DESIGN_SYSTEM.md`, `COMPONENTS.md`.

Target: WCAG 2.1 AA-equivalent where applicable to native macOS.

---

## 1. VoiceOver
- Every interactive element has a clear `accessibilityLabel`; decorative SF Symbols are hidden.
- `GroupCard` is a combined element: label = match type + explanation + member count + reclaimable size; group actions exposed as `accessibilityAction`s (Compare, Move to Trash, Ignore).
- `MemberRow`: announces name, size, date, keeper status, selection state; checkbox is a toggle.
- `ConfidenceMeter`: "Confidence 96 percent."
- `DiffView`: changes are navigable and announced ("Changed region: date") with rotor support for jumping between differences.
- Progress: announce milestones (25/50/75/100%) and terminal states, not every tick (avoid spam).
- Destructive confirmations announce consequence and reversibility.

## 2. Keyboard navigation (full, mouse-free)
- Tab order is logical: sidebar → content → inspector.
- Shortcuts: ⌘R scan, ⎋ cancel, arrows navigate groups/rows, space Quick Look, return open/compare, ⌘⌫ move-to-trash (with confirm), ⌘Z undo, ⌘, settings, ⌘F search.
- Visible focus ring everywhere (never removed). Full delete flow completable by keyboard only (tested in `TESTING.md` §6).
- Menus and context menus mirror all row/card actions.

## 3. Dynamic Type
- Use system text styles only (`DESIGN_SYSTEM.md` §3); layouts reflow without truncation of essential info up to the largest accessibility sizes.
- Snapshot tests at default + XL + accessibility sizes.

## 4. Reduced motion
- Read `accessibilityReduceMotion`; replace slides/scales with cross-fades or instant updates. No essential information conveyed only by motion. Toasts remain readable without animation.

## 5. Contrast & color
- Rely on system dynamic colors → pass contrast in light/dark.
- **Never** convey state by color alone: match-type badges include text + icon; diff highlights include symbols/labels, not just tint; keeper has a star, not just a color.
- Support Increase Contrast and Differentiate Without Color settings.

## 6. Focus & selection
- Clear, vibrancy-aware selection; focus distinct from selection; restored sensibly after actions (e.g., after delete, focus moves to next item).

## 7. Pointer & hit targets
- Minimum 28×28 pt targets; hover-revealed actions also reachable by keyboard/VoiceOver (not hover-only).

## 8. Audit checklist (gate before release)
- [ ] VoiceOver: navigate scan→results→compare→delete→undo end to end.
- [ ] Keyboard-only: same journey, no mouse.
- [ ] Dynamic Type XL + accessibility sizes: no clipped essential text.
- [ ] Reduced motion: no slides; info intact.
- [ ] Differentiate Without Color: all states distinguishable.
- [ ] Increase Contrast: legible.
- [ ] Accessibility Inspector audit: zero errors on each screen.

## Open Questions
- Custom rotor for "jump between duplicate groups by reclaimable size"?

## Future Improvements
- Localization + RTL audit when localized.

## Related Documents
- `UI_SPEC.md`, `DESIGN_SYSTEM.md`, `TESTING.md`.
