import Foundation

enum PackageDownloadError: LocalizedError {
    case http(Int), incomplete, invalidPackage, preparation(String)
    var errorDescription: String? {
        switch self {
        case .http(let status): return "Download server returned HTTP \(status). Retry the download to obtain a fresh URL."
        case .incomplete: return "The download is incomplete. The previous file has been preserved."
        case .invalidPackage: return "The downloaded file is not a supported application package."
        case .preparation(let reason): return "The package could not be prepared: \(reason). The previous file has been preserved."
        }
    }
}

enum PackageDownload {
    static func fetch(request: URLRequest, session: URLSession, destination: URL,
                      progress: ((Double, Int64, Int64) -> Void)?,
                      prepare: (URL) throws -> Void) async throws {
        // The async download convenience API does not deliver download-delegate
        // progress through its task delegate. Count streamed bytes explicitly.
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try validateResponse(response)
        let staged = AtomicFile.stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: staged)
        defer { try? handle.close() }
        let total = max(0, response.expectedContentLength)
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        var reportedBytes = false
        progress?(0, 0, total)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = ProcessInfo.processInfo.systemUptime
                if !reportedBytes || now - lastUpdate >= 0.1 {
                    progress?(total > 0 ? min(1, Double(written) / Double(total)) : 0, written, total)
                    lastUpdate = now
                    reportedBytes = true
                }
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try handle.close()
        try validateTransfer(staged, response: response)
        // EOF supplies a real total even if the server omitted Content-Length.
        progress?(1, written, total > 0 ? total : written)
        try Task.checkCancellation()
        try prepare(staged)
        try AtomicFile.commit(staged, to: destination)
    }

    /// Separate from transport so failure/commit behavior can be tested without Apple services.
    static func finish(temporary: URL, response: URLResponse, destination: URL,
                       prepare: (URL) throws -> Void) throws {
        try validateTransfer(temporary, response: response)
        try Task.checkCancellation()
        let staged = AtomicFile.stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: temporary, to: staged)
        try prepare(staged)
        try AtomicFile.commit(staged, to: destination)
    }

    private static func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PackageDownloadError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private static func validateTransfer(_ file: URL, response: URLResponse) throws {
        try validateResponse(response)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, response.expectedContentLength < 0 || Int64(size) == response.expectedContentLength else {
            throw PackageDownloadError.incomplete
        }
    }

    static func validate(_ file: URL, isMacPackage: Bool) throws {
        try Task.checkCancellation()
        if isMacPackage {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("xar!".utf8) else { throw PackageDownloadError.invalidPackage }
            _ = try ProcessRunner.run("/usr/bin/xar", ["-tf", file.path])
        } else {
            try IPASecurityScanner.validateArchiveLimits(ipaPath: file.path)
            _ = try ProcessRunner.run("/usr/bin/unzip", ["-tqq", file.path])
            guard let bundleID = try IPAResigner.loadInfoPlist(ipaPath: file.path)["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { throw PackageDownloadError.invalidPackage }
        }
    }
}
