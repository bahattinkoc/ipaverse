import Foundation

enum MacPackageError: LocalizedError {
    case missingDPInfo, conflictingMetadata, invalidHardwareID, invalidDecryptedPackage

    var errorDescription: String? {
        switch self {
        case .missingDPInfo: "Apple did not provide the decryption information (dpInfo) for this Mac package. Retry the download."
        case .conflictingMetadata: "Apple returned inconsistent Mac package metadata. The download was not saved."
        case .invalidHardwareID: "The device identifier could not be used to decrypt the Mac package."
        case .invalidDecryptedPackage: "The decrypted Mac package failed integrity verification. The previous file has been preserved."
        }
    }
}

enum MacPackage {
    static let chunkSize = 0x8000

    /// Retain Apple's opaque dpInfo, including duplicate identical values, but never
    /// choose arbitrarily between conflicting keys or mix mobile and Mac packages.
    static func dpInfo(from item: [String: Any]) throws -> Data {
        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let platform = (metadata["software-platform"] as? String ?? "").lowercased()
        let product = (metadata["product-type"] as? String ?? "").lowercased()
        guard platform != "ios", !(platform.isEmpty && product == "ios-app") else {
            throw MacPackageError.conflictingMetadata
        }
        var result: Data?
        for entry in item["sinfs"] as? [[String: Any]] ?? [] {
            let data = entry["dpInfo"] as? Data
            if let mobile = entry["sinf"] as? Data, !mobile.isEmpty, data?.isEmpty != false {
                throw MacPackageError.conflictingMetadata
            }
            guard let data, !data.isEmpty else { continue }
            guard data.count <= 16 * 1024 * 1024 else { throw MacPackageError.conflictingMetadata }
            if let result, result != data { throw MacPackageError.conflictingMetadata }
            result = data
        }
        guard let result else { throw MacPackageError.missingDPInfo }
        return result
    }

    /// Decode the exact GUID used in the metadata request, not a second hardware lookup.
    static func hardwareID(guid: String) throws -> [UInt8] {
        let hex = Array(guid.utf8)
        guard !hex.isEmpty, hex.count <= 40, hex.count.isMultiple(of: 2),
              hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw MacPackageError.invalidHardwareID
        }
        return stride(from: 0, to: hex.count, by: 2).map {
            UInt8(String(decoding: hex[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        }
    }

    static func prepare(_ staged: URL, hardwareID: [UInt8], dpInfo: Data) async throws {
        try Task.checkCancellation()
        let bundle = try await SAPAssets.load()
        let image = try await SAPAssets.loadStoreAgent()
        try Task.checkCancellation()
        let agent = try SAPStoreAgent(bundle: bundle, image: image, hardwareID: hardwareID, dpInfo: dpInfo)
        defer { try? agent.close() }
        try decryptStaged(staged, decrypt: agent.decrypt, close: agent.close)
    }

    /// Keep encrypted and decrypted staging separate. Close and verify before replacing
    /// even the staging file; PackageDownload publishes it only after this succeeds.
    static func decryptStaged(_ staged: URL, decrypt: (Data) throws -> Data, close: () throws -> Void) throws {
        let decoded = AtomicFile.stagingURL(for: staged)
        defer { try? FileManager.default.removeItem(at: decoded) }
        guard FileManager.default.createFile(atPath: decoded.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let source = try FileHandle(forReadingFrom: staged)
        defer { try? source.close() }
        let target = try FileHandle(forWritingTo: decoded)
        defer { try? target.close() }
        try decryptStream(read: { try source.read(upToCount: $0) ?? Data() },
                          write: { try target.write(contentsOf: $0) }, decrypt: decrypt)
        try target.close()
        try source.close()
        try close()
        try validate(decoded)
        try AtomicFile.commit(decoded, to: staged)
    }

    /// Fill each 32 KiB block even when the reader returns short reads. StoreAgent
    /// maintains state across calls, so only the final block may be partial.
    static func decryptStream(read: (Int) throws -> Data, write: (Data) throws -> Void,
                              decrypt: (Data) throws -> Data) throws {
        while true {
            try Task.checkCancellation()
            var block = Data()
            while block.count < chunkSize {
                try Task.checkCancellation()
                let part = try read(chunkSize - block.count)
                guard !part.isEmpty else { break }
                guard part.count <= chunkSize - block.count else { throw MacPackageError.invalidDecryptedPackage }
                block.append(part)
            }
            guard !block.isEmpty else { return }
            let output = try decrypt(block)
            guard output.count == block.count else { throw MacPackageError.invalidDecryptedPackage }
            try Task.checkCancellation()
            try write(output)
            if block.count < chunkSize { return }
        }
    }

    /// libxar checks the TOC and entry checksums without extracting or running the package.
    static func validate(_ file: URL) throws {
        try Task.checkCancellation()
        guard let archive = ipaverse_xar_open_read(file.path) else { throw MacPackageError.invalidDecryptedPackage }
        defer { xar_close(archive) }
        guard let iterator = xar_iter_new() else { throw MacPackageError.invalidDecryptedPackage }
        defer { xar_iter_free(iterator) }
        var entry = xar_file_first(archive, iterator)
        var count = 0
        while let current = entry {
            try Task.checkCancellation()
            guard xar_verify(archive, current) == 0 else { throw MacPackageError.invalidDecryptedPackage }
            count += 1
            entry = xar_file_next(iterator)
        }
        guard count > 0 else { throw MacPackageError.invalidDecryptedPackage }
    }
}
