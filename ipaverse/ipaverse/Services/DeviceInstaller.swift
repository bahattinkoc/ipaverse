//
//  DeviceInstaller.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 25.05.2026.
//

import Foundation

// MARK: - Models

struct ConnectedDevice: Identifiable, Hashable, Sendable {
    let id: String       // UDID
    let name: String
    let model: String
    let osVersion: String
    let platform: String
    let isAvailable: Bool

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
        // Stage the IPA in the per-user temp dir (not TCC-protected) first.
        progress("Preparing app...")
        let stagedPath = try stageForInstall(ipaPath: ipaPath)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: stagedPath).deletingLastPathComponent()) }

        progress("Connecting to \(device.name)...")

        let (out, err) = try runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "install", "app",
                        "--device", device.id,
                        stagedPath]
        )

        let combined = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.localizedCaseInsensitiveContains("error") || combined.localizedCaseInsensitiveContains("fail") {
            throw DeviceInstallerError.installFailed(combined.isEmpty ? "Unknown error" : combined)
        }

        progress("Installed on \(device.name)")
    }

    // MARK: - Private helpers

    /// Copies the IPA into a fresh per-user temp directory and returns the copy's
    /// path, so `devicectl` can read it without hitting TCC/sandbox restrictions.
    private static func stageForInstall(ipaPath: String) throws -> String {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: ipaPath)

        guard fm.fileExists(atPath: source.path) else {
            throw DeviceInstallerError.installFailed("IPA file not found at \(source.path)")
        }

        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("ipaverse_install_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let dest = stagingDir.appendingPathComponent(source.lastPathComponent)
        try fm.copyItem(at: source, to: dest)
        return dest.path
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String]) throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

        // Consider disconnected as available — install still works over cable
        let isAvailable = tunnelState != "unavailable"

        return ConnectedDevice(
            id: udid,
            name: name,
            model: model,
            osVersion: osVersion,
            platform: platform,
            isAvailable: isAvailable
        )
    }
}
