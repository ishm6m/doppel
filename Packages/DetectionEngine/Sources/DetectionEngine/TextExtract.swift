import DoppelKit
import Foundation

/// Plain-text extraction + normalization for Stage 2 (ARCHITECTURE.md §3).
/// ponytail: txt/md only. RTF/.docx/PDF need AppKit/PDFKit (RTF parsing is AppKit-only) and would
/// taint the pure engine — deferred to dedicated tasks (T3.1/T3.2) where that tradeoff is decided.
public struct PlainTextExtractor: ContentExtractor {
    /// Extensions this extractor claims. Anything else is left for a later extractor.
    public static let handledExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    public init() {}

    public func canHandle(_ kind: ContentKind) -> Bool {
        kind == .text
    }

    public func extract(_ url: URL) async throws -> ExtractedContent {
        // ponytail: utf8, lossy fallback for stray encodings — good enough for shingling.
        let raw = try (try? String(contentsOf: url, encoding: .utf8))
            ?? String(decoding: Data(contentsOf: url), as: UTF8.self)
        return ExtractedContent(normalizedText: Self.normalize(raw), contentKind: .text, needsOCR: false)
    }

    /// Lowercase + fold all whitespace runs to single spaces. This is the exact string the
    /// MinHasher shingles over, so it must be deterministic.
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
