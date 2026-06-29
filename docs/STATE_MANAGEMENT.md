# STATE_MANAGEMENT.md — State Architecture & Data Flow

> **Purpose:** Define how app state is owned, mutated, and observed.
> **Scope:** DI container, ViewModels, state machines, data flow from engine to UI.
> **Dependencies:** `ARCHITECTURE.md`, `API.md`, `UI_SPEC.md`.

---

## 1. Ownership model
- **Engine state** lives in the `ScanCoordinator` actor (off main).
- **Persisted state** lives in `IndexStore` (SQLite).
- **UI state** lives in `@MainActor @Observable` ViewModels that subscribe to engine streams and the store.
- No global mutable singletons. Dependencies flow via `AppEnvironment`.

## 2. Dependency injection — `AppEnvironment`
```swift
@MainActor final class AppEnvironment {
    let store: IndexStoring
    let coordinator: ScanCoordinating
    let scanService: ScanService
    init(...) { ... }                 // composition root in DoppelApp
}
```
Injected into the SwiftUI environment at the root; ViewModels receive what they need via init (constructor injection). Tests construct an env with in-memory store + stub providers.

## 3. ViewModels (`@Observable`, `@MainActor`)
- `SidebarViewModel` — sources + scan history.
- `ScanViewModel` — owns the scan state machine, consumes `AsyncThrowingStream<ScanEvent>`, exposes progress + groups.
- `ResultsViewModel` — group list, selection, sorting, keeper overrides, ignore.
- `CompareViewModel` — extracts + diffs the selected pair.
- `SettingsViewModel` — config, persisted via `@AppStorage`/store.

ViewModels never touch SQL or the filesystem directly — they call `ScanService`.

## 4. Scan state machine (`ScanViewModel.state`)
```
idle
 └─start→ enumerating ──▶ hashing ──▶ extracting ──▶ fingerprinting ──▶ (embedding) ──▶ clustering ──▶ finished
            │                                                                                   ▲
            └────────────── cancel ──▶ cancelled ───────────────────────────────────────────────┘
            └────────────── fatal  ──▶ failed
```
Transitions are driven by `ScanEvent`s. UI renders per-state (see `UI_SPEC.md` §5). Illegal transitions are programmer errors (assert in debug).

## 5. Data flow (scan)
```
User taps Scan
  → ScanViewModel.start()
    → ScanService.startScan(request)  [resolves bookmarks, starts access]
      → coordinator.scan(request) returns AsyncThrowingStream
  → for await event in stream { reduce(event) into @Observable state }
    → groupFound → append to ResultsViewModel via shared service
    → progress → update header
    → finished/cancelled/failed → terminal state, stop security-scoped access
```
Streaming + incremental: UI shows results before scan completes. Backpressure via bounded stream buffer.

## 6. Data flow (deletion + undo)
```
User confirms trash
  → ScanService.trash(ids)
    → FileManager.trashItem per file (capturing originalURL→trashURL)
    → store.markDeleted(ids)
    → push UndoableDeletion onto UndoManager (and an in-app stack)
  → ResultsViewModel recomputes reclaimable totals
Undo (⌘Z / Edit menu / toast)
  → restore files from recorded trash URLs
    → store.restore(ids) → groups reappear
```
`UndoManager` is wired through the responder chain so ⌘Z, Edit menu, and the toast all share one path.

## 7. Settings/config propagation
`DetectionConfig` is read at scan start (snapshot). Changing settings does **not** mutate an in-flight scan; it affects the next scan. Persist via store/`@AppStorage`.

## 8. Concurrency rules
- ViewModels `@MainActor`; engine off-main. Cross-boundary types `Sendable`.
- UI never blocks on the engine; everything awaited.
- Throttle high-frequency events (progress) to ~10–20 Hz for UI to avoid render thrash; counters use `.monospacedDigit`.

## 9. Error surfacing
Engine errors arrive as stream failures or `fileSkipped` events; ViewModels map them to UI states/toasts per `ERROR_HANDLING.md`. Fatal store errors → recovery screen.

## Open Questions
- Use Apple's `UndoManager` alone, or also keep an explicit undo stack for multi-step batch deletes? (Recommend both: UndoManager for menu integration, explicit stack for the toast.)

## Future Improvements
- Persist UI session (last selected group/scroll) across launches.

## Related Documents
- `API.md`, `ARCHITECTURE.md`, `ERROR_HANDLING.md`, `UI_SPEC.md`.
