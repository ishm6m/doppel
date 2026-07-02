<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doppel_dark_logo.png">
    <source media="(prefers-color-scheme: light)" srcset="doppel_light_logo.png">
    <img alt="Doppel" src="doppel_light_logo.png" width="160" height="160">
  </picture>
</p>

# Doppel

> Find duplicate **and near-duplicate** files by what they *contain*, not just their name and size. 100% offline. Open source.

> **Purpose:** Orient any human (or Claude Code) landing in this repo for the first time.
> **Scope:** What Doppel is, how to set it up, and where to go next.
> **Dependencies:** None.

---

## What it does

Doppel reads the **content** of your images, PDFs, and text/Office documents and finds files that are the same or nearly the same — even when filenames, sizes, and dates differ. The headline use case:

> *"These two files are the same contract with different dates."*

It does this through a **cost-ordered cascade**: cheap deterministic checks run first (exact hash, perceptual hash, near-duplicate text fingerprinting), and expensive on-device ML embeddings run **only** on the small set of candidates that survive. Nothing ever leaves your Mac.

### Principles
- **Offline by design.** No file content, names, paths, hashes, or embeddings ever touch a network.
- **Reversible by design.** Files are moved to Trash, never destroyed. Everything is undoable.
- **Explainable by design.** Every match shows *why* and *how confident*.

---

## Status

MVP in development. Scope: **documents (text + PDF) first**, images in V2. See `ROADMAP.md`.

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon recommended (Intel supported with reduced ML performance)
- Xcode 16+ and Swift 6 toolchain to build from source

## Install

Doppel is free and open source. Because it's built without a paid Apple Developer account, the release
is **ad-hoc signed, not notarized** — so macOS Gatekeeper will ask you to approve it once on first launch.
That's normal for open-source Mac apps and does not affect the privacy guarantees.

**Homebrew (recommended — handles updates via `brew upgrade`):**
```bash
brew install --cask --no-quarantine ishm6m/doppel/doppel
```
(`--no-quarantine` skips the Gatekeeper prompt. Omit it and instead right-click ▸ Open once if you prefer.)

**Or download the app directly:**
1. Grab `Doppel.zip` from the [latest release](https://github.com/ishm6m/doppel/releases/latest), unzip, move `Doppel.app` to `/Applications`.
2. First launch: **right-click Doppel.app ▸ Open** and confirm (or run `xattr -dr com.apple.quarantine /Applications/Doppel.app`). You only do this once.

Updates ship through Homebrew — there is **no in-app updater**, so the app makes zero network connections (see `SECURITY.md`).

## Quick start (build from source)

```bash
git clone https://github.com/ishm6m/doppel.git && cd doppel
brew install xcodegen && xcodegen generate
xcodebuild -scheme Doppel -configuration Debug build
open ./build/Debug/Doppel.app   # or run from Xcode
```

Run tests and linters:

```bash
swiftformat . && swiftlint --strict
xcodebuild test -scheme Doppel -destination 'platform=macOS'
```

## How it works (30-second version)

```
Files ─▶ Stage 0  size/metadata grouping
      ─▶ Stage 1  SHA-256        → exact duplicates (free)
      ─▶ Stage 2  pHash / MinHash → near-duplicate candidate clusters (cheap)
      ─▶ Stage 3  embeddings      → semantic matches on survivors only (expensive, on-device)
      ─▶ Cluster, explain, present → you review and Trash with one click
```

Full detail in `ARCHITECTURE.md`.

## Repository map

| Path | What |
|---|---|
| `Doppel/` | SwiftUI app target |
| `Packages/DetectionEngine/` | The cascade. Pure Swift, no UI. |
| `Packages/IndexStore/` | SQLite (GRDB) persistence |
| `Packages/DoppelKit/` | Shared models/utilities |
| `Tools/CorpusGen/` | Synthetic test-corpus generator |
| `*.md` (root `docs/`) | This documentation package |

## Documentation index

Start with `CLAUDE.md`, then `PRD.md` → `ARCHITECTURE.md` → `DATA_MODEL.md` → `FEATURES.md` → `TASKS.md`. Topic docs: `UI_SPEC`, `DESIGN_SYSTEM`, `COMPONENTS`, `STATE_MANAGEMENT`, `API`, `USER_FLOWS`, `ERROR_HANDLING`, `PERFORMANCE`, `TESTING`, `SECURITY`, `ACCESSIBILITY`, `RELEASE`.

## License

[MIT](LICENSE). Fully open source — use, modify, and redistribute freely. Distribution is via GitHub
Releases + Homebrew; see `RELEASE.md` → Distribution.

## Open Questions
- _(none currently)_

## Future Improvements
- CLI distribution via Homebrew.

## Related Documents
- All of `docs/`.
