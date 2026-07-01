import DoppelKit
import XCTest
@testable import DetectionEngine

/// Performance harness (PERFORMANCE.md §4). Runs the full cascade over a generated corpus, records
/// wall-clock + throughput + peak memory to a CSV for trend tracking, and asserts a ceiling so a
/// gross regression or hang reddens the suite.
///
/// Two tiers:
///  - `testCascadeThroughputOnSmallCorpus` — a fast DEBUG regression smoke test that runs on every CI
///    gate. Generous ceiling: catches hangs / order-of-magnitude regressions, not the real budget.
///  - `testFullScanBudget` — the PERFORMANCE.md §1 headline budget (50k docs < 5 min, < 1.5 GB peak).
///    Off by default (heavy: writes tens of thousands of files); opt in with `DOPPEL_PERF_BUDGET=1`,
///    and run `-c release` on Apple Silicon for a real number. Tune size via `DOPPEL_PERF_COUNT` /
///    `DOPPEL_PERF_WORDS`.
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

    /// Process peak resident memory. On macOS `ru_maxrss` is in bytes and is a high-water mark for the
    /// whole process lifetime, so reading it after the scan yields the peak (conservative: includes test
    /// harness overhead). Real, deterministic, and not flaky like XCTMemoryMetric.
    private func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)
    }

    private struct Result {
        let seconds: Double
        let filesPerSec: Double
        let groups: Int
        let peakBytes: Int64
    }

    /// Runs the full cascade over `dir`, recording to the CSV and returning the measured metrics.
    private func runScan(count: Int, in dir: URL) async throws -> Result {
        let clock = ContinuousClock()
        var groups = 0
        let elapsed = try await clock.measure {
            for try await event in ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])) {
                if case .groupFound = event { groups += 1 }
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let peakBytes = peakResidentBytes()
        let filesPerSec = Double(count) / max(seconds, 0.0001)
        record(count: count, seconds: seconds, filesPerSec: filesPerSec, groups: groups, peakBytes: peakBytes)
        return Result(seconds: seconds, filesPerSec: filesPerSec, groups: groups, peakBytes: peakBytes)
    }

    func testCascadeThroughputOnSmallCorpus() async throws {
        let count = 600
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCorpus(count: count, wordsPerDoc: 200, in: dir)

        let r = try await runScan(count: count, in: dir)

        XCTAssertGreaterThan(r.groups, 0, "the corpus has planted duplicates; the cascade must find some")
        // Generous ceiling for a debug build on shared CI — catches hangs / order-of-magnitude
        // regressions, not the real release budget (which is a nightly target-hardware run).
        XCTAssertLessThan(r.seconds, 60, "600-doc debug scan took \(r.seconds)s (\(Int(r.filesPerSec)) files/sec)")
    }

    /// PERFORMANCE.md §1 headline budget. Opt-in (`DOPPEL_PERF_BUDGET=1`) and meant for `-c release` on
    /// Apple Silicon — a debug build will miss the throughput budget. Writes `DOPPEL_PERF_COUNT` files
    /// (default 50k) and asserts full-scan wall-clock < 5 min and peak memory < 1.5 GB.
    func testFullScanBudget() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["DOPPEL_PERF_BUDGET"] == "1",
            "Set DOPPEL_PERF_BUDGET=1 (and run -c release on Apple Silicon) for the real budget."
        )
        let count = env["DOPPEL_PERF_COUNT"].flatMap { Int($0) } ?? 50000
        // ponytail: 200 words ≈ ~1.5 KB/doc keeps disk sane (~75 MB @ 50k) vs the doc's 200 KB avg;
        // throughput/memory scale with file COUNT here, not byte size. Bump DOPPEL_PERF_WORDS for a
        // byte-faithful run when disk allows.
        let words = env["DOPPEL_PERF_WORDS"].flatMap { Int($0) } ?? 200

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeCorpus(count: count, wordsPerDoc: words, in: dir)

        let r = try await runScan(count: count, in: dir)
        let peakGB = Double(r.peakBytes) / 1_073_741_824

        XCTAssertGreaterThan(r.groups, 0, "planted duplicates must be found")
        XCTAssertLessThan(
            r.seconds,
            300,
            "\(count)-doc full scan took \(String(format: "%.1f", r.seconds))s "
                + "(\(Int(r.filesPerSec)) files/sec); budget < 300s"
        )
        XCTAssertLessThan(
            peakGB,
            1.5,
            "peak memory \(String(format: "%.2f", peakGB)) GB exceeds 1.5 GB budget"
        )
    }

    /// Append one row to a CSV in the temp dir for trend tracking (PERFORMANCE.md §4).
    private func record(count: Int, seconds: Double, filesPerSec: Double, groups: Int, peakBytes: Int64) {
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent("doppel-perf.csv")
        let stamp = ISO8601DateFormatter().string(from: .now)
        let peakMB = Int(Double(peakBytes) / 1_048_576)
        let line = "\(stamp),\(count),\(String(format: "%.3f", seconds)),\(Int(filesPerSec)),\(groups),\(peakMB)\n"
        if let handle = try? FileHandle(forWritingTo: csv) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            let header = "timestamp,files,seconds,files_per_sec,groups,peak_mb\n"
            try? Data((header + line).utf8).write(to: csv)
        }
        print("PerfHarness: \(count) files in \(String(format: "%.2f", seconds))s "
            + "= \(Int(filesPerSec)) files/sec, \(groups) groups, peak \(peakMB) MB → \(csv.path)")
    }
}
