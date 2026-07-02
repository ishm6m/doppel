# RELEASE.md — Build, Signing, Distribution & Release

> **Purpose:** Define how Doppel goes from source to a notarized, auto-updating, monetizable build.
> **Scope:** Versioning, build config, signing, notarization, distribution channels, release checklist.
> **Dependencies:** `SECURITY.md`, `PERFORMANCE.md`, `TESTING.md`.

---

## 1. Versioning
- Semantic versioning `MAJOR.MINOR.PATCH`. Marketing version + build number (auto-incremented in CI).
- Phases map to roadmap: `0.1.x` documents MVP, `0.2.x` semantic+OCR, `1.0.x` images.

> **Distribution model:** Doppel ships **without a paid Apple Developer account** — fully open source,
> no notarization, no monetization. The build is ad-hoc signed and distributed via GitHub Releases +
> Homebrew; users clear Gatekeeper once on first launch. This keeps the app **100% offline** (no updater
> network egress) and free forever. A notarized track can be added later if a cert is ever obtained.

## 2. Build configurations
- **Debug:** stub embedding provider, verbose logs.
- **Release:** optimized, hardened runtime, redacted logging, real providers (when pinned).
- Build via `xcodebuild` / CI; reproducible; **no secrets needed** (ad-hoc signing requires no account).

## 3. Signing (release) — ad-hoc, no account
1. **Ad-hoc code signing** (`codesign --sign - --deep --options runtime`) — free, no Developer ID.
2. Entitlements exactly as `SECURITY.md`: sandbox, user-selected RW, app-scope bookmarks, **no network**.
3. No notarization (needs a paid cert). Users approve the app once via right-click ▸ Open or Homebrew's
   `--no-quarantine` (README → Install).
4. Verify: `codesign --verify --deep --strict`. `spctl --assess` will report "unnotarized" — expected.
5. `Scripts/release.sh` does the whole build → ad-hoc sign → zip → sha256; `release.yml` runs it on a
   `v*` tag and publishes the GitHub Release.

## 4. Distribution channels (free & open source)
- **Source (free):** public repo under MIT; anyone can build (`README.md` → Quick start).
- **GitHub Releases:** ad-hoc-signed `Doppel.zip` attached to each `v*` tag — the primary download.
- **Homebrew Cask:** `brew install --cask ishm6m/doppel/doppel` from a `homebrew-doppel` tap; `brew upgrade`
  delivers updates. Cask lives at `Casks/doppel.rb`; bump its `version` + `sha256` per release (the
  release workflow prints both).
- **No paid build, no cloud, no monetization** — privacy is the product (`SECURITY.md`).
- Mac App Store / notarized track: possible later if a Developer ID cert is obtained; not required.

## 5. Updates — Homebrew (no in-app updater)
- Updates ship through Homebrew (`brew upgrade`); there is **no Sparkle / no in-app update check**.
- Consequence (and feature): the app opens **zero network connections** — the egress guard proves it
  statically (golden rule 1). Nothing to sign, host, or verify at runtime.
- Per release: tag `vX.Y.Z`, let `release.yml` build + publish, then bump `Casks/doppel.rb`.

## 6. Release checklist (gate)
- [ ] All `TASKS.md` for the milestone `[x]`; DoDs met.
- [ ] CI green: build, lint, format, unit+integration, snapshot, perf (budgets met), **egress test**, entitlements snapshot.
- [ ] Safety tests pass (no permanent delete; undo; cancellation; crash-resume).
- [ ] Accessibility audit checklist complete.
- [ ] Privacy review: dependency audit clean; no new phone-home deps.
- [ ] Performance budgets met on 50k corpus.
- [ ] Ad-hoc signed; `codesign --verify --deep --strict` clean; first-launch (right-click ▸ Open) verified.
- [ ] Version bumped; `Casks/doppel.rb` `version` + `sha256` updated; changelog/release notes written.
- [ ] Crash reporting (privacy-safe) verified to contain no file data.
- [ ] Tag `vX.Y.Z`; `release.yml` published the GitHub Release with `Doppel.zip`.

## 7. Rollback
- GitHub Releases keeps every prior `Doppel.zip`; if a release regresses, point `Casks/doppel.rb` back at the last-good `version`/`sha256` and (optionally) delete/mark the bad release.

## Open Questions
- Crash reporting tool that's privacy-compatible (or roll our own minimal, opt-in).

## Future Improvements
- Notarized track if a Developer ID cert is ever obtained (nicer first-launch UX).
- Auto-bump `Casks/doppel.rb` from `release.yml` (needs a tap-repo token).
- Homebrew Cask for the CLI.

## Related Documents
- `SECURITY.md`, `TESTING.md`, `PERFORMANCE.md`, `ROADMAP.md`.
