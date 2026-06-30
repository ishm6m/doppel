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
