# USER_FLOWS.md — End-to-End User Journeys

> **Purpose:** Describe complete interaction flows so UI and state wiring are unambiguous.
> **Scope:** Primary flows with steps, system responses, and edge branches.
> **Dependencies:** `FEATURES.md`, `UI_SPEC.md`, `STATE_MANAGEMENT.md`.

Notation: **U** = user action, **S** = system response, **⤷** = edge/branch.

---

## UF-1 First run → first scan (happy path)
1. **U** launches app first time.
2. **S** shows onboarding page 1: "Everything stays on your Mac. No accounts, no uploads." (F10)
3. **U** clicks Continue → page 2 "Choose folders to scan."
4. **U** clicks "Choose Folders…", selects `~/Documents`.
5. **S** stores security-scoped bookmark, dismisses onboarding, shows main window with the source in the sidebar; content area shows "Ready to scan" empty state.
6. **U** confirms scope = Documents (default) and clicks **Scan**.
7. **S** enters `enumerating` → progress header appears; groups stream into the content list as found; counters update (groups, reclaimable size).
8. **S** scan finishes → summary banner: "Found 23 groups · 1.2 GB reclaimable."
   - ⤷ **U** clicks **Cancel** mid-scan → **S** stops, persists partial index, shows "Scan cancelled — partial results."

## UF-2 Reviewing a near-duplicate contract (the headline)
1. **U** selects a group badged "Near-identical text · 96%".
2. **S** inspector shows members; keeper marked (newest). Explanation: "Near-identical text — 2 changed regions."
3. **U** clicks **Compare**.
4. **S** opens side-by-side diff; identical text dimmed, the changed **date** and **signature block** highlighted. (F8)
5. **U** confirms these are the same contract, returns to group.
6. **U** clicks **Select all but keeper**, then **Move to Trash**.
7. **S** shows confirmation sheet: "Move 1 file to Trash? Frees 142 KB." → **U** confirms.
8. **S** moves to Trash, updates group/reclaimable totals, shows toast with **Undo**.
   - ⤷ **U** presses **⌘Z** → **S** restores file from Trash, group reappears.

## UF-3 Marking a false grouping
1. **U** opens a `.semantic` group that is actually two distinct docs.
2. **U** clicks **Not duplicates / Ignore group**.
3. **S** persists `ignore_pair`/`group.ignored`; group removed from view; won't recur on future scans. (F7/F14)

## UF-4 Scanned PDFs (OCR gating)
1. **S** after scan shows a "Needs OCR (5)" section. (F5)
2. **U** clicks **Run OCR** (opt-in).
3. **S** runs Vision OCR pass, re-feeds Stage 2; new groups may appear.
   - ⤷ OCR toggle off in Settings → section shows but action explains it's disabled.

## UF-5 Deep (semantic) scan — opt-in
1. After a normal scan, **S** offers **Deep scan** (finds same-meaning docs; "uses more battery").
2. **U** clicks it. **S** embeds Stage-2 survivors only, adds `.semantic` groups. (F6)
   - ⤷ If no embedding model pinned, the button is present but explains "Semantic model not configured" (stub in dev).

## UF-6 Incremental re-scan
1. **U** re-runs scan on the same source after editing a few files.
2. **S** skips unchanged files (signature match), reprocesses only changed ones; finishes fast. (FR-4)

## UF-7 Settings change affecting detection
1. **U** lowers near-dup threshold in Settings → Detection.
2. **S** persists; next scan uses new threshold (no live re-cluster of old results unless re-scanned).

## UF-8 Source removed
1. **U** removes a source from the sidebar.
2. **S** confirms, cascades delete of its `file_record`s and dependent groups; results update.

## Edge inventory (must be handled)
- Stale bookmark on launch → re-grant prompt.
- Permission denied on a subfolder → record issue, continue, show in "Skipped (N)."
- Empty selection / no files of scope → friendly empty state, not error.
- Force-quit mid-scan → clean resume (no corruption).
- Trash unavailable (rare) → surface error, do not fall back to permanent delete.

## Open Questions
- Should Deep scan be offered automatically as a one-click after every scan, or only via menu? (Default: visible button, not automatic.)

## Future Improvements
- Saved scan configurations (presets).

## Related Documents
- `UI_SPEC.md`, `FEATURES.md`, `ERROR_HANDLING.md`.
