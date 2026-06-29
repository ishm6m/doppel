import DoppelKit
import Foundation

/// Stage 3 semantic detection (ARCHITECTURE.md §3, F6). OPT-IN ("Deep scan") — never part of the
/// default `scan()` flow, which protects battery. Pure: given survivors' text + an `EmbeddingProvider`,
/// embeds each, buckets vectors by their strongest dimensions so only plausibly-parallel vectors are
/// ever compared (never all-pairs across the corpus), then cosine ≥ `semanticThreshold` emits a
/// `.semantic` edge (score = cosine). The final-clustering pass builds the groups.
public struct SemanticStage: Sendable {
    public struct Input: Sendable {
        public let record: FileRecord
        public let text: String // normalized (see PlainTextExtractor.normalize)
        public init(record: FileRecord, text: String) {
            self.record = record
            self.text = text
        }
    }

    private let provider: EmbeddingProvider
    private let config: DetectionConfig
    /// Test seam: observes every index pair handed to cosine, to prove bucket pruning (no all-pairs).
    private let onCompare: (@Sendable (Int, Int) -> Void)?

    public init(provider: EmbeddingProvider, config: DetectionConfig = .init()) {
        self.init(provider: provider, config: config, onCompare: nil)
    }

    init(provider: EmbeddingProvider, config: DetectionConfig, onCompare: (@Sendable (Int, Int) -> Void)?) {
        self.provider = provider
        self.config = config
        self.onCompare = onCompare
    }

    public func group(_ inputs: [Input]) async throws -> StageOutput {
        var out = StageOutput()
        out.records = inputs.map(\.record)
        guard inputs.count > 1 else { return out }

        // Embed survivors. Serial is fine for the stub; throttling a real Neural-Engine model is the
        // provider's concern (ARCHITECTURE.md §4 — dedicated bounded queue), not this stage's.
        var vectors: [[Float]] = []
        vectors.reserveCapacity(inputs.count)
        for input in inputs {
            try await vectors.append(provider.embed(text: input.text))
        }

        // Cheap cosine-LSH: near-parallel vectors share a dominant axis, orthogonal ones don't — so
        // bucket each vector by its top-k *non-zero* dimensions and only compare within a shared bucket.
        // ponytail: top-k coordinate bucketing; can miss a pair whose magnitude is spread evenly across
        // many dims. Upgrade to random-hyperplane (SimHash) LSH if semantic recall needs it.
        var buckets: [Int: [Int]] = [:]
        for (i, v) in vectors.enumerated() {
            for dim in Self.topDimensions(v, k: Self.bucketDimensions) {
                buckets[dim, default: []].append(i)
            }
        }

        let n = inputs.count
        var compared = Set<Int>() // flat i*n+j key, so a pair sharing two buckets is cosine'd once
        for members in buckets.values {
            for a in 0 ..< members.count {
                for b in (a + 1) ..< members.count {
                    let i = min(members[a], members[b]), j = max(members[a], members[b])
                    guard compared.insert(i * n + j).inserted else { continue }
                    onCompare?(i, j)
                    let cos = Self.cosine(vectors[i], vectors[j])
                    if cos >= config.semanticThreshold {
                        out.edges.append(StageEdge(
                            pair: Pair(inputs[i].record.id, inputs[j].record.id),
                            type: .semantic,
                            score: cos,
                            reason: "Semantically similar content"
                        ))
                    }
                }
            }
        }
        return out
    }

    private static let bucketDimensions = 2

    /// Indices of the `k` largest-magnitude *non-zero* dimensions. Zero dims are excluded so a sparse
    /// vector buckets only on the axes it actually occupies (a single-axis vector isn't dragged into a
    /// universal "dimension 0" bucket that would defeat pruning).
    static func topDimensions(_ v: [Float], k: Int) -> [Int] {
        Array(v.indices.filter { v[$0] != 0 }.sorted { abs(v[$0]) > abs(v[$1]) }.prefix(k))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
