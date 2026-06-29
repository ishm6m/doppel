# ARCHITECTURE.md — Technical Architecture & System Design

> **Purpose:** Define modules, the detection cascade, concurrency model, and data flow so Claude Code can implement engine and app without guessing structure.
> **Scope:** System decomposition, the cascade in detail, concurrency, persistence boundaries, error/observability strategy at the architectural level.
> **Dependencies:** `PRD.md`, `DATA_MODEL.md`, `CLAUDE.md`.

---

## 1. Architectural principles

1. **Engine is UI-agnostic.** `DetectionEngine` is a pure Swift package with **zero** SwiftUI/AppKit imports. It can run in a CLI, a test, or the app.
2. **Cost-ordered cascade.** Each file climbs only as far as needed. Expensive stages process only survivors.
3. **Actor-isolated mutable state.** The scan coordinator is an `actor`. Stages are stateless and parallelizable.
4. **Persistence behind one door.** Only `IndexStore` touches SQLite. UI and engine speak to it through protocols.
5. **Stream, don't accumulate.** Results flow as an `AsyncStream` of events; the UI renders incrementally. We never hold the whole corpus in memory.

---

## 2. Module dependency graph

```
            ┌────────────────────────┐
            │   Doppel (App, SwiftUI)│
            └───────────┬────────────┘
                        │ depends on
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
 ┌────────────┐  ┌────────────┐  ┌────────────┐
 │ DoppelKit  │  │ IndexStore │  │DetectionEng│
 │ (models,   │  │ (GRDB/SQL) │  │ (cascade)  │
 │  utils)    │  └─────┬──────┘  └─────┬──────┘
 └─────┬──────┘        │               │
       │               └──────┬────────┘
       └──────────────────────┘
        DoppelKit is the shared leaf; nothing depends on the App.
```

Rules:
- `DetectionEngine` → may depend on `DoppelKit` only. **Not** on `IndexStore` or UI.
- `IndexStore` → depends on `DoppelKit` + GRDB.
- App → depends on all three.
- No cycles. Enforced by SPM package boundaries.

---

## 3. The Detection Cascade (the core)

The cascade transforms a set of file URLs into a set of explained duplicate groups. Each stage **narrows** the candidate set.

### Stage 0 — Enumeration & signature
- Walk selected roots with `FileManager.enumerator`, respecting `.skipsHiddenFiles`, the user's type scopes, and the ignore list.
- Compute a cheap **file signature**: `(size, mtime, inode/fileID)`. Path is metadata, not identity.
- Group candidates by **size bucket**. Files alone in a size bucket *for the exact-hash path* can skip Stage 1's hash (but still proceed to content stages if their type qualifies for near-dup). Keep this nuance: size-uniqueness rules out *byte* duplicates, not *near* duplicates.
- Emit `ScanEvent.discovered(count)`.

### Stage 1 — Exact hash
- For each size-collision group, compute **SHA-256** (streamed, 1 MB chunks; never load whole file).
- Equal hashes ⇒ **exact-duplicate group**, match type `.exact`, confidence `1.0`, explanation `"Identical file contents"`.
- Exact dupes are removed from later content stages (one representative carries forward for content stages so we still cross-match against *other* files).

### Stage 2 — Cheap content fingerprint
Per file type:
- **Text/PDF-with-text-layer:** extract normalized text (see Extractors), tokenize, shingle (k=5 word shingles), compute **MinHash** signature (e.g., 128 permutations). Bucket via **LSH bands** so only plausibly-similar docs are compared. Estimate Jaccard from signatures.
  - Jaccard ≥ `nearDupTextThreshold` (default ~0.85) ⇒ **near-dup text group**, match type `.nearText`, confidence = estimated Jaccard, explanation derived from a quick diff summary ("Near-identical text — N changed regions").
- **Images (V2):** dHash + pHash; Hamming distance ≤ threshold ⇒ `.nearImage`.
- **Scanned PDF (no text layer):** flagged `.needsOCR`; not fingerprinted unless OCR pass enabled.

Stage 2 outputs **candidate clusters** — small groups of files that *might* be semantically related but didn't meet the near-dup bar, **plus** confirmed near-dup groups.

