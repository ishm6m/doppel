# FEATURES.md — Feature Specifications

> **Purpose:** Per-feature specs that Claude Code can implement one at a time, each with acceptance criteria and a Definition of Done.
> **Scope:** Every MVP + V1 feature. Each entry: Purpose, Requirements, User flow, UI behavior, Business logic, State changes, Data, Error handling, Acceptance criteria, Testing, DoD.
> **Dependencies:** `PRD.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`, `UI_SPEC.md`.

Features map to FR-IDs in `PRD.md`. Build in `TASKS.md` order.

---

## F1 — Folder selection & access (FR-1, FR-15)

- **Purpose:** Let the user pick folders to scan and grant persistent, sandbox-safe access.
- **Requirements:** `NSOpenPanel` (directories, multi-select) + drag-drop onto sidebar/empty state. Store **security-scoped bookmarks**. Re-resolve bookmarks on launch; handle stale.
- **User flow:** Empty state → "Choose Folders…" → panel → folders appear as sources in sidebar.
- **UI behavior:** Each source row shows path, file count (after enumeration), remove button on hover.
- **Business logic:** Persist bookmark, start `startAccessingSecurityScopedResource` around access, balance with stop.
- **State changes:** `sources` array gains a `SourceBookmark`; triggers optional auto-enumerate.
- **Data:** `source_bookmark` rows.
- **Error handling:** stale bookmark ⇒ prompt re-grant; permission denied ⇒ inline explainer (see `ERROR_HANDLING.md`).
- **Acceptance:** App relaunch retains access without re-prompting (unless OS invalidated). Removing a source cascades its file records.
- **Testing:** unit (bookmark resolve/stale), UI (drag-drop adds source).
- **DoD:** sources persist across launches; sandbox entitlements correct; tests pass.

---

## F2 — Scan engine run & progress (FR-3, FR-5–9)

- **Purpose:** Execute the cascade and stream results.
- **Requirements:** Cancellable, incremental, parallel; emits `ScanEvent`s; persists incrementally.
- **User flow:** Select sources + scopes → "Scan" → live progress → results populate as found.
- **UI behavior:** Progress header: phase label ("Hashing 12,304 / 50,000"), determinate bar where countable, indeterminate during enumeration, ETA, Cancel button, live "groups found / space reclaimable" counters.
- **Business logic:** see `ARCHITECTURE.md` §3 cascade. Honor thresholds from Settings.
- **State changes:** `scanState` machine: `idle → enumerating → hashing → fingerprinting → (embedding) → finished/cancelled/failed`.
- **Data:** writes `scan_session`, `file_record`, `duplicate_group`, etc. incrementally.
- **Error handling:** per-file failures recorded, scan continues; fatal errors (DB unavailable) abort with recovery.
- **Acceptance:** Cancel at 50% → consistent index, resumable. Re-scan unchanged corpus is near-instant (incremental).
- **Testing:** engine unit tests on synthetic corpus (precision/recall thresholds in `PRD.md`), cancellation test, incremental test, crash-resume test.
- **DoD:** meets `PERFORMANCE.md` budgets on the 50k corpus; precision/recall targets met.

---

## F3 — Exact duplicate detection (FR-5)

- **Purpose:** Group byte-identical files.
- **Business logic:** size-bucket → streamed SHA-256 → group equal hashes; confidence 1.0; explanation "Identical file contents."
- **Acceptance:** two identical files, different names → one exact group; a unique file → no group.
- **Testing:** known-pair corpus; large-file streaming (no full load) verified via memory assertion.
- **DoD:** deterministic, memory-bounded, tested.

---

## F4 — Near-duplicate text detection (FR-6, the headline) 

- **Purpose:** Catch "same contract, different dates" and similar small-edit variants.
- **Requirements:** normalized text extraction → 5-word shingling → 128-perm MinHash → LSH banding → Jaccard estimate; threshold default ~0.85 (Settings).
- **Business logic:** Only compare within shared LSH buckets. Produce `reasonSummary` from a fast diff (count of changed regions) for the explanation.
- **State changes:** writes `minhash`, `lsh_bucket`, near-dup `duplicate_group` + `match_edge`.
- **Acceptance:** contract vs date-changed copy → `.nearText` group labeled with change count; two unrelated docs → no group.
- **Testing:** corpus of paraphrase/edit pairs; threshold sensitivity test; precision ≥ 0.95.
- **DoD:** headline demo (contract+date) works end-to-end into the diff view (F8).

---

## F5 — PDF handling & OCR gating (FR-8)

