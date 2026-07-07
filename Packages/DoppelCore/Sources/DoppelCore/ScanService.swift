import DetectionEngine
import DoppelKit
import Foundation
import IndexStore
import Observation
import os

/// App-layer adapter between the pure engine and the store (API.md §5, STATE_MANAGEMENT.md §5).
/// Owns the scan session lifecycle: creates the session up front (the engine can't — it's pure and
/// has no DB), persists files + groups as `ScanEvent`s stream in, and finalizes the session at the end.
/// Exposes minimal `@Observable` state the ViewModels render. ViewModels never touch the store directly.
@MainActor
@Observable
public final class ScanService {
    private static let log = Logger(subsystem: "com.doppel.app", category: "ScanService")
    private let coordinator: any ScanCoordinating
    private let store: any IndexStoring

    /// Groups found so far in the current scan, in arrival order — UI shows results before completion.
    public private(set) var groups: [DuplicateGroup] = []
    /// Member files of found groups, keyed by id, so the results UI can render rows (name/path/size)
    /// without a DB round-trip. Only grouped members — not a full inventory (see persist note below).
    public private(set) var membersByID: [Int64: FileRecord] = [:]
    /// Latest progress phase, for the scan header. Nil before the first scan.
    public private(set) var phase: ScanPhase?
    /// Items processed in the current phase, for the determinate progress bar (F2 "Hashing 12 / 50").
    public private(set) var processed = 0
    /// Total items for the current phase, or nil while indeterminate (enumeration). Seeded by
    /// `.discovered` and refined by each `.progress` event.
    public private(set) var total: Int?
    /// Authoritative summary, set when the scan terminates.
    public private(set) var summary: ScanSummary?

    /// Past scans for the history sidebar (F12): pinned first, then newest. Refreshed on demand + after each scan.
    public private(set) var sessions: [ScanSession] = []

    /// Sessions whose scanned folders changed on disk since the scan finished — the UI flags them "Rescan".
    /// ponytail: folder mtime only, so it catches files added/removed/renamed at a root's top level, not
    /// in-place edits or changes deep in subfolders. Re-walk the tree if that precision is ever needed.
    public private(set) var staleSessionIDs: Set<Int64> = []

    /// A file the scan couldn't process (corrupt, unreadable, scanned-PDF-needs-OCR, …) paired with why.
    /// Surfaced as "Skipped (N)" so a bad file is never silently dropped and never fails the scan (T8.1).
    public struct SkippedFile: Identifiable, Sendable, Hashable {
        public let file: FileRecord
        public let issue: FileIssue
        public var id: Int64 {
            file.id
        }
    }

    /// Files skipped in the current scan, in arrival order. ponytail: in-memory for the live/just-finished
    /// scan only — not persisted, so reopened history won't list skips. Persist via upsertFiles(status:)
    /// if history needs them.
    public private(set) var skipped: [SkippedFile] = []

    /// Source root URLs of the current scan, keyed by the real `source_bookmark.id` that files carry in
    /// `FileRecord.bookmarkID` after persistence, for path reconstruction.
    private var rootURLByID: [Int64: URL] = [:]
    /// Real source_bookmark ids for the current scan, in root order. The engine emits a 0-based root
    /// index in `bookmarkID`; we translate index → this id before persisting so the FK to source_bookmark
    /// holds. Empty in tests, where index is used as-is.
    private var currentRootBookmarkIDs: [Int64] = []
    /// Roots we hold security-scoped access to. Kept open past scan end so the results can be acted on
    /// (e.g. trashed); released when the next scan starts. ponytail: not released on deinit — the OS
    /// reclaims at process exit; persist bookmarks (T4.2) when access must survive relaunch.
    private var scopedRoots: [URL] = []

    /// Snapshot enabling one-level undo of the most recent trash (⌘Z). ponytail: single level — for a
    /// full undo stack, push these onto an array instead of replacing.
    private struct TrashUndo {
        /// Each trashed file with the location it landed at inside the Trash, so it can be moved back.
        let files: [(record: FileRecord, trashURL: URL)]
        let groups: [DuplicateGroup]
        let members: [Int64: FileRecord]
    }

