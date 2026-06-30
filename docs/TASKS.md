# TASKS.md — Implementation Plan

> **Purpose:** An ordered, checkable task list. Claude Code picks the next unchecked task, implements it (with tests), meets its DoD, then moves on.
> **Scope:** MVP through V1, broken into milestones. Each task ≈ one focused PR.
> **Dependencies:** All specs. Tasks reference FR-/F-IDs.

**Working rule:** Do tasks top-to-bottom. Don't start a task until the previous one's DoD (code + tests + lint) passes. Mark `[x]` when done.

---

## Milestone 0 — Project skeleton
- [ ] **T0.1** Create Xcode project `Doppel` (macOS 14, SwiftUI lifecycle, Swift 6 strict concurrency). Add SwiftFormat + SwiftLint config. DoD: builds, lint passes, empty window launches.
- [ ] **T0.2** Create SPM packages `DoppelKit`, `IndexStore`, `DetectionEngine` with the dependency rules in `ARCHITECTURE.md` §2. DoD: packages compile, App depends on all three, no reverse deps.
- [ ] **T0.3** Add `AppEnvironment` DI container + `Logger` subsystems. DoD: env injected into root view; logs emit.
- [ ] **T0.4** Set entitlements: App Sandbox, user-selected read-write, no network. DoD: matches `SECURITY.md`.

## Milestone 1 — Persistence
- [ ] **T1.1** Implement `IndexStore` GRDB stack + `DatabaseMigrator` v1 (all tables in `DATA_MODEL.md` §3). DoD: migration test creates schema; WAL on.
- [ ] **T1.2** Implement `IndexStoring` async protocol + in-memory test double. DoD: CRUD for files/groups/sessions/sources covered by tests.
- [ ] **T1.3** Implement incremental signature lookup (skip-unchanged). DoD: unit test proves unchanged files skipped.

## Milestone 2 — Engine: Stage 0 & 1
- [ ] **T2.1** `Enumerator` (Stage 0): walk roots, apply scope + ignore + hidden rules, compute signatures, size-bucket. DoD: enumerates a fixture tree correctly.
- [ ] **T2.2** Streamed SHA-256 hasher (Stage 1) + exact grouping (union-find). DoD: F3 acceptance + memory-bounded test.
- [x] **T2.3** `ScanCoordinator` actor emitting `ScanEvent` `AsyncStream`, cancellation, incremental persistence. DoD: cancel-at-50% consistency test passes.

## Milestone 3 — Engine: Stage 2 (the headline)
- [ ] **T3.1** Text extractors: txt/md done (`PlainTextExtractor`). RTF/`.docx` deferred — RTF needs AppKit, .docx needs vendored unzip+XML; both would touch the pure engine, decide then.
- [x] **T3.2** PDF extractor (PDFKit text layer) + scanned-PDF classification (F5). DoD met: `PDFTextExtractor` classifies text-layer vs scanned (sparse-layer heuristic); text-PDFs routed into Stage 2 near-dup, scanned PDFs surfaced as `.needsOCR` skips (never dropped). Vision OCR pass itself is opt-in, deferred (F5 "Run OCR" / T7-era).
- [x] **T3.3** Shingling + MinHash (128 perms) + LSH banding (16×8) + Jaccard estimate. DoD met: near-dup pair detected; threshold via `DetectionConfig`.
- [x] **T3.4** Near-dup grouping + `reasonSummary` via fast diff. DoD met: precision 1.0 on constructed near-dup set (≥0.95); LSH pruning asserted.

## Milestone 4 — Results UI (vertical slice)
- [ ] **T4.1** `NavigationSplitView` shell: sidebar (sources/scans), content (results), inspector. DoD: matches `UI_SPEC.md` layout, empty states render.
- [ ] **T4.2** F1 folder selection (panel + drag-drop + bookmarks). DoD: F1 acceptance.
- [ ] **T4.3** Scan run + live progress header (F2 UI). DoD: progress streams, cancel works.
- [ ] **T4.4** Group list with badges, confidence, explanation, keeper, reclaimable size (F7). DoD: invariant test (no empty explanation).

## Milestone 5 — Compare & safe delete (trust core)
- [ ] **T5.1** Text diff engine (word/line) + compare view (F8). DoD: contract-date demo highlights the date.
- [ ] **T5.2** Safe deletion: Trash-only + confirmation sheet + multi-select + select-all-but-keeper (F9). DoD: files go to Trash; lint/test forbids `removeItem` on user files.
- [ ] **T5.3** Undo (⌘Z / Edit menu) restoring from Trash. DoD: F9 acceptance.
- [ ] **T5.4** Ignore group / not-duplicates persistence (F7/F14). DoD: ignored group doesn't recur.

## Milestone 6 — Onboarding, Settings, History
- [ ] **T6.1** Onboarding flow (F10). DoD: shown once, accessible.
- [ ] **T6.2** Settings scene: General/Detection/Model/Ignore/About (F11). DoD: toggles affect engine.
- [ ] **T6.3** Scan history sidebar + reopen (F12). DoD: F12 acceptance.

## Milestone 7 — Semantic tier (opt-in)
- [x] **T7.1** `EmbeddingProvider` protocol + deterministic stub. DoD met: stub-driven tests.
- [~] **T7.2** Stage 3 embed-survivors + cosine within buckets + `.semantic` groups + model invalidation (F6). Engine core done: pure `SemanticStage` emits `.semantic` edges (bucket-pruned cosine, no all-pairs), F6 stub acceptance + model-invalidation tests green; it slots into the existing edge/clustering pass. **Remaining:** opt-in `deepScan(sessionID:)` wiring over a finished session's persisted survivors (app/ScanService + IndexStore) — moves with T7.3.
- [ ] **T7.3** "Deep scan" UI affordance (global, opt-in). DoD: runs only on demand; battery note.
- [ ] **T7.4** (Gated) Wire Core ML provider once model pinned by human. DoD: provider swaps without engine changes.

## Milestone 8 — Hardening & release
- [ ] **T8.1** Per-file error capture + "Skipped (N)" UI (`ERROR_HANDLING.md`). DoD: corrupt file doesn't fail scan.
- [ ] **T8.2** Performance harness + budgets met (`PERFORMANCE.md`). DoD: 50k corpus within budget.
- [ ] **T8.3** Accessibility pass (`ACCESSIBILITY.md`): VoiceOver, keyboard, Dynamic Type, reduced motion. DoD: audit checklist passes.
- [ ] **T8.4** Network-egress CI test (no file-derived data leaves). DoD: test green.
- [ ] **T8.5** Signing, notarization, Sparkle appcast (`RELEASE.md`). DoD: notarized build auto-updates.

---

## Open Questions
- Sequence T7 before or after public 0.1? (Recommend ship 0.1 at end of M6 = documents MVP; semantic in 0.2.)

## Future Improvements
- Add CorpusGen tasks expansion for adversarial near-dup cases.

## Related Documents
- `FEATURES.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `TESTING.md`.
