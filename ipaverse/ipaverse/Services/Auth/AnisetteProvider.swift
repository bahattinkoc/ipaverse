//
//  AnisetteProvider.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.15.2025.
//
//  Generates Apple "anisette" authentication headers natively on macOS.
//
//  Apple migrated App Store / Apple ID auth to GrandSlam (GSA), which requires
//  device-bound anisette headers (X-Apple-I-MD / X-Apple-I-MD-M, ...). On macOS
//  these can be produced locally by the private AOSKit framework when available.
//  A configured Anisette V3 service can supply a separate, persistent identity
//  on systems where AOSKit no longer returns OTPs (including macOS 27 beta).
//
//  We load AOSKit at runtime via dlopen + the Objective-C runtime so the app does
//  not have to link a private framework at build time.
//

import Foundation
import CryptoKit

/// One source and device identity for an entire login, including retries and 2FA.
actor AnisetteSession {
    private var initialHeaders: [String: String]?
    private let refresh: @Sendable () async throws -> [String: String]

    init(initialHeaders: [String: String], refresh: @escaping @Sendable () async throws -> [String: String]) {
        self.initialHeaders = initialHeaders
        self.refresh = refresh
    }

    func headers() async throws -> [String: String] {
        try Task.checkCancellation()
        if let initial = initialHeaders {
            initialHeaders = nil
            return try Self.validate(initial)
        }
        let fresh = try await refresh()
        try Task.checkCancellation()
        return try Self.validate(fresh)
    }

    static func validate(_ headers: [String: String]) throws -> [String: String] {
        let required = ["X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU",
                        "X-Apple-I-MD-RINFO", "X-Mme-Device-Id", "X-Mme-Client-Info"]
        guard required.allSatisfy({ headers[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }),
              headers.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else {
            throw AnisetteError.incompleteHeaders
        }
        return headers
    }
}

actor AnisetteProvider {
    static let shared = AnisetteProvider()
    private let local: @Sendable () throws -> [String: String]
    private let remote: any AnisetteRemoteSource
    private let store: any AnisetteIdentityStoring
    private var provisioning: [URL: Task<AnisetteIdentity, Error>] = [:]

    init(local: @escaping @Sendable () throws -> [String: String] = { try LocalAnisetteSource.shared.headers() },
         remote: any AnisetteRemoteSource = AnisetteV3Client(),
         store: any AnisetteIdentityStoring = AnisetteKeychainStore()) {
        self.local = local
        self.remote = remote
        self.store = store
    }

    func makeSession(configuration: AnisetteConfiguration = .load()) async throws -> AnisetteSession {
        try Task.checkCancellation()
        if configuration.mode != .remote {
            do {
                let first = try localHeaders()
                return AnisetteSession(initialHeaders: first) { try await self.localHeaders() }
            } catch {
                if configuration.mode == .local { throw error }
            }
        }
        try Task.checkCancellation()
        let server = try AnisetteConfiguration.serverURL(configuration.server)
        let identity = try await identity(for: server)
        let first = try AnisetteSession.validate(await remote.headers(for: identity))
        try Task.checkCancellation()
        let remote = self.remote
        return AnisetteSession(initialHeaders: first) { try await remote.headers(for: identity) }
    }

    private func localHeaders() throws -> [String: String] {
        try AnisetteSession.validate(local())
    }

    private func identity(for server: URL) async throws -> AnisetteIdentity {
        if let saved = try store.load(server: server) {
            let updated = saved.updatingClientIdentifier()
            if updated.clientInfo != saved.clientInfo { try store.save(updated) }
            return updated
        }
        if let pending = provisioning[server] { return try await pending.value }
        let remote = self.remote
        let store = self.store
        let task = Task {
            let identity = try await remote.provision(server: server)
            try store.save(identity)
            return identity
        }
        provisioning[server] = task
        defer { provisioning[server] = nil }
        return try await task.value
    }
}

/// Produces anisette headers required by Apple's modern authentication endpoints.
private final class LocalAnisetteSource: @unchecked Sendable {
    static let shared = LocalAnisetteSource()

    private let deviceIdKey = "anisette.deviceId"
    private var aosKitLoaded = false
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Full set of anisette headers to attach to an auth request.
    /// OTP headers (X-Apple-I-MD / -M) come from AOSKit; the rest are derived locally.
    func headers() throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result = otpHeaders()
        guard result["X-Apple-I-MD"]?.isEmpty == false,
              result["X-Apple-I-MD-M"]?.isEmpty == false else {
            throw AnisetteError.localUnavailable
        }

        result["X-Apple-I-MD-RINFO"] = "17106176"
        result["X-Apple-I-MD-LU"] = localUserHash()
        result["X-Mme-Device-Id"] = deviceID()
        result["X-Apple-I-Client-Time"] = currentClientTime()
        result["X-Apple-I-TimeZone"] = TimeZone.current.abbreviation() ?? "UTC"
        result["X-Apple-Locale"] = Locale.current.identifier
        result["X-Mme-Client-Info"] = AnisetteClientInfo.current

        return result
    }

    // MARK: - AOSKit OTP headers (X-Apple-I-MD / X-Apple-I-MD-M)

    private func otpHeaders() -> [String: String] {
        loadAOSKitIfNeeded()

        guard let cls = NSClassFromString("AOSUtilities") else {
            print("🔑 [Anisette] AOSUtilities class not found — AOSKit not loaded")
            return [:]
        }

        let selector = NSSelectorFromString("retrieveOTPHeadersForDSID:")
        let classObject = cls as AnyObject
        guard classObject.responds(to: selector) else {
            print("🔑 [Anisette] AOSUtilities does not respond to retrieveOTPHeadersForDSID:")
            return [:]
        }

        // DSID "-2" is the conventional "anonymous / current machine" value.
        guard let raw = classObject.perform(selector, with: "-2")?.takeUnretainedValue(),
              let dict = raw as? [String: Any] else {
            print("🔑 [Anisette] retrieveOTPHeadersForDSID: returned no data")
            return [:]
        }

        var headers: [String: String] = [:]
        if let md = (dict["X-Apple-MD"] ?? dict["X-Apple-I-MD"]) as? String { headers["X-Apple-I-MD"] = md }
        if let mdm = (dict["X-Apple-MD-M"] ?? dict["X-Apple-I-MD-M"]) as? String { headers["X-Apple-I-MD-M"] = mdm }

        if headers.isEmpty {
            print("🔑 [Anisette] OTP dict present but missing expected keys: \(dict.keys)")
        }
        return headers
    }

    private func loadAOSKitIfNeeded() {
        guard !aosKitLoaded else { return }
        let path = "/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit"
        if dlopen(path, RTLD_NOW) != nil {
            aosKitLoaded = true
        } else {
            let err = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
            print("🔑 [Anisette] dlopen(AOSKit) failed: \(err)")
        }
    }

    // MARK: - Locally derived headers

    /// Stable per-installation device UUID, persisted across launches.
    private func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }

    /// X-Apple-I-MD-LU: an opaque, stable hash tied to the local user.
    private func localUserHash() -> String {
        let source = Data(NSUserName().utf8)
        let digest = SHA256.hash(data: source)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private func currentClientTime() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

}
