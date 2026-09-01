//
//  SAPAssets.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Fetches the four genuine Apple x86-64 Mach-O binaries the SAP (Sign App
//  Store Protocol) emulator runs: CommerceKit, CommerceCore, CoreFP (Core
//  FairPlay) and CoreFP.icxs. These ship inside a real macOS 10.9
//  (Mavericks) combo update package that Apple still serves at a fixed
//  URL — the exact byte offsets, sizes, and SHA-256 digests below are
//  reused verbatim from ipatool's internal/sap/assets (MIT licensed,
//  github.com/majd/ipatool), which found them by prior reverse engineering.
//  This file does not re-derive them; it re-implements the same extraction
//  in Swift: a ranged XAR lookup for the `Payload` entry (see
//  ``SAPXARReader``), a bzip2 stream missing its own magic bytes at a fixed
//  offset (see ``SAPBZip2Decoder``), and an old ASCII CPIO archive inside
//  that (see ``SAPCPIOReader``).
//

import Foundation
import CryptoKit

struct SAPAssetBundle {
    let commerceKit: Data
    let commerceCore: Data
    let coreFP: Data
    let coreFPICXS: Data
}

enum SAPAssetsError: LocalizedError {
    case invalidCacheEntry(String)
    case integrityCheckFailed(String)
    case missingFiles([String])

    var errorDescription: String? {
        switch self {
        case .invalidCacheEntry(let name): "Cached Apple SAP asset \(name) is invalid"
        case .integrityCheckFailed(let name): "Apple SAP asset \(name) failed integrity verification"
        case .missingFiles(let names): "Apple software update package is missing expected files: \(names.joined(separator: ", "))"
        }
    }
}

/// Downloads (or loads from cache) the four Apple binaries ``SAPMachine``
/// loads into the emulator.
enum SAPAssets {
    private struct FileSpec {
        let name: String
        let path: String
        let size: Int
        let digestHex: String
    }

    private static let updateURL = URL(string: "https://swcdn.apple.com/content/downloads/27/34/041-98128-A_SYPWICN3KH/5dqkl4rqgbsr18yzy61yeie9g3cmjc5hiv/OSXUpd10.9.pkg")!
    private static let payloadEntryName = "Payload"
    private static let payloadBZOffset: UInt64 = 0x352F40D5
    private static let payloadCPIOSkip = 0x3A4

    private static let requiredFiles: [FileSpec] = [
        FileSpec(
            name: "CommerceKit",
            path: "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/CommerceKit",
            size: 3271840,
            digestHex: "b84ff12c21987856c0a17b78f1ad82b73195a6dec5f3b208a17d245555a2c8a2"
        ),
        FileSpec(
            name: "CommerceCore",
            path: "./System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Frameworks/CommerceCore.framework/Versions/A/CommerceCore",
            size: 207744,
            digestHex: "c5401e57402230f3c876409d295319ddf1e61287bc882683c5d61277be7bc1f2"
        ),
        FileSpec(
            name: "CoreFP",
            path: "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP",
            size: 29014912,
            digestHex: "f19141336be4198d0f8991bb00017c915efc7aeaece36c345f7faa1237ea6074"
        ),
        FileSpec(
            name: "CoreFP.icxs",
            path: "./System/Library/PrivateFrameworks/CoreFP.framework/Versions/A/CoreFP.icxs",
            size: 5288352,
            digestHex: "473e78af86979f5bd4f6269561caf770b3d16c098d918846eeac8cdd2fe6566a"
        ),
    ]

    // MARK: - Load

    static func load() async throws -> SAPAssetBundle {
        let directory = try cacheDirectory()

        if let bundle = try? readCache(at: directory) {
            return bundle
        }

        let bundle = try await download()
        try? writeCache(bundle, to: directory)
        return bundle
    }

    // MARK: - Download

