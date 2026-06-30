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
}
