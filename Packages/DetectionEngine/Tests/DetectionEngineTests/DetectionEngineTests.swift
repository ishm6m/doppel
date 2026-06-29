import CryptoKit
import DoppelKit
import XCTest
@testable import DetectionEngine

final class DetectionEngineTests: XCTestCase {
    func testStreamedHashMatchesKnownValue() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = try Hasher256.hash(fileAt: tmp)
        // SHA-256("hello")
        XCTAssertEqual(
            digest.map { String(format: "%02x", $0) }.joined(),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testIdenticalFilesShareHash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        let payload = Data((0 ..< 5000).map { UInt8($0 % 256) })
        try payload.write(to: a); try payload.write(to: b)
        XCTAssertEqual(try Hasher256.hash(fileAt: a), try Hasher256.hash(fileAt: b))
    }

    func testUnionFindClusters() {
        var uf = UnionFind(count: 5)
        uf.union(0, 1); uf.union(1, 2); uf.union(3, 4)
        let groups = uf.groups().map { $0.sorted() }.sorted { $0[0] < $1[0] }
        XCTAssertEqual(groups, [[0, 1, 2], [3, 4]])
    }

    func testStubEmbeddingIsDeterministicAndNormalized() async throws {
        let p = StubEmbeddingProvider(dimension: 32)
        let v1 = try await p.embed(text: "the same contract")
        let v2 = try await p.embed(text: "the same contract")
        XCTAssertEqual(v1, v2)
        let norm = sqrt(v1.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    // MARK: - Stage 0 + Stage 1 (T2.1 / T2.2)

    /// Thread-safe recorder of every URL the injected hasher was asked to open.
    private final class HashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func record(_ url: URL) {
            lock.lock(); urls.append(url); lock.unlock()
        }

        var paths: Set<String> {
            lock.lock(); defer { lock.unlock() }; return Set(urls.map(\.path))
        }
    }

    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Names of files an edge connects, looked up in the stage's emitted records.
    private func edgeNames(_ edge: StageEdge, _ records: [FileRecord]) -> Set<String> {
        Set(records.filter { [edge.pair.a, edge.pair.b].contains($0.id) }.map(\.displayName))
    }

    func testIdenticalFilesProduceOneExactEdge() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("the same contract", "a.txt", in: dir)
        _ = try write("the same contract", "copy-of-a.txt", in: dir)

        let stage0 = FileEnumerator(scopes: [.document]).enumerate(roots: [dir])
        let out = await ExactGrouper().group(stage0.exactCandidateBuckets())

        XCTAssertTrue(out.skipped.isEmpty)
        XCTAssertEqual(out.edges.count, 1)
        let e = out.edges[0]
        XCTAssertEqual(e.type, .exact)
        XCTAssertEqual(e.score, 1.0)
        XCTAssertEqual(e.reason, "Identical file contents")
        XCTAssertEqual(edgeNames(e, out.records), ["a.txt", "copy-of-a.txt"])
        XCTAssertTrue(out.records.allSatisfy { $0.sha256 != nil }, "hashed records carry their digest")
    }

    func testSizeUniqueFileIsNeverHashedAndFormsNoEdge() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("aaaa", "a.txt", in: dir)
        _ = try write("aaaa", "b.txt", in: dir) // collides with a.txt on size
        let lone = try write("a unique length here", "lone.txt", in: dir) // unique size

        let stage0 = FileEnumerator(scopes: [.document]).enumerate(roots: [dir])
        let log = HashLog()
        let grouper = ExactGrouper(hash: { url in log.record(url); return try Hasher256.hash(fileAt: url) })
        let out = await grouper.group(stage0.exactCandidateBuckets())

        XCTAssertEqual(out.edges.count, 1)
        XCTAssertFalse(log.paths.contains(lone.path), "size-unique file must never be hashed")
        XCTAssertFalse(out.records.contains { $0.displayName == "lone.txt" })
    }

    func testUnreadableFileIsSkippedAndScanContinues() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("dup", "a.txt", in: dir)
        _ = try write("dup", "b.txt", in: dir)
        let secret = try write("xyz", "secret.txt", in: dir) // same 3-byte size → enters the bucket
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }

        let stage0 = FileEnumerator(scopes: [.document]).enumerate(roots: [dir])
        let out = await ExactGrouper().group(stage0.exactCandidateBuckets())

        XCTAssertEqual(out.edges.count, 1)
        XCTAssertEqual(edgeNames(out.edges[0], out.records), ["a.txt", "b.txt"])
        let allSkipped = stage0.skipped + out.skipped
        XCTAssertTrue(allSkipped.contains { $0.0.displayName == "secret.txt" })
    }

    func testZeroByteFilesEdgeSanely() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write("", "empty1.txt", in: dir)
        _ = try write("", "empty2.txt", in: dir)
        _ = try write("not empty", "full.txt", in: dir)

        let stage0 = FileEnumerator(scopes: [.document]).enumerate(roots: [dir])
        let out = await ExactGrouper().group(stage0.exactCandidateBuckets())

        XCTAssertTrue(out.skipped.isEmpty)
        XCTAssertEqual(out.edges.count, 1)
        XCTAssertEqual(edgeNames(out.edges[0], out.records), ["empty1.txt", "empty2.txt"])
    }

    func testHashingIsMemoryBounded() {
        let chunkSize = 1 << 16
        let totalChunks = 1024 // 64 MB streamed, never materialized whole in the hasher
        var produced = 0, maxChunk = 0
        let digest = Hasher256.hash(chunks: {
            guard produced < totalChunks else { return nil }
            produced += 1
            let d = Data(repeating: 0xAB, count: chunkSize)
            maxChunk = max(maxChunk, d.count)
            return d
        })
        XCTAssertLessThanOrEqual(maxChunk, chunkSize, "no chunk may exceed chunkSize")
        let reference = Data(SHA256.hash(data: Data(repeating: 0xAB, count: chunkSize * totalChunks)))
        XCTAssertEqual(digest, reference)
    }
}
