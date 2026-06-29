# BOOTSTRAP.md — Milestone 0 (Day One)

> **Purpose:** Get from this scaffold to a compiling, testing, launching app, then hand off to `TASKS.md`.
> **Scope:** What's already here, how to build it, what each placeholder means, and the exact next tasks.

This scaffold implements (or stubs) Milestone 0 and parts of M1–M2 from `TASKS.md`. It is designed to **compile and run an empty window with a real persistence schema and real exact-hash engine primitives**, so subsequent work is *extension*, not *greenfield*.

---

## What's already real (works today)
- **DoppelKit** — all domain models (`DATA_MODEL.md`), cosine similarity, keeper heuristic. ✅ tested.
- **IndexStore** — `IndexStoring` protocol, a **fully working** `InMemoryIndexStore`, and `GRDBIndexStore` with the **complete v1 SQLite migration**. ✅ migration + in-memory tested. (GRDB CRUD bodies are stubbed — that's task T1.2.)
- **DetectionEngine** — protocols/config/events, **working streamed SHA-256**, **working union-find**, and the **deterministic `StubEmbeddingProvider`** so the semantic tier is buildable now. ✅ tested.
- **App** — three-column `NavigationSplitView` shell, `AppEnvironment` DI container, native empty state, Settings scene placeholder, least-privilege entitlements.
- **Tooling** — `project.yml` (XcodeGen), SwiftLint (incl. the `no_permanent_delete` safety rule), SwiftFormat, `.gitignore`.

## What's intentionally a placeholder (and which task replaces it)
| Placeholder | Replaced by |
|---|---|
| `PlaceholderCoordinator` (yields empty scan) | `ScanCoordinator` actor — **T2.3** |
| `GRDBIndexStore` method bodies (`notImplemented`) | **T1.2** |
| Sidebar/content/inspector placeholder views | **M4** (T4.1–T4.4) |
| `SettingsPlaceholderView` | **T6.2** |
| `CoreMLEmbeddingProvider` (absent) | **T7.4**, after model pin |

---

## Build it

```bash
# 1. Packages build & test independently (no Xcode needed)
cd Packages/DoppelKit       && swift test && cd ../..
cd Packages/DetectionEngine && swift test && cd ../..
cd Packages/IndexStore      && swift test && cd ../..   # resolves GRDB from network

# 2. Generate and open the app project
brew install xcodegen swiftlint swiftformat
xcodegen generate
open Doppel.xcodeproj

# 3. In Xcode: select the Doppel scheme → Run. You should see the empty-state window.

# 4. Lint/format gate
swiftformat . && swiftlint --strict
```

> If `swift test` for IndexStore can't fetch GRDB, your network may block `github.com`/`*.githubusercontent.com`. Allow those, or vendor GRDB.

---

## Recommended first three tasks (in order)
1. **T1.2** — implement `GRDBIndexStore` methods against the existing migration, mirroring `InMemoryIndexStore` semantics. Copy the in-memory tests to run against `GRDBIndexStore(inMemory:true)` so both implementations share a test suite.
2. **T2.1 + T2.2** — `Enumerator` (Stage 0) and exact grouping on top of the existing `Hasher256` + `UnionFind`. This produces the first *real* duplicate groups.
3. **T2.3** — the `ScanCoordinator` actor emitting `ScanEvent`s; replace `PlaceholderCoordinator` in `AppEnvironment.live()`. Now the app finds exact duplicates end to end.

After that, follow `TASKS.md` (Stage 2 / MinHash is the headline — M3).

---

## Architectural guardrails baked into the scaffold
- `DetectionEngine`'s `Package.swift` depends on **DoppelKit only** — it cannot import persistence or UI. The coordinator emits events; the app-layer `ScanService` (build in M4) persists them. This resolves the apparent engine→store coupling in `API.md`.
- The `no_permanent_delete` lint rule fails any `removeItem`/`unlink` in app/engine code — keeping `CLAUDE.md` golden rule 2 enforced from commit one.
- Entitlements ship without network access by default (`SECURITY.md`).

## Related Documents
- `TASKS.md`, `ARCHITECTURE.md`, `API.md`, `CLAUDE.md`, `SECURITY.md`.
