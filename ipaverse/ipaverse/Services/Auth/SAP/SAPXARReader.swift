//
//  SAPXARReader.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Minimal XAR (eXtensible ARchive) container reader: just enough to locate
//  a named top-level file's heap offset/length inside a `.pkg`, without
//  downloading the archive itself. macOS ships a full libxar
//  (usr/include/xar/xar.h, usr/lib/libxar.tbd), but its C API operates on
//  local file paths, not remote byte ranges — reimplementing the ~30-line
//  header parse plus a small XML walk over the (already zlib-compressed,
//  reusing the zlib already linked for `Constant`-adjacent code) TOC is far
//  cheaper than downloading a multi-gigabyte package just to hand it to
//  libxar. ipatool's equivalent is `github.com/blacktop/go-macho/pkg/xar`.
//
//  XAR container layout (all header fields big-endian):
//    [0..4)   magic "xar!"
//    [4..6)   header size (normally 28)
//    [6..8)   version
//    [8..16)  TOC length, zlib-compressed
//    [16..24) TOC length, uncompressed
//    [24..28) checksum algorithm
//    [headerSize..headerSize+tocLengthCompressed) zlib-compressed TOC XML
//    [headerSize+tocLengthCompressed...) the "heap": every <file>'s
//      <data><offset> is relative to the start of the heap.
//

import Foundation

struct SAPXAREntry {
    let name: String
    let heapOffset: UInt64
    let length: UInt64
    let encodingStyle: String?
}

enum SAPXARError: LocalizedError {
    case invalidMagic
    case unexpectedStatus(Int)
    case truncatedResponse
    case tocInflateFailed(Int32)
    case tocParseFailed
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidMagic: "Not a XAR archive (bad magic)"
        case .unexpectedStatus(let code): "Apple software update server returned unexpected status \(code)"
        case .truncatedResponse: "Apple software update server returned less data than requested"
        case .tocInflateFailed(let code): "Failed to inflate XAR table of contents (zlib code \(code))"
        case .tocParseFailed: "Failed to parse XAR table of contents XML"
        case .entryNotFound(let name): "XAR archive has no top-level entry named \"\(name)\""
        }
    }
}

/// Reads just the XAR header and table of contents over HTTP range
/// requests, to locate one named entry's absolute byte range in the file.
enum SAPXARReader {
    private static let headerMagic: [UInt8] = Array("xar!".utf8)

    /// Returns the entry's absolute byte offset (from the start of the
    /// remote file) and its on-disk (heap) length.
    static func locate(name: String, in url: URL, session: URLSession = .shared) async throws -> (absoluteOffset: UInt64, length: UInt64) {
        let header = try await fetchRange(url: url, start: 0, length: 28, session: session)
        guard header.count == 28, Array(header[0..<4]) == headerMagic else {
            throw SAPXARError.invalidMagic
        }

        let headerSize = UInt64(bigEndian16: header, at: 4)
        let tocLengthCompressed = UInt64(bigEndian64: header, at: 8)

        let compressedTOC = try await fetchRange(url: url, start: UInt64(headerSize), length: tocLengthCompressed, session: session)
        let tocXML = try inflateTOC(compressedTOC)

        guard let entry = try parseTOC(tocXML, entryName: name) else {
            throw SAPXARError.entryNotFound(name)
        }

        let heapStart = UInt64(headerSize) + tocLengthCompressed
        return (heapStart + entry.heapOffset, entry.length)
    }

    private static func fetchRange(url: URL, start: UInt64, length: UInt64, session: URLSession) async throws -> [UInt8] {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SAPXARError.unexpectedStatus(status)
        }
        guard UInt64(data.count) >= length || http.statusCode == 200 else {
            throw SAPXARError.truncatedResponse
        }

