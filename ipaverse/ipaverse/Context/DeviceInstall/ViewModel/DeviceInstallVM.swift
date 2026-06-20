//
//  DeviceInstallVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 25.05.2026.
//

import SwiftUI

@MainActor
final class DeviceInstallVM: ObservableObject {

    enum State: Equatable {
        case idle
        case loadingDevices
        case installing(message: String)
        case success(deviceName: String)
        case error(String)
    }

    @Published var devices: [ConnectedDevice] = []
    @Published var selectedDevice: ConnectedDevice?
    @Published var state: State = .idle

    /// Minimum iOS version the IPA declares (Info.plist `MinimumOSVersion`).
    /// nil when unknown — in that case we don't block any device.
    @Published var minimumOSVersion: String?

    let ipaPath: String

    init(ipaPath: String) {
        self.ipaPath = ipaPath
    }

    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    var installMessage: String? {
        if case .installing(let msg) = state { return msg }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = state { return msg }
        return nil
    }

    var successMessage: String? {
        if case .success(let name) = state { return name }
        return nil
    }

    /// True when the install just failed (as opposed to "no devices found",
    /// which is surfaced by the empty state).
    var hasInstallError: Bool {
        if case .error = state, !devices.isEmpty { return true }
        return false
    }

    // MARK: - Compatibility

    /// Whether `device`'s iOS version meets the IPA's MinimumOSVersion.
    /// Unknown minimum (or unknown device version) is treated as compatible.
    func isCompatible(_ device: ConnectedDevice) -> Bool {
        guard let minOS = minimumOSVersion, !minOS.isEmpty,
              !device.osVersion.isEmpty else { return true }
        return Self.compareVersions(device.osVersion, minOS) != .orderedAscending
    }

    /// Warning to show for an incompatible device, or nil if it's fine.
    func requirementNote(for device: ConnectedDevice) -> String? {
        guard !isCompatible(device), let minOS = minimumOSVersion else { return nil }
        return "Requires iOS \(minOS) or later"
    }

    /// Component-wise numeric version compare ("9.0" < "10.0", "12.1.2" ok).
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    func clearError() {
        if case .error = state { state = .idle }
    }

    /// Pick the best default selection: prefer a connected device that can run
    /// the app, then any compatible one, then any connected device.
    private func preferredDevice(from list: [ConnectedDevice]) -> ConnectedDevice? {
        if let d = list.first(where: { $0.isAvailable && isCompatible($0) }) { return d }
        if let d = list.first(where: { isCompatible($0) }) { return d }
        if let d = list.first(where: { $0.isAvailable }) { return d }
        return list.first
    }

    // MARK: - Load

    func loadDevices() async {
        state = .loadingDevices
        let path = ipaPath
        let needMinOS = (minimumOSVersion == nil)

        let result = await Task.detached { () -> ([ConnectedDevice], String?) in
            let devices = (try? DeviceInstaller.listDevices()) ?? []
            let minOS: String? = needMinOS
                ? ((try? IPAResigner.loadInfoPlist(ipaPath: path))?["MinimumOSVersion"]) as? String
                : nil
            return (devices, minOS)
        }.value

        if needMinOS, let minOS = result.1, !minOS.isEmpty {
            minimumOSVersion = minOS
        }

        devices = result.0.filter { $0.isIPhone }
        selectedDevice = preferredDevice(from: devices)
        state = .idle

        if devices.isEmpty {
            state = .error(DeviceInstallerError.noDevicesFound.localizedDescription)
        }
    }

    // MARK: - Install

    func install() {
        guard let device = selectedDevice else { return }

        guard isCompatible(device) else {
            state = .error(
                "This version requires iOS \(minimumOSVersion ?? "?") or later, "
                + "but \(device.name) is running iOS \(device.osVersion). "
                + "Choose a device on a newer iOS, or download a version that supports iOS \(device.osVersion)."
            )
            return
        }

        let path = ipaPath

        Task.detached { [self] in
            do {
                try DeviceInstaller.install(ipaPath: path, device: device) { message in
                    Task { @MainActor [self] in self.state = .installing(message: message) }
                }
                await MainActor.run { self.state = .success(deviceName: device.name) }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
    }
}