    private var lastTrash: TrashUndo?

    /// Member-pairs the user marked "not duplicates" (F7/F14), loaded at scan start. A group whose
    /// every internal pair is ignored is dropped before it surfaces, so ignored groups don't recur.
    private var ignoredPairs: Set<Pair> = []

    /// Whether the last trash can still be undone (cleared by a new scan or a successful undo).
    public var canUndoTrash: Bool {
        lastTrash != nil
    }

    /// A remembered source folder, resolved from a persisted security-scoped bookmark, that the app
    /// can re-scan across launches without re-prompting the user.
    public struct Source: Identifiable, Sendable, Hashable {
        public let id: Int64
        public let url: URL
        public let displayPath: String
    }

    /// Folders the user has added, surviving relaunch (DATA_MODEL.md source_bookmark). We hold
    /// security-scoped access to each for the app's lifetime so files stay scannable/trashable.
    public private(set) var sources: [Source] = []
    private var sourceScoped: [URL] = []

    /// Security-scoped bookmark APIs need the app sandbox, which CI's `swift test` doesn't have, so
    /// they're injectable seams (live app uses the real ones below). ponytail: a test seam for OS
    /// sandbox magic, not a general abstraction.
    private let makeBookmark: @Sendable (URL) throws -> Data
    private let openBookmark: @Sendable (Data) throws -> URL

    public init(
        coordinator: any ScanCoordinating,
        store: any IndexStoring,
        makeBookmark: @escaping @Sendable (URL) throws -> Data = ScanService.securityScopedBookmark,
        openBookmark: @escaping @Sendable (Data) throws -> URL = ScanService.resolveSecurityScoped
    ) {
        self.coordinator = coordinator
        self.store = store
        self.makeBookmark = makeBookmark
        self.openBookmark = openBookmark
    }

    public nonisolated static func securityScopedBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public nonisolated static func resolveSecurityScoped(_ data: Data) throws -> URL {
        // ponytail: stale bookmarks aren't refreshed in place — the user re-adds the folder. Add a
        // refresh-and-resave path if staleness turns out to be common.
        var stale = false
        return try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Re-resolve persisted source bookmarks at launch and hold access. Bookmarks that no longer
    /// resolve (folder moved/deleted, access revoked) are skipped — the user re-adds them.
    public func loadSources() async throws {
        var live: [Source] = []
        var held: [URL] = []
        for bookmark in try await store.sources() {
            guard let url = try? openBookmark(bookmark.bookmarkData) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            held.append(url)
            live.append(Source(id: bookmark.id, url: url, displayPath: bookmark.displayPath))
        }
        sourceScoped = held
        sources = live
    }

    /// Persist newly chosen folders as security-scoped bookmarks and start holding access. Folders
    /// already remembered (same path) are skipped. Returns the sources actually added.
    @discardableResult
    public func addSources(_ urls: [URL]) async throws -> [Source] {
        var added: [Source] = []
        for url in urls {
            let path = url.path
            if sources.contains(where: { $0.url.path == path }) { continue }
            // The folder is accessible right now via the picker's transient grant; capture a durable
            // bookmark from inside that grant.
            let accessing = url.startAccessingSecurityScopedResource()
            let data = try makeBookmark(url)
            if accessing { url.stopAccessingSecurityScopedResource() }
            let id = try await store.addSource(SourceBookmark(id: 0, bookmarkData: data, displayPath: path))
            guard let opened = try? openBookmark(data) else { continue }
            _ = opened.startAccessingSecurityScopedResource()
            sourceScoped.append(opened)
            let source = Source(id: id, url: opened, displayPath: path)
            sources.append(source)
            added.append(source)
        }
        return added
    }

    /// Forget a source folder and release its access.
    public func removeSource(id: Int64) async throws {
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            let url = sources.remove(at: idx).url
            url.stopAccessingSecurityScopedResource()
            sourceScoped.removeAll { $0 == url }
        }
        try await store.removeSource(id: id)
        // Sweep scans whose folders are now all gone: removeSource drops the source + its file_records,
        // but a session keyed only to removed sources would linger showing broken paths. A session that
        // still covers at least one live source (a multi-folder scan) is kept, as is one with no root ids
        // (tests/legacy — nothing to reconcile).
        let liveIDs = Set(sources.map(\.id))
        let orphaned = sessions.filter { session in
            !session.rootBookmarkIDs.isEmpty && !session.rootBookmarkIDs.contains(where: liveIDs.contains)
        }
        for session in orphaned {
            try await store.deleteSession(id: session.id)
        }
        await loadSessions()
    }

