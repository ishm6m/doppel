// swift-tools-version: 6.0
import PackageDescription

/// Standalone tool (PERFORMANCE.md §4 / TESTING.md §2): generates deterministic synthetic corpora for
/// the perf harness. Not part of the app build; run via `swift run --package-path Tools/CorpusGen`.
let package = Package(
    name: "CorpusGen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CorpusGen")
    ]
)
