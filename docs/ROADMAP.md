# ROADMAP.md — MVP → V1 → Future

> **Purpose:** Sequence what ships when and why.
> **Scope:** Release phases, gating criteria, deferred bets.
> **Dependencies:** `PRD.md`, `TASKS.md`.

---

## Phasing principle
Ship the **documents MVP** first — it's where Doppel's differentiated claim ("same contract, different dates") has the least competition and the lowest ML risk (MinHash, no model required). Layer semantics, then images.

---

## 0.1 — Documents MVP (target: end of Milestone 6)
**Includes:** F1 folder access, F2 scan engine (Stages 0–2), F3 exact, F4 near-dup text, F5 PDF text-layer + scanned flagging, F7 results, F8 compare/diff, F9 safe delete + undo, F10 onboarding, F11 settings, F12 history.
**Excludes:** semantic embeddings, images, OCR execution.
**Gate to ship:** PRD success metrics for exact + near-dup met; safe-delete + undo bulletproof; network-egress test green; accessibility audit passes.

## 0.2 — Semantic + OCR
**Adds:** F6 semantic tier (opt-in deep scan) behind `EmbeddingProvider`, once a text embedding model is pinned via human evaluation; OCR execution pass for scanned PDFs.
**Gate:** semantic precision validated on corpus; OCR doesn't tank performance budgets.

## 1.0 — Images
**Adds:** image scope, perceptual hash (dHash/pHash) near-dup, CLIP-class on-device embeddings for semantic image dedup, image compare (overlay/slider). Re-enter the contested image-dedup space only once documents are excellent and the on-device image model story is solid.

## Future bets (unscheduled)
- **V2 CLI** (`doppel scan ~/Documents`) sharing `DetectionEngine`.
- **V3 Teams/Compliance:** scheduled scans over shared drives, audit log, exportable reports. This is where revenue concentrates — different product, separate track.
- Reused persisted embeddings for instant re-clustering.
- FTS5 search across the indexed corpus.
- Smart auto-keeper rules (prefer a designated "primary" folder).

## Monetization alignment (see RELEASE.md)
- Source: free/OSS. Paid: signed, notarized, auto-updating build (one-time) + Setapp + GitHub Sponsors. **No cloud features added solely to monetize** — it would break the privacy moat.

## Open Questions
- Is 0.2 (semantic) or 1.0 (images) the higher-leverage second release? Revisit after 0.1 user feedback.

## Future Improvements
- Localization beyond English.

## Related Documents
- `PRD.md`, `TASKS.md`, `RELEASE.md`.
