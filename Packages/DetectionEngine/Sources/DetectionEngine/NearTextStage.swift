import DoppelKit
import Foundation

/// Stage 2 near-duplicate text detection (ARCHITECTURE.md §3). Pure: given survivors' normalized
/// text, emits `.nearText` edges (the final-clustering pass builds the groups). LSH prunes comparisons
/// to docs sharing a band bucket, then estimated Jaccard ≥ `nearDupTextThreshold` confirms the edge
/// (score = that Jaccard).
public struct NearTextStage: Sendable {
    public struct Input: Sendable {
        public let record: FileRecord
        public let text: String // normalized (see PlainTextExtractor.normalize)
        public init(record: FileRecord, text: String) {
            self.record = record
            self.text = text
        }
    }

    private let config: DetectionConfig
    private let hasher: MinHasher
    private let banding: LSHBanding
    /// Test seam: observes every pair handed to the Jaccard comparator, to prove LSH pruning.
    private let onCompare: (@Sendable (Int, Int) -> Void)?

    public init(config: DetectionConfig = .init()) {
        self.init(config: config, onCompare: nil)
    }

    init(config: DetectionConfig, onCompare: (@Sendable (Int, Int) -> Void)?) {
        self.config = config
        self.onCompare = onCompare
        hasher = MinHasher(permutations: config.minhashPermutations, shingleSize: config.shingleSize)
        banding = LSHBanding(permutations: config.minhashPermutations)
    }

    public func group(_ inputs: [Input]) -> StageOutput {
        let sigs = inputs.map { hasher.signature($0.text) }
        var out = StageOutput()
        out.records = inputs.map(\.record)

        // Only LSH-bucket co-occurring docs are ever Jaccard-compared (the pruning invariant).
        for pair in banding.candidatePairs(signatures: sigs) {
            let i = Int(pair.a), j = Int(pair.b)
            onCompare?(i, j)
            guard let si = sigs[i], let sj = sigs[j] else { continue }
            let estimate = MinHasher.estimatedJaccard(si, sj)
            // ponytail: estimated Jaccard can false-negative on SHORT docs near the gate — one
            // changed token can become the per-perm min across many permutations and drag the
            // 128-perm estimate below threshold even at true Jaccard ~0.9 (see docs/KNOWN_LIMITATIONS.md).
            // Upgrade path: exact-Jaccard verify on near-gate candidates, or adaptive perm count.
            if estimate >= config.nearDupTextThreshold {
                let regions = Self.changedRegions(inputs[i].text, inputs[j].text)
                out.edges.append(StageEdge(
                    pair: Pair(inputs[i].record.id, inputs[j].record.id),
                    type: .nearText,
                    score: estimate,
                    reason: "Near-identical text — \(regions) changed region\(regions == 1 ? "" : "s")"
                ))
            }
        }
        return out
    }

    /// Count of contiguous changed word-runs between two normalized texts (a fast, cheap diff —
    /// ponytail: stdlib CollectionDifference; merges insert/remove offsets into runs).
    static func changedRegions(_ a: String, _ b: String) -> Int {
        let wa = a.split(separator: " "), wb = b.split(separator: " ")
        var offsets = Set<Int>()
        for change in wb.difference(from: wa) {
            switch change {
            case let .insert(offset, _, _): offsets.insert(offset)
            case let .remove(offset, _, _): offsets.insert(offset)
            }
        }
        var regions = 0, prev = -2
        for o in offsets.sorted() {
            if o != prev + 1 { regions += 1 }
            prev = o
        }
        return regions
    }
}
