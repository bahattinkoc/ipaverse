//
//  PartialZIPReader.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import Foundation

enum PartialZIPError: LocalizedError {
    case fileNotFound
    case infoPlistNotFound
    case invalidZIPStructure
    case decompressionFailed
    case noVersionInfo

    var errorDescription: String? {
        switch self {
        case .fileNotFound: "Remote file not found"
        case .infoPlistNotFound: "Info.plist not found in IPA"
        case .invalidZIPStructure: "Invalid ZIP structure"
        case .decompressionFailed: "Decompression failed"
        case .noVersionInfo: "No version info in Info.plist"
        }
    }
}

struct PartialZIPReader {

    let url: URL
    private let session: URLSession

    init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func readVersionMetadata() async throws -> VersionDisplayInfo {
        let fileSize = try await fetchFileSize()
        let eocd = try await findEOCD(fileSize: fileSize)
        let entries = try await readCentralDirectory(offset: eocd.cdOffset, size: eocd.cdSize)
        guard let entry = entries.first(where: { isMainAppInfoPlist($0.name) }) else {
            throw PartialZIPError.infoPlistNotFound
        }
        let plistData = try await readFileData(entry: entry)
        return try parseVersionMetadata(from: plistData, entry: entry)
    }

    // MARK: - File Size

