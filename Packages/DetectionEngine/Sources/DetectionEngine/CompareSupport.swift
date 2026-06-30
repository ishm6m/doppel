import Foundation

/// Normalized text for a single file, for the compare view (F8) — same extractor dispatch the
/// coordinator uses, minus the scan-event/skip bookkeeping. Returns nil for files with no text layer
/// (scanned PDF, unsupported type, decode failure); the caller shows "can't compare" rather than crash.
/// ponytail: returns the *normalized* text the engine matched on (lowercased, whitespace-folded), so the
/// diff lines up with the match. Original formatting/casing compare is a later nicety.
public func extractNormalizedText(at url: URL) async -> String? {
    let ext = url.pathExtension.lowercased()
    let extractor: ContentExtractor? = PlainTextExtractor.handledExtensions.contains(ext) ? PlainTextExtractor()
        : PDFTextExtractor.handledExtensions.contains(ext) ? PDFTextExtractor() : nil
    guard let extractor, let content = try? await extractor.extract(url) else { return nil }
    guard let text = content.normalizedText, !text.isEmpty else { return nil }
    return text
}
