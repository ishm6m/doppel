import DoppelKit
import XCTest
@testable import DetectionEngine

final class ScanCoordinatorTests: XCTestCase {
    private func makeTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func drain(_ stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> [ScanEvent] {
        var events: [ScanEvent] = []
        for try await e in stream {
            events.append(e)
        }
        return events
    }

    /// Full Stage0→Stage1 run emits the expected event order and the correct exact group.
    func testFullRunEmitsExpectedSequenceAndGroup() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("the same contract", "a.txt", in: dir)
        try write("the same contract", "copy.txt", in: dir)
        let req = ScanRequest(roots: [dir], scopes: [.document])

        let events = try await drain(ScanCoordinator().scan(req))

        guard case let .discovered(total) = events.first else { return XCTFail("first event must be .discovered") }
        XCTAssertEqual(total, 2)
        XCTAssertTrue(events.contains { if case .progress(.hashing, _, _) = $0 { return true }; return false })

        let groups = events.compactMap { e -> (DuplicateGroup, [FileRecord])? in
            if case let .groupFound(g, m) = e { return (g, m) }; return nil
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.0.matchType, .exact)
        XCTAssertEqual(groups.first?.0.explanation, "Identical file contents")
        XCTAssertEqual(Set(groups.first?.1.map(\.displayName) ?? []), ["a.txt", "copy.txt"])

        guard case let .finished(summary) = events.last else { return XCTFail("last event must be .finished") }
        XCTAssertEqual(summary.filesDiscovered, 2)
        XCTAssertEqual(summary.groupsFound, 1)
    }

    /// Cancel before clustering: groups are emitted ONLY after the clustering pass (event-timeline
    /// option i), so cancelling mid-hash yields .cancelled(partial:) with ZERO groups, no .finished,
    /// and a summary that agrees — no crash, no torn state, no partial/retracted group.
    func testCancelBeforeClusteringEmitsNoGroups() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        // Two distinct size buckets, each a dup pair → coordinator processes them serially.
        try write("alpha one", "a1.txt", in: dir)
        try write("alpha one", "a2.txt", in: dir)
        try write("beta two two two", "b1.txt", in: dir)
        try write("beta two two two", "b2.txt", in: dir)
        let req = ScanRequest(roots: [dir], scopes: [.document])

        final class Box: @unchecked Sendable { var task: Task<Void, Never>? }
        let box = Box()
        // First hash cancels the producer; the top-of-loop check before the next bucket emits
        // .cancelled — well before the clustering pass that would build any group.
        let coordinator = ScanCoordinator(hash: { url in
            box.task?.cancel()
            return try Hasher256.hash(fileAt: url)
        })

        let (stream, cont) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let producer = Task { await coordinator.run(req, cont) }
        box.task = producer // set before the actor-hop into run() can reach the hash closure
        let events = try await drain(stream)

