//
//  FridaRuntime.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//
//  Downloads and caches the (large, ~100MB+) Frida binaries on first use
//  instead of bundling them into ipaverse.app, so the vast majority of users
//  who never touch the Security Testing features don't pay for their size.
//  Used by FridaDumper (host-side libfrida-core.dylib) and DylibInjector
//  (target-side FridaGadget.dylib).

import Foundation
import CryptoKit

enum FridaRuntimeError: LocalizedError {
    case downloadFailed(String)
    case integrityCheckFailed(String)
    case dlopenFailed(String)
    case symbolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): "Couldn't download Frida components: \(msg)"
        case .integrityCheckFailed(let name): "Downloaded \(name) failed its integrity check. The file was removed; retry the download."
        case .dlopenFailed(let msg): "Couldn't load libfrida-core.dylib: \(msg)"
        case .symbolNotFound(let name): "libfrida-core.dylib is missing expected symbol \(name) — it may be corrupted or the wrong version. Try deleting \(FridaRuntime.cacheDirectory.path) and retrying."
        }
    }
}

struct FridaRuntime {

    private struct Asset {
        let byteCount: Int64
        let sha256: String
    }

    private final class DownloadResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<URL, Error>?

        func store(_ result: Result<URL, Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func load() -> Result<URL, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Bump alongside Vendor/frida and Vendor/frida-core when updating Frida.
    static let version = "17.17.0"

    static let releaseBaseURL = URL(string: "https://github.com/bahattinkoc/ipaverse/releases/download/frida-deps-\(version)/")!

    /// These values are pinned to the assets in the matching GitHub release. Updating Frida
    /// requires updating both the version and these digests in the same change.
    private static let assets: [String: Asset] = [
        "FridaGadget.dylib": Asset(
            byteCount: 39_686_480,
            sha256: "1c5855bacfbe2e2ed3029b15a44110967609416676c2e3f9e998a83b1c3a4bf5"
        ),
        "libfrida-core.dylib": Asset(
            byteCount: 103_558_496,
            sha256: "1595293340424cd2ec4d8ba2fc4f80a67b6be0e8595b814adefb64b53d1154ba"
        )
    ]

    private static let cacheLock = NSLock()

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ipaverse/Frida", isDirectory: true)
    }

    static func ensureCoreLibrary(progress: @escaping (String) -> Void) throws -> URL {
        try ensureFile(name: "libfrida-core.dylib", progress: progress)
    }

    static func ensureGadget(progress: @escaping (String) -> Void) throws -> URL {
        try ensureFile(name: "FridaGadget.dylib", progress: progress)
    }

    // MARK: - Download + cache

    private static func ensureFile(name: String, progress: @escaping (String) -> Void) throws -> URL {
        guard let asset = assets[name] else {
            throw FridaRuntimeError.integrityCheckFailed(name)
        }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        let dest = cacheDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            if try verifyFile(at: dest, asset: asset) {
                return dest
            }
            progress("Cached \(name) failed verification; downloading a clean copy...")
            try FileManager.default.removeItem(at: dest)
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        progress("Downloading \(name) (one-time, ~\(name.hasSuffix("core.dylib") ? "100" : "40")MB)...")

        let url = releaseBaseURL.appendingPathComponent(name)
        let tempURL = try downloadSync(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard try verifyFile(at: tempURL, asset: asset) else {
            throw FridaRuntimeError.integrityCheckFailed(name)
        }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func verifyFile(at url: URL, asset: Asset) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              Int64(fileSize) == asset.byteCount else {
            return false
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var hasher = SHA256()
        while true {
            let chunk = try file.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.sha256
    }

    private static func downloadSync(from url: URL) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = DownloadResultBox()

        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error {
                resultBox.store(.failure(FridaRuntimeError.downloadFailed(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                resultBox.store(.failure(FridaRuntimeError.downloadFailed("Server returned HTTP \(status) for \(url.lastPathComponent)")))
                return
            }
            guard let tempURL else {
                resultBox.store(.failure(FridaRuntimeError.downloadFailed("No data received")))
                return
            }

            // URLSession deletes its temp file as soon as this closure returns,
            // so move it somewhere stable before handing the path back.
            let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: tempURL, to: stable)
                resultBox.store(.success(stable))
            } catch {
                resultBox.store(.failure(FridaRuntimeError.downloadFailed(error.localizedDescription)))
            }
        }
        task.resume()
        semaphore.wait()
        guard let result = resultBox.load() else {
            throw FridaRuntimeError.downloadFailed("Unknown error")
        }
        return try result.get()
    }

    // MARK: - dlopen helper

    static func dlopenLibrary(at url: URL) throws -> UnsafeMutableRawPointer {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw FridaRuntimeError.dlopenFailed(String(cString: dlerror()))
        }
        return handle
    }

    static func dlsymRequired(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> UnsafeMutableRawPointer {
        guard let sym = dlsym(handle, name) else {
            throw FridaRuntimeError.symbolNotFound(name)
        }
        return sym
    }
}
