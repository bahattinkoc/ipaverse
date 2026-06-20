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
    @State private var showMismatchConfirm = false

    let appName: String

    init(ipaPath: String, appName: String, activeAppleID: String? = nil) {
        self._viewModel = StateObject(wrappedValue: DeviceInstallVM(ipaPath: ipaPath, activeAppleID: activeAppleID))
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
        .alert("Different Apple ID", isPresented: $showMismatchConfirm) {
            Button("Install Anyway", role: .destructive) { viewModel.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mismatchMessage)
        }
    }

    private var mismatchMessage: String {
        let bound = viewModel.boundAppleID ?? "?"
        let active = viewModel.activeAppleID ?? "?"
        return """
        This app was downloaded with the Apple ID \(bound). FairPlay-protected apps only launch on a device signed into that same Apple ID — installing it on a device using a different account will crash the app on launch.

        The account active in ipaverse right now is \(active).
        """
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
        } else if viewModel.hasInstallError, let msg = viewModel.errorMessage {
            errorView(message: msg)
        } else if viewModel.devices.isEmpty {
            emptyView
        } else {
            deviceList
        }
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Installation Failed")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(NSColor.separatorColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(message, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Back to Devices") { viewModel.clearError() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("Connect an iPhone or iPad via USB, unlock it, and tap Trust on the device. For Wi-Fi installs, pair once over cable, then enable \u{201C}Connect via network\u{201D} in Xcode \u{203A} Devices.")
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
            if viewModel.accountMismatch {
                accountMismatchBanner
            }

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
                DeviceRow(
                    device: device,
                    isSelected: viewModel.selectedDevice == device,
                    isCompatible: viewModel.isCompatible(device),
                    requirement: viewModel.requirementNote(for: device)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.isCompatible(device) { viewModel.selectedDevice = device }
                }
            }
            .listStyle(.plain)
        }
    }

    private var accountMismatchBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bound to a different Apple ID")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Downloaded with \(viewModel.boundAppleID ?? "?"). It will crash on launch unless the target device is signed into that Apple ID.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.top, 8)
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
                    if viewModel.accountMismatch {
                        showMismatchConfirm = true
                    } else {
                        viewModel.install()
                    }
                } label: {
                    Label("Install", systemImage: "iphone.and.arrow.forward")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.selectedDevice == nil ||
                    viewModel.isInstalling ||
                    viewModel.devices.isEmpty ||
                    (viewModel.selectedDevice.map { !viewModel.isCompatible($0) } ?? false)
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
    let isCompatible: Bool
    let requirement: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.stateIcon)
                .font(.title3)
                .foregroundColor(device.isAvailable && isCompatible ? .accentColor : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(isCompatible ? .primary : .secondary)
                    transportBadge
                }
                Text("\(device.displayModel) · iOS \(device.osVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let requirement {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(requirement)
                    }
                    .font(.caption2)
                    .foregroundColor(.orange)
                }
            }

            Spacer()

            if isSelected && isCompatible {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .opacity(isCompatible ? 1 : 0.6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var transportBadge: some View {
        if device.transport != .unknown {
            HStack(spacing: 3) {
                Image(systemName: device.transport.icon)
                Text(device.transport.label)
            }
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color(NSColor.quaternaryLabelColor).opacity(0.5))
            )
        }
    }
}
