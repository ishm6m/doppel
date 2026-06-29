import CryptoKit // macOS-native; no extra package dependency
import Foundation

/// Streamed SHA-256 (Stage 1, task T2.2). Never loads a whole file into memory.
public enum Hasher256 {
    public static func hash(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try hash { try handle.read(upToCount: chunkSize) }
    }

    /// Streams chunks from `nextChunk` until it yields nil/empty. Keeps the bounded-memory loop in one
    /// place so callers (and tests asserting no whole-file load) share the exact same code path.
    public static func hash(chunks nextChunk: () throws -> Data?) rethrows -> Data {
        var hasher = SHA256()
        while let chunk = try nextChunk(), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

/// Disjoint-set (union-find) for clustering pairwise matches into groups (ARCHITECTURE.md §3).
public struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    public init(count: Int) {
        parent = Array(0 ..< count)
        rank = Array(repeating: 0, count: count)
    }

    public mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root {
            root = parent[root]
        }
        var cur = x
        while parent[cur] != root {
            let next = parent[cur]; parent[cur] = root; cur = next
        }
        return root
    }

    public mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] { parent[ra] = rb }
        else if rank[ra] > rank[rb] { parent[rb] = ra }
        else { parent[rb] = ra; rank[ra] += 1 }
    }

    public mutating func groups() -> [[Int]] {
        var buckets: [Int: [Int]] = [:]
        for i in parent.indices {
            buckets[find(i), default: []].append(i)
        }
        return Array(buckets.values)
    }
}
