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
//  these can be produced locally by the private AOSKit framework — no external
//  anisette server is needed (unlike Linux/Windows clients).
//
//  We load AOSKit at runtime via dlopen + the Objective-C runtime so the app does
//  not have to link a private framework at build time.
//

import Foundation
import CryptoKit

/// Produces anisette headers required by Apple's modern authentication endpoints.
final class AnisetteProvider {
    static let shared = AnisetteProvider()

    private let deviceIdKey = "anisette.deviceId"
    private var aosKitLoaded = false

    private init() {}

    // MARK: - Public API

    /// Full set of anisette headers to attach to an auth request.
    /// OTP headers (X-Apple-I-MD / -M) come from AOSKit; the rest are derived locally.
    func headers() -> [String: String] {
        var result = otpHeaders()

        result["X-Apple-I-MD-RINFO"] = "17106176"
        result["X-Apple-I-MD-LU"] = localUserHash()
        result["X-Mme-Device-Id"] = deviceID()
        result["X-Apple-I-Client-Time"] = currentClientTime()
        result["X-Apple-I-TimeZone"] = TimeZone.current.abbreviation() ?? "UTC"
        result["X-Apple-Locale"] = Locale.current.identifier
        result["X-Mme-Client-Info"] = Self.clientInfo

        return result
    }

    /// `true` when the AOSKit-backed OTP headers were produced successfully.
    /// If this is `false`, anisette is unavailable (likely a sandbox/entitlement issue).
    var isOTPAvailable: Bool {
        !otpHeaders().isEmpty
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
        if let md = dict["X-Apple-MD"] as? String { headers["X-Apple-I-MD"] = md }
        if let mdm = dict["X-Apple-MD-M"] as? String { headers["X-Apple-I-MD-M"] = mdm }

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
            let err = String(cString: dlerror())
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

    /// Mirrors the Apple Configurator / AOSKit client-info string shape.
    private static let clientInfo =
        "<MacBookPro18,3> <Mac OS X;15.2;24C5089c> <com.apple.AOSKit/282 (com.apple.accountsd/113)>"
}
