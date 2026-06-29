# GLOSSARY.md — Terminology

> **Purpose:** Pin the meaning of every domain term so docs and code stay consistent.
> **Scope:** Detection, product, and engineering vocabulary.
> **Dependencies:** None.

- **Cascade** — the cost-ordered pipeline (Stage 0→3) that narrows files to explained duplicate groups. The engine's core.
- **Exact duplicate** — byte-identical files (equal SHA-256). Match type `.exact`, confidence 1.0.
- **Near-duplicate (text)** — small-edit variants (e.g., contract with changed date). Detected via MinHash+LSH Jaccard. `.nearText`.
- **Near-duplicate (image, V2)** — visually similar via perceptual hash (dHash/pHash). `.nearImage`.
- **Semantic match** — same meaning, different words; via on-device embeddings + cosine. `.semantic`. Opt-in (Deep scan).
- **Shingle** — a k-word (default 5) sliding window over normalized text; input to MinHash.
- **MinHash** — compact set-similarity signature estimating Jaccard between shingle sets.
- **LSH (banding)** — locality-sensitive hashing that buckets similar signatures so we avoid O(n²) comparisons.
- **Embedding** — a vector representation of content from a swappable `EmbeddingProvider`; stored with a `modelID` for cache invalidation.
- **Duplicate group** — a cluster of related files with a match type, confidence, explanation, and suggested keeper.
- **Keeper** — the file suggested to be retained in a group (heuristic: newest → largest → shortest path; user-overridable). Never auto-deletes others.
- **Explanation** — the mandatory human-readable reason a group exists. Never empty (invariant).
- **Match edge** — a pairwise relationship (with score + reason) powering the compare view.
- **Union-find** — disjoint-set structure merging pairwise matches into final groups.
- **Signature (file)** — `(size, mtime, inode/fileID)` used for identity and incremental skip.
- **Incremental scan** — re-scan that reprocesses only files whose signature changed.
- **Security-scoped bookmark** — sandbox mechanism granting persistent access to user-selected folders.
- **Trash-only deletion** — the only deletion path: move to Trash, fully reversible. Never `removeItem`/`unlink`.
- **Deep scan** — opt-in run of the semantic (embedding) stage on Stage-2 survivors.
- **Needs OCR** — a scanned PDF without a text layer; flagged, OCR is opt-in.
- **Skipped** — a file that couldn't be processed (unreadable/unsupported/etc.), recorded with an issue and surfaced, never silently dropped.
- **EmbeddingProvider** — protocol abstracting the embedding model (Stub for dev/tests, Core ML in prod).
- **IndexStore** — the SQLite (GRDB) persistence layer; the only module that touches SQL.
- **DetectionEngine** — the pure-Swift, UI-free package implementing the cascade.

## Related Documents
- `ARCHITECTURE.md`, `DATA_MODEL.md`, `FEATURES.md`.
