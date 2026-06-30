import DoppelKit
import Foundation
import PDFKit

/// PDF extraction for Stage 2 (F5, ARCHITECTURE.md §3). Reads PDFKit's text layer; a PDF whose layer is
/// empty/sparse is classified `.pdfScanned` + `needsOCR` so it is SURFACED (never silently dropped) for
/// the opt-in Vision OCR pass — it does not enter near-dup as empty text.
public struct PDFTextExtractor: ContentExtractor {
    /// Extensions this extractor claims.
    public static let handledExtensions: Set<String> = ["pdf"]

    /// Below this many normalized text chars per page, the text layer is treated as absent → scanned.
    /// ponytail: flat per-page heuristic. A text-light-but-real PDF may be over-flagged as needsOCR —
    /// the safe direction (surfaced for OCR, not dropped). Tune if real corpora misclassify.
    static let minCharsPerPage = 8

    public init() {}

    public func canHandle(_ kind: ContentKind) -> Bool {
        kind == .pdfTextLayer || kind == .pdfScanned
    }

    public func extract(_ url: URL) async throws -> ExtractedContent {
        guard let doc = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        let normalized = PlainTextExtractor.normalize(doc.string ?? "")
        let pages = max(doc.pageCount, 1)
        if normalized.count < pages * Self.minCharsPerPage {
            return ExtractedContent(normalizedText: nil, contentKind: .pdfScanned, needsOCR: true)
        }
        return ExtractedContent(normalizedText: normalized, contentKind: .pdfTextLayer, needsOCR: false)
    }
}
