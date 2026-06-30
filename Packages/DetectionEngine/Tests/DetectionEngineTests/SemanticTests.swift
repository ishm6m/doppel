import DoppelKit
import XCTest
@testable import DetectionEngine

/// Stage 3 tests driven by a CONTROLLED embedding provider (F6 acceptance) — deterministic, no real
/// model. The provider maps fixture texts to chosen vectors so we can hand-pick semantic pairs.
final class SemanticTests: XCTestCase {
    /// Returns the exact vector registered for a text (zeros if unknown) — lets a test dictate geometry.
    private struct FixedProvider: EmbeddingProvider {
        let modelID: String
        let dimension: Int
        let table: [String: [Float]]
        func embed(text: String) async throws -> [Float] {
            table[text] ?? [Float](repeating: 0, count: dimension)
        }
    }

    private func rec(_ id: Int64, _ name: String) -> FileRecord {
        FileRecord(
            id: id, bookmarkID: 0, relativePath: name, displayName: name,
            sizeBytes: 100, mtime: Date(timeIntervalSince1970: TimeInterval(id)), typeScope: .document
        )
    }

    private func input(_ id: Int64, _ name: String) -> SemanticStage.Input {
        .init(record: rec(id, name), text: name)
    }

    private func edgeNames(_ edge: StageEdge, _ records: [FileRecord]) -> Set<String> {
        Set(records.filter { [edge.pair.a, edge.pair.b].contains($0.id) }.map(\.displayName))
    }

    /// Known semantic pair (near-parallel vectors) groups; an orthogonal doc does not.
    func testNearParallelVectorsFormOneSemanticEdge() async throws {
        let provider = FixedProvider(modelID: "m1", dimension: 4, table: [
            "a.txt": [1, 0, 0, 0],
            "a2.txt": [0.98, 0.2, 0, 0], // cosine ≈ 0.98 with a.txt
            "b.txt": [0, 0, 1, 0] // orthogonal to both
        ])
        let out = try await SemanticStage(provider: provider).group([input(1, "a.txt"), input(2, "a2.txt"), input(3, "b.txt")])

        XCTAssertEqual(out.edges.count, 1)
        let e = out.edges[0]
        XCTAssertEqual(e.type, .semantic)
        XCTAssertEqual(e.reason, "Semantically similar content")
        XCTAssertGreaterThanOrEqual(e.score, 0.82)
        XCTAssertEqual(edgeNames(e, out.records), ["a.txt", "a2.txt"])
    }

    /// Two orthogonal docs never group, even if a bucket pairs them — cosine rejects.
    func testOrthogonalDocsFormNoEdge() async throws {
        let provider = FixedProvider(modelID: "m1", dimension: 4, table: [
            "x.txt": [1, 0, 0, 0],
            "y.txt": [0, 1, 0, 0]
        ])
        let out = try await SemanticStage(provider: provider).group([input(1, "x.txt"), input(2, "y.txt")])
        XCTAssertTrue(out.edges.isEmpty)
    }

    /// No all-pairs blowup: a vector occupying a disjoint axis shares no bucket and is NEVER cosine'd.
    func testBucketPruningNeverComparesDisjointVector() async throws {
        let provider = FixedProvider(modelID: "m1", dimension: 8, table: [
            "p0.txt": [1, 0, 0, 0, 0, 0, 0, 0],
            "p1.txt": [0.9, 0.3, 0, 0, 0, 0, 0, 0], // shares axis 0 with p0
            "iso.txt": [0, 0, 0, 0, 0, 1, 0, 0] // axis 5 only — disjoint
        ])
        let log = CompareLog()
        let stage = SemanticStage(provider: provider, config: .init(), onCompare: { a, b in log.add(a, b) })

        _ = try await stage.group([input(1, "p0.txt"), input(2, "p1.txt"), input(3, "iso.txt")])

        let touched = Set(log.pairs.flatMap { [$0.0, $0.1] })
        XCTAssertFalse(touched.contains(2), "disjoint-axis doc must be pruned, never cosine-compared")
        XCTAssertTrue(touched.contains(0) && touched.contains(1), "the real semantic pair was compared")
    }

