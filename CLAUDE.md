# CLAUDE.md — Instructions for Claude Code

> **Purpose:** The single source of truth for how Claude Code should work in this repository. Read this first, every session.
> **Scope:** Conventions, guardrails, build/test commands, and the order in which to read the other docs.
> **Dependencies:** None. This is the root document.

---

## 0. What we are building (one paragraph)

**Doppel** is an open-source, **100% offline** macOS app that finds duplicate *and near-duplicate* files by understanding their **content**, not just their name and size. It reads images, PDFs, and text/Office documents and surfaces semantic duplicates — e.g. *"these two files are the same contract with different dates."* The MVP focuses on **documents** (text + PDF). Images are V2. Everything runs on-device using Apple Silicon (Core ML / MLX). **No file content ever leaves the machine.**

The name `Doppel` is a placeholder; the product name lives in one constant (`AppInfo.productName`) so it can be changed in one place.

---

## 1. Golden rules (never violate)

1. **Privacy is the product.** No network calls that transmit file content, file names, paths, hashes, or embeddings. The *only* permitted outbound network traffic is the Sparkle update check and explicit user-initiated "check for updates." If you are about to add a dependency that phones home, stop and flag it.
2. **Never destroy data irreversibly.** The app **never** calls `unlink`/`FileManager.removeItem` on user files. Deletion = move to Trash via `NSWorkspace.recycle` / `FileManager.trashItem`, always undoable.
3. **Never auto-delete or pre-check files for deletion.** The app *suggests* a "keeper"; the human confirms every destructive action.
4. **Always explain a match.** Every duplicate grouping must carry a human-readable reason and a confidence score (see `FEATURES.md` → Match Explanation). A group with no explanation is a bug.
5. **The cascade is sacred.** Cheap, deterministic stages run before expensive ML stages. Never embed a file that an earlier stage could have resolved. See `ARCHITECTURE.md` → Detection Cascade.
6. **SwiftUI-first, AppKit where SwiftUI can't reach.** Don't reach for AppKit until you've confirmed SwiftUI genuinely can't do it (document the reason in a code comment).
7. **No force-unwraps in non-test code** except documented invariants with `// SAFETY:` comments. Prefer `guard`.
8. **Concurrency: Swift Concurrency only** (`async/await`, actors, `TaskGroup`). No `DispatchQueue` except where a framework API demands it. The scan engine is an `actor`.

---

## 2. Read order for the other docs

When starting a task, read in this order and stop when you have enough context:

1. `PRD.md` — what & why, success metrics, scope boundaries.
2. `ARCHITECTURE.md` — modules, the cascade, concurrency model. **Most important technical doc.**
3. `DATA_MODEL.md` — entities, the SwiftData/GRDB schema, storage.
4. `FEATURES.md` — per-feature specs with acceptance criteria & Definition of Done.
5. `TASKS.md` — the ordered milestone plan. **Pick the next unchecked task.**
6. Then the topic doc relevant to your task: `UI_SPEC.md`, `DESIGN_SYSTEM.md`, `STATE_MANAGEMENT.md`, `ERROR_HANDLING.md`, `PERFORMANCE.md`, `SECURITY.md`, `ACCESSIBILITY.md`, `TESTING.md`, `RELEASE.md`.

---

## 3. Tech stack (fixed decisions — do not relitigate without flagging)

| Concern | Decision | Rationale |
|---|---|---|
| Min OS | macOS 14.0 (Sonoma) | SwiftData maturity, modern SwiftUI APIs. (Verify current-OS-specific APIs like Liquid Glass before use — see note below.) |
| Language | Swift 6, strict concurrency | Compile-time data-race safety for the scan engine. |
| UI | SwiftUI + AppKit bridges (`NSViewRepresentable`) | First-party feel. |
| Persistence | **GRDB.swift (SQLite)** for the scan index; SwiftData for lightweight app/session prefs | We need fast bulk inserts, FTS, and blob storage of hashes/embeddings that SwiftData handles poorly at scale. See `DATA_MODEL.md` for the split. |
| ML runtime | Core ML (preferred) with MLX fallback path | On-device, Neural Engine. |
| PDF | PDFKit (text layer) + Vision (OCR fallback) | Native, offline. |
| Text extraction | Native parsers; for `.docx`/`.xlsx` use a vendored lightweight unzip+XML reader | Avoid heavy deps. |
| Perceptual hash | Custom dHash/pHash impl (small, no dep) | V2 (images). |
| Near-dup text | MinHash + LSH (custom impl) | Core of MVP. |
| Updater | Sparkle 2 | Standard, notarization-friendly. |
| Logging | `OSLog` (`Logger`) with subsystem `com.doppel.app` | Native, privacy-aware. |
| DI | Manual constructor injection + a small `AppEnvironment` container | No DI framework. |
| Tests | XCTest + ViewInspector (snapshot via swift-snapshot-testing) | See `TESTING.md`. |

