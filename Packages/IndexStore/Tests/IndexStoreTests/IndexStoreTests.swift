import DoppelKit
import XCTest
@testable import IndexStore

/// Shared behavioral contract: every assertion runs against BOTH IndexStoring implementations
/// (InMemoryIndexStore and GRDBIndexStore), proving they are observably equivalent. File records are
/// always parented to a real source so the contract is valid under GRDB's enforced foreign keys.
/// File ids are store-assigned (identity = source + path), so assertions use the ids upsert returns.
private func assertStoreBehavior(_ store: any IndexStoring) async throws {
    // Source round-trip + cascade delete
    let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/tmp"))
    let cascadeFile = try await store.upsertFiles([
        FileRecord(
            id: 0,
            bookmarkID: sid,
            relativePath: "a.txt",
            displayName: "a.txt",
            sizeBytes: 10,
            mtime: .now,
            typeScope: .document
        )
    ])[0]
    let sourceCount = try await store.sources().count
    XCTAssertEqual(sourceCount, 1)
    try await store.removeSource(id: sid)
    let cascaded = try await store.file(id: cascadeFile.id)
    XCTAssertNil(cascaded) // cascade removed the file

    try await assertRemoveSourceDropsKeeperGroup(store)
    try await assertUpsertKeysByPathNotEngineID(store)

    // A persistent source to parent the remaining file-based assertions.
    let src = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/docs"))

    // Unchanged detection (signature = size + mtime + fileID)
    let mtime = Date(timeIntervalSince1970: 100)
    let f = try await store.upsertFiles([
        FileRecord(
            id: 0,
            bookmarkID: src,
            relativePath: "a",
            displayName: "a",
            sizeBytes: 42,
            mtime: mtime,
            fileID: 7,
            typeScope: .document
        )
    ])[0]
    let unchanged = try await store.unchangedFileIDs(matching: [f.signature])
    XCTAssertTrue(unchanged.contains(f.id))

    // Mark deleted / restore
    let del = try await store.upsertFiles([
        FileRecord(
            id: 0,
            bookmarkID: src,
            relativePath: "del",
            displayName: "del",
            sizeBytes: 1,
            mtime: .now,
            typeScope: .document
        )
    ])[0]
    try await store.markDeleted(ids: [del.id])
    let deleted = try await store.file(id: del.id)
    XCTAssertEqual(deleted?.status, .skipped)
    try await store.restore(ids: [del.id])
    let restored = try await store.file(id: del.id)
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

    // Group save + members + keeper + ignore (files f & del exist under src, satisfying FKs).
    // Groups are tagged with the owning session (ssid); a different session must not see them.
    let gid = try await store.saveGroup(
        DuplicateGroup(
            id: 0,
            matchType: .exact,
            confidence: 1.0,
            explanation: "identical",
            keeperFileID: f.id,
            memberFileIDs: [f.id, del.id]
        ),
        members: [f.id, del.id],
        edges: [MatchEdge(groupID: 0, fileA: f.id, fileB: del.id, matchType: .exact, score: 1.0, reasonSummary: "sha256")],
        sessionID: ssid
    )
    let savedGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(savedGroup?.memberFileIDs, [f.id, del.id].sorted())
    let otherSession = try await store.createSession(ScanSession(id: 0, rootBookmarkIDs: [], scopes: [.document]))
    let isolated = try await store.groups(sessionID: otherSession)
    XCTAssertTrue(isolated.isEmpty, "groups are scoped to their owning session")
    try await store.setKeeper(groupID: gid, fileID: del.id)
    let keptGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(keptGroup?.keeperFileID, del.id)
    try await store.ignoreGroup(gid)
    let ignoredGroup = try await store.groups(sessionID: ssid).first { $0.id == gid }
    XCTAssertEqual(ignoredGroup?.ignored, true)

    // Ignore pairs (normalized so (a,b) == (b,a))
    try await store.ignorePair(del.id, f.id)
    let ignoredPairs = try await store.ignoredPairs()
    XCTAssertTrue(ignoredPairs.contains(Pair(f.id, del.id)))
}

/// Regression: removing a source whose file is a group's keeper must not trip the keeper FK
/// (duplicate_group.keeper_file_id has no ON DELETE cascade). Throws on GRDB before the fix.
private func assertRemoveSourceDropsKeeperGroup(_ store: any IndexStoring) async throws {
    let ksid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/k"))
    let files = try await store.upsertFiles([
        FileRecord(id: 0, bookmarkID: ksid, relativePath: "k1", displayName: "k1", sizeBytes: 5, mtime: .now, typeScope: .document),
        FileRecord(id: 0, bookmarkID: ksid, relativePath: "k2", displayName: "k2", sizeBytes: 5, mtime: .now, typeScope: .document)
    ])
    let ids = files.map(\.id)
    let ksess = try await store.createSession(ScanSession(id: 0, rootBookmarkIDs: [ksid], scopes: [.document]))
    let kgid = try await store.saveGroup(
        DuplicateGroup(id: 0, matchType: .exact, confidence: 1.0, explanation: "id", keeperFileID: ids[0], memberFileIDs: ids),
        members: ids,
        edges: [],
        sessionID: ksess
    )
    try await store.removeSource(id: ksid) // must not throw
    let keeperGroup = try await store.groups(sessionID: ksess).first { $0.id == kgid }
    XCTAssertNil(keeperGroup, "keeper's group is dropped")
    let keeperFile = try await store.file(id: ids[0])
    XCTAssertNil(keeperFile)
}

/// Regression: file identity is (source, path), NOT the engine's per-scan id. The engine renumbers
/// files every scan, so a rescan re-presents the same paths under different ids; upserting by id made
/// that trip "UNIQUE constraint failed: file_record.bookmark_id, file_record.relative_path"
/// (SQLite error 19) and kill the scan. Re-upserting the same paths — in any order, with any incoming
/// ids — must update in place and keep returning the same durable row ids.
private func assertUpsertKeysByPathNotEngineID(_ store: any IndexStoring) async throws {
    let sid = try await store.addSource(SourceBookmark(id: 0, bookmarkData: Data(), displayPath: "/r"))
    func rec(_ engineID: Int64, _ path: String, size: Int64) -> FileRecord {
        FileRecord(
            id: engineID,
            bookmarkID: sid,
            relativePath: path,
            displayName: path,
            sizeBytes: size,
            mtime: .now,
            typeScope: .document
        )
    }
    let first = try await store.upsertFiles([rec(1, "x", size: 1), rec(2, "y", size: 2)])
    // Rescan: same paths, renumbered + reordered engine ids. Must not throw.
    let second = try await store.upsertFiles([rec(1, "y", size: 20), rec(2, "x", size: 10), rec(3, "z", size: 3)])
    XCTAssertEqual(second[0].id, first[1].id, "same path keeps its durable row id across rescans")
    XCTAssertEqual(second[1].id, first[0].id)
    XCTAssertFalse(first.map(\.id).contains(second[2].id), "new path gets a fresh id")
    let updated = try await store.file(id: first[0].id)
    XCTAssertEqual(updated?.sizeBytes, 10, "rescan updated the existing row in place")
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
