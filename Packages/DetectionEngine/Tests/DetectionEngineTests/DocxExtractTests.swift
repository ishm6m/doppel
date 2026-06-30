import DoppelKit
import XCTest
@testable import DetectionEngine

final class DocxExtractTests: XCTestCase {
    /// A real minimal .docx (a ZIP with `[Content_Types].xml` + `word/document.xml`, DEFLATE-compressed),
    /// generated with Python's zipfile and embedded as base64 so the test is hermetic. Its body text is
    /// "This agreement is dated 2024 between Alice and Bob" + "Signed in good faith".
    private let docxBase64 = """
    UEsDBBQAAAAIAPGs3lyGfv6emgAAAMMAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbCWOSw7CMAxErxJ5T1NYIISSdMHnBOUAVup+\
    ROtEjUHt7Unp0vNmxmOqZRrVl+Y0BLZwLEpQxD40A3cWXvXzcAGVBLnBMTBZWClB5Uy9RkoqZzlZ6EXiVevke5owFSESZ9KGeULJ\
    59zpiP6NHelTWZ61DyzEcpCtA5y5U4ufUdRjyfK+I8dB3Xbf9soCxjgOHiVjvVHtjP6PcD9QSwMEFAAAAAgA8azeXBOCUDjeAAAA\
    WwEAABEAAAB3b3JkL2RvY3VtZW50LnhtbG1Q0U7DMAz8FSvvLKWaEKraTuOBH2B8QJp4baTGjuJsZX9PgkADiZezrLPvzu4PH2GF\
    KybxTIN63DUKkCw7T/Og3k+vD88KJBtyZmXCQd1Q1GHst86xvQSkDEWApNsGteQcO63FLhiM7DgiFe7MKZhc2jTrjZOLiS2KFP2w\
    6rZpnnQwnlSVnNjdao0VUoU8nhYvYOaE+GVWGmcyul5XsmK6D9conURjS86YUDBdUY3QNu0eJswbIsFx9Rah3AMvPP1R0d/Gv93f\
    /EzowBPMzA7OxuflnyX9k13f/zJ+AlBLAQIUAxQAAAAIAPGs3lyGfv6emgAAAMMAAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVu\
    dF9UeXBlc10ueG1sUEsBAhQDFAAAAAgA8azeXBOCUDjeAAAAWwEAABEAAAAAAAAAAAAAAIABywAAAHdvcmQvZG9jdW1lbnQueG1s\
    UEsFBgAAAAACAAIAgAAAANgBAAAAAA==
    """

    private func writeFixture() throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: docxBase64.replacingOccurrences(of: "\n", with: "")))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        try data.write(to: url)
        return url
    }

    /// The extractor unzips word/document.xml, strips OOXML to visible text, and normalizes it — the
    /// same normalized form the near-dup stage shingles over.
    func testExtractsNormalizedBodyTextFromDocx() async throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try await DocxTextExtractor().extract(url)

        XCTAssertEqual(content.contentKind, .text)
        XCTAssertFalse(content.needsOCR)
        XCTAssertEqual(
            content.normalizedText,
            "this agreement is dated 2024 between alice and bob signed in good faith"
        )
    }

    /// A non-.docx (or corrupt) blob yields no text rather than throwing — the coordinator then skips it.
    func testNonDocxYieldsNoText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try await DocxTextExtractor().extract(url)
        XCTAssertNil(content.normalizedText)
    }

    /// Tag-stripping keeps word boundaries (adjacent runs don't fuse) and decodes XML entities.
    func testPlainTextFromWordXMLSeparatesRunsAndDecodesEntities() {
        let xml = Data("<w:p><w:r><w:t>Smith</w:t></w:r><w:r><w:t>&amp; Jones</w:t></w:r></w:p>".utf8)
        let text = DocxTextExtractor.plainText(fromWordXML: xml)
        XCTAssertEqual(PlainTextExtractor.normalize(text), "smith & jones")
    }
}
