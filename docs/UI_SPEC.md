# UI_SPEC.md — UI/UX Specification

> **Purpose:** Specify every screen, region, and state precisely enough to build without design files.
> **Scope:** Window structure, each screen's layout/behavior/states, native patterns used.
> **Dependencies:** `DESIGN_SYSTEM.md`, `COMPONENTS.md`, `FEATURES.md`.

Target: feels like a first-party Apple app. SwiftUI-first; AppKit only where noted.

---

## 1. Window architecture

**Main window** = `NavigationSplitView` (three columns):
- **Sidebar (leading):** Sources section (folders), Scans section (history). Native `List` with sections, hover-reveal remove buttons, SF Symbols. Collapsible.
- **Content (center):** results — grouped outline of duplicate groups, or the active scan progress, or an empty/loading/error state.
- **Inspector (trailing, toggleable):** details for the selected group/file; hosts the Compare entry point.

Native chrome: unified toolbar, `.toolbar` items, `.searchable` on content, native `Settings` scene (⌘,), standard menu bar with app-specific commands, full-window vibrancy materials.

Window: min size 980×640; remembers frame; supports full screen. Title reflects active scan/source.

---

## 2. Toolbar (main window)
Leading: sidebar toggle. Center/primary: **Scan** (or **Cancel** while running) primary button; scope picker (Documents/Images[V2]); **Deep scan** (secondary, after a scan). Trailing: inspector toggle, search field. Use `.toolbarRole(.editor)` styling; primary action uses accent.

---

## 3. Screen: Onboarding (F10)
- Presented as a centered, borderless sheet/window on first launch.
- 2–3 pages with large SF Symbol, headline, one-line body, page control; "Continue"/"Get Started" primary button.
- Page 1 privacy promise; page 2 folder choose (invokes F1); optional page 3 "How it works" (the cascade in one sentence + diagram).
- States: default only. Fully keyboard navigable; respects reduced motion (cross-fade not slide).

## 4. Screen: Empty states (content area)
- **No sources:** large icon, "Choose folders to find duplicates", "Choose Folders…" button, drag-drop hint. Drop target highlights on hover-drag.
- **Sources but no scan:** "Ready to scan N folders", Scan button.
- **Scan found nothing:** "No duplicates found 🎉", subtle, with "Scan again" + "Adjust settings".
All empty states use the `EmptyStateView` component (`COMPONENTS.md`).

## 5. Screen: Scan progress (content area)
- **Progress header** (`ScanProgressHeader`): phase label ("Hashing 12,304 / 50,000" / "Reading documents…" / "Comparing…"), determinate bar when countable else indeterminate, ETA, live counters (groups found, reclaimable size), **Cancel** button.
- Below: groups stream in as found (list populates live). Newly added groups animate in (subtle, respect reduced motion).
- States: enumerating (indeterminate), per-stage (determinate), finishing, cancelled (inline notice), failed (error state with retry).

## 6. Screen: Results list (content area, F7)
- Grouped **outline** (`DisclosureGroup`/`OutlineGroup`) OR flat list of `GroupCard`s — use cards for scanability.
- **GroupCard** shows: match-type badge (color-coded per `DESIGN_SYSTEM.md`), confidence %, explanation text, member count, reclaimable size, suggested-keeper indicator, expand to see members.
- **Member row:** thumbnail/type icon, name, path (truncating middle), size, mtime, keeper star (tap to set keeper), selection checkbox (NOT pre-checked).
- Group actions (toolbar of card / context menu): Compare, Select all but keeper, Move to Trash, Ignore group, Reveal in Finder.
- Multi-select across rows with ⌘/⇧ click; bulk action bar appears when ≥1 non-keeper selected.
- Sorting: by reclaimable size (default), confidence, count, type.
- States: loading (skeleton rows), populated, empty, error.

## 7. Screen: Inspector (trailing, F7/F8 entry)
- Selected group: explanation, confidence meter, match-type, members summary, "Compare" button, keeper override control, "Why grouped?" expandable showing per-pair `reasonSummary`.
- Selected single file: metadata, Reveal in Finder, Quick Look button.

## 8. Screen: Compare / diff (F8)
- Presented as a sheet or dedicated detail.
- **Documents:** two synchronized scroll panes; word/line diff with color highlights (insert/delete/change per `DESIGN_SYSTEM.md`), a "differences only" toggle, jump-to-next-change. Header names each file + mtime/size.
- **Images (V2):** overlay with opacity slider + side-by-side toggle; difference heatmap optional.
- States: loading (extracting/diffing), ready, extraction-failed (explain), identical (banner "These files are byte-identical").

## 9. Screen: Confirmation sheet (F9)
- Native sheet: "Move N files to Trash? Frees X." Lists affected files (scrollable). Primary destructive button "Move to Trash" (accent/destructive role), Cancel. Checkbox "Don't ask again this session" (still always reversible).

## 10. Screen: Settings (F11)
- Native `Settings` scene, tabbed: **General** (default scopes, default keeper rule), **Detection** (near-dup threshold slider with live explanation, semantic threshold, deep-scan default, OCR toggle), **Model** (provider: Stub/Core ML, model info), **Ignore List** (table of ignored pairs/groups, remove), **About** (version, links, check for updates).
- Each control has helper text. Sliders show effect ("Higher = stricter, fewer matches").

## 11. Screen: Needs-OCR & Skipped sections
- Collapsible sections in results: "Needs OCR (N)" with Run OCR action; "Skipped (N)" listing files + issue reason (read-only), Reveal in Finder.

## 12. Global UI behaviors
- **Hover:** rows reveal secondary actions; cards lift subtly (shadow token).
- **Selection:** accent-tinted, vibrancy-aware.
- **Drag & drop:** folders onto sidebar/empty state add sources; files can be dragged out to Finder (copy).
- **Context menus:** on rows/cards (Compare, Reveal, Quick Look, Ignore, Trash).
- **Quick Look:** spacebar on a selected file.
- **Keyboard:** full navigation (see `ACCESSIBILITY.md`): ⌘R scan, ⎋ cancel, ⌘Z undo, arrows navigate, space Quick Look, ⌘⌫ move-to-trash (with confirm).

## Open Questions
- Cards vs. outline for results at very high group counts — may need virtualization; default to `List` for free reuse.

## Future Improvements
- A heatmap/treemap visualization of reclaimable space by folder.

## Related Documents
- `DESIGN_SYSTEM.md`, `COMPONENTS.md`, `USER_FLOWS.md`, `ACCESSIBILITY.md`.
