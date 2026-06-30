import Foundation

// MARK: - Enums

public enum MatchType: String, Sendable, Codable, CaseIterable {
    case exact, nearText, nearImage, semantic
}

public enum ContentKind: String, Sendable, Codable {
    case text, pdfTextLayer, pdfScanned, image, unknown
}

public enum FileStatus: String, Sendable, Codable {
    case indexed, skipped, needsOCR, error
}

public enum FileTypeScope: String, Sendable, Codable, CaseIterable {
    case document, image, other
}

public enum ScanState: String, Sendable, Codable {
    case running, cancelled, finished, failed
}

// MARK: - Issues

public struct FileIssue: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case unreadable, unsupported, decodeFailed, tooLarge, permissionDenied, needsOCR
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

// MARK: - Identity / signature

public struct FileSignature: Sendable, Hashable {
    public let sizeBytes: Int64
    public let mtime: Date
    public let fileID: UInt64?

    public init(sizeBytes: Int64, mtime: Date, fileID: UInt64?) {
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.fileID = fileID
    }
}

// MARK: - Core records

public struct FileRecord: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var bookmarkID: Int64
    public var relativePath: String
    public var displayName: String
    public var sizeBytes: Int64
    public var mtime: Date
    public var fileID: UInt64?
    public var typeScope: FileTypeScope
    public var contentKind: ContentKind
    public var sha256: Data?
    public var minhash: Data?
    public var phash: UInt64?
    public var embeddingID: Int64?
    public var status: FileStatus
    public var issue: FileIssue?

    public init(
        id: Int64,
        bookmarkID: Int64,
        relativePath: String,
        displayName: String,
        sizeBytes: Int64,
        mtime: Date,
        fileID: UInt64? = nil,
        typeScope: FileTypeScope,
        contentKind: ContentKind = .unknown,
        sha256: Data? = nil,
        minhash: Data? = nil,
        phash: UInt64? = nil,
        embeddingID: Int64? = nil,
        status: FileStatus = .indexed,
        issue: FileIssue? = nil
    ) {
        self.id = id
        self.bookmarkID = bookmarkID
        self.relativePath = relativePath
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.fileID = fileID
        self.typeScope = typeScope
        self.contentKind = contentKind
        self.sha256 = sha256
        self.minhash = minhash
        self.phash = phash
        self.embeddingID = embeddingID
        self.status = status
        self.issue = issue
    }

    public var signature: FileSignature {
        FileSignature(sizeBytes: sizeBytes, mtime: mtime, fileID: fileID)
    }
}

public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var matchType: MatchType
    public var confidence: Double
    public var explanation: String
    public var keeperFileID: Int64
    public var memberFileIDs: [Int64]
    public var ignored: Bool
    public var createdAt: Date

    public init(
        id: Int64,
        matchType: MatchType,
        confidence: Double,
        explanation: String,
        keeperFileID: Int64,
        memberFileIDs: [Int64],
        ignored: Bool = false,
        createdAt: Date = .now
    ) {
        // Invariants (see DATA_MODEL.md): explanation non-empty, confidence in [0,1].
        precondition(!explanation.isEmpty, "DuplicateGroup.explanation must not be empty")
        precondition((0.0 ... 1.0).contains(confidence), "confidence must be within 0...1")
        self.id = id
        self.matchType = matchType
        self.confidence = confidence
        self.explanation = explanation
        self.keeperFileID = keeperFileID
        self.memberFileIDs = memberFileIDs
        self.ignored = ignored
        self.createdAt = createdAt
    }
}

public struct MatchEdge: Sendable, Hashable {
    public let groupID: Int64
    public let fileA: Int64
    public let fileB: Int64
    public let matchType: MatchType
    public let score: Double
    public let reasonSummary: String

    public init(groupID: Int64, fileA: Int64, fileB: Int64, matchType: MatchType, score: Double, reasonSummary: String) {
        self.groupID = groupID
        self.fileA = fileA
        self.fileB = fileB
        self.matchType = matchType
        self.score = score
        self.reasonSummary = reasonSummary
    }
}

public struct SourceBookmark: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var bookmarkData: Data
    public var displayPath: String
    public var addedAt: Date

    public init(id: Int64, bookmarkData: Data, displayPath: String, addedAt: Date = .now) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
        self.addedAt = addedAt
    }
}

public struct ScanSession: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var startedAt: Date
    public var finishedAt: Date?
    public var rootBookmarkIDs: [Int64]
    public var scopes: Set<FileTypeScope>
    public var filesDiscovered: Int
    public var groupsFound: Int
    public var bytesReclaimable: Int64
    public var state: ScanState

    public init(
        id: Int64,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        rootBookmarkIDs: [Int64],
        scopes: Set<FileTypeScope>,
        filesDiscovered: Int = 0,
        groupsFound: Int = 0,
        bytesReclaimable: Int64 = 0,
        state: ScanState = .running
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rootBookmarkIDs = rootBookmarkIDs
        self.scopes = scopes
        self.filesDiscovered = filesDiscovered
        self.groupsFound = groupsFound
        self.bytesReclaimable = bytesReclaimable
        self.state = state
    }
}

public struct Embedding: Identifiable, Sendable, Hashable {
    public let id: Int64
    public var modelID: String
    public var dim: Int
    public var vector: [Float]

    public init(id: Int64, modelID: String, dim: Int, vector: [Float]) {
        self.id = id
        self.modelID = modelID
        self.dim = dim
        self.vector = vector
    }
}

public struct Pair: Sendable, Hashable {
    public let a: Int64
    public let b: Int64
    public init(_ a: Int64, _ b: Int64) {
        // Normalize so (a,b) == (b,a)
        self.a = min(a, b)
        self.b = max(a, b)
    }
}
