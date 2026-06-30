import DoppelKit
import Foundation

/// The single persistence boundary. UI and engine speak to SQLite only through this protocol.
/// See API.md §2 and DATA_MODEL.md. All methods are actor-safe.
public protocol IndexStoring: Sendable {
    // Sources
    func addSource(_ bookmark: SourceBookmark) async throws -> Int64
    func sources() async throws -> [SourceBookmark]
    func removeSource(id: Int64) async throws

    // Files
    func upsertFiles(_ files: [FileRecord]) async throws
    func unchangedFileIDs(matching sigs: [FileSignature]) async throws -> Set<Int64>
    func file(id: Int64) async throws -> FileRecord?
    func markDeleted(ids: [Int64]) async throws
    func restore(ids: [Int64]) async throws

    // Groups
    func saveGroup(_ group: DuplicateGroup, members: [Int64], edges: [MatchEdge], sessionID: Int64) async throws -> Int64
    func groups(sessionID: Int64) async throws -> [DuplicateGroup]
    func setKeeper(groupID: Int64, fileID: Int64) async throws
    func ignoreGroup(_ groupID: Int64) async throws
    func ignorePair(_ a: Int64, _ b: Int64) async throws
    func ignoredPairs() async throws -> Set<Pair>
    /// Clears the not-duplicates list (Settings ▸ Ignore List "Reset"); previously-ignored groups
    /// can resurface on the next scan.
    func clearIgnoredPairs() async throws

    // Embeddings
    func saveEmbedding(_ embedding: Embedding) async throws -> Int64
    func embedding(id: Int64) async throws -> Embedding?
    func invalidateEmbeddings(notModel modelID: String) async throws

    // Sessions
    func createSession(_ session: ScanSession) async throws -> Int64
    func updateSession(_ session: ScanSession) async throws
    func sessions() async throws -> [ScanSession]
}
