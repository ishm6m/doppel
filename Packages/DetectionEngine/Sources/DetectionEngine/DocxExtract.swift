import Compression
import DoppelKit
import Foundation

/// `.docx` text extraction for Stage 2 (T3.1). A .docx is a ZIP whose `word/document.xml` holds the
/// text. We read it with a minimal central-directory ZIP parser + Foundation's `Compression` (raw
/// DEFLATE) — no dependency, no AppKit — keeping the engine pure. RTF stays deferred (it needs AppKit).
/// ponytail: extracts `word/document.xml` only (headers/footers/footnotes live in other parts); that's
/// the body text near-dup cares about. Add the other parts if a real corpus needs them.
public struct DocxTextExtractor: ContentExtractor {
    public static let handledExtensions: Set<String> = ["docx"]

    public init() {}

    public func canHandle(_ kind: ContentKind) -> Bool {
        kind == .text
    }

    public func extract(_ url: URL) async throws -> ExtractedContent {
        let data = try Data(contentsOf: url)
        guard let xml = Zip.entry(named: "word/document.xml", in: data) else {
            // Not a readable .docx (encrypted, malformed, or missing the part) → no text layer.
            return ExtractedContent(normalizedText: nil, contentKind: .text, needsOCR: false)
        }
        let text = PlainTextExtractor.normalize(Self.plainText(fromWordXML: xml))
        return ExtractedContent(normalizedText: text.isEmpty ? nil : text, contentKind: .text, needsOCR: false)
    }

    /// Strip OOXML to visible text: every tag becomes a space (so adjacent `<w:t>` runs and paragraph
    /// breaks stay word-separated), then decode the handful of XML entities. `normalize` collapses the
    /// resulting whitespace runs.
    static func plainText(fromWordXML xml: Data) -> String {
        guard let raw = String(data: xml, encoding: .utf8) else { return "" }
        var out = ""
        out.reserveCapacity(raw.count)
        var insideTag = false
        for ch in raw {
            if ch == "<" { insideTag = true; out.append(" ") } else if ch == ">" { insideTag = false } else if !insideTag { out.append(ch) }
        }
        return decodeEntities(out)
    }

    /// Decode the five predefined XML entities + numeric references. An unrecognized `&…;` is left
    /// literal (we just emit the `&` and keep scanning).
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var iterator = s.startIndex
        while iterator < s.endIndex {
            let ch = s[iterator]
            guard ch == "&", let semi = s[iterator...].firstIndex(of: ";") else {
                result.append(ch)
                iterator = s.index(after: iterator)
                continue
            }
            if let replacement = replacement(forEntity: s[s.index(after: iterator) ..< semi]) {
                result.append(replacement)
                iterator = s.index(after: semi)
            } else {
                result.append(ch) // unknown entity → keep the literal '&', resume after it
                iterator = s.index(after: iterator)
            }
        }
        return result
    }

    /// The replacement string for an XML entity body (the text between `&` and `;`), or nil if unknown.
    private static func replacement(forEntity entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return scalarString(entity.dropFirst(2), radix: 16)
        }
        if entity.hasPrefix("#") {
            return scalarString(entity.dropFirst(), radix: 10)
        }
        return nil
    }

    /// A numeric character-reference body → its single-character string, or nil if out of range.
    private static func scalarString(_ digits: Substring, radix: Int) -> String? {
        guard let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) else { return nil }
        return String(scalar)
    }
}

/// Minimal read-only ZIP reader: finds one entry via the central directory and inflates it. Handles
/// stored (method 0) and DEFLATE (method 8) — the only methods .docx uses. ponytail: no ZIP64, no
/// encryption; real Office files written today fit in 32-bit offsets. Add ZIP64 if huge .docx appear.
enum Zip {
    /// Decompressed bytes of `named`, or nil if absent/unsupported/corrupt.
    static func entry(named name: String, in data: Data) -> Data? {
        guard let eocd = endOfCentralDirectory(in: data) else { return nil }
        var offset = eocd.cdOffset
        for _ in 0 ..< eocd.entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4B50 else { return nil }
            let method = u16(data, offset + 10)
            let compressedSize = Int(u32(data, offset + 20))
            let uncompressedSize = Int(u32(data, offset + 24))
            let nameLen = Int(u16(data, offset + 28))
            let extraLen = Int(u16(data, offset + 30))
            let commentLen = Int(u16(data, offset + 32))
            let localOffset = Int(u32(data, offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { return nil }
            // Compare raw bytes to the target name's UTF-8 — avoids building a throwaway String per entry.
            if data[nameStart ..< nameStart + nameLen].elementsEqual(name.utf8) {
                return readLocal(
                    in: data,
                    localHeaderOffset: localOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return nil
    }

    /// Read + decompress the entry's data, using the central directory's authoritative sizes (so a
    /// streaming data-descriptor in the local header doesn't matter).
    private static func readLocal(in data: Data, localHeaderOffset: Int, method: Int, compressedSize: Int, uncompressedSize: Int) -> Data? {
        guard localHeaderOffset + 30 <= data.count, u32(data, localHeaderOffset) == 0x0403_4B50 else { return nil }
        let nameLen = Int(u16(data, localHeaderOffset + 26))
        let extraLen = Int(u16(data, localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLen + extraLen
        guard dataStart + compressedSize <= data.count else { return nil }
        let payload = data.subdata(in: dataStart ..< dataStart + compressedSize)
        switch method {
        case 0: return payload // stored
        case 8: return inflate(payload, decompressedSize: uncompressedSize)
        default: return nil
        }
    }

    /// Raw DEFLATE (RFC 1951) inflate via Compression — `COMPRESSION_ZLIB` is the raw form on Apple,
    /// matching ZIP method 8.
    private static func inflate(_ src: Data, decompressedSize: Int) -> Data? {
        guard decompressedSize > 0 else { return Data() }
        var dst = Data(count: decompressedSize)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            src.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstPtr, decompressedSize, srcPtr, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == decompressedSize ? dst : nil
    }

    /// Locate the End Of Central Directory record by scanning backward for its signature (the trailing
    /// comment is almost always empty, so this is near the end).
    private static func endOfCentralDirectory(in data: Data) -> (cdOffset: Int, entryCount: Int)? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        let limit = max(0, data.count - 22 - 65536) // max comment length
        while i >= limit {
            if u32(data, i) == 0x0605_4B50 {
                return (Int(u32(data, i + 16)), Int(u16(data, i + 10)))
            }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: Data, _ offset: Int) -> Int {
        Int(d[d.startIndex + offset]) | (Int(d[d.startIndex + offset + 1]) << 8)
    }

    private static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        let base = d.startIndex + offset
        return UInt32(d[base]) | (UInt32(d[base + 1]) << 8) | (UInt32(d[base + 2]) << 16) | (UInt32(d[base + 3]) << 24)
    }
}
