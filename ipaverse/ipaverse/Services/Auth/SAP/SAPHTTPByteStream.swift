//
//  SAPHTTPByteStream.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Chunked, ranged HTTP byte source for the Apple SAP asset download.
//  ipatool streams the response body directly (`howett.net/ranger` +
//  `io.Reader` composition) as a single open-ended request; in practice,
//  a single open-ended `Range: bytes=start-` request against
//  swcdn.apple.com's CDN gets silently capped well short of the file's end
//  (observed directly: the response completes cleanly, with no error, but
//  far less data than the file actually has past that offset). Instead,
//  this issues bounded, fixed-size range requests sequentially, advancing
//  the offset by exactly how much came back each time, and only stops once
//  the server reports (via `Content-Range: bytes a-b/total`) that `total`
//  has been reached, or returns 416 Range Not Satisfiable.
//

import Foundation

enum SAPHTTPByteStreamError: LocalizedError {
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code): "Apple software update server returned unexpected status \(code)"
        }
    }
}

/// Sequential, resumable ranged-HTTP reader starting at a fixed offset.
final class SAPHTTPByteStream {
    private static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private static let windowSize: UInt64 = 64 << 20 // 64 MB per request

    private let url: URL
    private let session: URLSession
    private var currentOffset: UInt64
    private var totalLength: UInt64?
    private var reachedEnd = false

    private var pending: [UInt8] = []
    private var pendingOffset = 0

    init(url: URL, rangeStart: UInt64, session: URLSession = .shared) {
        self.url = url
        self.currentOffset = rangeStart
        self.session = session
    }

    /// Pulls the next chunk of at most `maxLength` bytes, issuing further
    /// ranged requests as needed. Returns an empty array once the server
    /// confirms there is nothing left past the current offset.
    func next(maxLength: Int = 1 << 16) async throws -> [UInt8] {
        if pendingOffset >= pending.count {
            try await fetchNextWindow()
        }

        guard pendingOffset < pending.count else { return [] }

        let take = min(maxLength, pending.count - pendingOffset)
        let result = Array(pending[pendingOffset..<(pendingOffset + take)])
        pendingOffset += take
        return result
    }

    /// No persistent connection is held between calls, so there is nothing
    /// to tear down — kept for symmetry with callers that stop pulling once
    /// they have everything they need.
    func cancel() {
        reachedEnd = true
    }

    private func fetchNextWindow() async throws {
        pending = []
        pendingOffset = 0

        if reachedEnd { return }
        if let total = totalLength, currentOffset >= total {
            reachedEnd = true
            return
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=\(currentOffset)-\(currentOffset + Self.windowSize - 1)", forHTTPHeaderField: "Range")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SAPHTTPByteStreamError.unexpectedStatus(-1)
        }

        if http.statusCode == 416 {
            reachedEnd = true
            return
        }

        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw SAPHTTPByteStreamError.unexpectedStatus(http.statusCode)
        }

        if totalLength == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/") {
            totalLength = UInt64(range[range.index(after: slash)...])
        }

        if data.isEmpty {
            reachedEnd = true
            return
        }

        pending = Array(data)
        currentOffset += UInt64(data.count)
    }
}
