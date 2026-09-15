//
//  SimulatorInstaller.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 16.09.2026.
//
//  Installs a downloaded App Store IPA onto an iOS Simulator. EXPERIMENTAL.
//
//  App Store IPAs are iphoneos/arm64 device binaries, ad-hoc-signed for a real
//  provisioning profile. The Simulator runtime's dyld refuses to load anything
//  whose Mach-O load commands aren't tagged for the "iossim" platform, and
//  SpringBoard (SBMainWorkspace) separately refuses to even open a scene for
//  an app whose Info.plist CFBundleSupportedPlatforms says "iPhoneOS" instead
//  of "iPhoneSimulator" — confirmed empirically: patching only the Mach-O tag
//  installs fine but SpringBoard denies the launch with "scene update failed"
//  until the Info.plist is patched too. Real device provisioning-profile
//  signatures are also rejected outright; the Simulator only accepts ad-hoc.
//
//  This clears exactly those two gates (Mach-O platform + Info.plist platform
//  + signature) and nothing else. It does NOT make the app itself Simulator-
//  compatible: anything gated on a StoreKit receipt, push notifications, or
//  hardware the Simulator doesn't model (Camera, Face ID, ...) can still
//  crash or misbehave after install. Verified end-to-end against a locally
//  built, unencrypted iphoneos-platform app (a genuine App Store IPA's
//  binary looks the same once ipaverse's own FairPlay decryption has run —
//  see IPAPatcher); a still-encrypted IPA (cryptid=1) cannot run here or
//  anywhere off-device regardless of this patch, same as on a real device.
//

import Foundation

enum SimulatorInstallerError: LocalizedError {
    case appBundleNotFound
    case bootFailed(String)
    case machOPatchFailed(binary: String, detail: String)
    case codesignFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound: "No .app bundle found inside the IPA's Payload folder."
        case .bootFailed(let msg): "Could not boot the Simulator: \(msg)"
        case .machOPatchFailed(let binary, let detail): "Could not patch \(binary) for Simulator: \(detail)"
        case .codesignFailed(let msg): "Signing for Simulator failed: \(msg)"
        case .installFailed(let msg): "Simulator install failed: \(msg)"
        }
    }
}

enum SimulatorInstaller {
    static func install(
        ipaPath: String,
        device: ConnectedDevice,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        let fm = FileManager.default
        progress("Preparing app...")
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("ipaverse_sim_install_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        try runProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", ipaPath, stagingDir.path])

        let payloadURL = stagingDir.appendingPathComponent("Payload", isDirectory: true)
        guard let appURL = (try? fm.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            throw SimulatorInstallerError.appBundleNotFound
        }

        progress("Booting \(device.name)...")
        bootIfNeeded(device: device)

        progress("Patching for Simulator...")
        let minOS = minimumOSVersion(appURL: appURL)
        try retagForSimulator(appURL: appURL, minOS: minOS)
        try retagSupportedPlatforms(appURL: appURL)

        progress("Signing...")
        try adHocSign(appURL: appURL)

        progress("Installing on \(device.name)...")
        try runProcess(executable: "/usr/bin/xcrun", arguments: ["simctl", "install", device.id, appURL.path])

        // Best-effort: install succeeding is the contract this call makes: a
        // launch failure here (app crashes on its own for an unrelated reason,
        // e.g. missing StoreKit receipt) shouldn't be reported as install failure.
        if let bundleID = bundleIdentifier(appURL: appURL) {
            progress("Launching...")
            _ = try? runProcess(executable: "/usr/bin/xcrun", arguments: ["simctl", "launch", device.id, bundleID])
        }

