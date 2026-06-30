# API.md — Internal Service Contracts

> **Purpose:** Define the internal protocol boundaries between modules so they can be built and tested independently. **No external/network APIs exist** — Doppel is offline.
> **Scope:** Public interfaces of `DetectionEngine`, `IndexStore`, `EmbeddingProvider`, and the app-facing service layer.
> **Dependencies:** `ARCHITECTURE.md`, `DATA_MODEL.md`.

All async APIs use Swift Concurrency. All shared types are `Sendable`. Interfaces are protocols with test doubles.

---

## 1. Engine: `ScanCoordinating`

```swift
public protocol ScanCoordinating: Sendable {
    /// Starts a scan; returns a stream of events. Cancelling the Task cancels the scan.
    func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error>

    // M3+ — NOT YET IMPLEMENTED. The shipped protocol has `scan` only (see Contracts.swift).
    /// Runs the opt-in semantic stage over a finished scan's survivors.
    func deepScan(sessionID: Int64) -> AsyncThrowingStream<ScanEvent, Error>
    /// Runs OCR over needsOCR files then re-fingerprints.
    func runOCR(sessionID: Int64) -> AsyncThrowingStream<ScanEvent, Error>
}

public struct ScanRequest: Sendable {
    public var roots: [URL]          // app resolves security-scoped bookmarks -> URLs before calling the engine
    public var scopes: Set<FileTypeScope>
    public var config: DetectionConfig
    public var knownSignatures: Set<FileSignature>   // incremental re-scan: signatures the store already has
}

public struct DetectionConfig: Sendable {
    public var nearDupTextThreshold: Double      // default 0.85
    public var semanticThreshold: Double         // default pending model
    public var minhashPermutations: Int          // default 128
    public var shingleSize: Int                  // default 5
    public var ocrEnabled: Bool                  // default false
    public var maxConcurrency: Int               // default activeProcessorCount
}

public enum ScanEvent: Sendable {
    case discovered(total: Int)
    case progress(phase: ScanPhase, processed: Int, total: Int?)
    case groupFound(DuplicateGroup, members: [FileRecord])
    case fileSkipped(FileRecord, FileIssue)
    case finished(summary: ScanSummary)
    case cancelled(partial: ScanSummary)
}

public enum ScanPhase: String, Sendable {
    case enumerating, hashing, extracting, fingerprinting, embedding, clustering
}

public struct ScanSummary: Sendable {
    public var filesDiscovered: Int
    public var groupsFound: Int
    public var bytesReclaimable: Int64
    public var skippedCount: Int
}
```

**Contract notes**
- Events are emitted in stage order; `groupFound` may arrive interleaved as stages complete.
- Cancellation always yields a `.cancelled(partial:)` with a consistent index.

**Session ownership (decided 2026-06-29).** The **app-side `ScanService` owns session lifecycle, not the engine.** The `DetectionEngine` is pure (no IndexStore import — see Contracts.swift): it cannot allocate a DB-backed session id, and its `FileRecord.id`s are scan-local counters that would collide with DB ids. So `ScanService` calls `createSession(...)` to get the real `sessionID` *before* the scan, holds it, tags each persisted group with it on `.groupFound`, and `updateSession(...)` on `.finished`. Consequently `ScanSummary` carries **no** `sessionID` — the engine never knows it. **Done:** `IndexStoring.saveGroup(_:members:edges:sessionID:)` takes the owning session, `groups(sessionID:)` filters by it, and the `scan_session(id:0)` sentinel is gone (groups now require a real session created first). `ScanService` wiring still pending (no app target buildable here — needs full Xcode).

---

## 2. Persistence: `IndexStoring`

```swift
public protocol IndexStoring: Sendable {
    // sources
    func addSource(_ bookmark: SourceBookmark) async throws -> Int64
    func sources() async throws -> [SourceBookmark]
    func removeSource(id: Int64) async throws            // cascades

    // files
    func upsertFiles(_ files: [FileRecord]) async throws
    func unchangedFileIDs(matching sigs: [FileSignature]) async throws -> Set<Int64>
    func file(id: Int64) async throws -> FileRecord?
    func markDeleted(ids: [Int64]) async throws
    func restore(ids: [Int64]) async throws              // undo support

    // groups
    func saveGroup(_ g: DuplicateGroup, members: [Int64], edges: [MatchEdge]) async throws -> Int64
    func groups(sessionID: Int64) async throws -> [DuplicateGroup]
    func setKeeper(groupID: Int64, fileID: Int64) async throws
    func ignoreGroup(_ groupID: Int64) async throws
    func ignorePair(_ a: Int64, _ b: Int64) async throws
    func ignoredPairs() async throws -> Set<Pair>

    // embeddings
    func saveEmbedding(_ e: Embedding) async throws -> Int64
    func embedding(id: Int64) async throws -> Embedding?
    func invalidateEmbeddings(notModel modelID: String) async throws

    // sessions
    func createSession(_ s: ScanSession) async throws -> Int64
    func updateSession(_ s: ScanSession) async throws
    func sessions() async throws -> [ScanSession]
}
```

Implementations: `GRDBIndexStore` (prod), `InMemoryIndexStore` (tests). All methods are actor-safe.

---

## 3. ML: `EmbeddingProvider`

```swift
public protocol EmbeddingProvider: Sendable {
    var modelID: String { get }       // identifies model for cache invalidation
    var dimension: Int { get }
    func embed(text: String) async throws -> [Float]
    // V2: func embed(image: CGImage) async throws -> [Float]
}
```

Implementations:
- `StubEmbeddingProvider` — deterministic vectors from a seeded hash of input; used in dev/tests so Stage 3 is fully testable without a real model.
- `CoreMLEmbeddingProvider` — wired once a model is pinned (gated task T7.4).

**Cosine** similarity helper lives in `DoppelKit`; comparisons happen only within LSH candidate buckets.

---

## 4. Extraction: `ContentExtractor`

```swift
public protocol ContentExtractor: Sendable {
    func canHandle(_ kind: ContentKind) -> Bool
    func extract(_ url: URL) async throws -> ExtractedContent
}

public struct ExtractedContent: Sendable {
    public var normalizedText: String?     // nil for images / scanned-no-OCR
    public var contentKind: ContentKind
    public var needsOCR: Bool
}
```

Registry pattern: `ExtractorRegistry` picks the right extractor by `ContentKind` (text, pdf, docx, image). New types = new extractor, no engine change.

---

## 5. App service layer: `ScanService` (MainActor-facing)
Thin adapter the ViewModels use: wraps `ScanCoordinating` + `IndexStoring`, exposes `@Observable` state and high-level intents (`startScan`, `cancel`, `deepScan`, `trash(ids:)`, `undoLastDeletion`, `ignore(group:)`). Handles security-scoped resource access lifecycle. See `STATE_MANAGEMENT.md`.

## Open Questions
- Should `deepScan` reuse cached embeddings across sessions? (Yes, once stable — keyed by `modelID`.)

## Future Improvements
- A `CLIInterface` exposing the same protocols.

## Related Documents
- `ARCHITECTURE.md`, `DATA_MODEL.md`, `STATE_MANAGEMENT.md`, `TESTING.md`.
