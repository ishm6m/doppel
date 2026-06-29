import DoppelKit
import XCTest
@testable import DetectionEngine

final class NearTextTests: XCTestCase {
    // MARK: - Fixtures

    private func rec(_ id: Int64, _ name: String) -> FileRecord {
        FileRecord(
            id: id, bookmarkID: 0, relativePath: name, displayName: name,
            sizeBytes: 100, mtime: Date(timeIntervalSince1970: TimeInterval(id)), typeScope: .document
        )
    }

    /// A near-dup pair: 200 unique words, the copy changes one word (the "date"). True Jaccard ≈ 0.95.
    /// 200 (not ~120) keeps the 128-perm MinHash *estimate* reliably above 0.85 regardless of which
    /// token changes — a single change in a shorter doc can dip the estimate under the gate.
    /// Disjoint `prefix` keeps unrelated pairs from cross-matching.
    private func nearDupPair(_ prefix: String, _ idA: Int64, _ idB: Int64) -> [NearTextStage.Input] {
        var words = (0 ..< 200).map { "\(prefix)\($0)" }
        let a = words.joined(separator: " ")
        words[100] = "\(prefix)changed"
        let b = words.joined(separator: " ")
        return [
            .init(record: rec(idA, "\(prefix)-a.txt"), text: a),
            .init(record: rec(idB, "\(prefix)-b.txt"), text: b)
        ]
    }

    private func loner(_ id: Int64, _ prefix: String) -> NearTextStage.Input {
        .init(record: rec(id, "\(prefix).txt"), text: (0 ..< 200).map { "\(prefix)\($0)" }.joined(separator: " "))
    }

    // MARK: - DoD cases

    /// Names of files an edge connects, looked up in the stage's emitted records.
    private func edgeNames(_ edge: StageEdge, _ records: [FileRecord]) -> Set<String> {
        Set(records.filter { [edge.pair.a, edge.pair.b].contains($0.id) }.map(\.displayName))
    }

    func testContractAndDateChangedCopyFormOneNearTextEdge() {
        let inputs = nearDupPair("clause", 1, 2)
        let out = NearTextStage().group(inputs)

        XCTAssertEqual(out.edges.count, 1)
        let e = out.edges[0]
        XCTAssertEqual(e.type, .nearText)
        XCTAssertGreaterThanOrEqual(e.score, 0.85) // ≈ 0.9 for a single-word change
        XCTAssertTrue(e.reason.contains("changed region"), "reason must note the change")
        XCTAssertEqual(edgeNames(e, out.records), ["clause-a.txt", "clause-b.txt"])
    }

    func testUnrelatedDocsFormNoEdge() {
        let inputs = [loner(1, "alpha"), loner(2, "beta")]
        XCTAssertTrue(NearTextStage().group(inputs).edges.isEmpty)
    }

    /// Precision target (PRD ≥ 0.95): 8 constructed near-dup pairs + 2 unrelated loners.
    /// Expect exactly 8 edges, each the correct same-prefix pair, zero false positives ⇒ precision 1.0.
    func testPrecisionOnConstructedNearDupSet() {
        var inputs: [NearTextStage.Input] = []
        for i in 0 ..< 8 {
            inputs += nearDupPair("doc\(i)_", Int64(i * 2 + 1), Int64(i * 2 + 2))
        }
        inputs += [loner(100, "stray-a"), loner(101, "stray-b")]

        let out = NearTextStage().group(inputs)
        XCTAssertEqual(out.edges.count, 8, "every near-dup pair found, nothing else")
        for e in out.edges {
            XCTAssertEqual(e.type, .nearText)
            let names = edgeNames(e, out.records).sorted()
            XCTAssertEqual(names.count, 2)
            XCTAssertEqual(names[0].dropLast(6), names[1].dropLast(6)) // same "docN_" prefix
        }
        let touched = Set(out.edges.flatMap { [$0.pair.a, $0.pair.b] })
        XCTAssertFalse(touched.contains(100) || touched.contains(101), "no false-positive edge on loners")
    }

    /// LSH pruning probe (mirrors T2.2's "lone file is never hashed"): a doc sharing no band bucket
    /// with any other is NEVER handed to the Jaccard comparator.
    func testLSHPrunesDocSharingNoBucket() {
        let inputs = nearDupPair("near", 1, 2) + [loner(3, "isolated")]
        let log = CompareLog()
        let stage = NearTextStage(config: .init(), onCompare: { a, b in log.add(a, b) })

        _ = stage.group(inputs)

        // index 2 is the isolated loner (disjoint vocabulary) — it must never be compared.
        let touched = Set(log.pairs.flatMap { [$0.0, $0.1] })
        XCTAssertFalse(touched.contains(2), "isolated doc must be pruned by LSH, never Jaccard-compared")
        XCTAssertTrue(touched.contains(0) && touched.contains(1), "the real near-dup pair was compared")
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