    /// Runs a scan to completion, persisting as it goes, and returns the owning sessionID.
    /// `rootBookmarkIDs` ties the session to its security-scoped sources (empty in tests).
    @discardableResult
    public func startScan(_ request: ScanRequest, rootBookmarkIDs: [Int64] = []) async throws -> Int64 {
        let sessionID = try await store.createSession(
            ScanSession(id: 0, rootBookmarkIDs: rootBookmarkIDs, scopes: request.scopes)
        )
        // Take security-scoped access for the whole results lifetime (sandbox); release the prior scan's.
        for url in scopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        currentRootBookmarkIDs = rootBookmarkIDs
        rootURLByID = mapRootURLsByID(request.roots)
        scopedRoots = request.roots.filter { $0.startAccessingSecurityScopedResource() }
        groups = []
        membersByID = [:]
        skipped = []
        phase = nil
        processed = 0
        total = nil
        summary = nil
        lastTrash = nil
        ignoredPairs = await (try? store.ignoredPairs()) ?? []

        var final = ScanSummary()
        var state: ScanState = .finished
        do {
            for try await event in coordinator.scan(request) {
                switch event {
                case let .discovered(total):
                    // Enumeration count; the bar stays indeterminate (phase nil) until the first phase tick.
                    self.total = total
                case let .progress(phase, processed, total):
                    self.phase = phase
                    self.processed = processed
                    self.total = total ?? self.total
                case let .groupFound(group, members):
                    try await persistFoundGroup(group, members: members, sessionID: sessionID)
                case let .fileSkipped(record, issue):
                    // Recorded, never fatal — the scan continues (T8.1 / ERROR_HANDLING.md).
                    skipped.append(SkippedFile(file: record, issue: issue))
                case let .finished(summary):
                    final = summary
                case let .cancelled(summary):
                    final = summary
                    state = .cancelled
                }
            }
        } catch {
            // A thrown scan (engine error, task cancellation) must not strand the session as `running`
            // forever — that's exactly what pollutes history with phantom scans. Finalize it as `.failed`
            // and rethrow so the caller still sees the error.
            try? await store.updateSession(ScanSession(
                id: sessionID, finishedAt: .now, rootBookmarkIDs: rootBookmarkIDs,
                scopes: request.scopes, filesDiscovered: final.filesDiscovered, state: .failed
            ))
            await loadSessions()
            throw error
        }

        summary = final
        try await store.updateSession(ScanSession(
            id: sessionID,
            finishedAt: .now,
            rootBookmarkIDs: rootBookmarkIDs,
            scopes: request.scopes,
            filesDiscovered: final.filesDiscovered,
            groupsFound: final.groupsFound,
            bytesReclaimable: final.bytesReclaimable,
            state: state
        ))
        await loadSessions()
        return sessionID
    }

    /// Loads the scan history (F12): pinned first, then newest, and refreshes staleness.
    /// Only scans that actually completed are history. A `.running` row is either the scan happening right
    /// now (shown live in the main pane, not the sidebar) or an orphan from a crash/force-quit; a `.failed`
    /// row errored out with nothing reliable. Excluding both is what keeps a fresh install's history empty
    /// — a stranded session must never masquerade as a scan the user ran.
    public func loadSessions() async {
        sessions = await ((try? store.sessions()) ?? [])
            .filter { $0.state == .finished || $0.state == .cancelled }
            .sorted(by: Self.historyOrder)
        recomputeStaleness()
    }

    /// Pinned before unpinned, then newest first.
    private static func historyOrder(_ a: ScanSession, _ b: ScanSession) -> Bool {
        a.pinned == b.pinned ? a.startedAt > b.startedAt : a.pinned
    }

