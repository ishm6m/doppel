import XCTest
import DoppelKit
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
        try text.data(using: .utf8)!.write(to: url) // SAFETY: ASCII literal always UTF-8 encodable (test-only)
        return url
    }

    private func drain(_ stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> [ScanEvent] {
        var events: [ScanEvent] = []
        for try await e in stream { events.append(e) }
        return events
    }

    // Full Stage0→Stage1 run emits the expected event order and the correct exact group.
    func testFullRunEmitsExpectedSequenceAndGroup() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("the same contract", "a.txt", in: dir)
        try write("the same contract", "copy.txt", in: dir)
        let req = ScanRequest(roots: [dir], scopes: [.document])

        let events = try await drain(ScanCoordinator().scan(req))

        guard case .discovered(let total) = events.first else { return XCTFail("first event must be .discovered") }
        XCTAssertEqual(total, 2)
        XCTAssertTrue(events.contains { if case .progress(.hashing, _, _) = $0 { return true }; return false })

        let groups = events.compactMap { e -> (DuplicateGroup, [FileRecord])? in
            if case .groupFound(let g, let m) = e { return (g, m) }; return nil
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.0.matchType, .exact)
        XCTAssertEqual(groups.first?.0.explanation, "Identical file contents")
        XCTAssertEqual(Set(groups.first?.1.map(\.displayName) ?? []), ["a.txt", "copy.txt"])

        guard case .finished(let summary) = events.last else { return XCTFail("last event must be .finished") }
        XCTAssertEqual(summary.filesDiscovered, 2)
        XCTAssertEqual(summary.groupsFound, 1)
    }

    // Cancel mid-run: cancelling the producer while hashing the first bucket yields one group, then
    // .cancelled(partial:) with a consistent summary and no .finished — no crash, no torn state.
    func testCancelMidRunEmitsCancelledWithConsistentSummary() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        // Two distinct size buckets, each a dup pair → coordinator processes them serially.
        try write("alpha one", "a1.txt", in: dir)
        try write("alpha one", "a2.txt", in: dir)
        try write("beta two two two", "b1.txt", in: dir)
        try write("beta two two two", "b2.txt", in: dir)
        let req = ScanRequest(roots: [dir], scopes: [.document])

        final class Box: @unchecked Sendable { var task: Task<Void, Never>? }
        let box = Box()
        // First hash cancels the producer; whichever bucket runs first completes (group emitted),
        // then the top-of-loop check before the next bucket emits .cancelled.
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
        guard case .cancelled(let partial) = events.last else { return XCTFail("must end on .cancelled") }
        let emittedGroups = events.filter { if case .groupFound = $0 { return true }; return false }.count
        XCTAssertEqual(partial.groupsFound, emittedGroups) // summary agrees with what was emitted
        XCTAssertLessThan(partial.groupsFound, 2)          // cancelled before both buckets finished
    }

    // Incremental: files whose signature is already known are never re-hashed.
    func testIncrementalRunSkipsUnchangedFiles() async throws {
        let dir = try makeTree(); defer { try? FileManager.default.removeItem(at: dir) }
        try write("dup body", "x.txt", in: dir)
        try write("dup body", "y.txt", in: dir)

        let known = Set(FileEnumerator(scopes: [.document]).enumerate(roots: [dir]).files.map { $0.record.signature })
        XCTAssertEqual(known.count, 2)

        let hashed = HashRecorder()
        let coordinator = ScanCoordinator(hash: { url in hashed.add(url); return try Hasher256.hash(fileAt: url) })
        let req = ScanRequest(roots: [dir], scopes: [.document], knownSignatures: known)

        let (stream, cont) = AsyncThrowingStream<ScanEvent, Error>.makeStream()
        let producer = Task { await coordinator.run(req, cont) }
        _ = producer
        let events = try await drain(stream)

        XCTAssertTrue(hashed.urls.isEmpty, "unchanged files must not be re-hashed")
        guard case .discovered(let total) = events.first else { return XCTFail("first event must be .discovered") }
        XCTAssertEqual(total, 0)
        guard case .finished(let summary) = events.last else { return XCTFail("last event must be .finished") }
        XCTAssertEqual(summary.groupsFound, 0)
    }
}

private final class HashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    func add(_ url: URL) { lock.lock(); seen.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return seen }
}
