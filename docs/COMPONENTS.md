# COMPONENTS.md — Reusable Component Specifications

> **Purpose:** Specify reusable SwiftUI components with their inputs, states, and behavior.
> **Scope:** The shared component library under `Doppel/DesignSystem/Components`.
> **Dependencies:** `DESIGN_SYSTEM.md`, `UI_SPEC.md`.

Each component: **Props → States → Behavior → A11y**. All consume design tokens; none hard-code colors/sizes.

---

## C1 `GroupCard`
- **Props:** `group: DuplicateGroup`, `members: [FileRecord]`, callbacks (`onCompare`, `onTrash`, `onIgnore`, `onSetKeeper`, `onSelectAllButKeeper`).
- **States:** collapsed/expanded, hover, selected, loading.
- **Behavior:** header shows `MatchBadge` + `ConfidenceMeter` + explanation + reclaimable size; expand reveals `MemberRow`s; actions in trailing menu + context menu.
- **A11y:** accessibilityElement combining children; label = explanation + count; actions as accessibility actions.

## C2 `MatchBadge`
- **Props:** `matchType: MatchType`.
- **Behavior:** colored capsule + SF Symbol + text ("Exact", "Near text", "Near image", "Semantic"). Colors per `DESIGN_SYSTEM.md`.
- **A11y:** label = "Match type: Near text".

## C3 `ConfidenceMeter`
- **Props:** `confidence: Double (0...1)`.
- **Behavior:** compact bar or percentage with `.monospacedDigit()`. Tooltip explains meaning.
- **A11y:** "Confidence 96 percent".

## C4 `MemberRow`
- **Props:** `file: FileRecord`, `isKeeper: Bool`, `isSelected: Bool`, `onToggleSelect`, `onSetKeeper`.
- **States:** default, hover (reveal Reveal-in-Finder/Quick Look), selected, keeper.
- **Behavior:** thumbnail/type icon, name, middle-truncated path, size, mtime, keeper star, **unchecked-by-default** checkbox.
- **A11y:** full label; keeper announced; checkbox is a toggle.

## C5 `ScanProgressHeader`
- **Props:** `phase`, `processed`, `total?`, `eta?`, `groupsFound`, `reclaimable`, `onCancel`.
- **Behavior:** determinate/indeterminate `ProgressView`, live counters (`.monospacedDigit`), Cancel.
- **A11y:** progress value exposed; updates throttled to avoid VoiceOver spam (announce milestones).

## C6 `EmptyStateView`
- **Props:** `icon (SF Symbol)`, `title`, `message`, `primaryAction?`, `secondaryAction?`, `isDropTarget: Bool`.
- **States:** default, drag-hover (highlight).
- **Behavior:** centered; supports folder drop.

## C7 `DiffView`
- **Props:** `left: DiffDocument`, `right: DiffDocument`, `differencesOnly: Bool`.
- **Behavior:** synchronized scroll, word/line highlight (insert/delete/change tints), jump-to-next-change, monospaced.
- **States:** loading, ready, extraction-failed, identical.
- **A11y:** changes navigable via keyboard + announced ("Changed: date").

## C8 `ConfirmTrashSheet`
- **Props:** `files: [FileRecord]`, `bytes: Int64`, `onConfirm`, `onCancel`.
- **Behavior:** native sheet; destructive primary; scrollable file list; reversible-promise copy.

## C9 `SourceRow`
- **Props:** `source: SourceBookmark`, `fileCount?`, `onRemove`.
- **States:** default, hover (reveal remove), stale (warning badge + re-grant).

## C10 `SectionDisclosure` (Needs OCR / Skipped)
- **Props:** `title`, `count`, `action?`, `rows`.
- **Behavior:** collapsible; optional action button (Run OCR).

## C11 `Toast` / `UndoBanner`
- **Props:** `message`, `actionTitle ("Undo")`, `onAction`, auto-dismiss interval.
- **Behavior:** transient, bottom; Undo wired to ⌘Z action too.
- **A11y:** announced via accessibility notification; not motion-dependent.

## C12 `GlassBackground`
- **Props:** none / `material`.
- **Behavior:** uses newest glass effect when `#available`, else `.regularMaterial`. Single place that encapsulates progressive enhancement (see `DESIGN_SYSTEM.md` §2).

## C13 `ThresholdSlider`
- **Props:** `value`, `range`, `explanation closure`.
- **Behavior:** slider + live helper text ("Higher = stricter"). Used in Settings → Detection.

## Open Questions
- Virtualized member lists for very large groups — wrap `MemberRow` in `List` for reuse.

## Future Improvements
- `SpaceTreemap` component (future viz).

## Related Documents
- `UI_SPEC.md`, `DESIGN_SYSTEM.md`, `STATE_MANAGEMENT.md`.