    private func fetchFileSize() async throws -> Int {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range") else {
            throw PartialZIPError.fileNotFound
        }
        // "bytes 0-0/SIZE"
        let parts = contentRange.components(separatedBy: "/")
        guard let last = parts.last,
              let size = Int(last.trimmingCharacters(in: .whitespaces)) else {
            throw PartialZIPError.fileNotFound
        }
        return size
    }

    // MARK: - EOCD

    private struct EOCDInfo {
        let cdOffset: Int
        let cdSize: Int
    }

    private static let eocdSignature: UInt32 = 0x06054b50

    private func findEOCD(fileSize: Int) async throws -> EOCDInfo {
        // Try the minimum 22-byte EOCD first (no ZIP comment — covers nearly all IPAs)
        let minData = try await rangeRequest(offset: fileSize - 22, length: 22)
        if minData.count == 22, minData.readUInt32LE(at: 0) == Self.eocdSignature {
            return parseEOCDRecord(minData, at: 0)
        }

        // Full search (ZIP comment up to 65535 bytes)
        let searchSize = min(65535 + 22, fileSize)
        let searchData = try await rangeRequest(offset: fileSize - searchSize, length: searchSize)
        var i = searchData.count - 22
        while i >= 0 {
            if searchData.readUInt32LE(at: i) == Self.eocdSignature {
                return parseEOCDRecord(searchData, at: i)
            }
            i -= 1
        }
        throw PartialZIPError.invalidZIPStructure
    }

    private func parseEOCDRecord(_ data: Data, at i: Int) -> EOCDInfo {
        EOCDInfo(
            cdOffset: Int(data.readUInt32LE(at: i + 16)),
            cdSize: Int(data.readUInt32LE(at: i + 12))
        )
    }

    // MARK: - Central Directory

    private struct CDEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let modTime: UInt16
        let modDate: UInt16
    }

    private static let cdSignature: UInt32 = 0x02014b50

    private func readCentralDirectory(offset: Int, size: Int) async throws -> [CDEntry] {
        let data = try await rangeRequest(offset: offset, length: size)
        var entries: [CDEntry] = []
        var pos = 0

        while pos + 46 <= data.count {
            guard data.readUInt32LE(at: pos) == Self.cdSignature else { break }

            let compressionMethod = data.readUInt16LE(at: pos + 10)
            let modTime = data.readUInt16LE(at: pos + 12)
            let modDate = data.readUInt16LE(at: pos + 14)
            let compressedSize = data.readUInt32LE(at: pos + 20)
            let uncompressedSize = data.readUInt32LE(at: pos + 24)
            let fileNameLen = Int(data.readUInt16LE(at: pos + 28))
            let extraLen = Int(data.readUInt16LE(at: pos + 30))
            let commentLen = Int(data.readUInt16LE(at: pos + 32))
            let localHeaderOffset = data.readUInt32LE(at: pos + 42)

            let nameStart = pos + 46
            let nameEnd = nameStart + fileNameLen
            guard nameEnd <= data.count else { break }

            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            entries.append(CDEntry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                modTime: modTime,
                modDate: modDate
            ))
            pos = nameEnd + extraLen + commentLen
        }
        return entries
    }

    // MARK: - Local File Data

    private static let localHeaderSignature: UInt32 = 0x04034b50

    private func readFileData(entry: CDEntry) async throws -> Data {
        let headerData = try await rangeRequest(offset: Int(entry.localHeaderOffset), length: 30)
        guard headerData.readUInt32LE(at: 0) == Self.localHeaderSignature else {
            throw PartialZIPError.invalidZIPStructure
        }

        let fileNameLen = Int(headerData.readUInt16LE(at: 26))
        let extraLen = Int(headerData.readUInt16LE(at: 28))
        let dataOffset = Int(entry.localHeaderOffset) + 30 + fileNameLen + extraLen
        let compressedData = try await rangeRequest(offset: dataOffset, length: Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:   // STORED
            return compressedData
        case 8:   // DEFLATED
            return try inflateRaw(compressedData, uncompressedSize: Int(entry.uncompressedSize))
        default:
            throw PartialZIPError.decompressionFailed
        }
    }

    // MARK: - Raw DEFLATE Decompression (Darwin zlib, windowBits = -15)

    private func inflateRaw(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard !data.isEmpty, uncompressedSize > 0 else { return Data() }

        var output = Data(count: uncompressedSize)
        var stream = z_stream()

        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PartialZIPError.decompressionFailed
        }

        let status: Int32 = data.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                )
                stream.avail_in = uInt(data.count)
                stream.next_out = outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.avail_out = uInt(uncompressedSize)
                return inflate(&stream, Z_FINISH)
            }
        }

        inflateEnd(&stream)
        guard status == Z_STREAM_END else { throw PartialZIPError.decompressionFailed }
        return output
    }

    // MARK: - Parsing

    private func isMainAppInfoPlist(_ name: String) -> Bool {
        let parts = name.components(separatedBy: "/")
        return parts.count == 3
            && parts[0] == "Payload"
            && parts[1].hasSuffix(".app")
            && parts[2] == "Info.plist"
    }

    private func parseVersionMetadata(from data: Data, entry: CDEntry) throws -> VersionDisplayInfo {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw PartialZIPError.noVersionInfo
        }

        let versionString = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
        guard let version = versionString, !version.isEmpty else {
            throw PartialZIPError.noVersionInfo
        }

        let releaseDate = parseReleaseDate(from: plist)
            ?? modDateFromZIP(modTime: entry.modTime, modDate: entry.modDate)

        return VersionDisplayInfo(versionString: version, releaseDate: releaseDate)
    }

    private func parseReleaseDate(from plist: [String: Any]) -> Date? {
        for key in ["releaseDate", "ReleaseDate"] {
            guard let value = plist[key] else { continue }
            if let str = value as? String {
                let iso = ISO8601DateFormatter()
                if let d = iso.date(from: str) { return d }

                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                for format in ["MMMM d, yyyy", "yyyy-MM-dd", "EEEE, MMMM d, yyyy"] {
                    df.dateFormat = format
                    if let d = df.date(from: str) { return d }
                }
            }
            if let ts = value as? Int { return Date(timeIntervalSince1970: TimeInterval(ts)) }
            if let ts = value as? Double { return Date(timeIntervalSince1970: ts) }
        }
        return nil
    }

    private func modDateFromZIP(modTime: UInt16, modDate: UInt16) -> Date? {
        let year = Int((modDate >> 9) & 0x7F) + 1980
        let month = Int((modDate >> 5) & 0x0F)
        let day = Int(modDate & 0x1F)
        let hour = Int((modTime >> 11) & 0x1F)
        let minute = Int((modTime >> 5) & 0x3F)
        let second = Int(modTime & 0x1F) * 2
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return Calendar.current.date(from: comps)
    }

    // MARK: - HTTP Range Request

    private func rangeRequest(offset: Int, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206 || http.statusCode == 200 else {
            throw PartialZIPError.fileNotFound
        }
        return data
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b0 = UInt32(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt32(self[index(startIndex, offsetBy: offset + 1)])
        let b2 = UInt32(self[index(startIndex, offsetBy: offset + 2)])
        let b3 = UInt32(self[index(startIndex, offsetBy: offset + 3)])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let b0 = UInt16(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt16(self[index(startIndex, offsetBy: offset + 1)])
        return b0 | (b1 << 8)
    }
}
