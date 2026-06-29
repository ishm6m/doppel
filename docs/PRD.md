# PRD.md — Product Requirements Document

> **Purpose:** Define what Doppel is, who it's for, what it must do, and how we'll know it succeeded.
> **Scope:** Product vision, personas, requirements (functional + non-functional), scope boundaries, success metrics.
> **Dependencies:** None (upstream of all other docs).

---

## 1. Vision

Most duplicate finders are stuck in 2010: they match on filename, size, and exact byte hash. They cannot tell you that two files are *the same document with a different date*, or *the same photo re-exported at a different size*. Doppel closes that gap by reading **content** and understanding **near-duplication and semantic similarity** — entirely on-device, so the most private data a person owns never leaves their Mac.

**Positioning statement:** For privacy-conscious Mac power users drowning in document and photo clutter, Doppel is an offline duplicate finder that understands content, so they can reclaim disk space and sanity without trusting a cloud or fearing accidental deletion.

---

## 2. Goals & non-goals

### Goals
- Detect exact, near-duplicate, and semantically-similar **documents** (text + PDF) in the MVP.
- Make every result **explainable** and every deletion **safe and reversible**.
- Run **100% offline** with competitive speed on large libraries (100k+ files).
- Feel like a **first-party Apple app**.

### Non-goals (explicitly out of scope)
- Cloud sync, accounts, or any server component.
- Cross-platform (Windows/Linux) — macOS only.
- Generic file management / cleaning beyond duplicates.
- Editing or merging file contents.
- "AI assistant" chat features.

---

## 3. Target users (personas)

| Persona | Need | Why Doppel |
|---|---|---|
| **Priya, privacy-first freelancer** | Years of contracts/invoices as PDFs, many near-identical versions | Finds "same contract, different date"; never uploads her clients' data |
| **Marcus, photographer (V2)** | 200k+ images, many re-exports/screenshots | Perceptual + semantic image dedup, fast, local |
| **Dana, ops/compliance (V3)** | Shared drive with redundant policy docs | Scheduled, explainable dedup with audit trail |

MVP optimizes for **Priya**.

---

## 4. Functional requirements

IDs are stable references used across docs and `TASKS.md`.

### Scanning
- **FR-1** User can select one or more folders (or drag-drop) to scan. The app requests and persists security-scoped bookmarks for access.
- **FR-2** User can configure file-type scopes (Documents: txt/md/rtf/pdf/docx/pages; Images V2). Default = Documents.
- **FR-3** Scan reports live progress: files discovered, stage reached, candidates, ETA, and is cancellable at any time without corrupting the index.
- **FR-4** Scans are **incremental**: a re-scan only re-processes files whose `(path, size, mtime, inode)` signature changed.

### Detection
- **FR-5** Stage 1 detects **exact duplicates** via SHA-256.
- **FR-6** Stage 2 detects **near-duplicate text** via MinHash+LSH (and near-duplicate images via perceptual hash in V2).
- **FR-7** Stage 3 detects **semantic matches** via on-device embeddings + cosine similarity, run only on Stage-2 survivors and configurable-threshold.
- **FR-8** PDFs with a text layer are extracted via PDFKit; scanned PDFs are **detected** and flagged "OCR needed" (OCR runs as an opt-in pass in V1).
- **FR-9** Detected files are grouped into **duplicate groups**; each group has a match type, a confidence score, and a human-readable explanation.

### Reviewing & acting
- **FR-10** Results are shown grouped, with a suggested **keeper** (default heuristic: newest, then largest, then shortest path — user-overridable).
- **FR-11** User can open a **side-by-side comparison**: for documents, a text **diff** highlighting changed regions (e.g., dates, signature blocks).
- **FR-12** User can select non-keeper files and **move them to Trash**, with multi-select, select-all-but-keeper, and full **undo**.
- **FR-13** No file is ever selected for deletion by default; no deletion happens without explicit confirmation.
- **FR-14** User can mark a group as "not duplicates" (ignore), persisted so it won't reappear.

### App
- **FR-15** First-run **onboarding** explains privacy guarantees and requests folder access.
- **FR-16** Native **Settings** window: scan scopes, thresholds, model selection, ignore list, OCR toggle.
- **FR-17** Scan **history**: prior scans with summary stats; re-open results.

---

## 5. Non-functional requirements

- **NFR-1 Privacy:** zero outbound transmission of file-derived data (see `SECURITY.md`). Verified by a network-egress test in CI.
- **NFR-2 Safety:** all deletions reversible (Trash + in-app undo). No `removeItem` on user files anywhere in the codebase (enforced by a lint rule / unit test).
- **NFR-3 Performance:** scan 50,000 mixed documents (avg 200 KB) in **< 5 min** on M-series, peak memory **< 1.5 GB** (see `PERFORMANCE.md` for full budgets).
- **NFR-4 Reliability:** a crash or force-quit mid-scan never corrupts the index; resume is clean.
- **NFR-5 Native feel:** passes the "first-party app" bar in `DESIGN_SYSTEM.md` and full accessibility in `ACCESSIBILITY.md`.
- **NFR-6 Sandboxed:** App Sandbox enabled, least-privilege entitlements, security-scoped bookmarks only.
- **NFR-7 Explainability:** 100% of groups carry an explanation + confidence.

---

## 6. Acceptance criteria (product-level)

- Given a folder containing a contract and a copy with only the date changed, Doppel groups them as a near-duplicate, labels it (e.g., "Near-identical text — 2 differences"), and the diff view highlights the date.
- Given two byte-identical files with different names, they appear as an exact-duplicate group.
- Deleting a non-keeper moves it to Trash and can be undone from the Edit menu and ⌘Z.
- With networking blocked at the OS level, a full scan completes successfully.
- Cancelling a scan at 50% leaves a consistent, resumable index.

---

## 7. Success metrics

| Metric | Target |
|---|---|
| Precision of near-dup document grouping on test corpus | ≥ 0.95 |
| Recall of exact + near-dup on test corpus | ≥ 0.98 / ≥ 0.90 |
| False "these are different" deletions reported by users | ~0 (safety net should make impossible) |
| p50 scan throughput (docs) | ≥ 300 files/sec through Stage 2 |
| Crash-free sessions | ≥ 99.5% |
| GitHub stars / paid-build conversion (business) | tracked, not gating MVP |

---

## 8. Constraints & assumptions

- Single-user desktop app; no concurrency across machines.
- Embedding model is swappable and **not yet pinned** (see `CLAUDE.md` §3 note); build against `EmbeddingProvider` with a deterministic stub until evaluation completes.
- macOS 14+ only.

## Open Questions
- Do we ship OCR in V1 or V1.1? (Leaning V1.1.)
- Default semantic threshold value pending model evaluation.

## Future Improvements
- Image dedup (V2), scheduled scans + audit (V3), CLI.

## Related Documents
- `ROADMAP.md`, `FEATURES.md`, `ARCHITECTURE.md`, `USER_FLOWS.md`.
