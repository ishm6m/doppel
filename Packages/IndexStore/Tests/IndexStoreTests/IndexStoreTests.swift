import XCTest
import DoppelKit
@testable import IndexStore

/// Shared behavioral contract: every assertion runs against BOTH IndexStoring implementations
/// (InMemoryIndexStore and GRDBIndexStore), proving they are observably equivalent. File records are
/// always parented to a real source so the contract is valid under GRDB's enforced foreign keys.
private func assertStoreBehavior(_ store: any IndexStoring) async throws {
    // Source round-trip + cascade delete
    let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/tmp"))
    try await store.upsertFiles([
        FileRecord(id: 1, bookmarkID: sid, relativePath: "a.txt", displayName: "a.txt",
                   sizeBytes: 10, mtime: .now, typeScope: .document)
    ])
    XCTAssertEqual(try await store.sources().count, 1)
    try await store.removeSource(id: sid)
    XCTAssertNil(try await store.file(id: 1)) // cascade removed the file

    // A persistent source to parent the remaining file-based assertions.
    let src = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/docs"))

    // Unchanged detection (signature = size + mtime + fileID)
    let mtime = Date(timeIntervalSince1970: 100)
    let f = FileRecord(id: 11, bookmarkID: src, relativePath: "a", displayName: "a",
                       sizeBytes: 42, mtime: mtime, fileID: 7, typeScope: .document)
    try await store.upsertFiles([f])
    XCTAssertTrue(try await store.unchangedFileIDs(matching: [f.signature]).contains(11))

    // Mark deleted / restore
    try await store.upsertFiles([
        FileRecord(id: 21, bookmarkID: src, relativePath: "del", displayName: "del",
                   sizeBytes: 1, mtime: .now, typeScope: .document)
    ])
    try await store.markDeleted(ids: [21])
    XCTAssertEqual(try await store.file(id: 21)?.status, .skipped)
    try await store.restore(ids: [21])
    XCTAssertEqual(try await store.file(id: 21)?.status, .indexed)

    // Embedding invalidation + float32 BLOB round-trip
    let keep = try await store.saveEmbedding(Embedding(id: 0, modelID: "modelB", dim: 2, vector: [1, 0]))
    let drop = try await store.saveEmbedding(Embedding(id: 0, modelID: "modelA", dim: 2, vector: [0, 1]))
    try await store.invalidateEmbeddings(notModel: "modelB")
    let kept = try await store.embedding(id: keep)
    XCTAssertNotNil(kept)
    XCTAssertEqual(kept?.vector, [1, 0])
    XCTAssertNil(try await store.embedding(id: drop))

    // Session round-trip (rootBookmarkIDs packed into scopes_json). id 0 => the store assigns the id and
    // the returned session must carry it (regression guard for the InMemory createSession id fix).
    let ssid = try await store.createSession(
        ScanSession(id: 0, rootBookmarkIDs: [3, 1], scopes: [.document, .image], filesDiscovered: 5)
    )
    let session = try await store.sessions().first { $0.id == ssid }
    XCTAssertEqual(session?.rootBookmarkIDs, [3, 1])
    XCTAssertEqual(session?.scopes, [.document, .image])
    XCTAssertEqual(session?.filesDiscovered, 5)

    // Group save + members + keeper + ignore (files 11 & 21 exist under src, satisfying FKs)
    let gid = try await store.saveGroup(
        DuplicateGroup(id: 0, matchType: .exact, confidence: 1.0, explanation: "identical",
                       keeperFileID: 11, memberFileIDs: [11, 21]),
        members: [11, 21],
        edges: [MatchEdge(groupID: 0, fileA: 11, fileB: 21, matchType: .exact, score: 1.0, reasonSummary: "sha256")]
    )
    XCTAssertEqual(try await store.groups(sessionID: 0).first { $0.id == gid }?.memberFileIDs, [11, 21])
    try await store.setKeeper(groupID: gid, fileID: 21)
    XCTAssertEqual(try await store.groups(sessionID: 0).first { $0.id == gid }?.keeperFileID, 21)
    try await store.ignoreGroup(gid)
    XCTAssertEqual(try await store.groups(sessionID: 0).first { $0.id == gid }?.ignored, true)
    XCTAssertTrue(try await store.sessions().allSatisfy { $0.id != 0 }) // group-parking sentinel stays hidden

    // Ignore pairs (normalized so (a,b) == (b,a))
    try await store.ignorePair(21, 11)
    XCTAssertTrue(try await store.ignoredPairs().contains(Pair(11, 21)))
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
