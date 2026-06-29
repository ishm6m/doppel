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

    /// A near-dup pair: 120 unique words, the copy changes one word (the "date"). True Jaccard ≈ 0.92,
    /// comfortably above the 0.85 gate. Disjoint `prefix` keeps unrelated pairs from cross-matching.
    private func nearDupPair(_ prefix: String, _ idA: Int64, _ idB: Int64) -> [NearTextStage.Input] {
        var words = (0 ..< 120).map { "\(prefix)\($0)" }
        let a = words.joined(separator: " ")
        words[60] = "\(prefix)changed"
        let b = words.joined(separator: " ")
        return [
            .init(record: rec(idA, "\(prefix)-a.txt"), text: a),
            .init(record: rec(idB, "\(prefix)-b.txt"), text: b)
        ]
    }

    private func loner(_ id: Int64, _ prefix: String) -> NearTextStage.Input {
        .init(record: rec(id, "\(prefix).txt"), text: (0 ..< 120).map { "\(prefix)\($0)" }.joined(separator: " "))
    }

    // MARK: - DoD cases

    func testContractAndDateChangedCopyFormOneNearTextGroup() {
        let inputs = nearDupPair("clause", 1, 2)
        let groups = NearTextStage().group(inputs)

        XCTAssertEqual(groups.count, 1)
        let g = groups[0].group
        XCTAssertEqual(g.matchType, .nearText)
        XCTAssertGreaterThanOrEqual(g.confidence, 0.85) // ≈ 0.9 for a single-word change
        XCTAssertTrue(g.explanation.contains("changed region"), "explanation must note the change")
        XCTAssertEqual(Set(groups[0].members.map(\.displayName)), ["clause-a.txt", "clause-b.txt"])
    }

    func testUnrelatedDocsFormNoGroup() {
        let inputs = [loner(1, "alpha"), loner(2, "beta")]
        XCTAssertTrue(NearTextStage().group(inputs).isEmpty)
    }

    /// Precision target (PRD ≥ 0.95): 8 constructed near-dup pairs + 2 unrelated loners.
    /// Expect exactly 8 groups, each the correct pair, zero false positives ⇒ precision 1.0.
    func testPrecisionOnConstructedNearDupSet() {
        var inputs: [NearTextStage.Input] = []
        for i in 0 ..< 8 {
            inputs += nearDupPair("doc\(i)_", Int64(i * 2 + 1), Int64(i * 2 + 2))
        }
        inputs += [loner(100, "stray-a"), loner(101, "stray-b")]

        let groups = NearTextStage().group(inputs)
        XCTAssertEqual(groups.count, 8, "every near-dup pair grouped, nothing else")
        for g in groups {
            XCTAssertEqual(g.group.matchType, .nearText)
            XCTAssertEqual(g.members.count, 2)
            let names = g.members.map(\.displayName).sorted()
            XCTAssertEqual(names[0].dropLast(6), names[1].dropLast(6)) // same "docN_" prefix
        }
        let grouped = Set(groups.flatMap(\.group.memberFileIDs))
        XCTAssertFalse(grouped.contains(100) || grouped.contains(101), "no false-positive group on loners")
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
