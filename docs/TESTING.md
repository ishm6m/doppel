# TESTING.md — Testing Strategy

> **Purpose:** Define what we test and how, so every feature ships with proof.
> **Scope:** Unit, integration, UI, snapshot, performance, and the synthetic corpus.
> **Dependencies:** All feature/engine docs.

**Rule:** Engine logic is TDD. UI gets snapshot + interaction tests. No task in `TASKS.md` is done without its tests green.

---

## 1. Test pyramid
- **Unit (most):** cascade stages, hashing, MinHash/LSH, diff, clustering, store CRUD, keeper heuristic, config.
- **Integration:** full cascade on synthetic corpus; store + engine; trash + undo; incremental scan; cancellation; crash-resume.
- **UI/interaction:** ViewInspector for SwiftUI view logic; key flows (scan, compare, delete, undo, ignore).
- **Snapshot:** component states (GroupCard, EmptyState, DiffView, ConfirmTrashSheet) via swift-snapshot-testing, light/dark + Dynamic Type sizes.
- **Performance:** PerfHarness against budgets (`PERFORMANCE.md`).
- **Accessibility:** automated audits + checklist (`ACCESSIBILITY.md`).
- **Privacy/security:** network-egress test (see §5).

## 2. Synthetic corpus (`Tools/CorpusGen`)
Generates deterministic, labeled corpora:
- exact duplicate pairs (byte-identical, different names),
- near-dup text pairs (contract with changed date/name/signature; configurable edit distance),
- paraphrase/semantic pairs (for Stage 3 stub testing),
- unrelated negatives,
- text-layer PDFs and image-only (scanned) PDFs,
- edge files: zero-byte, huge, corrupt, unsupported, symlinks.
Each file carries ground-truth labels enabling precision/recall assertions.

## 3. Engine acceptance thresholds (gate)
On the default corpus:
- Exact recall = 1.0, precision = 1.0.
- Near-dup text precision ≥ 0.95, recall ≥ 0.90.
- Semantic (stub-driven, controlled vectors): deterministic pass/fail on known pairs.
- Clustering: no file in >1 final group; strongest-type label correct.
- Invariant: every group has non-empty explanation, confidence ∈ [0,1].

## 4. Critical safety tests (must always pass)
- **No permanent delete:** a test/lint rule asserts `FileManager.removeItem`/`unlink` is never called on user-file URLs anywhere in app/engine code. Deletion path uses `trashItem`/`recycle` only.
- **Undo restores:** trash N files → undo → all restored, groups reappear, index consistent.
- **Cancellation consistency:** cancel at 50% → store passes integrity check, resumable.
- **Crash-resume:** kill process mid-scan (simulated) → relaunch → consistent index.
- **No pre-selection:** results never have files pre-checked for deletion.

## 5. Privacy/egress test (CI-gating, NFR-1)
- Run a full scan in a test that fails if **any** outbound socket carrying file-derived data is opened. Strategy: inject a network-monitoring shim / run under a sandbox profile denying network and assert scan still succeeds; assert zero connections from engine/store code paths. Sparkle update check is isolated and excluded (it transmits no file data).

## 6. UI tests (XCUITest + ViewInspector)
- First-run onboarding → choose folder → scan → results appear.
- Compare opens, diff highlights the changed date for the contract fixture.
- Select-all-but-keeper → Move to Trash → confirm → toast → ⌘Z undo.
- Ignore group → not present after re-scan.
- Keyboard-only completion of the delete flow (a11y).

## 7. Coverage & CI
- Engine package target ≥ 85% line coverage; safety paths 100%.
- CI matrix: build, lint (`swiftlint --strict`), format check, unit+integration, snapshot, 10k perf, egress test. All gate merge.
- Nightly: 50k/200k perf, full snapshot suite.

## 8. Test data hygiene
Fixtures are synthetic only — no real personal documents in the repo. CorpusGen output is git-ignored and regenerated.

## Open Questions
- Snapshot tolerance for material/vibrancy rendering differences across OS minor versions.

## Future Improvements
- Mutation testing on the cascade.
- Fuzzing the extractors with malformed PDFs/docx.

## Related Documents
- `PERFORMANCE.md`, `FEATURES.md`, `ERROR_HANDLING.md`, `SECURITY.md`.
