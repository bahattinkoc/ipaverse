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

    // MARK: - Load

    func loadDevices() async {
        state = .loadingDevices
        let result = await Task.detached {
            (try? DeviceInstaller.listDevices()) ?? []
        }.value

        devices = result.filter { $0.isIPhone }
        selectedDevice = devices.first(where: { $0.isAvailable }) ?? devices.first
        state = .idle

        if devices.isEmpty {
            state = .error(DeviceInstallerError.noDevicesFound.localizedDescription)
        }
    }

    // MARK: - Install

    func install() {
        guard let device = selectedDevice else { return }
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
