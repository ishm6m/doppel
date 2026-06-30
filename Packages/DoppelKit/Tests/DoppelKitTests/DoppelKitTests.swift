import XCTest
@testable import DoppelKit

final class DoppelKitTests: XCTestCase {
    func testCosineIdenticalIsOne() {
        let v: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(Similarity.cosine(v, v), 1.0, accuracy: 1e-9)
    }

    func testCosineOrthogonalIsZero() {
        XCTAssertEqual(Similarity.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-9)
    }

    func testKeeperPrefersNewest() {
        let old = FileRecord(
            id: 1,
            bookmarkID: 1,
            relativePath: "a.txt",
            displayName: "a.txt",
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1),
            typeScope: .document
        )
        let new = FileRecord(
            id: 2,
            bookmarkID: 1,
            relativePath: "b.txt",
            displayName: "b.txt",
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 2),
            typeScope: .document
        )
        XCTAssertEqual(KeeperHeuristic.suggestKeeper(from: [old, new])?.id, 2)
    }

    func testPairIsOrderIndependent() {
        XCTAssertEqual(Pair(2, 5), Pair(5, 2))
    }

    func testGroupInvariantsHold() {
        let g = DuplicateGroup(
            id: 1,
            matchType: .exact,
            confidence: 1.0,
            explanation: "Identical file contents",
            keeperFileID: 1,
            memberFileIDs: [1, 2]
        )
        XCTAssertFalse(g.explanation.isEmpty)
        XCTAssertTrue((0 ... 1).contains(g.confidence))
    }
}

extension DoppelKitTests {
    /// F8 diff: a contract pair identical except the date highlights ONLY the date on each side,
    /// everything else stays unchanged. This is the "trust builder" demo as a unit test.
    func testTextDiffHighlightsOnlyTheChangedWord() {
        let a = "this agreement dated 2024 between alice and bob"
        let b = "this agreement dated 2025 between alice and bob"
        let diff = TextDiff.compute(a, b)
        XCTAssertFalse(diff.isIdentical)
        XCTAssertEqual(diff.left.filter(\.changed).map { String($0.text) }, ["2024"])
        XCTAssertEqual(diff.right.filter(\.changed).map { String($0.text) }, ["2025"])
        // Unchanged words are shared and not flagged on either side.
        XCTAssertEqual(
            diff.left.filter { !$0.changed }.map { String($0.text) },
            ["this", "agreement", "dated", "between", "alice", "and", "bob"]
        )
    }

    func testTextDiffIdenticalTextHasNoChanges() {
        let diff = TextDiff.compute("same body here", "same body here")
        XCTAssertTrue(diff.isIdentical)
    }
}