    /// Flags sessions whose source folders' top-level contents changed since the scan finished. See the
    /// `staleSessionIDs` note for the mtime-only ceiling. Cheap: one stat per remembered root.
    private func recomputeStaleness() {
        var stale: Set<Int64> = []
        for session in sessions {
            guard let finished = session.finishedAt else { continue }
            for bid in session.rootBookmarkIDs {
                guard let url = sources.first(where: { $0.id == bid })?.url,
                      let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      mod > finished else { continue }
                stale.insert(session.id)
                break
            }
        }
        staleSessionIDs = stale
    }

    /// Forgets a past scan from history. Files are untouched; only the scan record + its groups go.
    public func deleteSession(_ id: Int64) async throws {
        try await store.deleteSession(id: id)
        sessions.removeAll { $0.id == id }
        staleSessionIDs.remove(id)
    }

    /// Renames a past scan (nil/blank clears back to the folder label). Persists and re-sorts live.
    public func renameSession(_ id: Int64, to name: String?) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try await store.updateSession(sessions[idx])
        sessions.sort(by: Self.historyOrder)
    }

    /// Pins/unpins a past scan. Persists and re-sorts live (pinned float to the top).
    public func setPinned(_ id: Int64, _ pinned: Bool) async throws {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].pinned = pinned
        try await store.updateSession(sessions[idx])
        sessions.sort(by: Self.historyOrder)
    }

    /// Reopens a past scan: loads its groups + member records into the live results state so the same
    /// results UI renders them. Rebuilds source URLs from the still-remembered sources, so compare/trash
    /// work when those folders are still added; otherwise actions degrade safely (paths won't resolve).
    /// ponytail: approximates F12's "read-only if files changed" — it doesn't diff disk, it just fails
    /// gracefully on missing files. Add an on-disk freshness check if stale reopen becomes confusing.
    public func openSession(_ id: Int64) async throws {
        let saved = try await store.groups(sessionID: id)
        var members: [Int64: FileRecord] = [:]
        for group in saved {
            for memberID in group.memberFileIDs where members[memberID] == nil {
                members[memberID] = try await store.file(id: memberID)
            }
        }
        for url in scopedRoots {
            url.stopAccessingSecurityScopedResource()
        }
        scopedRoots = []
        if let session = sessions.first(where: { $0.id == id }) {
            // Persisted files carry the real source_bookmark.id in bookmarkID; key roots by that id.
            currentRootBookmarkIDs = session.rootBookmarkIDs
            rootURLByID = [:]
            for sid in session.rootBookmarkIDs {
                rootURLByID[sid] = sources.first { $0.id == sid }?.url ?? URL(fileURLWithPath: "/")
            }
        }
        groups = saved
        membersByID = members.compactMapValues { $0 }
        skipped = [] // not persisted; a reopened scan shows groups only
        phase = nil
        summary = nil
        lastTrash = nil
    }

    /// Persists and surfaces one found group, unless the user already marked this exact set "not
    /// duplicates" (F7/F14), in which case it's dropped before surfacing so it doesn't recur.
    private func persistFoundGroup(_ group: DuplicateGroup, members: [FileRecord], sessionID: Int64) async throws {
        if Self.isFullyIgnored(group, by: ignoredPairs) { return }
        // The engine stamps bookmarkID with a 0-based root index; translate it to the real
        // source_bookmark.id so file_record's FK holds (and path reconstruction stays keyed by that id).
        var mapped: [FileRecord] = []
        for file in members {
            guard let sid = sourceID(forRootIndex: Int(file.bookmarkID)) else {
                // Fail safe: a root index with no live source means a corrupt scan state. Drop the whole
                // group rather than write a dangling foreign key that would crash the entire scan. This
                // never happens on the happy path (runScan aligns roots ↔ ids); the guard is the backstop.
                Self.log.error("Dropping group: file references unknown root index \(file.bookmarkID, privacy: .public)")
                return
            }
            var f = file
            f.bookmarkID = sid
            mapped.append(f)
        }
        // ponytail: persist the group's members + the group. We do NOT persist a full file inventory —
        // the engine only emits grouped/skipped files, which is all the results UI needs.
        try await store.upsertFiles(mapped)
        // ponytail: edges:[] — groupFound carries no MatchEdges; the compare view (F8) reads text live
        // rather than stored edges. Surface with the store-assigned id (the engine emits id 0) so the
        // list has stable identities and "Ignore group" can target this group.
        let savedID = try await store.saveGroup(group, members: mapped.map(\.id), edges: [], sessionID: sessionID)
        groups.append(group.withID(savedID))
        for member in mapped {
            membersByID[member.id] = member
        }
    }

    /// Real source_bookmark.id for a 0-based root index. When ids were supplied (production), an index
    /// outside them is a corrupt state → nil, so the caller drops the file instead of writing a bogus FK.
    /// When none were supplied (tests, FK-less in-memory store), the index doubles as the id.
    private func sourceID(forRootIndex i: Int) -> Int64? {
        if currentRootBookmarkIDs.isEmpty { return Int64(i) }
        return currentRootBookmarkIDs.indices.contains(i) ? currentRootBookmarkIDs[i] : nil
    }

    /// Root URLs keyed by their real source_bookmark.id, for path reconstruction of persisted files.
    private func mapRootURLsByID(_ roots: [URL]) -> [Int64: URL] {
        var map: [Int64: URL] = [:]
        for (i, url) in roots.enumerated() {
            if let sid = sourceID(forRootIndex: i) { map[sid] = url }
        }
        return map
    }

    /// On-disk URL for a member file, rebuilt from its source root + relative path.
    public func absoluteURL(for file: FileRecord) -> URL? {
        guard let root = rootURLByID[file.bookmarkID] else { return nil }
        return root.appendingPathComponent(file.relativePath)
    }

    /// Word-level diff of two member files for the compare view (F8 — "why did these match?"). Reads
    /// each file's normalized text off disk (we hold security-scoped access) and diffs them. Returns nil
    /// if either has no comparable text layer (scanned PDF, unsupported type) — the UI says so.
    public func compareTexts(_ a: FileRecord, _ b: FileRecord) async -> TextDiff? {
        guard let ua = absoluteURL(for: a), let ub = absoluteURL(for: b),
              let ta = await extractNormalizedText(at: ua), let tb = await extractNormalizedText(at: ub)
        else { return nil }
        return TextDiff.compute(ta, tb)
    }

    /// Moves the given member files to the Trash — never `removeItem`/`unlink`, so every deletion is
    /// recoverable (golden rule 2). We trash exactly the ids asked; the human chose them. Returns the
    /// ids actually trashed. After trashing, members drop from the live results and groups that fall
    /// below two members disappear (no longer a duplicate set).
    @discardableResult
    public func trash(_ ids: [Int64]) async throws -> [Int64] {
        let fm = FileManager.default
        let groupsBefore = groups, membersBefore = membersByID
        var trashed: [Int64] = []
        var undoFiles: [(record: FileRecord, trashURL: URL)] = []
        for id in ids {
            guard let file = membersByID[id], let url = absoluteURL(for: file) else { continue }
            // ponytail: trash each file independently so one failure (already gone, permissions) can't
            // abort the batch or strand the index — only files actually trashed leave the results and
            // get markDeleted (index stays consistent, F9). A failed file stays visibly in its group.
            do {
                // Capture where it lands in the Trash so undoLastTrash can move it straight back.
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                trashed.append(id)
                if let dest = resulting as URL? { undoFiles.append((file, dest)) }
            } catch {
                continue
            }
        }
        guard !trashed.isEmpty else { return [] }
        try await store.markDeleted(ids: trashed)
        // ponytail: no Trash URL means we can't move it back, so don't offer a misleading undo.
        lastTrash = undoFiles.isEmpty ? nil : TrashUndo(files: undoFiles, groups: groupsBefore, members: membersBefore)
        let gone = Set(trashed)
        for id in gone {
            membersByID[id] = nil
        }
        groups = groups.compactMap { group in
            let remaining = group.memberFileIDs.filter { !gone.contains($0) }
            guard remaining.count >= 2 else { return nil }
            var updated = group
            updated.memberFileIDs = remaining
            if gone.contains(group.keeperFileID) { updated.keeperFileID = remaining[0] }
            return updated
        }
        return trashed
    }

    /// Reverses the most recent trash: moves each file back from the Trash to its original location and
    /// restores the live results. Returns the ids actually restored. ponytail: single-level undo; a file
    /// the user already emptied from the Trash can't be moved back — it's skipped, the rest still restore.
    @discardableResult
    public func undoLastTrash() async throws -> [Int64] {
        guard let undo = lastTrash else { return [] }
        let fm = FileManager.default
        var restored: [Int64] = []
        for item in undo.files {
            guard let original = absoluteURL(for: item.record),
                  fm.fileExists(atPath: item.trashURL.path),
                  !fm.fileExists(atPath: original.path) else { continue }
            try fm.moveItem(at: item.trashURL, to: original)
            restored.append(item.record.id)
        }
        lastTrash = nil
        guard !restored.isEmpty else { return [] }
        try await store.restore(ids: restored)
        // Restore the results as they were before the trash (only the restored ids actually came back,
        // but a partial restore here just means the snapshot over-shows — harmless, the next scan corrects).
        groups = undo.groups
        membersByID = undo.members
        return restored
    }

    /// Marks a group "not duplicates" (F7/F14): persists every member pair as ignored and removes the
    /// group from the live results. On a later scan, a group whose every internal pair is ignored is
    /// dropped before it surfaces, so it won't recur. ponytail: keyed by `FileRecord.id`, which is
    /// stable only while enumeration order is — a content-hash key is the robust cross-rescan upgrade.
    public func ignore(_ group: DuplicateGroup) async throws {
        for pair in Self.memberPairs(group.memberFileIDs) {
            try await store.ignorePair(pair.a, pair.b)
            ignoredPairs.insert(pair)
        }
        if group.id != 0 { try await store.ignoreGroup(group.id) }
        groups.removeAll { $0.id == group.id }
    }

    /// Overrides the suggested keeper for a group (guided review lets the user correct the app's pick
    /// before trashing the rest). Persists via the store and updates the live `groups` so the UI reflects
    /// it at once. No-op if the group isn't in the current results or `fileID` isn't one of its members.
    public func setKeeper(groupID: Int64, fileID: Int64) async throws {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }),
              groups[idx].memberFileIDs.contains(fileID) else { return }
        try await store.setKeeper(groupID: groupID, fileID: fileID)
        groups[idx].keeperFileID = fileID
    }

    /// How many not-duplicate pairs are remembered (Settings ▸ Ignore List).
    public func ignoredPairCount() async -> Int {
        await ((try? store.ignoredPairs()) ?? []).count
    }

    /// Forget the entire not-duplicates list; previously-ignored groups can resurface next scan.
    public func clearIgnoredList() async throws {
        try await store.clearIgnoredPairs()
        ignoredPairs = []
    }

    /// Every unordered pair of member ids (a group of N has N·(N-1)/2 pairs).
    static func memberPairs(_ ids: [Int64]) -> [Pair] {
        var pairs: [Pair] = []
        for i in ids.indices {
            for j in ids.index(after: i) ..< ids.endIndex {
                pairs.append(Pair(ids[i], ids[j]))
            }
        }
        return pairs
    }

    /// A group counts as ignored only when *every* internal pair is ignored — a new member joining a
    /// previously-ignored set makes it a fresh group the user hasn't judged, so it resurfaces.
    static func isFullyIgnored(_ group: DuplicateGroup, by ignored: Set<Pair>) -> Bool {
        let pairs = memberPairs(group.memberFileIDs)
        return !pairs.isEmpty && pairs.allSatisfy(ignored.contains)
    }
}

private extension DuplicateGroup {
    /// Copy carrying a new id (the model's id is `let`); used to stamp the store-assigned id onto the
    /// engine's id-0 group when surfacing it.
    func withID(_ id: Int64) -> DuplicateGroup {
        DuplicateGroup(
            id: id, matchType: matchType, confidence: confidence, explanation: explanation,
            keeperFileID: keeperFileID, memberFileIDs: memberFileIDs, ignored: ignored, createdAt: createdAt
        )
    }
}
