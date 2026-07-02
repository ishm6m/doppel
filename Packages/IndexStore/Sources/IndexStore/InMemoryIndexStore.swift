import DoppelKit
import Foundation

/// In-memory implementation used by tests and previews. Fully functional, no SQLite.
/// The production GRDBIndexStore (skeleton in GRDBIndexStore.swift) mirrors this behavior.
public actor InMemoryIndexStore: IndexStoring {
    private var sourcesByID: [Int64: SourceBookmark] = [:]
    private var filesByID: [Int64: FileRecord] = [:]
    private struct StoredGroup {
        var group: DuplicateGroup
        var members: [Int64]
        var edges: [MatchEdge]
        var sessionID: Int64
    }

    private var groupsByID: [Int64: StoredGroup] = [:]
    private var embeddingsByID: [Int64: Embedding] = [:]
    private var sessionsByID: [Int64: ScanSession] = [:]
    private var ignored: Set<Pair> = []
    private var nextID: Int64 = 1

    public init() {}

    private func makeID() -> Int64 {
        defer { nextID += 1 }; return nextID
    }

    /// Sources
    public func addSource(_ bookmark: SourceBookmark) async throws -> Int64 {
        let id = makeID()
        sourcesByID[id] = SourceBookmark(
            id: id,
            bookmarkData: bookmark.bookmarkData,
            displayPath: bookmark.displayPath,
            addedAt: bookmark.addedAt
        )
        return id
    }

    public func sources() async throws -> [SourceBookmark] {
        Array(sourcesByID.values).sorted { $0.id < $1.id }
    }

    public func removeSource(id: Int64) async throws {
        sourcesByID[id] = nil
        let removed = Set(filesByID.values.filter { $0.bookmarkID == id }.map(\.id))
        for fid in removed { filesByID[fid] = nil }
        // Mirror GRDB: a group whose keeper lived in this source is dropped (keeper FK has no cascade).
        for (gid, g) in groupsByID where removed.contains(g.group.keeperFileID) {
            groupsByID[gid] = nil
        }
    }

    /// Files
    public func upsertFiles(_ files: [FileRecord]) async throws {
        for f in files {
            filesByID[f.id] = f
        }
    }

    public func unchangedFileIDs(matching sigs: [FileSignature]) async throws -> Set<Int64> {
        let sigSet = Set(sigs)
        return Set(filesByID.values.filter { sigSet.contains($0.signature) }.map(\.id))
    }

    public func file(id: Int64) async throws -> FileRecord? {
        filesByID[id]
    }

    public func markDeleted(ids: [Int64]) async throws {
        for id in ids {
            filesByID[id]?.status = .skipped
        }
    }

    public func restore(ids: [Int64]) async throws {
        for id in ids {
            filesByID[id]?.status = .indexed
        }
    }

    /// Groups
    public func saveGroup(_ group: DuplicateGroup, members: [Int64], edges: [MatchEdge], sessionID: Int64) async throws -> Int64 {
        let id = group.id == 0 ? makeID() : group.id
        var g = group
        g = DuplicateGroup(
            id: id,
            matchType: group.matchType,
            confidence: group.confidence,
            explanation: group.explanation,
            keeperFileID: group.keeperFileID,
            memberFileIDs: members,
            ignored: group.ignored,
            createdAt: group.createdAt
        )
        groupsByID[id] = StoredGroup(group: g, members: members, edges: edges, sessionID: sessionID)
        return id
    }

    public func groups(sessionID: Int64) async throws -> [DuplicateGroup] {
        groupsByID.values.filter { $0.sessionID == sessionID }.map(\.group).sorted { $0.id < $1.id }
    }

    public func setKeeper(groupID: Int64, fileID: Int64) async throws {
        guard var entry = groupsByID[groupID] else { return }
        let g = entry.group
        entry.group = DuplicateGroup(
            id: g.id,
            matchType: g.matchType,
            confidence: g.confidence,
            explanation: g.explanation,
            keeperFileID: fileID,
            memberFileIDs: g.memberFileIDs,
            ignored: g.ignored,
            createdAt: g.createdAt
        )
        groupsByID[groupID] = entry
    }

    public func ignoreGroup(_ groupID: Int64) async throws {
        guard var entry = groupsByID[groupID] else { return }
        let g = entry.group
        entry.group = DuplicateGroup(
            id: g.id,
            matchType: g.matchType,
            confidence: g.confidence,
            explanation: g.explanation,
            keeperFileID: g.keeperFileID,
            memberFileIDs: g.memberFileIDs,
            ignored: true,
            createdAt: g.createdAt
        )
        groupsByID[groupID] = entry
    }

    public func ignorePair(_ a: Int64, _ b: Int64) async throws {
        ignored.insert(Pair(a, b))
    }

    public func ignoredPairs() async throws -> Set<Pair> {
        ignored
    }

    public func clearIgnoredPairs() async throws {
        ignored.removeAll()
    }

    /// Embeddings
    public func saveEmbedding(_ embedding: Embedding) async throws -> Int64 {
        let id = embedding.id == 0 ? makeID() : embedding.id
        embeddingsByID[id] = Embedding(id: id, modelID: embedding.modelID, dim: embedding.dim, vector: embedding.vector)
        return id
    }

    public func embedding(id: Int64) async throws -> Embedding? {
        embeddingsByID[id]
    }

    public func invalidateEmbeddings(notModel modelID: String) async throws {
        for (id, e) in embeddingsByID where e.modelID != modelID {
            embeddingsByID[id] = nil
        }
    }

    /// Sessions
    public func createSession(_ session: ScanSession) async throws -> Int64 {
        let id = session.id == 0 ? makeID() : session.id
        sessionsByID[id] = ScanSession(
            id: id,
            startedAt: session.startedAt,
            finishedAt: session.finishedAt,
            rootBookmarkIDs: session.rootBookmarkIDs,
            scopes: session.scopes,
            filesDiscovered: session.filesDiscovered,
            groupsFound: session.groupsFound,
            bytesReclaimable: session.bytesReclaimable,
            state: session.state
        )
        return id
    }

    public func updateSession(_ session: ScanSession) async throws {
        sessionsByID[session.id] = session
    }

    public func sessions() async throws -> [ScanSession] {
        Array(sessionsByID.values).sorted { $0.id < $1.id }
    }
}