        progress("Installed on \(device.name)")
    }

    // MARK: - Boot

    private static func bootIfNeeded(device: ConnectedDevice) {
        do {
            _ = try runProcess(executable: "/usr/bin/xcrun", arguments: ["simctl", "boot", device.id])
        } catch {
            // "Unable to boot device in current state: Booted" just means it's
            // already running — anything else surfaces via bootstatus below.
        }
        _ = try? runProcess(executable: "/usr/bin/xcrun", arguments: ["simctl", "bootstatus", device.id, "-b"])
        // Bring the Simulator UI forward so the user sees the app appear.
        // Its app bundle was renamed (Simulator.app -> DeviceHub.app in Xcode
        // 27); the bundle identifier is the stable way to find it either way,
        // with the pre-27 app name as a fallback on older Xcode installs.
        if (try? runProcess(executable: "/usr/bin/open", arguments: ["-b", "com.apple.dt.Devices"])) == nil {
            _ = try? runProcess(executable: "/usr/bin/open", arguments: ["-a", "Simulator"])
        }
    }

    // MARK: - Mach-O platform retagging

    /// `vtool -set-build-version iossim <minos> <sdk> -replace` on every Mach-O
    /// in the bundle: main executable, embedded framework/dylib binaries, and
    /// app extension executables. Loose resource files are never touched —
    /// each target is resolved from a bundle's own CFBundleExecutable (or is a
    /// bare .dylib, which has no wrapping bundle) rather than sniffed by magic
    /// bytes, so nothing outside the known bundle shapes is at risk.
    private static func retagForSimulator(appURL: URL, minOS: String) throws {
        for target in machOTargets(in: appURL) {
            do {
                try runProcess(executable: "/usr/bin/vtool", arguments: [
                    "-set-build-version", "iossim", minOS, minOS, "-replace", "-output", target.path, target.path
                ])
            } catch {
                throw SimulatorInstallerError.machOPatchFailed(binary: target.lastPathComponent, detail: error.localizedDescription)
            }
        }
    }

    /// SpringBoard's SBMainWorkspace separately checks Info.plist's
    /// CFBundleSupportedPlatforms and denies the launch ("scene update
    /// failed") for a bundle still declaring "iPhoneOS" even once every
    /// Mach-O is correctly tagged — patch the main app and any nested
    /// app extensions (widgets, etc.), which SpringBoard also registers.
    private static func retagSupportedPlatforms(appURL: URL) throws {
        var bundles = [appURL]
        if let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let item as URL in enumerator where ["appex", "xpc"].contains(item.pathExtension) {
                bundles.append(item)
            }
        }
        for bundle in bundles {
            let infoPlistURL = bundle.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: infoPlistURL),
                  var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            plist["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
            guard let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { continue }
            try? updated.write(to: infoPlistURL)
        }
    }

    /// Every Mach-O binary in the bundle, resolved from bundle structure
    /// (never by sniffing file contents): the main executable, each
    /// Frameworks/*.framework's and PlugIns/*.appex's own CFBundleExecutable,
    /// and any loose Frameworks/*.dylib.
    private static func machOTargets(in appURL: URL) -> [URL] {
        var targets: [URL] = []
        if let main = bundleExecutableURL(bundleURL: appURL) { targets.append(main) }

        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let item = enumerator.nextObject() as? URL {
                switch item.pathExtension {
                case "framework", "appex", "xpc":
                    if let exe = bundleExecutableURL(bundleURL: item) { targets.append(exe) }
                case "dylib":
                    targets.append(item)
                default:
                    break
                }
            }
        }
        return targets
    }

    private static func bundleExecutableURL(bundleURL: URL) -> URL? {
        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty else { return nil }
        let url = bundleURL.appendingPathComponent(executable)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func minimumOSVersion(appURL: URL) -> String {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["MinimumOSVersion"] as? String, !version.isEmpty else { return "12.0" }
        return version
    }

    private static func bundleIdentifier(appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    // MARK: - Signing

    /// Ad-hoc sign every nested bundle inside-out, then the app itself — the
    /// Simulator has no provisioning-profile concept at all, only a valid
    /// ad-hoc (`-`) signature is required. Old device signatures/profile are
    /// removed first since codesign won't overwrite a signature that still
    /// references a different (now-stale) Team ID in place.
    private static func adHocSign(appURL: URL) throws {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator where item.lastPathComponent == "_CodeSignature" {
                try? fm.removeItem(at: item)
            }
        }
        try? fm.removeItem(at: appURL.appendingPathComponent("embedded.mobileprovision"))

        var targets: [URL] = []
        if let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let item = enumerator.nextObject() as? URL {
                if ["framework", "dylib", "appex", "xpc"].contains(item.pathExtension) { targets.append(item) }
            }
        }
        targets.append(appURL)
        targets.sort { $0.pathComponents.count > $1.pathComponents.count }
        for target in targets {
            do {
                try runProcess(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", target.path])
            } catch {
                throw SimulatorInstallerError.codesignFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Process helper

    @discardableResult
    private static func runProcess(executable: String, arguments: [String]) throws -> String {
        do {
            return String(decoding: try ProcessRunner.run(executable, arguments).output, as: UTF8.self)
        } catch let ProcessRunner.Failure.failed(_, _, detail) {
            throw SimulatorInstallerError.installFailed(detail)
        }
    }
}
