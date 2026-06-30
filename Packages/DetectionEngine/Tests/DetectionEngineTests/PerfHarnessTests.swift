import DoppelKit
import XCTest
@testable import DetectionEngine

/// Performance harness (PERFORMANCE.md §4). Runs the full cascade over a generated corpus, records
/// wall-clock + throughput to a CSV for trend tracking, and asserts a generous ceiling so a gross
/// regression or hang reddens the suite.
///
/// ponytail: this runs a SMALL corpus in a DEBUG build, so it is a *regression smoke test*, not the
/// real budget gate. The PERFORMANCE.md budgets (50k docs < 5 min, < 1.5 GB peak) are release-mode on
/// Apple Silicon and belong to a target-hardware / nightly run — they can't run headless here. Peak
/// memory isn't asserted (XCTMemoryMetric is flaky in CI); add it to the nightly job.
final class PerfHarnessTests: XCTestCase {
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Minimal deterministic corpus inline (CorpusGen is an executable target, not importable): N docs,
    /// ~20% exact copies + ~20% one-word-changed near-dupes of earlier docs.
    private func makeCorpus(count: Int, wordsPerDoc: Int, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vocab = (0 ..< 64).map { "word\($0)" }
        var rng = Rng(state: 42)
        var uniques: [String] = []
        for i in 0 ..< count {
            let roll = Double(rng.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
            let text: String
            if !uniques.isEmpty, roll < 0.2 {
                text = uniques[Int(rng.next() % UInt64(uniques.count))]
            } else if !uniques.isEmpty, roll < 0.4 {
                var words = uniques[Int(rng.next() % UInt64(uniques.count))].split(separator: " ").map(String.init)
                words[Int(rng.next() % UInt64(words.count))] = "changed\(i)"
                text = words.joined(separator: " ")
            } else {
                text = (0 ..< wordsPerDoc).map { _ in vocab[Int(rng.next() % UInt64(vocab.count))] }.joined(separator: " ")
                uniques.append(text)
            }
            try Data(text.utf8).write(to: dir.appendingPathComponent(String(format: "doc%05d.txt", i)))
        }
    }

    func testCascadeThroughputOnSmallCorpus() async throws {
        let count = 600
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCorpus(count: count, wordsPerDoc: 200, in: dir)

        let clock = ContinuousClock()
        var groups = 0
        let elapsed = try await clock.measure {
            for try await event in ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])) {
                if case .groupFound = event { groups += 1 }
            }
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let filesPerSec = Double(count) / max(seconds, 0.0001)
        record(count: count, seconds: seconds, filesPerSec: filesPerSec, groups: groups)

        XCTAssertGreaterThan(groups, 0, "the corpus has planted duplicates; the cascade must find some")
        // Generous ceiling for a debug build on shared CI — catches hangs / order-of-magnitude
        // regressions, not the real release budget (which is a nightly target-hardware run).
        XCTAssertLessThan(seconds, 60, "600-doc debug scan took \(seconds)s (\(Int(filesPerSec)) files/sec)")
    }

    /// Append one row to a CSV in the temp dir for trend tracking (PERFORMANCE.md §4).
    private func record(count: Int, seconds: Double, filesPerSec: Double, groups: Int) {
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent("doppel-perf.csv")
        let stamp = ISO8601DateFormatter().string(from: .now)
        let line = "\(stamp),\(count),\(String(format: "%.3f", seconds)),\(Int(filesPerSec)),\(groups)\n"
        if let handle = try? FileHandle(forWritingTo: csv) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            let header = "timestamp,files,seconds,files_per_sec,groups\n"
            try? Data((header + line).utf8).write(to: csv)
        }
        print("PerfHarness: \(count) files in \(String(format: "%.2f", seconds))s "
            + "= \(Int(filesPerSec)) files/sec, \(groups) groups → \(csv.path)")
    }
}
