# Changelog

All notable changes to Doppel are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions follow SemVer (`RELEASE.md` §1).

## [0.1.1] — 2026-07-02

### Fixed
- **Scan no longer fails with "FOREIGN KEY constraint failed."** Files are now persisted with their
  real `source_bookmark` id instead of the engine's internal root index, so the scan index writes
  cleanly. Regression-tested against the real GRDB store (FK enforcement on).
- **Removing a scanned folder no longer fails with "FOREIGN KEY constraint failed."** A folder whose
  file was a duplicate group's keeper now drops that group before deleting the source, instead of
  tripping the keeper foreign key mid-cascade. Regression-tested against the real GRDB store.

### Changed
- **About** now links to [getdoppel.vercel.app](https://getdoppel.vercel.app).

## [0.1.0] — Documents MVP — 2026-07-02

First public release. **100% offline, open source (MIT), ad-hoc signed** (not notarized —
approve once on first launch; see README → Install). Finds duplicate **and near-duplicate**
documents by content, not name/size.

### Added
- **Content-aware cascade** — cost-ordered stages, cheap before expensive: enumerate → SHA-256
  exact → MinHash/LSH near-duplicate text. Never runs an expensive stage a cheaper one could resolve.
- **Text + PDF understanding** — `.txt`/`.md`/`.docx` extraction (pure-Swift, no deps) and PDF
  text-layer extraction; scanned PDFs surfaced as "needs OCR" rather than dropped.
- **Explained matches** — every group carries a human-readable reason + confidence; near-dup groups
  show what differs (e.g. "same contract, changed date").
- **Safe delete** — Trash-only (never destroys data), confirmation sheet, multi-select,
  select-all-but-keeper, and single-level Undo (⌘Z) that restores from Trash.
- **Compare view** — side-by-side word diff against the suggested keeper.
- **Results UI** — three-column shell, live scan progress, group cards with badges/confidence/
  reclaimable size, "Not duplicates" that persists and won't recur on re-scan.
- **Incremental scans** — unchanged files are skipped, never re-hashed.
- **Onboarding, Settings, and scan History** (reopen past sessions).
- **Opt-in Deep Scan** — on-device semantic embeddings over cascade survivors only; explicit
  per-run action with a battery note, never a default. Ships behind a deterministic stub provider.
- **Distribution** — GitHub Releases + Homebrew Cask; `brew upgrade` for updates, no in-app updater.

### Security & privacy
- Zero network egress — the app opens no connections and requests no network entitlement; a CI
  guard fails the build if networking APIs or a network entitlement ever appear (golden rule 1).
- App Sandbox with user-selected read-write + app-scope bookmarks only.

### Known limits
- Images are V2; semantic tier uses a stub embedding model until one is pinned (0.2.x).
- Drag-drop folder add, ETA in the progress header, and RTF extraction are deferred.

[0.1.1]: https://github.com/ishm6m/doppel/releases/tag/v0.1.1
[0.1.0]: https://github.com/ishm6m/doppel/releases/tag/v0.1.0
