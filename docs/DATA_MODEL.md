# DATA_MODEL.md — Data Models, Entities & Storage

> **Purpose:** Define every entity, relationship, and the SQLite schema so the engine and store are unambiguous.
> **Scope:** Domain models (DoppelKit), persistence schema (IndexStore/GRDB), storage strategy, migrations.
> **Dependencies:** `ARCHITECTURE.md`.

---

## 1. Storage strategy (why two stores)

- **GRDB / SQLite (`IndexStore`)** — the scan index: potentially millions of rows, bulk inserts, FTS, BLOB storage of hashes/MinHash/embeddings. SwiftData is unsuitable at this scale and for raw BLOB perf.
- **SwiftData (or `UserDefaults` + a small store)** — app-level prefs & lightweight session state (last window layout, onboarding-complete). Small, low-churn.

Rule: **all scan/detection data lives in SQLite.** Do not put file records in SwiftData.

DB file location: `~/Library/Application Support/Doppel/index.sqlite` (outside the sandbox container only if non-sandboxed; in sandbox it's inside the container). WAL mode on. Encrypted at rest only if user enables FileVault (we do not add SQLCipher in MVP; flagged in `SECURITY.md`).

---

## 2. Domain models (DoppelKit, `Sendable` value types)

```swift
struct FileRecord: Identifiable, Sendable, Hashable {
    let id: Int64                 // db rowid
    let bookmarkID: Int64         // which security-scoped source
    var relativePath: String      // path relative to bookmark root
    var displayName: String
    var sizeBytes: Int64
    var mtime: Date
    var fileID: UInt64?           // inode / file resource id (identity, not path)
    var typeScope: FileTypeScope  // .document / .image / .other
    var contentKind: ContentKind  // .text, .pdfTextLayer, .pdfScanned, .image, .unknown
    var sha256: Data?             // 32 bytes, nil until Stage 1
    var minhash: Data?            // packed UInt64 signature, nil until Stage 2 (text)
    var phash: UInt64?            // perceptual hash (images, V2)
    var embeddingID: Int64?       // FK to Embedding, nil unless Stage 3 ran
    var status: FileStatus        // .indexed, .skipped, .needsOCR, .error
    var issue: FileIssue?         // populated when status == .error/.skipped
}

enum MatchType: String, Sendable { case exact, nearText, nearImage, semantic }

struct DuplicateGroup: Identifiable, Sendable {
    let id: Int64
    var matchType: MatchType      // strongest type in the group
    var confidence: Double        // 0...1, representative confidence
    var explanation: String       // human-readable, never empty (invariant)
    var keeperFileID: Int64       // suggested keeper (user-overridable)
    var memberFileIDs: [Int64]
    var ignored: Bool             // user marked "not duplicates"
    var createdAt: Date
}

struct MatchEdge: Sendable {      // pairwise reason, powers compare view
    let groupID: Int64
    let fileA: Int64
    let fileB: Int64
    let matchType: MatchType
    let score: Double
    let reasonSummary: String     // e.g. "2 changed regions (dates)"
}

struct ScanSession: Identifiable, Sendable {
    let id: Int64
    var startedAt: Date
    var finishedAt: Date?
    var rootBookmarkIDs: [Int64]
    var scopes: Set<FileTypeScope>
    var filesDiscovered: Int
    var groupsFound: Int
    var bytesReclaimable: Int64
    var state: ScanState          // .running, .cancelled, .finished, .failed
}

struct SourceBookmark: Identifiable, Sendable {
    let id: Int64
    var bookmarkData: Data        // security-scoped
    var displayPath: String
    var addedAt: Date
}

enum ContentKind: String, Sendable { case text, pdfTextLayer, pdfScanned, image, unknown }
enum FileStatus: String, Sendable { case indexed, skipped, needsOCR, error }
enum FileTypeScope: String, Sendable, CaseIterable { case document, image, other }
enum ScanState: String, Sendable { case running, cancelled, finished, failed }

struct FileIssue: Sendable, Codable {
    enum Kind: String, Codable { case unreadable, unsupported, decodeFailed, tooLarge, permissionDenied }
    let kind: Kind
    let message: String
}
```

**Invariant (test-enforced):** `DuplicateGroup.explanation` is never empty and `confidence ∈ [0,1]`.

---

## 3. SQLite schema (GRDB migrations)

```sql
-- v1
CREATE TABLE source_bookmark (
  id INTEGER PRIMARY KEY,
  bookmark_data BLOB NOT NULL,
  display_path TEXT NOT NULL,
  added_at REAL NOT NULL
);

CREATE TABLE file_record (
  id INTEGER PRIMARY KEY,
  bookmark_id INTEGER NOT NULL REFERENCES source_bookmark(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  display_name TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  mtime REAL NOT NULL,
  file_id INTEGER,                       -- inode/fileID
  type_scope TEXT NOT NULL,
  content_kind TEXT NOT NULL,
  sha256 BLOB,
  minhash BLOB,
  phash INTEGER,
  embedding_id INTEGER REFERENCES embedding(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  issue_json TEXT,
  UNIQUE(bookmark_id, relative_path)
);
CREATE INDEX idx_file_size ON file_record(size_bytes);
CREATE INDEX idx_file_sha ON file_record(sha256);
CREATE INDEX idx_file_status ON file_record(status);

CREATE TABLE embedding (
  id INTEGER PRIMARY KEY,
  model_id TEXT NOT NULL,                -- which model produced it (for invalidation)
  dim INTEGER NOT NULL,
  vector BLOB NOT NULL                   -- float32 packed
);

CREATE TABLE lsh_bucket (                -- Stage 2 banding for text near-dup
  band INTEGER NOT NULL,
  bucket_hash INTEGER NOT NULL,
  file_id INTEGER NOT NULL REFERENCES file_record(id) ON DELETE CASCADE
);
CREATE INDEX idx_lsh ON lsh_bucket(band, bucket_hash);

CREATE TABLE duplicate_group (
  id INTEGER PRIMARY KEY,
  scan_id INTEGER NOT NULL REFERENCES scan_session(id) ON DELETE CASCADE,
  match_type TEXT NOT NULL,
  confidence REAL NOT NULL,
  explanation TEXT NOT NULL,
  keeper_file_id INTEGER NOT NULL REFERENCES file_record(id),
  ignored INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);

CREATE TABLE group_member (
  group_id INTEGER NOT NULL REFERENCES duplicate_group(id) ON DELETE CASCADE,
  file_id INTEGER NOT NULL REFERENCES file_record(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, file_id)
);

CREATE TABLE match_edge (
  group_id INTEGER NOT NULL REFERENCES duplicate_group(id) ON DELETE CASCADE,
  file_a INTEGER NOT NULL,
  file_b INTEGER NOT NULL,
  match_type TEXT NOT NULL,
  score REAL NOT NULL,
  reason_summary TEXT NOT NULL
);

CREATE TABLE scan_session (
  id INTEGER PRIMARY KEY,
  started_at REAL NOT NULL,
  finished_at REAL,
  scopes_json TEXT NOT NULL,
  files_discovered INTEGER NOT NULL DEFAULT 0,
  groups_found INTEGER NOT NULL DEFAULT 0,
  bytes_reclaimable INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL
);

CREATE TABLE ignore_pair (               -- persisted "not duplicates"
  file_a INTEGER NOT NULL,
  file_b INTEGER NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY (file_a, file_b)
);
```

### Migration policy
- Use GRDB `DatabaseMigrator` with named, append-only migrations (`v1`, `v2`, …). Never edit a shipped migration.
- If the embedding **model changes**, embeddings with a stale `model_id` are invalidated (set `embedding_id = NULL`, delete orphan rows) and recomputed lazily — never silently compared across models.

---

## 4. Identity & incremental rules

- **File identity** = `(bookmark_id, file_id)` when `file_id` is available, else `(bookmark_id, relative_path)`. This lets us follow renames/moves within a source.
- **Unchanged file** = same identity AND same `(size_bytes, mtime)` ⇒ skip re-hash/extract on incremental scan.
- **Keeper default heuristic:** newest `mtime`, tiebreak largest `size_bytes`, tiebreak shortest `relative_path`. User override persists per group.

---

## 5. Storage budgets
- Per file: ~ a few hundred bytes of metadata + 32 B sha + ~1 KB MinHash + optional embedding (dim×4 B). For 1M files with embeddings (dim 384) ≈ ~1.5–2 GB DB. Embeddings are the dominant cost ⇒ they are **opt-in/lazy** (Stage 3 only).

## Open Questions
- Store extracted text for diff caching, or re-extract on demand? (MVP: re-extract for compare; cache only if perf demands.)

## Future Improvements
- FTS5 table for full-text search over indexed documents.

## Related Documents
- `ARCHITECTURE.md`, `API.md`, `PERFORMANCE.md`, `SECURITY.md`.
