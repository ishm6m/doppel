<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="doppel_dark_logo.png">
    <source media="(prefers-color-scheme: light)" srcset="doppel_light_logo.png">
    <img alt="Doppel" src="doppel_light_logo.png" width="140" height="140">
  </picture>
</p>

<h1 align="center">Doppel</h1>

<p align="center">
  <b>The duplicate finder that actually reads your files.</b><br>
  Finds duplicates <i>and near-duplicates</i> by what they contain — not just name and size.<br>
  100% offline. Nothing ever leaves your Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/100%25-offline-2ea44f" alt="100% offline">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
  <img src="https://img.shields.io/github/stars/ishm6m/doppel?style=social" alt="Stars">
</p>

---

## Why this exists

Every duplicate finder I tried compares **filenames and byte sizes**. That misses the thing I actually
care about: *"these two files are the same contract, just with a different date."* Same content, different
bytes — invisible to a normal deduper.

So I built Doppel. It reads the **content** of your images, PDFs, and text/Office docs and groups files
that are the same or nearly the same, even when the name, size, and date all differ.

And because it's your files, **none of it touches a network.** Ever. No accounts, no cloud, no telemetry.
It's the whole reason I didn't just make a web app.

## What makes it different

- 🧠 **Content-aware.** Catches the same doc saved twice, renamed, or re-exported with a tweaked date.
- 🔒 **Truly offline.** No file, name, path, hash, or embedding ever leaves the machine. The app opens
  **zero** network connections — updates come through Homebrew, out of process.
- ♻️ **Never destroys anything.** Files go to the Trash, never `rm`. Everything is undoable, and *you*
  confirm every deletion — Doppel only ever suggests.
- 💡 **Explains itself.** Every match tells you *why* it's a match and how confident it is. No black box.
- ⚡ **Fast by design.** Cheap checks run first; the expensive on-device ML only touches the handful of
  files that survive.

## Install

> Doppel is free, open source, and built without a paid Apple Developer account — so it's **ad-hoc signed,
> not notarized.** macOS will ask you to approve it once on first launch. Totally normal for indie Mac
> apps, and it changes nothing about the privacy guarantees.

**Homebrew** (recommended — you get updates via `brew upgrade`):

```bash
brew install --cask --no-quarantine ishm6m/doppel/doppel
```

<sub>`--no-quarantine` skips the Gatekeeper prompt. Prefer not to? Drop it, then right-click ▸ Open once.</sub>

**Or grab the app directly:**

1. Download `Doppel.zip` from the [latest release](https://github.com/ishm6m/doppel/releases/latest), unzip, drag `Doppel.app` to `/Applications`.
2. First launch: **right-click ▸ Open** and confirm (or `xattr -dr com.apple.quarantine /Applications/Doppel.app`). One time only.

There is **no in-app updater** — that's deliberate. It's how the app can promise zero network calls (see [`SECURITY.md`](docs/SECURITY.md)).

## How it works

Doppel runs a **cost-ordered cascade** — cheap, deterministic stages first, expensive ML last, and only
on what's left:

```
Files ─▶ Stage 0  group by size / metadata
      ─▶ Stage 1  SHA-256          → exact duplicates          (free)
      ─▶ Stage 2  pHash / MinHash  → near-duplicate candidates (cheap)
      ─▶ Stage 3  ML embeddings    → semantic matches, on-device only on survivors (expensive)
      ─▶ cluster ─▶ explain ─▶ you review and Trash in one click
```

Full write-up in [`ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Status

🚧 **Early — MVP in active development.** Documents first (**text + PDF**), images in V2.
It's built in the open; expect rough edges and follow along. Roadmap: [`ROADMAP.md`](docs/ROADMAP.md).

## Build from source

```bash
git clone https://github.com/ishm6m/doppel.git && cd doppel
brew install xcodegen && xcodegen generate
xcodebuild -scheme Doppel -configuration Debug build
open ./build/Debug/Doppel.app        # or just open it in Xcode
```

Tests and linters:

```bash
swiftformat . && swiftlint --strict
xcodebuild test -scheme Doppel -destination 'platform=macOS'
```

**Requirements:** macOS 14 (Sonoma)+, Xcode 16 + Swift 6 toolchain. Apple Silicon recommended (Intel works,
slower ML).

## Contributing

Contributions are genuinely welcome — this is a solo project and help makes it better. Good first steps:

- ⭐ **Star the repo** if the idea resonates. It's the #1 thing that keeps an indie project going.
- 🐛 Found a bug or have an idea? [Open an issue](https://github.com/ishm6m/doppel/issues).
- 🔧 Want to hack on it? Read [`CONTRIBUTING.md`](CONTRIBUTING.md), then `CLAUDE.md` for the house rules
  (the two golden ones: **never touch the network, never destroy a file**).

New to the codebase? Read in this order: [`PRD`](docs/PRD.md) → [`ARCHITECTURE`](docs/ARCHITECTURE.md) →
[`DATA_MODEL`](docs/DATA_MODEL.md) → [`FEATURES`](docs/FEATURES.md) → [`TASKS`](docs/TASKS.md). Everything
lives in [`docs/`](docs/).

## License

[MIT](LICENSE) — use it, fork it, ship it. Distribution is via GitHub Releases + Homebrew.

<p align="center"><sub>Built on Apple Silicon, for people who'd rather their files stayed theirs.</sub></p>