    private static func download() async throws -> SAPAssetBundle {
        let (absoluteOffset, _) = try await SAPXARReader.locate(name: payloadEntryName, in: updateURL)
        let rangeStart = absoluteOffset + payloadBZOffset

        let httpStream = SAPHTTPByteStream(url: updateURL, rangeStart: rangeStart)
        defer { httpStream.cancel() }

        var prependedMagic = false
        let bzip2 = try SAPBZip2Decoder(pullCompressed: {
            if !prependedMagic {
                prependedMagic = true
                let magic: [UInt8] = Array("BZh9".utf8)
                let firstChunk = try await httpStream.next()
                return magic + firstChunk
            }
            return try await httpStream.next()
        })

        let byteSource = SAPByteSource(pull: { try await bzip2.next(maxOutput: 1 << 16) })
        try await byteSource.skip(payloadCPIOSkip)

        let cpio = SAPCPIOReader(source: byteSource)
        var wanted = Dictionary(uniqueKeysWithValues: requiredFiles.map { ($0.path, $0) })
        var found: [String: Data] = [:]

        // `wanted` shrinks by one on every match, so comparing `found.count`
        // against it (rather than the fixed `requiredFiles.count`) would
        // make the loop exit after finding exactly half of the targets.
        while found.count < requiredFiles.count {
            guard let entry = try await cpio.next() else { break }

            guard let spec = wanted[entry.path] else {
                _ = try await cpio.read(upTo: entry.size)
                continue
            }

            var collected = Data()
            collected.reserveCapacity(entry.size)
            while collected.count < entry.size {
                let chunk = try await cpio.read(upTo: entry.size - collected.count)
                if chunk.isEmpty { break }
                collected.append(contentsOf: chunk)
            }

            found[spec.name] = collected
            wanted.removeValue(forKey: entry.path)
        }

        let missing = requiredFiles.map(\.name).filter { found[$0] == nil }
        guard missing.isEmpty else {
            throw SAPAssetsError.missingFiles(missing)
        }

        let bundle = SAPAssetBundle(
            commerceKit: found["CommerceKit"]!,
            commerceCore: found["CommerceCore"]!,
            coreFP: found["CoreFP"]!,
            coreFPICXS: found["CoreFP.icxs"]!
        )
        try validate(bundle)
        return bundle
    }

    // MARK: - Validation

    private static func validate(_ bundle: SAPAssetBundle) throws {
        for spec in requiredFiles {
            let data = files(of: bundle)[spec.name]!
            guard data.count == spec.size else {
                throw SAPAssetsError.integrityCheckFailed(spec.name)
            }

            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == spec.digestHex else {
                throw SAPAssetsError.integrityCheckFailed(spec.name)
            }
        }
    }

    private static func files(of bundle: SAPAssetBundle) -> [String: Data] {
        [
            "CommerceKit": bundle.commerceKit,
            "CommerceCore": bundle.commerceCore,
            "CoreFP": bundle.coreFP,
            "CoreFP.icxs": bundle.coreFPICXS,
        ]
    }

    // MARK: - Cache

    private static func cacheDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return root.appendingPathComponent("ipaverse/sap/apple-assets-v1", isDirectory: true)
    }

    private static func readCache(at directory: URL) throws -> SAPAssetBundle {
        var files: [String: Data] = [:]
        for spec in requiredFiles {
            let fileURL = directory.appendingPathComponent(spec.name)
            let data = try Data(contentsOf: fileURL)
            guard data.count == spec.size else {
                throw SAPAssetsError.invalidCacheEntry(spec.name)
            }
            files[spec.name] = data
        }

        let bundle = SAPAssetBundle(
            commerceKit: files["CommerceKit"]!,
            commerceCore: files["CommerceCore"]!,
            coreFP: files["CoreFP"]!,
            coreFPICXS: files["CoreFP.icxs"]!
        )
        try validate(bundle)
        return bundle
    }

    private static func writeCache(_ bundle: SAPAssetBundle, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        for (name, data) in files(of: bundle) {
            let fileURL = directory.appendingPathComponent(name)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
