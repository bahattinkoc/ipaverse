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

enum FridaRuntimeError: LocalizedError {
    case downloadFailed(String)
    case dlopenFailed(String)
    case symbolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let msg): "Couldn't download Frida components: \(msg)"
        case .dlopenFailed(let msg): "Couldn't load libfrida-core.dylib: \(msg)"
        case .symbolNotFound(let name): "libfrida-core.dylib is missing expected symbol \(name) — it may be corrupted or the wrong version. Try deleting \(FridaRuntime.cacheDirectory.path) and retrying."
        }
    }
}

struct FridaRuntime {

    /// Bump alongside Vendor/frida and Vendor/frida-core when updating Frida.
    static let version = "17.17.0"

    static let releaseBaseURL = URL(string: "https://github.com/bahattinkoc/ipaverse/releases/download/frida-deps-\(version)/")!

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
        let dest = cacheDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        progress("Downloading \(name) (one-time, ~\(name.hasSuffix("core.dylib") ? "100" : "40")MB)...")

        let url = releaseBaseURL.appendingPathComponent(name)
        let tempURL = try downloadSync(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func downloadSync(from url: URL) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(FridaRuntimeError.downloadFailed("Unknown error"))

        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(FridaRuntimeError.downloadFailed(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                result = .failure(FridaRuntimeError.downloadFailed("Server returned HTTP \(status) for \(url.lastPathComponent)"))
                return
            }
            guard let tempURL else {
                result = .failure(FridaRuntimeError.downloadFailed("No data received"))
                return
            }

            // URLSession deletes its temp file as soon as this closure returns,
            // so move it somewhere stable before handing the path back.
            let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: tempURL, to: stable)
                result = .success(stable)
            } catch {
                result = .failure(FridaRuntimeError.downloadFailed(error.localizedDescription))
            }
        }
        task.resume()
        semaphore.wait()
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
