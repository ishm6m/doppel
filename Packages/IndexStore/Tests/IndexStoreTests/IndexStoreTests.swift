import DoppelKit
import XCTest
@testable import IndexStore

/// Shared behavioral contract: every assertion runs against BOTH IndexStoring implementations
/// (InMemoryIndexStore and GRDBIndexStore), proving they are observably equivalent. File records are
/// always parented to a real source so the contract is valid under GRDB's enforced foreign keys.
private func assertStoreBehavior(_ store: any IndexStoring) async throws {
    // Source round-trip + cascade delete
    let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/tmp"))
    try await store.upsertFiles([
        FileRecord(
            id: 1,
            bookmarkID: sid,
            relativePath: "a.txt",
            displayName: "a.txt",
            sizeBytes: 10,
            mtime: .now,
            typeScope: .document
        )
    ])
    let sourceCount = try await store.sources().count
    XCTAssertEqual(sourceCount, 1)
    try await store.removeSource(id: sid)
    let cascaded = try await store.file(id: 1)
    XCTAssertNil(cascaded) // cascade removed the file

    try await assertRemoveSourceDropsKeeperGroup(store)

    // A persistent source to parent the remaining file-based assertions.
    let src = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/docs"))

    // Unchanged detection (signature = size + mtime + fileID)
    let mtime = Date(timeIntervalSince1970: 100)
    let f = FileRecord(
        id: 11,
        bookmarkID: src,
        relativePath: "a",
        displayName: "a",
        sizeBytes: 42,
        mtime: mtime,
        fileID: 7,
        typeScope: .document
    )
    try await store.upsertFiles([f])
    let unchanged = try await store.unchangedFileIDs(matching: [f.signature])
    XCTAssertTrue(unchanged.contains(11))

    // Mark deleted / restore
    try await store.upsertFiles([
        FileRecord(
            id: 21,
            bookmarkID: src,
            relativePath: "del",
            displayName: "del",
            sizeBytes: 1,
            mtime: .now,
            typeScope: .document
        )
    ])
    try await store.markDeleted(ids: [21])
    let deleted = try await store.file(id: 21)
    XCTAssertEqual(deleted?.status, .skipped)
    try await store.restore(ids: [21])
    let restored = try await store.file(id: 21)
    XCTAssertEqual(restored?.status, .indexed)

    // Embedding invalidation + float32 BLOB round-trip
    let keep = try await store.saveEmbedding(Embedding(id: 0, modelID: "modelB", dim: 2, vector: [1, 0]))
    let drop = try await store.saveEmbedding(Embedding(id: 0, modelID: "modelA", dim: 2, vector: [0, 1]))
    try await store.invalidateEmbeddings(notModel: "modelB")
    let kept = try await store.embedding(id: keep)
    XCTAssertNotNil(kept)
    XCTAssertEqual(kept?.vector, [1, 0])
    let dropped = try await store.embedding(id: drop)
    XCTAssertNil(dropped)

    // Session round-trip (rootBookmarkIDs packed into scopes_json). id 0 => the store assigns the id and
    // the returned session must carry it (regression guard for the InMemory createSession id fix).
    let ssid = try await store.createSession(
        ScanSession(id: 0, rootBookmarkIDs: [3, 1], scopes: [.document, .image], filesDiscovered: 5)
    )
    let session = try await store.sessions().first { $0.id == ssid }
    XCTAssertEqual(session?.rootBookmarkIDs, [3, 1])
    XCTAssertEqual(session?.scopes, [.document, .image])
    XCTAssertEqual(session?.filesDiscovered, 5)

    // Group save + members + keeper + ignore (files 11 & 21 exist under src, satisfying FKs).
    // Groups are tagged with the owning session (ssid); a different session must not see them.
    let gid = try await store.saveGroup(
        DuplicateGroup(
            id: 0,
            matchType: .exact,
            confidence: 1.0,
            explanation: "identical",
            keeperFileID: 11,
            memberFileIDs: [11, 21]
        ),
        members: [11, 21],
        edges: [MatchEdge(groupID: 0, fileA: 11, fileB: 21, matchType: .exact, score: 1.0, reasonSummary: "sha256")],
        sessionID: ssid
    )
    let savedGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(savedGroup?.memberFileIDs, [11, 21])
    let otherSession = try await store.createSession(ScanSession(id: 0, rootBookmarkIDs: [], scopes: [.document]))
    let isolated = try await store.groups(sessionID: otherSession)
    XCTAssertTrue(isolated.isEmpty, "groups are scoped to their owning session")
    try await store.setKeeper(groupID: gid, fileID: 21)
    let keptGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(keptGroup?.keeperFileID, 21)
    try await store.ignoreGroup(gid)
    let ignoredGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(ignoredGroup?.ignored, true)

    // Ignore pairs (normalized so (a,b) == (b,a))
    try await store.ignorePair(21, 11)
    let ignoredPairs = try await store.ignoredPairs()
    XCTAssertTrue(ignoredPairs.contains(Pair(11, 21)))

    // Deleting a session forgets it and cascades its groups; the scanned files persist.
    try await store.deleteSession(id: ssid)
    let remainingSessions = try await store.sessions()
    let cascadedGroups = try await store.groups(sessionID: ssid)
    let survivingFile = try await store.file(id: 11)
    XCTAssertFalse(remainingSessions.contains { $0.id == ssid })
    XCTAssertTrue(cascadedGroups.isEmpty)
    XCTAssertNotNil(survivingFile, "files outlive their scan session")
}

/// Regression: removing a source whose file is a group's keeper must not trip the keeper FK
/// (duplicate_group.keeper_file_id has no ON DELETE cascade). Throws on GRDB before the fix.
private func assertRemoveSourceDropsKeeperGroup(_ store: any IndexStoring) async throws {
    let ksid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/k"))
    try await store.upsertFiles([
        FileRecord(id: 101, bookmarkID: ksid, relativePath: "k1", displayName: "k1", sizeBytes: 5, mtime: .now, typeScope: .document),
        FileRecord(id: 102, bookmarkID: ksid, relativePath: "k2", displayName: "k2", sizeBytes: 5, mtime: .now, typeScope: .document)
    ])
    let ksess = try await store.createSession(ScanSession(id: 0, rootBookmarkIDs: [ksid], scopes: [.document]))
    let kgid = try await store.saveGroup(
        DuplicateGroup(id: 0, matchType: .exact, confidence: 1.0, explanation: "id", keeperFileID: 101, memberFileIDs: [101, 102]),
        members: [101, 102],
        edges: [],
        sessionID: ksess
    )
    try await store.removeSource(id: ksid) // must not throw
    let keeperGroup = try await store.groups(sessionID: ksess).first { $0.id == kgid }
    XCTAssertNil(keeperGroup, "keeper's group is dropped")
    let keeperFile = try await store.file(id: 101)
    XCTAssertNil(keeperFile)
}

final class InMemoryIndexStoreTests: XCTestCase {
    func testBehaviorContract() async throws {
        try await assertStoreBehavior(InMemoryIndexStore())
    }
}

final class GRDBIndexStoreTests: XCTestCase {
    func testBehaviorContract() async throws {
        try await assertStoreBehavior(GRDBIndexStore(inMemory: true))
    }

    func testMigrationCreatesSchema() throws {
        // Verifies v1 migration applies cleanly to an in-memory SQLite db.
        XCTAssertNoThrow(try GRDBIndexStore(inMemory: true))
    }
}
