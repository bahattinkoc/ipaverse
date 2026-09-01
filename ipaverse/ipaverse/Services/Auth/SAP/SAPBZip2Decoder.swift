//
//  SAPBZip2Decoder.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Streaming bzip2 decompression backed by the system libbz2 (bzlib.h,
//  linked the same way libz.tbd already is — see ipaverse.xcodeproj's
//  Frameworks phase). Apple's `Payload` archive inside the Mavericks update
//  package is a raw bzip2 stream missing its 4-byte magic at the exact
//  offset ipatool's reference implementation seeks to, so callers prepend
//  "BZh9" before the first chunk — mirrored from
//  internal/sap/assets/assets.go's `io.MultiReader(bytes.NewReader([]byte{
//  'B','Z','h','9'}), raw)`.
//

import Foundation

enum SAPBZip2Error: LocalizedError {
    case initFailed(Int32)
    case decompressFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .initFailed(let code): "Failed to initialize bzip2 decoder (code \(code))"
        case .decompressFailed(let code): "bzip2 decompression failed (code \(code))"
        }
    }
}

/// Pulls compressed chunks on demand (async) and yields decompressed output
/// incrementally, so the caller (``SAPByteSource``) never has to buffer the
/// full decompressed archive. All libbz2 calls themselves are synchronous;
/// only the upstream chunk fetch suspends.
final class SAPBZip2Decoder {
    private var stream = bz_stream()
    private var finished = false
    private var pendingInput: [UInt8] = []
    private let pullCompressed: () async throws -> [UInt8]

    init(pullCompressed: @escaping () async throws -> [UInt8]) throws {
        self.pullCompressed = pullCompressed

        let result = BZ2_bzDecompressInit(&stream, 0, 0)
        guard result == BZ_OK else {
            throw SAPBZip2Error.initFailed(result)
        }
    }

    deinit {
        BZ2_bzDecompressEnd(&stream)
    }

    /// Produces up to `maxOutput` bytes of decompressed data. Returns an
    /// empty array once the bzip2 stream is fully consumed (BZ_STREAM_END).
    func next(maxOutput: Int) async throws -> [UInt8] {
        if finished { return [] }

        var output = [UInt8](repeating: 0, count: maxOutput)
        var totalOut = 0

        while totalOut < maxOutput {
            if pendingInput.isEmpty {
                let chunk = try await pullCompressed()
                if chunk.isEmpty {
                    // Genuinely nothing left upstream. This is a real
                    // end-of-stream (not an error) — the caller treats an
                    // empty result as EOF.
                    finished = true
                    break
                }
                pendingInput = chunk
            }

            let (bytesIn, bytesOut, code) = decompressOnce(into: &output, outputOffset: totalOut, maxOutput: maxOutput)

            if bytesIn > 0 {
                pendingInput.removeFirst(bytesIn)
            }

            totalOut += bytesOut

            if code == BZ_STREAM_END {
                // Apple's payload here concatenates multiple independent
                // bzip2 members one after another (observed directly: the
                // first two target files decoded correctly, then decoding
                // silently stopped right at a member boundary). Whatever is
                // left in `pendingInput` after this call is the start of
                // the next member, so reinitialize and keep going — only a
                // subsequent empty pull (handled above) means we've reached
                // the true end of the archive.
                BZ2_bzDecompressEnd(&stream)
                stream = bz_stream()
                let reinit = BZ2_bzDecompressInit(&stream, 0, 0)
                guard reinit == BZ_OK else {
                    throw SAPBZip2Error.initFailed(reinit)
                }
                continue
            }

            guard code == BZ_OK else {
                throw SAPBZip2Error.decompressFailed(code)
            }
        }

        return Array(output.prefix(totalOut))
    }

    /// One synchronous call into libbz2 with whatever input/output space is
    /// currently available. Returns bytes consumed from `pendingInput`,
    /// bytes written into `output` (from `outputOffset`), and libbz2's
    /// status code.
    private func decompressOnce(
        into output: inout [UInt8],
        outputOffset: Int,
        maxOutput: Int
    ) -> (bytesIn: Int, bytesOut: Int, code: Int32) {
        pendingInput.withUnsafeMutableBufferPointer { inBuffer -> (Int, Int, Int32) in
            output.withUnsafeMutableBufferPointer { outBuffer -> (Int, Int, Int32) in
                inBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: inBuffer.count) { inPtr -> (Int, Int, Int32) in
                    let outCapacity = maxOutput - outputOffset
                    return outBuffer.baseAddress!.advanced(by: outputOffset).withMemoryRebound(to: CChar.self, capacity: outCapacity) { outPtr -> (Int, Int, Int32) in
                        stream.next_in = inPtr
                        stream.avail_in = UInt32(inBuffer.count)
                        stream.next_out = outPtr
                        stream.avail_out = UInt32(outCapacity)

                        let code = BZ2_bzDecompress(&stream)

                        let bytesIn = inBuffer.count - Int(stream.avail_in)
                        let bytesOut = outCapacity - Int(stream.avail_out)

                        return (bytesIn, bytesOut, code)
                    }
                }
            }
        }
    }
}