    /// Model invalidation (F6): swapping the model changes results for the same texts — so embeddings
    /// cached under one `modelID` must never be reused for another. Same inputs, different provider.
    func testDifferentModelChangesResultsSoCacheMustInvalidate() async throws {
        let inputs = [input(1, "doc.txt"), input(2, "doc2.txt")]
        let m1 = FixedProvider(modelID: "m1", dimension: 4, table: [
            "doc.txt": [1, 0, 0, 0], "doc2.txt": [0.97, 0.24, 0, 0] // near-parallel → groups
        ])
        let m2 = FixedProvider(modelID: "m2", dimension: 4, table: [
            "doc.txt": [1, 0, 0, 0], "doc2.txt": [0, 1, 0, 0] // orthogonal → no group
        ])
        XCTAssertNotEqual(m1.modelID, m2.modelID)
        let underM1 = try await SemanticStage(provider: m1).group(inputs)
        let underM2 = try await SemanticStage(provider: m2).group(inputs)
        XCTAssertEqual(underM1.edges.count, 1)
        XCTAssertTrue(underM2.edges.isEmpty, "old-model embeddings would misgroup under a new model")
    }

    func testSingleSurvivorFormsNoEdge() async throws {
        let provider = FixedProvider(modelID: "m1", dimension: 4, table: ["solo.txt": [1, 0, 0, 0]])
        let out = try await SemanticStage(provider: provider).group([input(1, "solo.txt")])
        XCTAssertTrue(out.edges.isEmpty)
    }

    /// Coordinator wiring (T7.2): deep scan is OPT-IN. The SAME two textually-distinct files yield no
    /// group on a normal scan, but one `.semantic` group when `config.deepScan` is on — proving the
    /// tier runs only on demand and folds into the single clustering pass. A controlled provider makes
    /// every embedded survivor near-parallel, so the assertion is deterministic without a real model.
    func testDeepScanIsOptInAndFoldsSemanticGroups() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Distinct, non-near-dup contents (Jaccard 0, not identical) → no exact/near edge on a fast scan.
        try Data("the quick brown fox jumps over".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("lorem ipsum dolor sit amet consectetur".utf8).write(to: dir.appendingPathComponent("b.txt"))

        struct AllParallel: EmbeddingProvider {
            let modelID = "test-parallel"
            let dimension = 4
            func embed(text _: String) async throws -> [Float] {
                [1, 0, 0, 0]
            } // shared axis → near-parallel
        }
        let coordinator = ScanCoordinator(embedding: AllParallel())

        func groups(deepScan: Bool) async throws -> [(DuplicateGroup, [FileRecord])] {
            let config = DetectionConfig(deepScan: deepScan)
            var found: [(DuplicateGroup, [FileRecord])] = []
            for try await e in coordinator.scan(ScanRequest(roots: [dir], scopes: [.document], config: config)) {
                if case let .groupFound(g, m) = e { found.append((g, m)) }
            }
            return found
        }

        let normal = try await groups(deepScan: false)
        XCTAssertTrue(normal.isEmpty, "distinct files must not group on a normal (no-embed) scan")

        let deep = try await groups(deepScan: true)
        XCTAssertEqual(deep.count, 1, "deep scan must surface the semantic group")
        XCTAssertEqual(deep.first?.0.matchType, .semantic)
        XCTAssertEqual(deep.first?.0.explanation, "Semantically similar content")
        XCTAssertEqual(Set(deep.first?.1.map(\.displayName) ?? []), ["a.txt", "b.txt"])
    }

    /// Deep scan honors golden rule 5: it never embeds a file an earlier stage already resolved. Two
    /// exact copies + one distinct doc ⇒ the exact pair contributes ONE representative to embedding,
    /// so the controlled "everything-parallel" provider is asked to embed exactly 2 survivors, not 3.
    func testDeepScanEmbedsOnlySurvivorsNotResolvedFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("identical contract text here".utf8).write(to: dir.appendingPathComponent("orig.txt"))
        try Data("identical contract text here".utf8).write(to: dir.appendingPathComponent("copy.txt")) // exact dup
        try Data("a totally separate unrelated memo".utf8).write(to: dir.appendingPathComponent("memo.txt"))

        let counter = EmbedCounter()
        struct Counting: EmbeddingProvider {
            let modelID = "count"
            let dimension = 4
            let counter: EmbedCounter
            func embed(text _: String) async throws -> [Float] {
                counter.bump(); return [1, 0, 0, 0]
            }
        }
        let coordinator = ScanCoordinator(embedding: Counting(counter: counter))
        for try await _ in coordinator.scan(
            ScanRequest(roots: [dir], scopes: [.document], config: DetectionConfig(deepScan: true))
        ) {}

        XCTAssertEqual(counter.count, 2, "exact dup must collapse to one survivor before embedding (golden rule 5)")
    }
}

private final class EmbedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() {
        lock.lock(); n += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return n
    }
}

private final class CompareLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(Int, Int)] = []
    func add(_ a: Int, _ b: Int) {
        lock.lock(); seen.append((a, b)); lock.unlock()
    }

    var pairs: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}
