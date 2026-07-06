import DoppelKit
import Foundation
import GRDB

/// Production persistence (SQLite via GRDB). This is a SKELETON for Milestone 1 (tasks T1.1–T1.3):
/// the schema migration `v1` is defined here per DATA_MODEL.md §3; method bodies are stubbed with
/// `notImplemented()` and must be filled in (each becomes a tested unit in T1.2).
///
/// Why GRDB and not SwiftData: bulk inserts, FTS, and BLOB storage of hashes/embeddings at scale.
public actor GRDBIndexStore: IndexStoring {
    private let dbQueue: DatabaseQueue

    public init(path: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: path.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory variant for tests that still exercise the real schema.
    public init(inMemory: Bool) throws {
        precondition(inMemory)
        dbQueue = try DatabaseQueue() // anonymous in-memory db
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: Migrations (DATA_MODEL.md §3) — append-only, never edit a shipped migration.

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "source_bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookmark_data", .blob).notNull()
                t.column("display_path", .text).notNull()
                t.column("added_at", .double).notNull()
            }
            try db.create(table: "embedding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("model_id", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(table: "scan_session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .double).notNull()
                t.column("finished_at", .double)
                t.column("scopes_json", .text).notNull()
                t.column("files_discovered", .integer).notNull().defaults(to: 0)
                t.column("groups_found", .integer).notNull().defaults(to: 0)
                t.column("bytes_reclaimable", .integer).notNull().defaults(to: 0)
                t.column("state", .text).notNull()
            }
            try db.create(table: "file_record") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookmark_id", .integer).notNull()
                    .references("source_bookmark", onDelete: .cascade)
                t.column("relative_path", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("size_bytes", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("file_id", .integer)
                t.column("type_scope", .text).notNull()
                t.column("content_kind", .text).notNull()
                t.column("sha256", .blob)
                t.column("minhash", .blob)
                t.column("phash", .integer)
                t.column("embedding_id", .integer).references("embedding", onDelete: .setNull)
                t.column("status", .text).notNull()
                t.column("issue_json", .text)
                t.uniqueKey(["bookmark_id", "relative_path"])
            }
            try db.create(indexOn: "file_record", columns: ["size_bytes"])
            try db.create(indexOn: "file_record", columns: ["sha256"])
            try db.create(indexOn: "file_record", columns: ["status"])

            try db.create(table: "duplicate_group") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("scan_id", .integer).notNull().references("scan_session", onDelete: .cascade)
                t.column("match_type", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("explanation", .text).notNull()
                t.column("keeper_file_id", .integer).notNull().references("file_record")
                t.column("ignored", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
            }
            try db.create(table: "group_member") { t in
                t.column("group_id", .integer).notNull().references("duplicate_group", onDelete: .cascade)
                t.column("file_id", .integer).notNull().references("file_record", onDelete: .cascade)
                t.primaryKey(["group_id", "file_id"])
            }
            try db.create(table: "match_edge") { t in
                t.column("group_id", .integer).notNull().references("duplicate_group", onDelete: .cascade)
                t.column("file_a", .integer).notNull()
                t.column("file_b", .integer).notNull()
                t.column("match_type", .text).notNull()
                t.column("score", .double).notNull()
                t.column("reason_summary", .text).notNull()
            }
            try db.create(table: "lsh_bucket") { t in
                t.column("band", .integer).notNull()
                t.column("bucket_hash", .integer).notNull()
                t.column("file_id", .integer).notNull().references("file_record", onDelete: .cascade)
            }
            try db.create(indexOn: "lsh_bucket", columns: ["band", "bucket_hash"])
            try db.create(table: "ignore_pair") { t in
                t.column("file_a", .integer).notNull()
                t.column("file_b", .integer).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["file_a", "file_b"])
            }
        }
        return m
    }

    // MARK: IndexStoring

    /// Sources
    public func addSource(_ bookmark: SourceBookmark) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO source_bookmark (bookmark_data, display_path, added_at) VALUES (?, ?, ?)",
                arguments: [bookmark.bookmarkData, bookmark.displayPath, bookmark.addedAt.timeIntervalSince1970]
            )
            return db.lastInsertedRowID
        }
    }

    public func sources() async throws -> [SourceBookmark] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_bookmark ORDER BY id").map { row in
                SourceBookmark(
                    id: row["id"],
                    bookmarkData: row["bookmark_data"],
                    displayPath: row["display_path"],
                    addedAt: Date(timeIntervalSince1970: row["added_at"])
                )
            }
        }
    }

    public func removeSource(id: Int64) async throws {
        // FK ON DELETE CASCADE drops the source's file_records (DATA_MODEL.md §3). But
        // duplicate_group.keeper_file_id has NO cascade (a group must always have a keeper), so a
        // group whose keeper lives in this source would violate that FK mid-cascade. Drop those
        // groups first (their members/edges cascade), then the source.
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM duplicate_group
                WHERE keeper_file_id IN (SELECT id FROM file_record WHERE bookmark_id = ?)
                """,
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM source_bookmark WHERE id = ?", arguments: [id])
        }
    }

    /// Files
    public func upsertFiles(_ files: [FileRecord]) async throws {
        try await dbQueue.write { db in
            for f in files {
                try db.execute(
                    sql: """
                    INSERT INTO file_record
                      (id, bookmark_id, relative_path, display_name, size_bytes, mtime, file_id,
                       type_scope, content_kind, sha256, minhash, phash, embedding_id, status, issue_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      bookmark_id = excluded.bookmark_id, relative_path = excluded.relative_path,
                      display_name = excluded.display_name, size_bytes = excluded.size_bytes,
                      mtime = excluded.mtime, file_id = excluded.file_id, type_scope = excluded.type_scope,
                      content_kind = excluded.content_kind, sha256 = excluded.sha256, minhash = excluded.minhash,
                      phash = excluded.phash, embedding_id = excluded.embedding_id, status = excluded.status,
                      issue_json = excluded.issue_json
                    """,
                    arguments: fileArguments(f)
                )
            }
        }
    }

    public func unchangedFileIDs(matching sigs: [FileSignature]) async throws -> Set<Int64> {
        let sigSet = Set(sigs)
        // ponytail: full table scan + filter in Swift, mirrors InMemoryIndexStore exactly.
        // T1.3 is the dedicated incremental-lookup task; index/narrow the query there if perf demands.
        return try await dbQueue.read { db in
            var result: Set<Int64> = []
            let rows = try Row.fetchAll(db, sql: "SELECT id, size_bytes, mtime, file_id FROM file_record")
            for row in rows {
                let fileID: Int64? = row["file_id"]
                let sig = FileSignature(
                    sizeBytes: row["size_bytes"],
                    mtime: Date(timeIntervalSince1970: row["mtime"]),
                    fileID: fileID.map { UInt64(bitPattern: $0) }
                )
                if sigSet.contains(sig) { result.insert(row["id"]) }
            }
            return result
        }
    }

    public func file(id: Int64) async throws -> FileRecord? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM file_record WHERE id = ?", arguments: [id])
                .map(decodeFile)
        }
    }

    public func markDeleted(ids: [Int64]) async throws {
        try await setStatus(ids, to: .skipped)
    }

    public func restore(ids: [Int64]) async throws {
        try await setStatus(ids, to: .indexed)
    }

    private func setStatus(_ ids: [Int64], to status: FileStatus) async throws {
        guard !ids.isEmpty else { return }
        try await dbQueue.write { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            try db.execute(
                sql: "UPDATE file_record SET status = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments([status.rawValue] + ids)
            )
        }
    }

    /// Groups
    public func saveGroup(_ group: DuplicateGroup, members: [Int64], edges: [MatchEdge], sessionID: Int64) async throws -> Int64 {
        try await dbQueue.write { db in
            // scan_id is the owning session (created by ScanService before the scan — see docs/API.md).
            if group.id == 0 {
                try db.execute(
                    sql: """
                    INSERT INTO duplicate_group
                      (scan_id, match_type, confidence, explanation, keeper_file_id, ignored, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [sessionID, group.matchType.rawValue, group.confidence, group.explanation,
                                group.keeperFileID, group.ignored, group.createdAt.timeIntervalSince1970]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO duplicate_group
                      (id, scan_id, match_type, confidence, explanation, keeper_file_id, ignored, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [group.id, sessionID, group.matchType.rawValue, group.confidence, group.explanation,
                                group.keeperFileID, group.ignored, group.createdAt.timeIntervalSince1970]
                )
            }
            let gid = group.id == 0 ? db.lastInsertedRowID : group.id

            for fileID in members {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO group_member (group_id, file_id) VALUES (?, ?)",
                    arguments: [gid, fileID]
                )
            }
            for e in edges {
                try db.execute(
                    sql: """
                    INSERT INTO match_edge (group_id, file_a, file_b, match_type, score, reason_summary)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [gid, e.fileA, e.fileB, e.matchType.rawValue, e.score, e.reasonSummary]
                )
            }
            return gid
        }
    }

    public func groups(sessionID: Int64) async throws -> [DuplicateGroup] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM duplicate_group WHERE scan_id = ? ORDER BY id", arguments: [sessionID]).map { row in
                let gid: Int64 = row["id"]
                let members = try Int64.fetchAll(
                    db, sql: "SELECT file_id FROM group_member WHERE group_id = ? ORDER BY file_id",
                    arguments: [gid]
                )
                return try decodeGroup(row, members: members)
            }
        }
    }

    public func setKeeper(groupID: Int64, fileID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE duplicate_group SET keeper_file_id = ? WHERE id = ?",
                arguments: [fileID, groupID]
            )
        }
    }

    public func ignoreGroup(_ groupID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE duplicate_group SET ignored = 1 WHERE id = ?", arguments: [groupID])
        }
    }

    public func ignorePair(_ a: Int64, _ b: Int64) async throws {
        let pair = Pair(a, b) // normalizes ordering
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO ignore_pair (file_a, file_b, created_at) VALUES (?, ?, ?)",
                arguments: [pair.a, pair.b, Date.now.timeIntervalSince1970]
            )
        }
    }

    public func ignoredPairs() async throws -> Set<Pair> {
        try await dbQueue.read { db in
            var pairs: Set<Pair> = []
            for row in try Row.fetchAll(db, sql: "SELECT file_a, file_b FROM ignore_pair") {
                pairs.insert(Pair(row["file_a"], row["file_b"]))
            }
            return pairs
        }
    }

    public func clearIgnoredPairs() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM ignore_pair")
        }
    }

    /// Embeddings
    public func saveEmbedding(_ embedding: Embedding) async throws -> Int64 {
        let blob = packFloats(embedding.vector)
        return try await dbQueue.write { db in
            if embedding.id == 0 {
                try db.execute(
                    sql: "INSERT INTO embedding (model_id, dim, vector) VALUES (?, ?, ?)",
                    arguments: [embedding.modelID, embedding.dim, blob]
                )
                return db.lastInsertedRowID
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO embedding (id, model_id, dim, vector) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      model_id = excluded.model_id, dim = excluded.dim, vector = excluded.vector
                    """,
                    arguments: [embedding.id, embedding.modelID, embedding.dim, blob]
                )
                return embedding.id
            }
        }
    }

    public func embedding(id: Int64) async throws -> Embedding? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM embedding WHERE id = ?", arguments: [id]).map { row in
                Embedding(
                    id: row["id"],
                    modelID: row["model_id"],
                    dim: row["dim"],
                    vector: unpackFloats(row["vector"])
                )
            }
        }
    }

    public func invalidateEmbeddings(notModel modelID: String) async throws {
        // Deleting rows nulls file_record.embedding_id via FK ON DELETE SET NULL (DATA_MODEL.md §3).
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM embedding WHERE model_id <> ?", arguments: [modelID])
        }
    }

    /// Sessions
    public func createSession(_ session: ScanSession) async throws -> Int64 {
        let scopesJSON = try encodeSessionScopes(session)
        return try await dbQueue.write { db in
            if session.id == 0 {
                try db.execute(
                    sql: """
                    INSERT INTO scan_session
                      (started_at, finished_at, scopes_json, files_discovered, groups_found, bytes_reclaimable, state)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [session.startedAt.timeIntervalSince1970, session.finishedAt?.timeIntervalSince1970,
                                scopesJSON, session.filesDiscovered, session.groupsFound,
                                session.bytesReclaimable, session.state.rawValue]
                )
                return db.lastInsertedRowID
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO scan_session
                      (id, started_at, finished_at, scopes_json, files_discovered, groups_found, bytes_reclaimable, state)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [session.id, session.startedAt.timeIntervalSince1970,
                                session.finishedAt?.timeIntervalSince1970, scopesJSON, session.filesDiscovered,
                                session.groupsFound, session.bytesReclaimable, session.state.rawValue]
                )
                return session.id
            }
        }
    }

    public func updateSession(_ session: ScanSession) async throws {
        let scopesJSON = try encodeSessionScopes(session)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE scan_session SET
                  started_at = ?, finished_at = ?, scopes_json = ?, files_discovered = ?,
                  groups_found = ?, bytes_reclaimable = ?, state = ?
                WHERE id = ?
                """,
                arguments: [session.startedAt.timeIntervalSince1970, session.finishedAt?.timeIntervalSince1970,
                            scopesJSON, session.filesDiscovered, session.groupsFound,
                            session.bytesReclaimable, session.state.rawValue, session.id]
            )
        }
    }

    public func sessions() async throws -> [ScanSession] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM scan_session ORDER BY id").map(decodeSession)
        }
    }

    public func deleteSession(id: Int64) async throws {
        // duplicate_group.scan_id cascades → group_member + match_edge drop too. Files stay (tied to sources).
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM scan_session WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Row mapping helpers (nonisolated; safe to call inside @Sendable db closures)

private enum StoreError: Error { case decode(String) }

private func fileArguments(_ f: FileRecord) throws -> StatementArguments {
    let issueJSON: String? = try f.issue.map { issue in
        guard let s = try String(data: JSONEncoder().encode(issue), encoding: .utf8) else {
            throw StoreError.decode("issue JSON not UTF-8")
        }
        return s
    }
    return [
        f.id, f.bookmarkID, f.relativePath, f.displayName, f.sizeBytes, f.mtime.timeIntervalSince1970,
        f.fileID.map { Int64(bitPattern: $0) }, f.typeScope.rawValue, f.contentKind.rawValue,
        f.sha256, f.minhash, f.phash.map { Int64(bitPattern: $0) }, f.embeddingID, f.status.rawValue, issueJSON
    ]
}

private func decodeFile(_ row: Row) throws -> FileRecord {
    guard let typeScope = FileTypeScope(rawValue: row["type_scope"]) else {
        throw StoreError.decode("type_scope")
    }
    guard let contentKind = ContentKind(rawValue: row["content_kind"]) else {
        throw StoreError.decode("content_kind")
    }
    guard let status = FileStatus(rawValue: row["status"]) else {
        throw StoreError.decode("status")
    }
    let storedFileID: Int64? = row["file_id"]
    let storedPHash: Int64? = row["phash"]
    let issueJSON: String? = row["issue_json"]
    let issue = try issueJSON.flatMap { try $0.data(using: .utf8).map { try JSONDecoder().decode(FileIssue.self, from: $0) } }
    return FileRecord(
        id: row["id"], bookmarkID: row["bookmark_id"], relativePath: row["relative_path"],
        displayName: row["display_name"], sizeBytes: row["size_bytes"],
        mtime: Date(timeIntervalSince1970: row["mtime"]),
        fileID: storedFileID.map { UInt64(bitPattern: $0) }, typeScope: typeScope, contentKind: contentKind,
        sha256: row["sha256"], minhash: row["minhash"], phash: storedPHash.map { UInt64(bitPattern: $0) },
        embeddingID: row["embedding_id"], status: status, issue: issue
    )
}

private func decodeGroup(_ row: Row, members: [Int64]) throws -> DuplicateGroup {
    guard let matchType = MatchType(rawValue: row["match_type"]) else {
        throw StoreError.decode("match_type")
    }
    let ignored: Int = row["ignored"]
    return DuplicateGroup(
        id: row["id"], matchType: matchType, confidence: row["confidence"],
        explanation: row["explanation"], keeperFileID: row["keeper_file_id"],
        memberFileIDs: members, ignored: ignored != 0,
        createdAt: Date(timeIntervalSince1970: row["created_at"])
    )
}

private struct SessionScopes: Codable {
    let scopes: [String]
    let roots: [Int64]
}

private func encodeSessionScopes(_ session: ScanSession) throws -> String {
    let payload = SessionScopes(scopes: session.scopes.map(\.rawValue).sorted(), roots: session.rootBookmarkIDs)
    guard let s = try String(data: JSONEncoder().encode(payload), encoding: .utf8) else {
        throw StoreError.decode("scopes JSON not UTF-8")
    }
    return s
}

private func decodeSession(_ row: Row) throws -> ScanSession {
    guard let state = ScanState(rawValue: row["state"]) else { throw StoreError.decode("state") }
    let scopesText: String = row["scopes_json"]
    guard let data = scopesText.data(using: .utf8) else { throw StoreError.decode("scopes_json not UTF-8") }
    let payload = try JSONDecoder().decode(SessionScopes.self, from: data)
    let scopes = Set(payload.scopes.compactMap { FileTypeScope(rawValue: $0) })
    let finished: Double? = row["finished_at"]
    return ScanSession(
        id: row["id"], startedAt: Date(timeIntervalSince1970: row["started_at"]),
        finishedAt: finished.map { Date(timeIntervalSince1970: $0) },
        rootBookmarkIDs: payload.roots, scopes: scopes,
        filesDiscovered: row["files_discovered"], groupsFound: row["groups_found"],
        bytesReclaimable: row["bytes_reclaimable"], state: state
    )
}

private func packFloats(_ vector: [Float]) -> Data {
    vector.withUnsafeBytes { Data($0) }
}

private func unpackFloats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
