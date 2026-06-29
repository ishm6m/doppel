# ERROR_HANDLING.md — Errors, Recovery & Edge Cases

> **Purpose:** Enumerate failure modes and define exact handling so nothing fails silently or destructively.
> **Scope:** Error taxonomy, per-error UX, recovery strategies, edge-case inventory.
> **Dependencies:** `ARCHITECTURE.md`, `STATE_MANAGEMENT.md`, `USER_FLOWS.md`.

**Principle:** A single bad file must never fail a scan; a failure must never cause data loss; every error has a user-understandable message and a path forward.

---

## 1. Error taxonomy

```swift
enum DoppelError: Error {
    case fileUnreadable(URL)
    case fileTooLarge(URL, Int64)
    case unsupportedType(URL)
    case decodeFailed(URL, underlying: Error)
    case permissionDenied(URL)
    case staleBookmark(SourceBookmark)
    case trashFailed(URL, underlying: Error)
    case storeUnavailable(underlying: Error)
    case ocrUnavailable
    case embeddingModelMissing
    case cancelled
}
```

Severity tiers: **per-file** (recoverable, continue) vs **fatal** (abort scan, recover app).

---

## 2. Per-file errors (scan continues)
| Error | Handling | UX |
|---|---|---|
| `fileUnreadable` / `permissionDenied` | catch, record `FileIssue`, continue | counted in "Skipped (N)" with reason + Reveal in Finder |
| `fileTooLarge` | skip content stages (still hash if feasible) | shown as skipped with size note (threshold in config) |
| `unsupportedType` | skip silently from results, count in skipped | only shown if user expands Skipped |
| `decodeFailed` | record, continue | skipped with "couldn't read contents" |
| scanned PDF | not an error — `needsOCR` | "Needs OCR (N)" section, opt-in Run OCR |

Per-file failures emit `ScanEvent.fileSkipped`. They never bubble up to fail the stream.

## 3. Fatal errors (abort + recover)
| Error | Handling | UX |
|---|---|---|
| `storeUnavailable` | abort scan, attempt DB recovery (integrity check, rebuild if corrupt) | recovery screen: "Rebuild index" action; never auto-deletes data |
| `staleBookmark` (at start) | prompt re-grant before scanning that source | inline re-grant button on source row |
| `trashFailed` | **do not** fall back to permanent delete | error toast: "Couldn't move to Trash"; file remains; retry option |
| `embeddingModelMissing` | only blocks Deep scan | Deep scan button explains "model not configured"; normal scan unaffected |

## 4. Recovery strategies
- **Crash/force-quit mid-scan:** incremental persistence means the index is consistent up to the last flushed batch. On relaunch, the partial session is marked `cancelled`; user can re-scan (incremental skips done work). No corruption (WAL + transactions).
- **DB corruption:** run `PRAGMA integrity_check`; if failed, offer rebuild (re-enumerate). User data (their files) is never touched by a rebuild.
- **Partial deletion failure:** batch trash reports per-file results; successes are recorded, failures listed for retry. Index stays consistent with reality.

## 5. Edge-case inventory (must all be handled & tested)
- Empty folder / no in-scope files → friendly empty state, not error.
- Symlinks/aliases → resolve; avoid infinite loops (visited-set); don't follow into excluded volumes.
- Files changing during scan (size/mtime mid-read) → detect, re-queue or skip with note.
- Zero-byte files → group exact among themselves but flag (likely placeholders); never auto-suggest deleting all copies of a 0-byte set without keeper.
- Duplicate of the keeper across multiple groups → union-find ensures one final group.
- Network/removable volume disappears mid-scan → treat as permission/unreadable, continue, note in skipped.
- Extremely large single file → stream hash; if over content-size cap, skip content stages.
- Same file referenced via two bookmarks (overlapping roots) → dedupe by file identity, don't double-count.
- Trash disabled / unavailable → surface, never permanent-delete.
- Reduced disk space for index → warn, allow choosing index location (advanced).

## 6. Logging on error
Log via `OSLog` at appropriate level **without** file contents; paths only at `.debug`, redacted in release (see `SECURITY.md`). User-facing messages are plain-language, not raw errors.

## Open Questions
- Default `fileTooLarge` content cap (e.g., 50 MB for text extraction)? Make configurable.

## Future Improvements
- "Retry all skipped" action.

## Related Documents
- `USER_FLOWS.md`, `STATE_MANAGEMENT.md`, `SECURITY.md`, `TESTING.md`.
