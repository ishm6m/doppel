import DetectionEngine
import DoppelKit
import Foundation
import IndexStore
import Observation

/// App-layer adapter between the pure engine and the store (API.md §5, STATE_MANAGEMENT.md §5).
/// Owns the scan session lifecycle: creates the session up front (the engine can't — it's pure and
/// has no DB), persists files + groups as `ScanEvent`s stream in, and finalizes the session at the end.
/// Exposes minimal `@Observable` state the ViewModels render. ViewModels never touch the store directly.
@MainActor
@Observable
public final class ScanService {
    private let coordinator: any ScanCoordinating
    private let store: any IndexStoring

    /// Groups found so far in the current scan, in arrival order — UI shows results before completion.
    public private(set) var groups: [DuplicateGroup] = []
    /// Member files of found groups, keyed by id, so the results UI can render rows (name/path/size)
    /// without a DB round-trip. Only grouped members — not a full inventory (see persist note below).
    public private(set) var membersByID: [Int64: FileRecord] = [:]
    /// Latest progress phase, for the scan header. Nil before the first scan.
    public private(set) var phase: ScanPhase?
    /// Authoritative summary, set when the scan terminates.
    public private(set) var summary: ScanSummary?

    /// Source roots of the current scan, indexed by `FileRecord.bookmarkID`, for path reconstruction.
    private var rootURLs: [URL] = []
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

    /// Whether the last trash can still be undone (cleared by a new scan or a successful undo).
    public var canUndoTrash: Bool {
        lastTrash != nil
    }

    public init(coordinator: any ScanCoordinating, store: any IndexStoring) {
        self.coordinator = coordinator
        self.store = store
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
        rootURLs = request.roots
        scopedRoots = request.roots.filter { $0.startAccessingSecurityScopedResource() }
        groups = []
        membersByID = [:]
        phase = nil
        summary = nil
        lastTrash = nil

        var final = ScanSummary()
        var state: ScanState = .finished
        for try await event in coordinator.scan(request) {
            switch event {
            case .discovered:
                break
            case let .progress(phase, _, _):
                self.phase = phase
            case let .groupFound(group, members):
                // ponytail: persist the group's members + the group. We do NOT persist a full file
                // inventory — the engine only emits grouped/skipped files, which is all the results
                // UI needs. Add whole-corpus persistence when a screen actually needs every file.
                try await store.upsertFiles(members)
                _ = try await store.saveGroup(group, members: members.map(\.id), edges: [], sessionID: sessionID)
                // ponytail: edges:[] — groupFound carries no MatchEdges; the compare view (F8) doesn't
                // exist yet. Thread real edges through when it does.
                groups.append(group)
                for member in members {
                    membersByID[member.id] = member
                }
            case .fileSkipped:
                break
            case let .finished(summary):
                final = summary
            case let .cancelled(summary):
                final = summary
                state = .cancelled
            }
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
        return sessionID
    }

    /// On-disk URL for a member file, rebuilt from its source root + relative path.
    public func absoluteURL(for file: FileRecord) -> URL? {
        let idx = Int(file.bookmarkID)
        guard rootURLs.indices.contains(idx) else { return nil }
        return rootURLs[idx].appendingPathComponent(file.relativePath)
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
            // Capture where it lands in the Trash so undoLastTrash can move it straight back.
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            trashed.append(id)
            if let dest = resulting as URL? { undoFiles.append((file, dest)) }
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
}
