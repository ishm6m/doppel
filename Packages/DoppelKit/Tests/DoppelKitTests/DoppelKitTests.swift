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
        let old = FileRecord(id: 1, bookmarkID: 1, relativePath: "a.txt", displayName: "a.txt",
                             sizeBytes: 100, mtime: Date(timeIntervalSince1970: 1), typeScope: .document)
        let new = FileRecord(id: 2, bookmarkID: 1, relativePath: "b.txt", displayName: "b.txt",
                             sizeBytes: 100, mtime: Date(timeIntervalSince1970: 2), typeScope: .document)
        XCTAssertEqual(KeeperHeuristic.suggestKeeper(from: [old, new])?.id, 2)
    }

    func testPairIsOrderIndependent() {
        XCTAssertEqual(Pair(2, 5), Pair(5, 2))
    }

    func testGroupInvariantsHold() {
        let g = DuplicateGroup(id: 1, matchType: .exact, confidence: 1.0,
                               explanation: "Identical file contents", keeperFileID: 1, memberFileIDs: [1, 2])
        XCTAssertFalse(g.explanation.isEmpty)
        XCTAssertTrue((0...1).contains(g.confidence))
    }
}
