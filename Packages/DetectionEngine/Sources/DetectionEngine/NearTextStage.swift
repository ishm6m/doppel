import DoppelKit
import Foundation

/// Stage 2 near-duplicate text detection (ARCHITECTURE.md §3). Pure: given survivors' normalized
/// text, emits `.nearText` `DuplicateGroup`s. LSH prunes comparisons to docs sharing a band bucket,
/// then estimated Jaccard ≥ `nearDupTextThreshold` confirms the edge (confidence = that Jaccard).
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

    public func group(_ inputs: [Input]) -> [ResolvedGroup] {
        let sigs = inputs.map { hasher.signature($0.text) }

        // Only LSH-bucket co-occurring docs are ever Jaccard-compared (the pruning invariant).
        var uf = UnionFind(count: inputs.count)
        var edgeJaccard: [Pair: Double] = [:]
        for pair in banding.candidatePairs(signatures: sigs) {
            let i = Int(pair.a), j = Int(pair.b)
            onCompare?(i, j)
            guard let si = sigs[i], let sj = sigs[j] else { continue }
            let estimate = MinHasher.estimatedJaccard(si, sj)
            if estimate >= config.nearDupTextThreshold {
                uf.union(i, j)
                edgeJaccard[pair] = estimate
            }
        }

        return uf.groups().compactMap { cluster in
            guard cluster.count > 1 else { return nil }
            return makeGroup(cluster: cluster, inputs: inputs, edgeJaccard: edgeJaccard)
        }
    }

    private func makeGroup(cluster: [Int], inputs: [Input], edgeJaccard: [Pair: Double]) -> ResolvedGroup? {
        let members = cluster.map { inputs[$0].record }.sorted { $0.id < $1.id }
        guard let keeper = KeeperHeuristic.suggestKeeper(from: members) else { return nil }
        let clusterSet = Set(cluster)
        // Conservative confidence: the weakest edge holding the cluster together.
        let edges = edgeJaccard.filter { clusterSet.contains(Int($0.key.a)) && clusterSet.contains(Int($0.key.b)) }
        let confidence = edges.values.min() ?? config.nearDupTextThreshold

        let texts = Dictionary(uniqueKeysWithValues: cluster.map { (inputs[$0].record.id, inputs[$0].text) })
        let other = members.first { $0.id != keeper.id } ?? keeper
        let regions = Self.changedRegions(texts[keeper.id] ?? "", texts[other.id] ?? "")
        let group = DuplicateGroup(
            id: 0,
            matchType: .nearText,
            confidence: confidence,
            explanation: "Near-identical text — \(regions) changed region\(regions == 1 ? "" : "s")",
            keeperFileID: keeper.id,
            memberFileIDs: members.map(\.id)
        )
        return ResolvedGroup(group: group, members: members)
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