### Stage 3 — Semantic embedding (expensive, survivors only)
- Runs **only** on candidate clusters that Stage 2 flagged as "similar but below near-dup threshold," or when the user explicitly requests deep semantic scan.
- Extract embedding via `EmbeddingProvider` (text model; CLIP-class for images in V2).
- Compare with **cosine similarity** within the LSH-bucketed candidate set (never all-pairs across the corpus).
- Similarity ≥ `semanticThreshold` ⇒ **semantic group**, match type `.semantic`, confidence = cosine score, explanation `"Semantically similar content"` plus the top differing/similar passages where cheaply available.

### Clustering
- Across all stages, matches are edges in a graph; **union-find (disjoint set)** merges them into final groups.
- A file can belong to exactly one final group (highest-confidence edge wins on conflict; ties broken by match-type priority `exact > nearText/nearImage > semantic`).
- Each group records the **strongest** match type as its label but retains per-pair reasons for the compare view.

### Cascade pseudocode (engine-level)

```
func scan(roots) -> AsyncStream<ScanEvent> {
  let files = enumerate(roots)                    // Stage 0
  emit .discovered(files.count)
  let exactGroups = hashAndGroup(files)           // Stage 1
  emit groups(exactGroups)
  let survivors = representatives(files, removing: exactDupesWithin(exactGroups))
  let (nearGroups, candidates) = fingerprint(survivors)  // Stage 2
  emit groups(nearGroups)
  if deepEnabled {
    let semGroups = embedAndCompare(candidates)   // Stage 3
    emit groups(semGroups)
  }
  let final = unionFind(exactGroups + nearGroups + semGroups)
  emit .finished(final)
}
```

Every `emit` persists incrementally via `IndexStore` so a crash loses at most the in-flight batch.

---

## 4. Concurrency model

- **`ScanCoordinator` is an `actor`** owning scan state, cancellation, and progress.
- Stages 1–3 are **CPU/IO-parallel** via `withThrowingTaskGroup`, bounded by a concurrency limit (`ProcessInfo.activeProcessorCount`, capped to avoid thermal/IO thrash). Hashing and extraction are IO-bound; embedding is NE/GPU-bound and is throttled separately (a dedicated bounded queue so we don't oversubscribe the Neural Engine).
- **Backpressure:** results are produced into an `AsyncStream` with a bounded buffer; if the UI lags, production slows rather than ballooning memory.
- **Cancellation:** cooperative — every stage checks `Task.isCancelled` between files and flushes the current batch to the store before returning.
- **Swift 6 strict concurrency:** all shared types are `Sendable`; engine compiles clean under complete checking.

---

## 5. Persistence boundary

- `IndexStore` (GRDB) holds: file records, signatures, hashes, MinHash signatures, embeddings (as BLOBs), groups, group memberships, ignore list, scan history. See `DATA_MODEL.md`.
- The store exposes an **async protocol** (`IndexStoring`) so the engine and UI never see SQL. Tests use an in-memory implementation.
- **Incremental scans** query the store for existing signatures and skip unchanged files (FR-4).

---

## 6. App layer (SwiftUI)

- **Pattern:** MVVM with a thin `AppEnvironment` for dependency injection (manual constructor injection; see `STATE_MANAGEMENT.md`).
- **Windows:** main window (NavigationSplitView: sidebar = sources/scans, content = results, inspector = details/compare), Settings window (native `Settings` scene), onboarding window.
- ViewModels are `@Observable` (Observation framework), `@MainActor`, and consume engine `AsyncStream`s.

---

## 7. Observability

- `OSLog` `Logger` per subsystem (`engine`, `store`, `ui`, `update`). **No file contents, names, or paths in logs** at default level (paths only at `.debug` and redacted in release). See `SECURITY.md`.
- Signposts (`OSSignposter`) around each cascade stage for Instruments-based perf work (`PERFORMANCE.md`).

---

## 8. Failure isolation

- A single unreadable/corrupt file never fails the scan: it's caught, recorded as `FileIssue`, surfaced in a "Skipped (N)" affordance, and the scan continues. See `ERROR_HANDLING.md`.

---

## Open Questions
- Embedding throttle: fixed concurrency vs adaptive based on thermal state?
- Should Stage 3 ever run automatically on near-dup *survivors*, or strictly user-initiated, to protect battery? (Default: user-initiated "Deep scan" button.)

## Future Improvements
- Pluggable extractor registry for new file types.
- Persisted embeddings reused across scans for instant re-clustering.

## Related Documents
- `DATA_MODEL.md`, `STATE_MANAGEMENT.md`, `PERFORMANCE.md`, `API.md`, `ERROR_HANDLING.md`.
