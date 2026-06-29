# SECURITY.md — Security, Privacy & Sandbox

> **Purpose:** Codify the privacy guarantees and sandbox posture that *are* the product's moat.
> **Scope:** Threat model, entitlements, data handling, logging, update channel, verification.
> **Dependencies:** `ARCHITECTURE.md`, `DATA_MODEL.md`, `ERROR_HANDLING.md`.

**Core promise:** No file content, file name, path, hash, fingerprint, or embedding ever leaves the user's Mac. This is enforced, tested, and marketed.

---

## 1. Privacy guarantees (hard requirements)
- **No network transmission of file-derived data**, ever. The only permitted outbound traffic is the Sparkle update check (app version + appcast fetch), which carries **no** user/file data, and only when enabled.
- **No telemetry/analytics** that includes file data. If any usage analytics are ever added, they must be opt-in, anonymous, and exclude all file-derived data; default off. (MVP: none.)
- **No accounts, no cloud, no third-party SDKs that phone home.** New dependencies are reviewed against this rule (`CLAUDE.md` Golden Rule 1).

## 2. Threat model (what we protect against)
- Accidental data exfiltration via a dependency or careless logging → mitigated by egress test, dependency review, log redaction.
- Accidental irreversible data loss → mitigated by Trash-only deletion + undo + safety tests (`TESTING.md` §4).
- Over-broad file access → mitigated by App Sandbox + security-scoped bookmarks (least privilege).
Out of scope: defending against a compromised OS or a user deliberately granting access to malware.

## 3. App Sandbox & entitlements (least privilege)
- `com.apple.security.app-sandbox` = true.
- `com.apple.security.files.user-selected.read-write` = true (user picks folders).
- `com.apple.security.files.bookmarks.app-scope` = true (persist access).
- **No** `com.apple.security.network.client` for engine/store. If Sparkle requires network, scope it tightly and document it; the egress test must still prove no file-derived data is sent. (Evaluate distributing the auto-updating build outside MAS to keep network strictly for updates.)
- No `com.apple.security.device.*`, no full-disk-access requirement.

## 4. File access lifecycle
- Resolve security-scoped bookmark → `startAccessingSecurityScopedResource()` → access → **always** `stop...()` in `defer`. Balance is mandatory (leak = sandbox violation).
- Never persist absolute paths as the access mechanism; bookmarks only.

## 5. Data at rest
- Index DB in app container (sandboxed). Contains metadata, hashes, fingerprints, optional embeddings, and (if cached) extracted text. **Treat the index as sensitive** because fingerprints/text derive from private docs.
- MVP relies on the user's FileVault for at-rest encryption. SQLCipher is a **future** option (flagged) if we want app-level encryption.
- Provide a "Clear index / Reset" action that securely removes the DB.

## 6. Logging discipline (privacy-safe)
- `OSLog` with privacy qualifiers: file names/paths/contents are `.private` (redacted in release); never log contents. Default release logs contain no file-identifying data.
- Crash reports must not embed file data.

## 7. Update channel
- Sparkle 2 with EdDSA-signed appcast; verify signatures. Update check is the sole network call; isolate it so the egress test can exclude it explicitly while still proving the engine never connects.

## 8. Code signing & notarization
- Release builds are Developer ID signed, hardened runtime enabled, notarized, stapled. See `RELEASE.md`.

## 9. Verification (how we prove it)
- CI **egress test** (`TESTING.md` §5): full scan under network-denied profile succeeds; assert zero engine/store connections.
- Lint/test forbidding `removeItem`/`unlink` on user files.
- Dependency audit step in CI listing all packages; manual review gate for any new one.
- Entitlements snapshot test: build fails if disallowed entitlements appear.

## Open Questions
- Ship app-level DB encryption (SQLCipher) in 1.0, or rely on FileVault?
- MAS vs Developer-ID-only distribution (affects sandbox/network nuances).

## Future Improvements
- Optional encrypted index.
- Per-source access revocation UI.

## Related Documents
- `ERROR_HANDLING.md`, `RELEASE.md`, `TESTING.md`, `DATA_MODEL.md`.