- **Purpose:** Extract text from PDFs; gracefully handle scanned ones.
- **Business logic:** PDFKit text layer → if empty/sparse, classify `pdfScanned`, set status `.needsOCR`. OCR (Vision `VNRecognizeTextRequest`) runs as **opt-in** pass (Settings), then feeds Stage 2.
- **UI behavior:** scanned PDFs grouped under "Needs OCR (N)" with a "Run OCR" action.
- **Acceptance:** text-layer PDF participates in near-dup; scanned PDF is flagged, not silently dropped.
- **Testing:** text-PDF and image-only-PDF fixtures.
- **DoD:** no scanned PDF ever silently ignored.

---

## F6 — Semantic detection (FR-7)

- **Purpose:** Catch same-meaning-different-words documents.
- **Requirements:** `EmbeddingProvider` protocol; Core ML impl + deterministic stub; cosine within LSH candidate buckets; threshold in Settings; **user-initiated "Deep scan"** to protect battery.
- **Business logic:** embed survivors only; store embeddings with `model_id`; compare cosine; `.semantic` groups.
- **Acceptance:** with stub provider returning controlled vectors, known semantic pairs group and non-pairs don't. (Real-model accuracy validated post model-pin.)
- **Testing:** stub-driven deterministic tests; model invalidation test.
- **DoD:** swappable provider, no all-pairs blowup, opt-in.

---

## F7 — Results browsing & grouping (FR-9, FR-10, FR-14)

- **Purpose:** Present groups for review.
- **UI behavior:** grouped list/outline; each group shows match-type badge, confidence, explanation, member thumbnails/file rows, reclaimable size; suggested keeper marked; "Ignore group" and per-file selection.
- **Business logic:** keeper heuristic (DATA_MODEL §4), user override persists; ignore writes `ignore_pair`/`group.ignored`.
- **Acceptance:** groups render incrementally; ignoring removes from view and won't recur next scan.
- **Testing:** snapshot tests of group states; ignore persistence.
- **DoD:** every group shows non-empty explanation + confidence (invariant test).

---

## F8 — Side-by-side compare & diff (FR-11)

- **Purpose:** Show *why* two files match; this is the trust-builder.
- **Requirements:** two-pane compare; for documents a **text diff** highlighting changed regions (dates, names, signature blocks). For images (V2) overlay/slider.
- **Business logic:** diff via a line/word diff algorithm on normalized text; highlight insert/delete/change.
- **Acceptance:** contract pair shows everything identical except date highlighted.
- **Testing:** diff unit tests; snapshot of compare view.
- **DoD:** the "HN screenshot" demo is reproducible.

---

## F9 — Safe deletion & undo (FR-12, FR-13, NFR-2)

- **Purpose:** Reclaim space without fear.
- **Requirements:** move-to-Trash only (`FileManager.trashItem`/`NSWorkspace.recycle`); multi-select; "Select all but keeper"; **Undo** (⌘Z, Edit menu) restoring from Trash; confirmation sheet summarizing count + bytes.
- **Business logic:** never pre-select; never `removeItem`; record an `UndoableDeletion` with original URLs + trash URLs.
- **State changes:** files marked deleted in index after success; groups recompute reclaimable size; undo reverses.
- **Error handling:** partial failures reported per-file; index stays consistent.
- **Acceptance:** delete non-keepers → in Trash → ⌘Z restores. Networking-off doesn't matter (local op).
- **Testing:** trash + undo integration test; lint/test asserting no `removeItem(at:)` on user files anywhere.
- **DoD:** zero irreversible-deletion code paths; undo works.

---

## F10 — Onboarding (FR-15)

- **Purpose:** Set privacy expectation + grant access.
- **UI behavior:** 2–3 native pages: "Everything stays on your Mac" → "Choose folders" → done. Skippable, shown once.
- **Acceptance:** first launch only; explains offline guarantee; leads into F1.
- **DoD:** onboarding-complete persisted; accessible.

---

## F11 — Settings (FR-16)

- **Purpose:** Configure behavior.
- **Requirements:** native `Settings` scene with tabs: General (scopes, default keeper), Detection (thresholds, deep-scan default, OCR toggle), Model (provider selection — stub vs Core ML), Ignore List (review/remove), About/Updates.
- **Acceptance:** changes persist and affect next scan.
- **DoD:** all toggles wired to engine config.

---

## F12 — Scan history (FR-17)

- **Purpose:** Revisit prior scans.
- **UI behavior:** sidebar section lists past `scan_session`s with date + stats; selecting reopens its groups (read-only if files changed since).
- **DoD:** history persists; reopening works.

---

## Open Questions
- Should "Deep scan" be a per-group action in addition to global?

## Future Improvements
- Smart "auto-keeper" rules (prefer files in a chosen "primary" folder).

## Related Documents
- `USER_FLOWS.md`, `UI_SPEC.md`, `STATE_MANAGEMENT.md`, `TASKS.md`.
