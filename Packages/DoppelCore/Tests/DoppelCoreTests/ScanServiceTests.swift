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

        // Group persisted under the owning session, with its members carrying store-assigned ids
        // (identity = source + path; the engine's per-scan ids are rewritten on persist).
        let saved = try await store.groups(sessionID: sessionID)
        XCTAssertEqual(saved.count, 1)
        let memberIDs = try XCTUnwrap(saved.first?.memberFileIDs)
        XCTAssertEqual(memberIDs.count, 2)
        XCTAssertEqual(saved.first?.explanation, "Identical file contents")

        // Member files persisted and queryable.
        let savedFile = try await store.file(id: memberIDs[0])
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
        // Member records retained for the results UI to render rows, keyed by store ids.
        XCTAssertEqual(svc.membersByID[memberIDs[0]]?.displayName, "a.txt")
        XCTAssertEqual(svc.membersByID[memberIDs[1]]?.displayName, "b.txt")
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

    /// Per-file failures are captured as "Skipped (N)" and never fail the scan (T8.1). A corrupt file
    /// in the middle of the stream still lets the surrounding group + summary land.
    func testSkippedFilesAreCapturedAndScanStillSucceeds() async throws {
        let store = InMemoryIndexStore()
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .discovered(total: 3),
            .fileSkipped(file(3, "scan.pdf"), FileIssue(kind: .needsOCR, message: "Scanned PDF — no text layer")),
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 3, groupsFound: 1))
        ]), store: store)

        try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))

        XCTAssertEqual(svc.skipped.map(\.file.displayName), ["scan.pdf"])
        XCTAssertEqual(svc.skipped.first?.issue.kind, .needsOCR)
        XCTAssertEqual(svc.groups.count, 1, "the scan still completes and surfaces the group")
        XCTAssertEqual(svc.summary?.groupsFound, 1)
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

    /// Scan history (F12): a finished scan is listed by a fresh service, and reopening it reloads the
    /// persisted groups + member records into the results state.
    func testReopenSessionRestoresGroups() async throws {
        let store = InMemoryIndexStore()
        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let writer = ScanService(coordinator: StubCoordinator(events: [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1, bytesReclaimable: 10))
        ]), store: store)
        let sessionID = try await writer.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]))

        // A fresh service (as on relaunch) sees the scan in history and can reopen it.
        let reader = ScanService(coordinator: StubCoordinator(events: []), store: store)
        await reader.loadSessions()
        XCTAssertEqual(reader.sessions.map(\.id), [sessionID])
        XCTAssertTrue(reader.groups.isEmpty)

        try await reader.openSession(sessionID)
        XCTAssertEqual(reader.groups.count, 1)
        let memberIDs = try XCTUnwrap(reader.groups.first?.memberFileIDs)
        XCTAssertEqual(memberIDs.count, 2)
        XCTAssertEqual(reader.membersByID[memberIDs[0]]?.displayName, "a.txt")
        XCTAssertEqual(reader.membersByID[memberIDs[1]]?.displayName, "b.txt")
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
        XCTAssertTrue(persisted.contains(Pair(surfaced.memberFileIDs[0], surfaced.memberFileIDs[1])))

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

        let dupeID = try XCTUnwrap(svc.membersByID.first { $0.value.displayName == "b.txt" }?.key)
        let trashed = try await svc.trash([dupeID])
        XCTAssertEqual(trashed, [dupeID])
        XCTAssertTrue(fm.fileExists(atPath: keeper.path), "keeper stays")
        XCTAssertFalse(fm.fileExists(atPath: dupe.path), "non-keeper moved to Trash")
        XCTAssertNil(svc.membersByID[dupeID])
        XCTAssertTrue(svc.groups.isEmpty, "singleton group removed")

        // Undo brings the trashed file back from the Trash and restores the live results.
        XCTAssertTrue(svc.canUndoTrash)
        let restored = try await svc.undoLastTrash()
        XCTAssertEqual(restored, [dupeID])
        XCTAssertTrue(fm.fileExists(atPath: dupe.path), "non-keeper moved back out of Trash")
        XCTAssertEqual(svc.membersByID[dupeID]?.displayName, "b.txt")
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

        let bID = try XCTUnwrap(svc.membersByID.first { $0.value.displayName == "b.txt" }?.key)
        let cID = try XCTUnwrap(svc.membersByID.first { $0.value.displayName == "c.txt" }?.key)
        let trashed = try await svc.trash([bID, cID])
        XCTAssertEqual(trashed, [bID], "only the reachable dupe is trashed")
        XCTAssertFalse(fm.fileExists(atPath: dupe1.path), "b.txt went to Trash")
        XCTAssertNil(svc.membersByID[bID], "trashed file left the results")
        XCTAssertNotNil(svc.membersByID[cID], "the missing file stays visible (not silently dropped)")
        // Index agrees: only b.txt is marked deleted (.skipped); the missing file is untouched.
        let statusB = try await store.file(id: bID)?.status
        let statusC = try await store.file(id: cID)?.status
        XCTAssertEqual(statusB, .skipped)
        XCTAssertEqual(statusC, .indexed)
    }

    /// Regression (real SQLite): the engine stamps `bookmarkID` with a 0-based root index, but the DB's
    /// file_record.bookmark_id has an FK to source_bookmark.id. Persisting the index verbatim threw
    /// "FOREIGN KEY constraint failed" and killed the scan. ScanService must translate index → real
    /// source id before persisting. Uses GRDBIndexStore (FKs enforced), not the in-memory fake.
    func testScanPersistsRealSourceIDNotRootIndex() async throws {
        let store = try GRDBIndexStore(inMemory: true)
        // Real source ids autoincrement from 1, so they never equal the engine's 0-based index.
        let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/tmp"))
        XCTAssertNotEqual(sid, 0)

        let group = DuplicateGroup(
            id: 0, matchType: .exact, confidence: 1.0,
            explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2]
        )
        let svc = ScanService(coordinator: StubCoordinator(events: [
            .groupFound(group, members: [file(1, "a.txt"), file(2, "b.txt")]),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1))
        ]), store: store)

        // Before the fix this threw on the first upsert; now it completes.
        try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]), rootBookmarkIDs: [sid])

        let memberID = try XCTUnwrap(svc.groups.first?.memberFileIDs.first)
        let saved = try await store.file(id: memberID)
        XCTAssertEqual(saved?.bookmarkID, sid, "persisted with the real source id, not the root index")
    }

    /// Regression (real SQLite): the engine renumbers files 1…N every scan, so a rescan re-presents
    /// the same paths under different engine ids. Upserting by id then threw "UNIQUE constraint
    /// failed: file_record.bookmark_id, file_record.relative_path" (SQLite error 19) and killed the
    /// scan. A rescan must complete, reuse each path's durable row id, and its group must reference
    /// those rows.
    func testRescanWithRenumberedEngineIDsSucceeds() async throws {
        let store = try GRDBIndexStore(inMemory: true)
        let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/tmp"))
        func scan(_ svcEvents: [ScanEvent]) async throws -> ScanService {
            let svc = ScanService(coordinator: StubCoordinator(events: svcEvents), store: store)
            try await svc.startScan(ScanRequest(roots: [URL(fileURLWithPath: "/tmp")], scopes: [.document]), rootBookmarkIDs: [sid])
            return svc
        }

        let first = try await scan([
            .groupFound(
                DuplicateGroup(
                    id: 0,
                    matchType: .exact,
                    confidence: 1.0,
                    explanation: "Identical file contents",
                    keeperFileID: 1,
                    memberFileIDs: [1, 2]
                ),
                members: [file(1, "a.txt"), file(2, "b.txt")]
            ),
            .finished(summary: ScanSummary(filesDiscovered: 2, groupsFound: 1))
        ])
        let firstIDs = try XCTUnwrap(first.groups.first?.memberFileIDs)

        // Rescan: a new file shifted enumeration, so a.txt/b.txt arrive renumbered (2, 3).
        // Before the fix this threw on the upsert; now the same paths keep their row ids.
        let second = try await scan([
            .groupFound(
                DuplicateGroup(
                    id: 0,
                    matchType: .exact,
                    confidence: 1.0,
                    explanation: "Identical file contents",
                    keeperFileID: 2,
                    memberFileIDs: [2, 3]
                ),
                members: [file(2, "a.txt"), file(3, "b.txt")]
            ),
            .finished(summary: ScanSummary(filesDiscovered: 3, groupsFound: 1))
        ])
        let secondIDs = try XCTUnwrap(second.groups.first?.memberFileIDs)
        XCTAssertEqual(secondIDs, firstIDs, "same paths resolve to the same durable row ids across rescans")
        let keeper = try XCTUnwrap(second.groups.first?.keeperFileID)
        let keeperFile = try await store.file(id: keeper)
        XCTAssertEqual(keeperFile?.displayName, "a.txt", "keeper remapped to the store id of the right file")
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
