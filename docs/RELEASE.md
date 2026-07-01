# RELEASE.md — Build, Signing, Distribution & Release

> **Purpose:** Define how Doppel goes from source to a notarized, auto-updating, monetizable build.
> **Scope:** Versioning, build config, signing, notarization, distribution channels, release checklist.
> **Dependencies:** `SECURITY.md`, `PERFORMANCE.md`, `TESTING.md`.

---

## 1. Versioning
- Semantic versioning `MAJOR.MINOR.PATCH`. Marketing version + build number (auto-incremented in CI).
- Phases map to roadmap: `0.1.x` documents MVP, `0.2.x` semantic+OCR, `1.0.x` images.

## 2. Build configurations
- **Debug:** stub embedding provider, verbose logs, no notarization.
- **Release:** optimized, hardened runtime, redacted logging, real providers (when pinned), Sparkle enabled.
- Build via `xcodebuild` / CI; reproducible; no secrets in repo (signing creds in CI keychain).

## 3. Signing & notarization (release)
1. Developer ID Application signing, **hardened runtime** enabled.
2. Entitlements exactly as `SECURITY.md` (sandbox, user-selected RW, app-scope bookmarks; network only if Sparkle requires, scoped).
3. `notarytool` submit → wait → **staple** the ticket.
4. Verify: `spctl --assess`, `codesign --verify --deep --strict`, Gatekeeper launch test on a clean machine.

## 4. Distribution channels (open-core model)
- **Source (free):** public repo under OSI license; anyone can build. This is the OSS promise.
- **Paid notarized build (primary revenue):** signed, notarized, auto-updating binary sold one-time ($15–30) from the website. People pay for convenience + notarization + updates, not for source.
- **Setapp:** submit for steady passive distribution (good fit for utilities).
- **GitHub Sponsors / sponsorware:** fund development; sponsor-only early features.
- **No cloud features added to monetize** — would break the privacy moat (`SECURITY.md`).
- Mac App Store: optional later; sandbox already compatible, but Developer-ID + Sparkle gives more update control for MVP.

## 5. Auto-update (Sparkle 2)
- EdDSA-signed appcast hosted on the site/CDN. Verify signature before applying.
- Update check is the **only** network call; isolated for the egress test.
- Release notes per version; user can disable auto-check.

**Wiring (done — T8.5):** Sparkle 2 is a package dep (`project.yml`); the updater and the "Check for
Updates…" menu item live in `App/Doppel/App/Updater.swift` (the sole network touch-point). Feed URL and
public key are Info.plist keys. The network entitlement is Release-only (`Doppel.release.entitlements`),
so Debug builds and the egress guard stay network-free.

**First-release setup (maintainer, one-time — needs Apple credentials):**
1. Generate the EdDSA key pair once: `./bin/generate_keys` (from the Sparkle release tools). It stores
   the **private** key in your login keychain and prints the **public** key.
2. In `project.yml` under the `Doppel` target's `info.properties`, replace the two placeholders:
   `SUPublicEDKey` → the printed public key; `SUFeedURL` → your real appcast URL. Run `xcodegen generate`.
3. Store notary credentials once: `xcrun notarytool store-credentials <PROFILE> --apple-id … --team-id …
   --password <app-specific-pw>`.
4. Build + notarize: `DEVELOPER_ID="Developer ID Application: … (TEAMID)" TEAM_ID=… NOTARY_PROFILE=<PROFILE>
   ./Scripts/release.sh`.
5. Appcast: run Sparkle's `./bin/generate_appcast <updates-dir>` over the notarized `.zip`; publish
   `appcast.xml` + zip to the feed host. Keep the prior build + entry for rollback (§7).

## 6. Release checklist (gate)
- [ ] All `TASKS.md` for the milestone `[x]`; DoDs met.
- [ ] CI green: build, lint, format, unit+integration, snapshot, perf (budgets met), **egress test**, entitlements snapshot.
- [ ] Safety tests pass (no permanent delete; undo; cancellation; crash-resume).
- [ ] Accessibility audit checklist complete.
- [ ] Privacy review: dependency audit clean; no new phone-home deps.
- [ ] Performance budgets met on 50k corpus.
- [ ] Signed, notarized, stapled; Gatekeeper clean-machine launch verified.
- [ ] Appcast updated + signed; previous version can update to this one.
- [ ] Version bumped; changelog/release notes written.
- [ ] Crash reporting (privacy-safe) verified to contain no file data.
- [ ] Tag release; attach build artifact.

## 7. Rollback
- Keep prior notarized build + appcast entry; if a release regresses, re-point appcast to last good and publish a patched build.

## Open Questions
- License choice (MIT vs Apache-2.0) before first public tag.
- Crash reporting tool that's privacy-compatible (or roll our own minimal, opt-in).

## Future Improvements
- Homebrew Cask for the CLI.
- Mac App Store track.

## Related Documents
- `SECURITY.md`, `TESTING.md`, `PERFORMANCE.md`, `ROADMAP.md`.
