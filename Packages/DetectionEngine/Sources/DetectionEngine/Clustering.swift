import DoppelKit

/// A single pairwise match contributed by a stage, keyed by `FileRecord.id` (the one id space shared
/// across all stages). Stages emit edges; the final-clustering pass — not the stages — builds groups.
struct StageEdge {
    let pair: Pair
    let type: MatchType
    let score: Double // 0...1; exact == 1.0
    let reason: String // per-pair explanation, carried into the group label
}

/// What a detection stage hands the coordinator: edges it found, records it touched (with any hashes
/// attached), and files it had to skip. The coordinator merges these across stages, then clusters once.
public struct StageOutput: Sendable {
    var edges: [StageEdge] = []
    var records: [FileRecord] = []
    var skipped: [(FileRecord, FileIssue)] = []
}

/// Final-clustering pass (ARCHITECTURE.md §3). Unions ALL stage edges so one file lands in exactly one
/// group. A group's label is the STRONGEST edge type present (exact > nearText > nearImage > semantic);
/// confidence + explanation derive only from the strongest-type edges — so an exact+near cluster is
/// `.exact` / "Identical file contents". This is the single place groups are constructed.
enum FinalClustering {
    static func cluster(edges: [StageEdge], records: [Int64: FileRecord]) -> [ResolvedGroup] {
        guard !edges.isEmpty else { return [] }

        // Compact the sparse file-id space to 0..<n so UnionFind can index it.
        let ids = Array(Set(edges.flatMap { [$0.pair.a, $0.pair.b] })).sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var uf = UnionFind(count: ids.count)
        for e in edges {
            guard let ia = index[e.pair.a], let ib = index[e.pair.b] else { continue }
            uf.union(ia, ib)
        }

        // Bucket every edge under its cluster root so each group sees only its own edges.
        var edgesByRoot: [Int: [StageEdge]] = [:]
        for e in edges {
            guard let ia = index[e.pair.a] else { continue }
            edgesByRoot[uf.find(ia), default: []].append(e)
        }

        var groups: [ResolvedGroup] = []
        for cluster in uf.groups() where cluster.count > 1 {
            let clusterEdges = edgesByRoot[uf.find(cluster[0])] ?? []
            let members = cluster.compactMap { records[ids[$0]] }.sorted { $0.id < $1.id }
            guard let keeper = KeeperHeuristic.suggestKeeper(from: members),
                  let strongest = clusterEdges.map(\.type).min(by: { rank($0) < rank($1) }) else { continue }

            // Confidence = weakest strongest-type edge; explanation = a strongest-type edge touching
            // the keeper if any (else the lowest-id pair) — deterministic.
            let strong = clusterEdges.filter { $0.type == strongest }
            let confidence = strong.map(\.score).min() ?? 1.0
            let representative = strong.first { $0.pair.a == keeper.id || $0.pair.b == keeper.id }
                ?? strong.min { ($0.pair.a, $0.pair.b) < ($1.pair.a, $1.pair.b) }

            let g = DuplicateGroup(
                id: 0,
                matchType: strongest,
                confidence: confidence,
                explanation: representative?.reason ?? "Duplicate content",
                keeperFileID: keeper.id,
                memberFileIDs: members.map(\.id)
            )
            groups.append(ResolvedGroup(group: g, members: members))
        }
        return groups
    }

    /// Match-type priority, lower == stronger (ARCHITECTURE.md §3).
    private static func rank(_ t: MatchType) -> Int {
        switch t {
        case .exact: 0
        case .nearText: 1
        case .nearImage: 2
        case .semantic: 3
        }
    }
}
