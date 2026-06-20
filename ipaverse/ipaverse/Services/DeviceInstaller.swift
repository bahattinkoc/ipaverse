//
//  DeviceInstaller.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 25.05.2026.
//

import Foundation

// MARK: - Models

/// How the device is reached by `devicectl`. Wireless installs work the same as
/// wired ones once the device has been paired over cable and "Connect via
/// network" is enabled in Xcode.
enum DeviceTransport: Sendable {
    case wired
    case wireless
    case unknown

    /// Maps `connectionProperties.transportType` reported by devicectl.
    init(rawTransportType: String) {
        switch rawTransportType.lowercased() {
        case "wired", "usb":
            self = .wired
        case "localnetwork", "network", "wifi":
            self = .wireless
        default:
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .wired: "USB"
        case .wireless: "Wi-Fi"
        case .unknown: ""
        }
    }

    var icon: String {
        switch self {
        case .wired: "cable.connector"
        case .wireless: "wifi"
        case .unknown: "bolt.horizontal"
        }
    }
}

struct ConnectedDevice: Identifiable, Hashable, Sendable {
    let id: String       // UDID
    let name: String
    let model: String
    let osVersion: String
    let platform: String
    let isAvailable: Bool
    let transport: DeviceTransport

    var isIPhone: Bool { platform == "iOS" || platform == "iPadOS" }
    var displayModel: String { model.isEmpty ? platform : model }

    var stateIcon: String {
        isAvailable ? "iphone" : "iphone.slash"
    }
}

enum DeviceInstallerError: LocalizedError {
    case devicectlNotFound
    case noDevicesFound
    case jsonParseError
    case installFailed(String)
    case processFailure(String)

    var errorDescription: String? {
        switch self {
        case .devicectlNotFound:
            "xcrun devicectl not found. Xcode 15 or later is required."
        case .noDevicesFound:
            "No connected iOS/iPadOS devices found. Make sure your device is connected, unlocked, and trusted."
        case .jsonParseError:
            "Failed to parse device list."
        case .installFailed(let msg):
            "Installation failed: \(msg)"
        case .processFailure(let msg):
            msg
        }
    }
}

// MARK: - DeviceInstaller

struct DeviceInstaller {

    // MARK: - List

    static func listDevices() throws -> [ConnectedDevice] {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipaverse_devices_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let (_, _) = try runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "list", "devices", "--json-output", tmpURL.path]
        )

        guard let data = try? Data(contentsOf: tmpURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            throw DeviceInstallerError.jsonParseError
        }

        return devices.compactMap { parse(device: $0) }
    }

    // MARK: - Install

    static func install(
        ipaPath: String,
        device: ConnectedDevice,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        // devicectl/coredeviced runs in its own sandbox and cannot read files in
        // TCC-protected locations (~/Desktop, ~/Documents, ~/Downloads), which
        // fails with CoreDeviceError 1005 ("unable to create bookmark data").
        // Stage the app in the per-user temp dir (not TCC-protected) first.
        progress("Preparing app...")
        let staged = try stageForInstall(ipaPath: ipaPath)
        defer { try? FileManager.default.removeItem(at: staged.cleanupDir) }

        progress("Connecting to \(device.name)...")

        let (out, err) = try runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "install", "app",
                        "--device", device.id,
                        staged.appPath]
        )

        let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.localizedCaseInsensitiveContains("error") || combined.localizedCaseInsensitiveContains("fail") {
            throw DeviceInstallerError.installFailed(combined.isEmpty ? "Unknown error" : combined)
        }

        progress("Installed on \(device.name)")
    }

    // MARK: - Private helpers

    /// Extracts the IPA into a fresh per-user temp directory and returns the path
    /// to the `.app` bundle inside it (plus the staging dir to clean up).
    ///
    /// devicectl natively installs a `.app` bundle ("This command installs an app
    /// bundle (with a .app extension)"). When handed an `.ipa` it unzips the
    /// archive internally with a decoder that, for entries whose names aren't
    /// flagged UTF-8, mangles non-ASCII bytes into "?". Apps with a non-ASCII
    /// bundle name (e.g. "Tıkla Gelsin.app", where "ı" is the two UTF-8 bytes
    /// C4 B1) then unpack as "T??kla Gelsin.app" — the binary no longer matches
    /// CFBundleExecutable, so the bundle is invalid and install fails with
    /// CoreDeviceError 3000/3002 ("Failed to get the identifier").
    ///
    /// Extracting with `ditto` onto APFS decodes those names as UTF-8 correctly,
    /// so we hand devicectl the resulting `.app` directory and it never re-decodes
    /// the archive. The temp dir is also outside TCC-protected locations, avoiding
    /// the sandbox read failures (CoreDeviceError 1005) that plain paths hit.
    private static func stageForInstall(ipaPath: String) throws -> (appPath: String, cleanupDir: URL) {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: ipaPath)

        guard fm.fileExists(atPath: source.path) else {
            throw DeviceInstallerError.installFailed("IPA file not found at \(source.path)")
        }

        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("ipaverse_install_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // ditto preserves UTF-8 filenames correctly; unlike devicectl's internal
        // unzip it does not mangle non-ASCII bundle names.
        try runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", source.path, stagingDir.path]
        )

        let payloadURL = stagingDir.appendingPathComponent("Payload", isDirectory: true)
        let appURL = (try? fm.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" })

        guard let appURL else {
            try? fm.removeItem(at: stagingDir)
            throw DeviceInstallerError.installFailed("No .app bundle found inside the IPA's Payload folder.")
        }

        return (appURL.path, stagingDir)
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String]) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.useUTF8Locale()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw DeviceInstallerError.devicectlNotFound
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
            throw DeviceInstallerError.processFailure(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (out, err)
    }

    private static func parse(device: [String: Any]) -> ConnectedDevice? {
        guard
            let hw = device["hardwareProperties"] as? [String: Any],
            let conn = device["connectionProperties"] as? [String: Any],
            let devProps = device["deviceProperties"] as? [String: Any]
        else { return nil }

        let udid = hw["udid"] as? String ?? ""
        guard !udid.isEmpty else { return nil }

        let name = devProps["name"] as? String ?? "Unknown Device"
        let model = hw["marketingName"] as? String ?? ""
        let osVersion = devProps["osVersionNumber"] as? String ?? ""
        let platform = hw["platform"] as? String ?? ""
        let tunnelState = conn["tunnelState"] as? String ?? ""
        let transportType = conn["transportType"] as? String ?? ""

        // Consider disconnected as available — install still works over cable
        let isAvailable = tunnelState != "unavailable"

        return ConnectedDevice(
            id: udid,
            name: name,
            model: model,
            osVersion: osVersion,
            platform: platform,
            isAvailable: isAvailable,
            transport: DeviceTransport(rawTransportType: transportType)
        )
    }
}
