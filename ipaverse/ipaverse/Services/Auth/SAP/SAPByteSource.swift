//
//  SAPByteSource.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  A pull-based async byte buffer: something upstream (the bzip2 decoder)
//  produces chunks on demand, and ``SAPCPIOReader`` consumes exact byte
//  counts across chunk boundaries. This is the Swift equivalent of Go's
//  `io.Reader` composition in ipatool's asset pipeline (bzip2.Reader wraps
//  the HTTP body, cpio.Reader wraps that) — network bytes are only pulled
//  as far as decompression and CPIO parsing actually need them.
//

import Foundation

/// Closure-driven pull source. Return an empty array to signal end-of-stream.
final class SAPByteSource {
    private var buffer: [UInt8] = []
    private var reachedEnd = false
    private let pull: () async throws -> [UInt8]

    init(pull: @escaping () async throws -> [UInt8]) {
        self.pull = pull
    }

    /// Reads exactly `count` bytes, pulling more upstream chunks as needed.
    /// Returns fewer bytes only once the upstream source is exhausted.
    func read(upTo count: Int) async throws -> [UInt8] {
        while buffer.count < count && !reachedEnd {
            let chunk = try await pull()
            if chunk.isEmpty {
                reachedEnd = true
                break
            }
            buffer.append(contentsOf: chunk)
        }

        let take = min(count, buffer.count)
        let result = Array(buffer.prefix(take))
        buffer.removeFirst(take)
        return result
    }

    /// Discards exactly `count` bytes without retaining them.
    func skip(_ count: Int) async throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try await read(upTo: min(remaining, 1 << 16))
            if chunk.isEmpty { throw SAPByteSourceError.unexpectedEndOfStream }
            remaining -= chunk.count
        }
    }
}

enum SAPByteSourceError: LocalizedError {
    case unexpectedEndOfStream

    var errorDescription: String? {
        switch self {
        case .unexpectedEndOfStream: "Apple SAP asset stream ended before the expected data was read"
        }
    }
}
