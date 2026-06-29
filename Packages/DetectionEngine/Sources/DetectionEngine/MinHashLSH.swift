import DoppelKit
import Foundation

/// Deterministic 64→31-bit PRNG used to derive the MinHash permutation coefficients.
/// Fixed seed ⇒ identical signatures across runs (required for incremental re-scan + tests).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// MinHash over k-word shingles (Stage 2, ARCHITECTURE.md §3). Estimates Jaccard similarity from
/// fixed-length signatures so two docs are compared in O(permutations), not O(text).
public struct MinHasher: Sendable {
    /// 2^31 − 1 (Mersenne prime). Keeping hashed values < 2^31 means `a*x + b` fits in UInt64
    /// with no overflow, so the universal hash needs no 128-bit math.
    static let prime: UInt64 = 2_147_483_647

    public let permutations: Int
    public let shingleSize: Int
    private let a: [UInt64]
    private let b: [UInt64]

    public init(permutations: Int = 128, shingleSize: Int = 5, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.permutations = max(1, permutations)
        self.shingleSize = max(1, shingleSize)
        var rng = SplitMix64(seed: seed)
        a = (0 ..< self.permutations).map { _ in rng.next() % (Self.prime - 1) + 1 } // [1, prime-1]
        b = (0 ..< self.permutations).map { _ in rng.next() % Self.prime } // [0, prime-1]
    }

    /// k-word shingles. Docs shorter than k collapse to one shingle of all words, so two short
    /// identical docs still match. Returns hashed shingles (already reduced mod prime).
    func shingles(_ normalized: String) -> Set<UInt64> {
        let words = normalized.split(separator: " ")
        guard !words.isEmpty else { return [] }
        guard words.count >= shingleSize else { return [Self.hashShingle(words[...])] }
        var set = Set<UInt64>()
        for i in 0 ... (words.count - shingleSize) {
            set.insert(Self.hashShingle(words[i ..< (i + shingleSize)]))
        }
        return set
    }

    /// Signature, or nil when the doc has no shingles (empty text) — uncomparable.
    public func signature(_ normalized: String) -> [UInt64]? {
        let sh = shingles(normalized)
        guard !sh.isEmpty else { return nil }
        var sig = [UInt64](repeating: Self.prime, count: permutations) // prime > any value in [0, prime-1]
        for h in sh {
            for i in 0 ..< permutations {
                let hv = (a[i] &* h &+ b[i]) % Self.prime
                if hv < sig[i] { sig[i] = hv }
            }
        }
        return sig
    }

    /// Fraction of matching positions ≈ Jaccard similarity of the two shingle sets.
    public static func estimatedJaccard(_ x: [UInt64], _ y: [UInt64]) -> Double {
        let n = min(x.count, y.count)
        guard n > 0 else { return 0 }
        var eq = 0
        for i in 0 ..< n where x[i] == y[i] {
            eq += 1
        }
        return Double(eq) / Double(n)
    }

    private static func hashShingle(_ words: ArraySlice<Substring>) -> UInt64 {
        var h: UInt64 = 1_469_598_103_934_665_603 // FNV-1a
        for w in words {
            for byte in w.utf8 {
                h = (h ^ UInt64(byte)) &* 1_099_511_628_211
            }
            h = (h ^ 0x20) &* 1_099_511_628_211 // word separator: "ab cd" ≠ "abc d"
        }
        return h % prime
    }
}

/// LSH banding (ARCHITECTURE.md §3). Splits each signature into `bands` bands of `rows` rows and
/// buckets docs per band. Only docs sharing a bucket become candidate pairs — this is what makes
/// Stage 2 near-linear instead of O(n²).
///
/// Defaults: 16 bands × 8 rows over 128 perms ⇒ band threshold ≈ (1/16)^(1/8) ≈ 0.74. Deliberately
/// below the 0.85 near-dup gate so banding is recall-biased (~0.99 hit at true Jaccard 0.85); the
/// estimated-Jaccard threshold downstream supplies precision.
public struct LSHBanding: Sendable {
    public let bands: Int
    public let rows: Int

    public init(permutations: Int, rows: Int = 8) {
        let r = max(1, rows)
        self.rows = r
        bands = max(1, permutations / r)
    }

    /// Candidate pairs (doc-index pairs sharing ≥1 band bucket), de-duplicated across bands.
    public func candidatePairs(signatures: [[UInt64]?]) -> Set<Pair> {
        var buckets: [UInt64: [Int]] = [:]
        for (doc, sig) in signatures.enumerated() {
            guard let sig else { continue }
            for band in 0 ..< bands {
                buckets[bandKey(sig, band: band), default: []].append(doc)
            }
        }
        var pairs = Set<Pair>()
        for ids in buckets.values where ids.count > 1 {
            for x in 0 ..< ids.count {
                for y in (x + 1) ..< ids.count {
                    pairs.insert(Pair(Int64(ids[x]), Int64(ids[y])))
                }
            }
        }
        return pairs
    }

    private func bandKey(_ sig: [UInt64], band: Int) -> UInt64 {
        var h: UInt64 = 1_469_598_103_934_665_603 // FNV-1a, seeded with band index
        h = (h ^ UInt64(band)) &* 1_099_511_628_211
        let start = band * rows
        for k in 0 ..< rows where start + k < sig.count {
            h = (h ^ sig[start + k]) &* 1_099_511_628_211
        }
        return h
    }
}
