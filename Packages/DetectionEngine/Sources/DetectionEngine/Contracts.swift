import DoppelKit
import Foundation

// MARK: - Configuration (API.md §1)

public struct DetectionConfig: Sendable {
    public var nearDupTextThreshold: Double
    public var semanticThreshold: Double
    public var minhashPermutations: Int
    public var shingleSize: Int
    public var ocrEnabled: Bool
    public var maxConcurrency: Int
    /// Opt-in Stage 3 (F6 "Deep scan"). OFF by default so the default scan never embeds (battery).
    /// When true, the coordinator embeds survivors of the cheaper stages and adds `.semantic` edges.
    public var deepScan: Bool

    public init(
        nearDupTextThreshold: Double = 0.85,
        semanticThreshold: Double = 0.82, // placeholder; finalize after model evaluation
        minhashPermutations: Int = 128,
        shingleSize: Int = 5,
        ocrEnabled: Bool = false,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        deepScan: Bool = false
    ) {
        self.nearDupTextThreshold = nearDupTextThreshold
        self.semanticThreshold = semanticThreshold
        self.minhashPermutations = minhashPermutations
        self.shingleSize = shingleSize
        self.ocrEnabled = ocrEnabled
        self.maxConcurrency = maxConcurrency
        self.deepScan = deepScan
    }
}

public struct ScanRequest: Sendable {
    public var roots: [URL] // already security-scope-resolved by the app layer
    public var scopes: Set<FileTypeScope>
    public var config: DetectionConfig
    /// Signatures of files the store already knows are unchanged. The app fills this from
    /// `IndexStoring.unchangedFileIDs(...)`; the engine just skips matches (incremental re-scan)
    /// without ever importing IndexStore.
    public var knownSignatures: Set<FileSignature>
    public init(
        roots: [URL],
        scopes: Set<FileTypeScope> = [.document],
        config: DetectionConfig = .init(),
        knownSignatures: Set<FileSignature> = []
    ) {
        self.roots = roots
        self.scopes = scopes
        self.config = config
        self.knownSignatures = knownSignatures
    }
}

// MARK: - Events (API.md §1)

public enum ScanPhase: String, Sendable {
    case enumerating, hashing, extracting, fingerprinting, embedding, clustering
}

public struct ScanSummary: Sendable {
    public var filesDiscovered: Int
    public var groupsFound: Int
    public var bytesReclaimable: Int64
    public var skippedCount: Int
    public init(filesDiscovered: Int = 0, groupsFound: Int = 0, bytesReclaimable: Int64 = 0, skippedCount: Int = 0) {
        self.filesDiscovered = filesDiscovered
        self.groupsFound = groupsFound
        self.bytesReclaimable = bytesReclaimable
        self.skippedCount = skippedCount
    }
}

public enum ScanEvent: Sendable {
    case discovered(total: Int)
    case progress(phase: ScanPhase, processed: Int, total: Int?)
    case groupFound(DuplicateGroup, members: [FileRecord])
    case fileSkipped(FileRecord, FileIssue)
    case finished(summary: ScanSummary)
    case cancelled(partial: ScanSummary)
}

// MARK: - Coordinator protocol

//
// Architectural note (resolves the apparent coupling in API.md): the engine is PURE and does NOT
// depend on IndexStore. It only emits events. The app-layer ScanService consumes the stream and
// persists via IndexStoring. This keeps DetectionEngine free of any persistence/UI dependency.

public protocol ScanCoordinating: Sendable {
    func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, Error>
}

// MARK: - Content extraction (API.md §4)

public struct ExtractedContent: Sendable {
    public var normalizedText: String?
    public var contentKind: ContentKind
    public var needsOCR: Bool
    public init(normalizedText: String?, contentKind: ContentKind, needsOCR: Bool) {
        self.normalizedText = normalizedText
        self.contentKind = contentKind
        self.needsOCR = needsOCR
    }
}

public protocol ContentExtractor: Sendable {
    func canHandle(_ kind: ContentKind) -> Bool
    func extract(_ url: URL) async throws -> ExtractedContent
}

// MARK: - Embedding (API.md §3)

public protocol EmbeddingProvider: Sendable {
    var modelID: String { get }
    var dimension: Int { get }
    /// False only for the deterministic stub, whose vectors are NOT semantically meaningful. The app
    /// hides the opt-in Deep Scan UI until this is true, so users are never shown "semantically
    /// similar" groups that aren't (golden rule 4). Real models inherit the `true` default.
    var isSemantic: Bool { get }
    func embed(text: String) async throws -> [Float]
}

public extension EmbeddingProvider {
    var isSemantic: Bool {
        true
    }
}

/// Deterministic stub so the entire semantic tier is buildable and testable before a real model is pinned.
/// Produces a stable pseudo-embedding from the input text. NOT semantically meaningful — for wiring/tests only.
public struct StubEmbeddingProvider: EmbeddingProvider {
    public let modelID = "stub-v1"
    public let isSemantic = false
    public let dimension: Int
    public init(dimension: Int = 64) {
        self.dimension = dimension
    }

    public func embed(text: String) async throws -> [Float] {
        var vec = [Float](repeating: 0, count: dimension)
        // Hash each token into the vector deterministically.
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var h = 1_469_598_103_934_665_603 as UInt64 // FNV-1a
            for byte in token.utf8 {
                h = (h ^ UInt64(byte)) &* 1_099_511_628_211
            }
            let idx = Int(h % UInt64(dimension))
            vec[idx] += 1
        }
        // L2 normalize
        let norm = sqrt(vec.reduce(0) { $0 + Double($1 * $1) })
        if norm > 0 { for i in vec.indices {
            vec[i] = Float(Double(vec[i]) / norm)
        } }
        return vec
    }
}
