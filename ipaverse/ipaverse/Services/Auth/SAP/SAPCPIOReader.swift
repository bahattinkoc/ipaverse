//
//  SAPCPIOReader.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Reads the old portable ASCII CPIO format ("070707") used by Apple's
//  software-update payload archives.
//
//  Direct port of ipatool's internal/sap/cpio.Reader (MIT licensed,
//  github.com/majd/ipatool) — same fixed 76-byte header layout, same
//  offsets. Entries are consumed sequentially and bodies are pulled on
//  demand so unrelated files in the archive are never fully buffered.
//

import Foundation

enum SAPCPIOError: LocalizedError {
    case invalidMagic(String)
    case invalidField(String)
    case nameNotTerminated

    var errorDescription: String? {
        switch self {
        case .invalidMagic(let value): "Invalid CPIO magic \"\(value)\""
        case .invalidField(let value): "Invalid CPIO header field \"\(value)\""
        case .nameNotTerminated: "CPIO entry name is not NUL-terminated"
        }
    }
}

/// Sequential reader over an old ASCII ("070707") CPIO stream, pulling bytes
/// from an in-memory buffer produced by ``SAPBZip2Decoder``.
final class SAPCPIOReader {
    private static let headerSize = 76
    private static let nameSizeRange = 59..<65
    private static let fileSizeRange = 65..<76
    private static let magic = Array("070707".utf8)
    private static let trailerName = "TRAILER!!!"

    private let source: SAPByteSource
    private var remainingInCurrentEntry: Int = 0

    init(source: SAPByteSource) {
        self.source = source
    }

    /// Returns the next entry's path and its exact byte size, or `nil` at the
    /// CPIO trailer entry. Call ``read(upTo:)`` to consume the body before
    /// requesting the next entry.
    func next() async throws -> (path: String, size: Int)? {
        if remainingInCurrentEntry > 0 {
            _ = try await source.read(upTo: remainingInCurrentEntry)
            remainingInCurrentEntry = 0
        }

        let header = try await source.read(upTo: Self.headerSize)
        guard header.count == Self.headerSize else { return nil }

        let magicBytes = Array(header[0..<6])
        guard magicBytes == Self.magic else {
            throw SAPCPIOError.invalidMagic(String(decoding: magicBytes, as: UTF8.self))
        }

        guard let nameSize = Self.parseOctal(header[Self.nameSizeRange]), nameSize >= 1 else {
            throw SAPCPIOError.invalidField("namesize")
        }

        guard let fileSize = Self.parseOctal(header[Self.fileSizeRange]) else {
            throw SAPCPIOError.invalidField("filesize")
        }

        var name = try await source.read(upTo: nameSize)
        guard name.last == 0 else { throw SAPCPIOError.nameNotTerminated }
        name.removeLast()

        let path = String(decoding: name, as: UTF8.self)
        if path == Self.trailerName {
            return nil
        }

        remainingInCurrentEntry = fileSize
        return (path, fileSize)
    }

    /// Reads (and consumes) up to `count` bytes of the current entry's body.
    func read(upTo count: Int) async throws -> [UInt8] {
        let toRead = min(count, remainingInCurrentEntry)
        let data = try await source.read(upTo: toRead)
        remainingInCurrentEntry -= data.count
        return data
    }

    private static func parseOctal(_ bytes: ArraySlice<UInt8>) -> Int? {
        Int(String(decoding: bytes, as: UTF8.self), radix: 8)
    }
}
