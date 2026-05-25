//
//  DeviceInstallView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 25.05.2026.
//

import SwiftUI

struct DeviceInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: DeviceInstallVM

    let appName: String

    init(ipaPath: String, appName: String) {
        self._viewModel = StateObject(wrappedValue: DeviceInstallVM(ipaPath: ipaPath))
        self.appName = appName
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 420, height: 320)
        .onAppear { Task { await viewModel.loadDevices() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Install to Device")
                    .font(.headline)
                Text(appName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if case .loadingDevices = viewModel.state {
            ProgressView("Searching for connected devices...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .success(let name) = viewModel.state {
            successView(deviceName: name)
        } else if viewModel.devices.isEmpty {
            emptyView
        } else {
            deviceList
        }
    }

    private func successView(deviceName: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Installed Successfully")
                .font(.title3)
                .fontWeight(.semibold)
            Text("App was installed on \(deviceName)")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No iOS Devices Found")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Connect an iPhone or iPad via USB, unlock it, and tap Trust on the device.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Refresh") { Task { await viewModel.loadDevices() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Device")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.loadDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isInstalling)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            List(viewModel.devices, selection: $viewModel.selectedDevice) { device in
                DeviceRow(device: device, isSelected: viewModel.selectedDevice == device)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.selectedDevice = device }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let msg = viewModel.installMessage {
                ProgressView().scaleEffect(0.75)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let err = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if case .success = viewModel.state {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isInstalling)

                Button {
                    viewModel.install()
                } label: {
                    Label("Install", systemImage: "iphone.and.arrow.forward")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.selectedDevice == nil ||
                    viewModel.isInstalling ||
                    viewModel.devices.isEmpty
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

// MARK: - DeviceRow

private struct DeviceRow: View {
    let device: ConnectedDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.stateIcon)
                .font(.title3)
                .foregroundColor(device.isAvailable ? .accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(device.displayModel) · iOS \(device.osVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