> **Model-selection note:** The *specific* on-device embedding model (text + later CLIP-class image) is intentionally **not pinned** in these docs because the best quality/size tradeoff on Apple Silicon moves fast. Treat the embedding model as a swappable `EmbeddingProvider` behind a protocol. Before pinning a model, the human will run a current evaluation. Until then, build against the protocol with a deterministic stub provider.

---

## 4. Build, run, test commands

```bash
# Resolve packages and build
xcodebuild -scheme Doppel -configuration Debug build

# Run all tests
xcodebuild test -scheme Doppel -destination 'platform=macOS'

# Lint & format (must pass before any commit)
swiftformat .
swiftlint --strict

# Generate a synthetic test corpus for the engine (see TESTING.md)
swift run CorpusGen --out ./TestCorpora/default
```

If a command above doesn't exist yet, your task may be to create it — check `TASKS.md`.

---

## 5. Working agreement for Claude Code

- **One task at a time, in `TASKS.md` order.** Each task in `TASKS.md` has a Definition of Done. Do not start the next until the current one's DoD (including tests) is met.
- **Write the test alongside the code**, never "later." Engine logic is TDD; UI gets snapshot + interaction tests.
- **Keep modules decoupled.** The `DetectionEngine` package must not import SwiftUI. The UI must not import SQLite directly — it goes through `IndexStore`.
- **Surface uncertainty.** If a doc is ambiguous or contradicts another doc, stop and write the conflict into that doc's *Open Questions* section, then ask. Do not guess on destructive-action or privacy behavior.
- **Performance is a feature.** Before merging engine work, run the perf harness (`PERFORMANCE.md`) and check against budgets.
- **Commit style:** Conventional Commits (`feat:`, `fix:`, `perf:`, `test:`, `docs:`, `refactor:`). One logical change per commit.

---

## 6. Module layout (top level)

```
Doppel/
├── Doppel/                     # App target (SwiftUI)
│   ├── App/                    # Entry point, AppEnvironment, windows
│   ├── Features/               # One folder per feature (Scan, Results, Compare, Settings, Onboarding)
│   ├── DesignSystem/           # Tokens, components, modifiers
│   └── Resources/              # Assets, models, localizations
├── Packages/
│   ├── DetectionEngine/        # PURE Swift, no UI. The cascade.
│   │   ├── Sources/Cascade/
│   │   ├── Sources/Extractors/ # text/pdf/image content extraction
│   │   ├── Sources/Hashing/    # sha256, dHash/pHash
│   │   ├── Sources/NearDup/    # MinHash, LSH, SimHash
│   │   ├── Sources/Embedding/  # EmbeddingProvider protocol + Core ML impl + stub
│   │   └── Sources/Clustering/ # union-find grouping
│   ├── IndexStore/             # GRDB persistence layer
│   └── DoppelKit/              # shared models, formatters, utilities
├── DoppelTests/
├── DoppelUITests/
└── Tools/CorpusGen/            # synthetic corpus generator
```

See `ARCHITECTURE.md` for the dependency graph and `DATA_MODEL.md` for schemas.

---

## Open Questions
- Final product name and bundle ID.
- Whether to ship MLX path in V1 or defer entirely to Core ML.

## Future Improvements
- Add a CLI target (`doppel scan ~/Documents`) sharing `DetectionEngine`.

## Related Documents
- `README.md`, `ARCHITECTURE.md`, `TASKS.md`, `PRD.md`.
