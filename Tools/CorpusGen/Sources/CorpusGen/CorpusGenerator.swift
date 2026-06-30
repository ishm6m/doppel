import Foundation

/// Deterministic synthetic-corpus generator (PERFORMANCE.md §4). Same seed ⇒ byte-identical corpus,
/// with a known mix of unique / exact-duplicate / near-duplicate documents so the perf harness and
/// accuracy tests have ground truth. Pure (no I/O) so it's unit-testable; `writeCorpus` does the I/O.
public struct CorpusGenerator {
    public struct Spec {
        public var count: Int
        public var seed: UInt64
        /// Fraction of files that are exact copies of an earlier unique file.
        public var exactRatio: Double
        /// Fraction that are near-duplicates (one token changed) of an earlier unique file.
        public var nearRatio: Double
        /// Words per document (drives file size; ~6 bytes/word).
        public var wordsPerDoc: Int

        public init(count: Int, seed: UInt64 = 42, exactRatio: Double = 0.2, nearRatio: Double = 0.2, wordsPerDoc: Int = 400) {
            self.count = count
            self.seed = seed
            self.exactRatio = exactRatio
            self.nearRatio = nearRatio
            self.wordsPerDoc = wordsPerDoc
        }
    }

    /// What a generated file is, so callers know the ground-truth duplicate structure.
    public enum Kind: String { case unique, exact, near }

    public struct Doc {
        public let name: String
        public let text: String
        public let kind: Kind
    }

    let spec: Spec
    public init(spec: Spec) {
        self.spec = spec
    }

    /// Generate the corpus deterministically. The first file is always unique; each later file is
    /// unique / exact / near per the seeded RNG, copying or mutating a random earlier *unique* doc.
    public func documents() -> [Doc] {
        var rng = SplitMix64(seed: spec.seed)
        var docs: [Doc] = []
        var uniqueIndices: [Int] = []
        for i in 0 ..< spec.count {
            let roll = rng.nextUnit()
            let canCopy = !uniqueIndices.isEmpty
            let name = String(format: "doc%06d.txt", i)
            if canCopy, roll < spec.exactRatio {
                let src = docs[uniqueIndices[Int(rng.next() % UInt64(uniqueIndices.count))]]
                docs.append(Doc(name: name, text: src.text, kind: .exact))
            } else if canCopy, roll < spec.exactRatio + spec.nearRatio {
                let src = docs[uniqueIndices[Int(rng.next() % UInt64(uniqueIndices.count))]]
                docs.append(Doc(name: name, text: Self.mutate(src.text, &rng), kind: .near))
            } else {
                uniqueIndices.append(i)
                docs.append(Doc(name: name, text: randomDoc(&rng), kind: .unique))
            }
        }
        return docs
    }

    /// Write the corpus to `dir` and return the docs (for a manifest/ground truth). Creates `dir`.
    @discardableResult
    public func writeCorpus(to dir: URL) throws -> [Doc] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let docs = documents()
        for doc in docs {
            try Data(doc.text.utf8).write(to: dir.appendingPathComponent(doc.name))
        }
        return docs
    }

    private func randomDoc(_ rng: inout SplitMix64) -> String {
        var words: [String] = []
        words.reserveCapacity(spec.wordsPerDoc)
        for _ in 0 ..< spec.wordsPerDoc {
            words.append(Self.vocabulary[Int(rng.next() % UInt64(Self.vocabulary.count))])
        }
        return words.joined(separator: " ")
    }

    /// Change a single word, so the result is a near-duplicate (high Jaccard, not byte-identical).
    static func mutate(_ text: String, _ rng: inout SplitMix64) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text + " edited" }
        words[Int(rng.next() % UInt64(words.count))] = "edited\(rng.next() % 100_000)"
        return words.joined(separator: " ")
    }

    /// A small fixed vocabulary keeps docs realistic-ish and the generator dependency-free.
    static let vocabulary: [String] = {
        let base = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt "
            + "ut labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco "
            + "laboris nisi aliquip ex ea commodo consequat duis aute irure reprehenderit voluptate velit"
        return base.split(separator: " ").map(String.init)
    }()
}

/// SplitMix64 — a tiny, fast, deterministic PRNG (no Foundation randomness, so output is reproducible
/// across platforms/runs for a given seed).
public struct SplitMix64 {
    private var state: UInt64
    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
