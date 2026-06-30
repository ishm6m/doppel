import DetectionEngine
import DoppelKit
import IndexStore
import XCTest
@testable import DoppelCore

/// ScanService is pure orchestration, so we drive it with a scripted stub coordinator (no real files)
/// and assert the session, files, and groups land in an InMemoryIndexStore — the engine→store contract.
@MainActor
final class ScanServiceTests: XCTestCase {
    /// Replays a fixed event timeline, exactly as the real coordinator would stream it.
    private struct StubCoordinator: ScanCoordinating {
        let events: [ScanEvent]
        func scan(_: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error> {
            AsyncThrowingStream { cont in
                for e in events {
                    cont.yield(e)
                }
                cont.finish()
            }
        }
    }

    private func file(_ id: Int64, _ name: String) -> FileRecord {
        FileRecord(
            id: id,
            bookmarkID: 0,
            relativePath: name,
            displayName: name,
            sizeBytes: 10,
            mtime: .now,
            typeScope: .document
        )
    }

    func testScanPersistsSessionFilesAndGroups() async throws {
        let store = InMemoryIndexStore()
        let f1 = file(1, "a.txt"), f2 = file(2, "b.txt")
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .discovered(total: 2),
            .progress(phase: .hashing, processed: 2, total: 2),
            .groupFound(group, members: [f1, f2]),
            .progress(phase: .clustering, processed: 2, total: 2),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1, bytesReclaimable: 10))
        ]), store: store)

        let sessionID = try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))

        // Group persisted under the owning session, with its members.
        let saved = try await store.groups(sessionID: sessionID)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.memberFileIDs, [1, 2])
        XCTAssertEqual(saved.first?.explanation, "Identical file contents")

        // Member files persisted and queryable.
        let savedFile = try await store.file(id: 1)
        XCTAssertEqual(savedFile?.displayName, "a.txt")

        // Session finalized with the authoritative summary counts.
        let session = try await store.sessions().first { $0.id == sessionID }
        XCTAssertEqual(session?.groupsFound, 1)
        XCTAssertEqual(session?.filesDiscovered, 2)
        XCTAssertEqual(session?.state, .finished)
        XCTAssertNotNil(session?.finishedAt)

        // Observable state mirrors what the UI would render.
        XCTAssertEqual(svc.groups.count, 1)
        XCTAssertEqual(svc.summary?.bytesReclaimable, 10)
        // Member records retained for the results UI to render rows.
        XCTAssertEqual(svc.membersByID[1]?.displayName, "a.txt")
        XCTAssertEqual(svc.membersByID[2]?.displayName, "b.txt")
    }

    /// The header counts (phase, processed/total) mirror the last progress event so the UI can show
    /// a determinate bar like "Hashing 2 / 2" (T4.3 / F2). `.discovered` seeds the total up front.
    func testProgressCountsSurfaceForHeader() async throws {
        let store = InMemoryIndexStore()
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .discovered(total: 2),
            .progress(phase: .hashing, processed: 1, total: 2),
            .progress(phase: .hashing, processed: 2, total: 2),
            .finished(summary: ScanSummary(filesDiscovered: 2))
        ]), store: store)

        try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")]))

        XCTAssertEqual(svc.phase, .hashing)
        XCTAssertEqual(svc.processed, 2)
        XCTAssertEqual(svc.total, 2)
    }

    /// A cancelled scan finalizes the session as `.cancelled` (terminal state still recorded).
    func testCancelledScanMarksSessionCancelled() async throws {
        let store = InMemoryIndexStore()
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .discovered(total: 0),
            .cancelled(partial: ScanSummary(filesDiscovered: 0))
        ]), store: store)

        let sessionID = try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")]))

        let session = try await store.sessions().first { $0.id == sessionID }
        XCTAssertEqual(session?.state, .cancelled)
        XCTAssertTrue(svc.groups.isEmpty)
    }

    /// Ignoring a group (F7/F14) removes it from the live results, persists its member pairs, and a
    /// later scan that re-finds the same set drops it before it surfaces — it doesn't recur.
    func testIgnoredGroupDoesNotRecurOnRescan() async throws {
        let store = InMemoryIndexStore()
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let events: [ScanEvent] = [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1))
        ]
        let svc = ScanService(coordinator: StubCoordinator(events: events), store: store)
        try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))
        XCTAssertEqual(svc.groups.count, 1)

        // The surfaced group carries the store-assigned id (engine emits 0).
        let surfaced = try XCTUnwrap(svc.groups.first)
        XCTAssertNotEqual(surfaced.id, 0)
        try await svc.ignore(surfaced)
        XCTAssertTrue(svc.groups.isEmpty, "ignored group leaves the live results")
        let persisted = try await store.ignoredPairs()
        XCTAssertTrue(persisted.contains(Pair(1, 2)))

        // Re-scan finds the same pair again; it must not resurface.
        let rescan = ScanService(coordinator: StubCoordinator(events: events), store: store)
        try await rescan.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))
        XCTAssertTrue(rescan.groups.isEmpty, "ignored group does not recur")
    }

    /// Settings ▸ Ignore List "Reset" (F11): clearing the ignore list lets a previously-ignored group
    /// surface again on the next scan.
    func testClearIgnoredListLetsGroupRecur() async throws {
        let store = InMemoryIndexStore()
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let events: [ScanEvent] = [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1))
        ]
        let svc = ScanService(coordinator: StubCoordinator(events: events), store: store)
        try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))
        try await svc.ignore(XCTUnwrap(svc.groups.first))
        let before = await svc.ignoredPairCount()
        XCTAssertEqual(before, 1)

        try await svc.clearIgnoredList()
        let after = await svc.ignoredPairCount()
        XCTAssertEqual(after, 0)

        // Re-scan: the group is no longer suppressed.
        let rescan = ScanService(coordinator: StubCoordinator(events: events), store: store)
        try await rescan.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))
        XCTAssertEqual(rescan.groups.count, 1, "cleared ignore list lets the group recur")
    }

    /// trash() moves the chosen files to the Trash (not unlinked), leaves the keeper, marks them
    /// deleted, and drops the now-singleton group. Uses real files in a temp dir.
    func testTrashMovesNonKeeperToTrashAndUpdatesState() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) } // test fixture cleanup — our dir, not user files
        let keeper = tmp.appendingPathComponent("a.txt")
        let dupe = tmp.appendingPathComponent("b.txt")
        try "dup".write(to: keeper, atomically: true, encoding: .utf8)
        try "dup".write(to: dupe, atomically: true, encoding: .utf8)

        let store = InMemoryIndexStore()
        // file(id,name) gives bookmarkID 0 + relativePath == name, so root[0]+name resolves the URL.
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1, bytesReclaimable: 3))
        ]), store: store)
        try await svc.startScan(ScanRequest(roots: [tmp], scopes: [.document]))

        let trashed = try await svc.trash([2])
        XCTAssertEqual(trashed, [2])
        XCTAssertTrue(fm.fileExists(atPath: keeper.path), "keeper stays")
        XCTAssertFalse(fm.fileExists(atPath: dupe.path), "non-keeper moved to Trash")
        XCTAssertNil(svc.membersByID[2])
        XCTAssertTrue(svc.groups.isEmpty, "singleton group removed")

        // Undo brings the trashed file back from the Trash and restores the live results.
        XCTAssertTrue(svc.canUndoTrash)
        let restored = try await svc.undoLastTrash()
        XCTAssertEqual(restored, [2])
        XCTAssertTrue(fm.fileExists(atPath: dupe.path), "non-keeper moved back out of Trash")
        XCTAssertEqual(svc.membersByID[2]?.displayName, "b.txt")
        XCTAssertEqual(svc.groups.count, 1, "group restored")
        XCTAssertFalse(svc.canUndoTrash, "undo consumed")
    }

    /// Partial-failure consistency (F9): trashing a set where one file is already gone trashes the
    /// reachable one, skips the missing one, and leaves the index consistent — the batch isn't aborted
    /// and no file is half-deleted (on disk but still marked live, or vice-versa).
    func testTrashContinuesPastAMissingFileAndStaysConsistent() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) } // fixture cleanup — our dir
        let keeper = tmp.appendingPathComponent("a.txt")
        let dupe1 = tmp.appendingPathComponent("b.txt")
        let dupe2 = tmp.appendingPathComponent("c.txt")
        for url in [keeper, dupe1, dupe2] {
            try "dup".write(to: url, atomically: true, encoding: .utf8)
        }

        let store = InMemoryIndexStore()
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2, 3]
        )
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt"), file(3, "c.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 3, groupsFound: 1))
        ]), store: store)
        try await svc.startScan(ScanRequest(roots: [tmp], scopes: [.document]))

        // c.txt vanishes before we trash — trashItem will throw for it.
        try fm.removeItem(at: dupe2)

        let trashed = try await svc.trash([2, 3])
        XCTAssertEqual(trashed, [2], "only the reachable dupe is trashed")
        XCTAssertFalse(fm.fileExists(atPath: dupe1.path), "b.txt went to Trash")
        XCTAssertNil(svc.membersByID[2], "trashed file left the results")
        XCTAssertNotNil(svc.membersByID[3], "the missing file stays visible (not silently dropped)")
        // Index agrees: only id 2 is marked deleted (.skipped); the missing file is untouched.
        let status2 = try await store.file(id: 2)?.status
        let status3 = try await store.file(id: 3)?.status
        XCTAssertEqual(status2, .skipped)
        XCTAssertEqual(status3, .indexed)
    }

    /// Source folders are persisted on add and re-resolved by a fresh service from the same store,
    /// so folder access survives relaunch (T4.2). Identity bookmark codecs stand in for the
    /// security-scoped APIs, which need the app sandbox that `swift test` lacks.
    func testSourcesPersistAndReloadAcrossServices() async throws {
        let store = InMemoryIndexStore()
        let encode: @Sendable (URL) throws -> Data = { Data($0.path.utf8) }
        let decode: @Sendable (Data) throws -> URL = { URL(fileURLWithPath: String(bytes: $0, encoding: .utf8) ?? "") }
        let svc = ScanService(coordinator: StubCoordinator(events: []), store: store, makeBookmark: encode, openBookmark: decode)

        let added = try await svc.addSources([URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")])
        XCTAssertEqual(added.count, 2)
        // Re-adding the same path is a no-op (deduped).
        try await svc.addSources([URL(fileURLWithPath: "/tmp/a")])
        XCTAssertEqual(svc.sources.map(\.displayPath), ["/tmp/a", "/tmp/b"])

        // A brand-new service over the same store rebuilds the source list from persisted bookmarks.
        let relaunched = ScanService(coordinator: StubCoordinator(events: []), store: store, makeBookmark: encode, openBookmark: decode)
        try await relaunched.loadSources()
        XCTAssertEqual(relaunched.sources.map(\.displayPath), ["/tmp/a", "/tmp/b"])

        try await relaunched.removeSource(id: added[0].id)
        XCTAssertEqual(relaunched.sources.map(\.displayPath), ["/tmp/b"])
        let persisted = try await store.sources().map(\.displayPath)
        XCTAssertEqual(persisted, ["/tmp/b"])
    }
}