        XCTAssertTrue(events.contains { if case .cancelled = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .finished = $0 { return true }; return false })
        guard case let .cancelled(partial) = events.last else { return XCTFail("must end on .cancelled") }
        let emittedGroups = events.count(where: { if case .groupFound = $0 { return true }; return false })
        XCTAssertEqual(emittedGroups, 0, "no group is emitted before the clustering pass")
        XCTAssertEqual(partial.groupsFound, 0)
        XCTAssertEqual(partial.bytesReclaimable, 0)
    }

    /// Event-timeline contract (option i): no `.groupFound` is emitted before `.progress(.clustering)`,
    /// while progress events still stream throughout for liveness.
    func testGroupsEmittedOnlyAfterClusteringPhase() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("the same contract here", "a.txt", in: dir)
        try write("the same contract here", "b.txt", in: dir)

        let events = try await drain(ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])))

        let clusterIdx = events.firstIndex { if case .progress(.clustering, _, _) = $0 { return true }; return false }
        let firstGroupIdx = events.firstIndex { if case .groupFound = $0 { return true }; return false }
        XCTAssertNotNil(clusterIdx, "clustering phase must be announced")
        guard let clusterIdx, let firstGroupIdx else { return XCTFail("expected a group after clustering") }
        XCTAssertGreaterThan(firstGroupIdx, clusterIdx, "no group may precede the clustering phase")
        XCTAssertTrue(events.contains { if case .progress(.hashing, _, _) = $0 { return true }; return false })
    }

    /// THE bug-death test (integration): A≡B byte-identical AND C is a near-text copy of them. The old
    /// per-stage emission put a file in two groups; now they collapse to ONE `.exact` cluster {A,B,C}
    /// with one keeper, one explanation, and bytesReclaimable counted once (no double-count).
    func testExactAndNearOverlapCollapseToOneExactGroup() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        var words = (0 ..< 200).map { "w\($0)" }
        let base = words.joined(separator: " ")
        try write(base, "a.txt", in: dir)
        try write(base, "b.txt", in: dir) // byte-identical to a → exact edge
        words[100] = "dated2025" // one word changed, different byte size → near-text to a/b, not exact
        try write(words.joined(separator: " "), "c.txt", in: dir)

        let events = try await drain(ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])))

        let groups = events.compactMap { e -> (DuplicateGroup, [FileRecord])? in
            if case let .groupFound(g, m) = e { return (g, m) }; return nil
        }
        XCTAssertEqual(groups.count, 1, "overlapping exact+near matches must form exactly one group")
        let (g, members) = groups[0]
        XCTAssertEqual(g.matchType, .exact, "strongest type wins")
        XCTAssertEqual(g.explanation, "Identical file contents")
        XCTAssertEqual(Set(members.map(\.displayName)), ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(members.count(where: { $0.id == g.keeperFileID }), 1, "exactly one keeper")

        guard case let .finished(summary) = events.last else { return XCTFail("must finish") }
        XCTAssertEqual(summary.groupsFound, 1)
        let firstSize = members.min { $0.id < $1.id }?.sizeBytes ?? 0
        XCTAssertEqual(summary.bytesReclaimable, 2 * firstSize, "reclaim counted once over the final cluster")
    }

    /// Stage 2 wiring: a contract + a date-changed copy (not byte-identical) survive Stage 1 and
    /// surface as one `.nearText` group, with a `.progress(.fingerprinting)` event emitted.
    func testStage2EmitsNearTextGroupAndFingerprintingProgress() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        var words = (0 ..< 200).map { "w\($0)" }
        try write(words.joined(separator: " "), "contract.txt", in: dir)
        words[100] = "dated2025"
        try write(words.joined(separator: " "), "contract-2025.txt", in: dir)

        let events = try await drain(ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])))

        XCTAssertTrue(events.contains { if case .progress(.fingerprinting, _, _) = $0 { return true }; return false })
        let near = events.compactMap { e -> DuplicateGroup? in
            if case let .groupFound(g, _) = e, g.matchType == .nearText { return g }; return nil
        }
        XCTAssertEqual(near.count, 1)
        XCTAssertGreaterThanOrEqual(near.first?.confidence ?? 0, 0.85)
        guard case let .finished(summary) = events.last else { return XCTFail("must finish") }
        XCTAssertEqual(summary.groupsFound, 1)
    }

    // Incremental: files whose signature is already known are never re-hashed.
    func testIncrementalRunSkipsUnchangedFiles() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("dup body", "x.txt", in: dir)
        try write("dup body", "y.txt", in: dir)

        let known = Set(FileEnumerator(scopes: [.document]).enumerate(roots: [dir]).files.map(\.record.signature))
        XCTAssertEqual(known.count, 2)

        let hashed = HashRecorder()
        let coordinator = ScanCoordinator(hash: { url in hashed.add(url); return try Hasher256.hash(fileAt: url) })
        let req = ScanRequest(roots: [dir], scopes: [.document], knownSignatures: known)

        let (stream, cont) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let producer = Task { await coordinator.run(req, cont) }
        _ = producer
        let events = try await drain(stream)

        XCTAssertTrue(hashed.urls.isEmpty, "unchanged files must not be re-hashed")
        guard case let .discovered(total) = events.first else { return XCTFail("first event must be .discovered") }
        XCTAssertEqual(total, 0)
        guard case let .finished(summary) = events.last else { return XCTFail("last event must be .finished") }
        XCTAssertEqual(summary.groupsFound, 0)
    }
}

private final class HashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    func add(_ url: URL) {
        lock.lock(); seen.append(url); lock.unlock()
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }; return seen
    }
}