        return Array(data.prefix(Int(length)))
    }

    /// Raw zlib inflate (RFC 1950 — the standard `zlib.h` `uncompress`-style
    /// stream, distinct from the raw-DEFLATE variant XAR does *not* use here).
    /// Named `inflateTOC` (not `inflate`) to avoid shadowing zlib's global
    /// `inflate(z_streamp, Int32)` C function used inside this method.
    private static func inflateTOC(_ compressed: [UInt8]) throws -> Data {
        var stream = z_stream()
        var result = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else { throw SAPXARError.tocInflateFailed(result) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var outBuffer = [UInt8](repeating: 0, count: 1 << 16)
        var input = compressed

        try input.withUnsafeMutableBufferPointer { inBuffer in
            try inBuffer.baseAddress!.withMemoryRebound(to: Bytef.self, capacity: inBuffer.count) { inPtr in
                stream.next_in = inPtr
                stream.avail_in = UInt32(inBuffer.count)

                repeat {
                    try outBuffer.withUnsafeMutableBufferPointer { outPtrBuffer in
                        try outPtrBuffer.baseAddress!.withMemoryRebound(to: Bytef.self, capacity: outPtrBuffer.count) { outPtr in
                            stream.next_out = outPtr
                            stream.avail_out = UInt32(outPtrBuffer.count)

                            result = inflate(&stream, Z_NO_FLUSH)
                            guard result == Z_OK || result == Z_STREAM_END else {
                                throw SAPXARError.tocInflateFailed(result)
                            }

                            let produced = outPtrBuffer.count - Int(stream.avail_out)
                            output.append(outPtrBuffer.baseAddress!, count: produced)
                        }
                    }
                } while result != Z_STREAM_END && stream.avail_in > 0
            }
        }

        return output
    }

    private static func parseTOC(_ xml: Data, entryName: String) throws -> SAPXAREntry? {
        let delegate = TOCParserDelegate(targetName: entryName)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate

        guard parser.parse() else {
            throw SAPXARError.tocParseFailed
        }

        return delegate.foundEntry
    }

    /// Walks `<file name="..."> ... <data><offset>/<length>/<encoding> ...`
    /// looking for a single top-level entry by name. XAR TOCs can nest
    /// `<file>` elements for directories; Apple's update payload stores
    /// `Payload` at the top level, so this only needs to track the current
    /// `<file><name>` and the immediately-following `<data>` fields.
    private final class TOCParserDelegate: NSObject, XMLParserDelegate {
        let targetName: String
        private(set) var foundEntry: SAPXAREntry?

        private var elementStack: [String] = []
        private var currentText = ""
        private var currentFileName: String?
        private var currentOffset: UInt64?
        private var currentLength: UInt64?
        private var currentEncodingStyle: String?

        init(targetName: String) {
            self.targetName = targetName
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            elementStack.append(elementName)
            currentText = ""

            if elementName == "file" {
                currentFileName = nil
                currentOffset = nil
                currentLength = nil
                currentEncodingStyle = nil
            } else if elementName == "encoding" {
                currentEncodingStyle = attributeDict["style"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            defer {
                elementStack.removeLast()
                currentText = ""
            }

            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            switch elementName {
            case "name" where elementStack.last == "name" && elementStack.dropLast().last == "file":
                currentFileName = text
            case "offset":
                currentOffset = UInt64(text)
            case "length":
                currentLength = UInt64(text)
            case "file":
                if foundEntry == nil, currentFileName == targetName,
                   let offset = currentOffset, let length = currentLength {
                    foundEntry = SAPXAREntry(name: targetName, heapOffset: offset, length: length, encodingStyle: currentEncodingStyle)
                }
            default:
                break
            }
        }
    }
}

private extension UInt64 {
    init(bigEndian16 bytes: [UInt8], at offset: Int) {
        self = (UInt64(bytes[offset]) << 8) | UInt64(bytes[offset + 1])
    }

    init(bigEndian64 bytes: [UInt8], at offset: Int) {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        self = value
    }
}
