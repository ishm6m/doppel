import DoppelKit
import XCTest
@testable import DetectionEngine

/// Pure final-clustering tests over synthetic edges — deterministic, independent of MinHash variance.
final class ClusteringTests: XCTestCase {
    private func rec(_ id: Int64) -> FileRecord {
        FileRecord(
            id: id, bookmarkID: 0, relativePath: "\(id).txt", displayName: "\(id).txt",
            sizeBytes: 100, mtime: Date(timeIntervalSince1970: TimeInterval(id)), typeScope: .document
        )
    }

    private func records(_ ids: Int64...) -> [Int64: FileRecord] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, rec($0)) })
    }

    /// THE bug-death proof: A≡B (exact) AND B~C (near-text) collapse to ONE `.exact` cluster {A,B,C}.
    func testExactAndNearEdgesCollapseToOneExactCluster() {
        let edges = [
            StageEdge(pair: Pair(1, 2), type: .exact, score: 1.0, reason: "Identical file contents"),
            StageEdge(pair: Pair(2, 3), type: .nearText, score: 0.9, reason: "Near-identical text — 1 changed region")
        ]
        let groups = FinalClustering.cluster(edges: edges, records: records(1, 2, 3))

        XCTAssertEqual(groups.count, 1)
        let g = groups[0].group
        XCTAssertEqual(g.matchType, .exact)
        XCTAssertEqual(g.confidence, 1.0)
        XCTAssertEqual(g.explanation, "Identical file contents")
        XCTAssertEqual(Set(g.memberFileIDs), [1, 2, 3])
        XCTAssertTrue(g.memberFileIDs.contains(g.keeperFileID))
    }

    /// Regression guard: every file lands in exactly one group, never two.
    func testEachFileAppearsInExactlyOneGroup() {
        let edges = [
            StageEdge(pair: Pair(1, 2), type: .exact, score: 1.0, reason: "Identical file contents"),
            StageEdge(pair: Pair(2, 3), type: .nearText, score: 0.9, reason: "near"),
            StageEdge(pair: Pair(4, 5), type: .nearText, score: 0.88, reason: "near")
        ]
        let groups = FinalClustering.cluster(edges: edges, records: records(1, 2, 3, 4, 5))
        let all = groups.flatMap(\.group.memberFileIDs)
        XCTAssertEqual(all.count, Set(all).count, "no file may appear in two groups")
        XCTAssertEqual(Set(all), [1, 2, 3, 4, 5])
    }

    func testPureExactClusterStaysExact() {
        let edges = [StageEdge(pair: Pair(1, 2), type: .exact, score: 1.0, reason: "Identical file contents")]
        let groups = FinalClustering.cluster(edges: edges, records: records(1, 2))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].group.matchType, .exact)
        XCTAssertEqual(groups[0].group.confidence, 1.0)
    }

    func testPureNearTextClusterKeepsTypeConfidenceReason() {
        let edges = [StageEdge(pair: Pair(1, 2), type: .nearText, score: 0.9, reason: "Near-identical text — 2 changed regions")]
        let groups = FinalClustering.cluster(edges: edges, records: records(1, 2))
        XCTAssertEqual(groups.count, 1)
        let g = groups[0].group
        XCTAssertEqual(g.matchType, .nearText)
        XCTAssertEqual(g.confidence, 0.9)
        XCTAssertEqual(g.explanation, "Near-identical text — 2 changed regions")
    }

    /// Confidence is the WEAKEST strongest-type edge; weaker non-strongest edges don't drag it down.
    func testConfidenceIsWeakestStrongestTypeEdge() {
        let edges = [
            StageEdge(pair: Pair(1, 2), type: .nearText, score: 0.95, reason: "a"),
            StageEdge(pair: Pair(2, 3), type: .nearText, score: 0.86, reason: "b")
        ]
        let groups = FinalClustering.cluster(edges: edges, records: records(1, 2, 3))
        XCTAssertEqual(groups[0].group.confidence, 0.86, accuracy: 1e-9)
    }

    func testNoEdgesYieldsNoGroups() {
        XCTAssertTrue(FinalClustering.cluster(edges: [], records: [:]).isEmpty)
    }
}
