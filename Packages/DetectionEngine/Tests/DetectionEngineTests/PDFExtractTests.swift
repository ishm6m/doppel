import DoppelKit
import PDFKit
import XCTest
@testable import DetectionEngine

/// F5 acceptance: a text-layer PDF participates in near-dup; a scanned (image-only) PDF is flagged,
/// never silently dropped. Fixtures are built at runtime — text layer via NSTextView's vector PDF
/// (real, extractable glyphs), scanned via an image-only `PDFPage`.
@MainActor
final class PDFExtractTests: XCTestCase {
    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeTextPDF(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        view.string = text
        let url = dir.appendingPathComponent(name)
        try view.dataWithPDF(inside: view.bounds).write(to: url)
        return url
    }

    @discardableResult
    private func makeScannedPDF(_ name: String, in dir: URL) throws -> URL {
        let img = NSImage(size: NSSize(width: 200, height: 200))
        img.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        img.unlockFocus()
        guard let page = PDFPage(image: img) else { throw CocoaError(.fileWriteUnknown) }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        let url = dir.appendingPathComponent(name)
        guard doc.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// A PDF with a real text layer extracts as `.pdfTextLayer` with its words available for near-dup.
    func testTextLayerPDFExtractsText() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeTextPDF("the same contract dated twenty twenty five", "c.pdf", in: dir)

        let content = try await PDFTextExtractor().extract(url)
        XCTAssertEqual(content.contentKind, .pdfTextLayer)
        XCTAssertFalse(content.needsOCR)
        XCTAssertTrue(content.normalizedText?.contains("contract") ?? false, "text layer must be extracted")
    }

    /// An image-only PDF has no text layer → `.pdfScanned` + needsOCR, with no text for near-dup.
    func testScannedPDFFlaggedNeedsOCR() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeScannedPDF("scan.pdf", in: dir)

        let content = try await PDFTextExtractor().extract(url)
        XCTAssertEqual(content.contentKind, .pdfScanned)
        XCTAssertTrue(content.needsOCR)
        XCTAssertNil(content.normalizedText)
    }

    /// DoD: no scanned PDF is ever silently ignored. In a full scan it surfaces as a `.needsOCR`
    /// skip and appears in no group.
    func testScannedPDFSurfacedInScanNotDropped() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try makeScannedPDF("scan.pdf", in: dir)

        var events: [ScanEvent] = []
        for try await e in ScanCoordinator().scan(ScanRequest(roots: [dir], scopes: [.document])) {
            events.append(e)
        }

        let ocrSkips = events.compactMap { e -> FileRecord? in
            if case let .fileSkipped(rec, issue) = e, issue.kind == .needsOCR { return rec }; return nil
        }
        XCTAssertEqual(ocrSkips.count, 1, "scanned PDF must be surfaced as needsOCR")
        XCTAssertFalse(events.contains { if case .groupFound = $0 { return true }; return false })
        guard case .finished = events.last else { return XCTFail("scan must finish") }
    }
}
