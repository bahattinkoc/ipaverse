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
    /// Height of the preflight-checks panel below the resize handle. Dragged
    /// by the user via `resizeHandle` — the device list above absorbs the rest
    /// of the fixed-height sheet automatically (it has no explicit height).
    @State private var checksPanelHeight: CGFloat = 230
    @State private var checksPanelDragStartHeight: CGFloat?

    private let checksPanelMinHeight: CGFloat = 48
    private let checksPanelMaxHeight: CGFloat = 420

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
            resizeHandle
            ZStack {
                if viewModel.isCheckingPreflight {
                    ProgressView("Checking installation readiness…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        PreflightChecksView(checks: viewModel.preflightChecks)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
            }.frame(height: checksPanelHeight)
            Divider()
            footer
        }
        .frame(width: 560, height: 590)
        .onAppear { Task { await viewModel.loadDevices() } }
        .alert("Different Apple ID", isPresented: $showMismatchConfirm) {
            Button("Install Anyway", role: .destructive) { viewModel.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mismatchMessage)
        }
    }

    /// Draggable divider between the device list and the preflight-checks
    /// panel — drag up to grow the checks panel, down to shrink it.
    private var resizeHandle: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color(NSColor.tertiaryLabelColor))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = checksPanelDragStartHeight ?? checksPanelHeight
                    checksPanelDragStartHeight = start
                    let proposed = start - value.translation.height
                    checksPanelHeight = min(max(proposed, checksPanelMinHeight), checksPanelMaxHeight)
                }
                .onEnded { _ in checksPanelDragStartHeight = nil }
        )
    }

    private var mismatchMessage: String {
        let bound = viewModel.boundAppleID ?? "?"
        let active = viewModel.activeAppleID ?? "?"
        return """
        This app was downloaded with the Apple ID \(bound). Launch may require its associated App Store license. ipaverse cannot verify the App Store account on your device.

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
        } else if !viewModel.hasAnyDevices {
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

            List(selection: $viewModel.selectedDevice) {
                if viewModel.physicalDevices.isEmpty {
                    Text("No physical iOS devices connected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.physicalDevices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: viewModel.selectedDevice == device,
                            isCompatible: viewModel.isCompatible(device),
                            requirement: viewModel.requirementNote(for: device)
                        )
                        .tag(device)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if viewModel.isCompatible(device) { viewModel.selectedDevice = device }
                        }
                    }
                }

                if !viewModel.simulatorDevices.isEmpty {
                    Section {
                        ForEach(viewModel.simulatorDevices) { device in
                            DeviceRow(
                                device: device,
                                isSelected: viewModel.selectedDevice == device,
                                isCompatible: viewModel.isCompatible(device),
                                requirement: viewModel.requirementNote(for: device)
                            )
                            .tag(device)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if viewModel.isCompatible(device) { viewModel.selectedDevice = device }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Simulators — Experimental")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("Patches the app to run on Simulator. Store purchases, push notifications, and camera/Face ID-dependent apps may still not work.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                        .textCase(nil)
                    }
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
                    viewModel.preflightBlocksInstallation ||
                    viewModel.selectedDevice == nil ||
                    viewModel.isInstalling ||
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
            Image(systemName: device.isSimulator ? "apps.iphone" : device.stateIcon)
                .font(.title3)
                .foregroundColor(device.isSimulator ? .purple : (device.isAvailable && isCompatible ? .accentColor : .secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(isCompatible ? .primary : .secondary)
                    if device.isSimulator { simulatorBadge } else { transportBadge }
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

    private var simulatorBadge: some View {
        Text("SIMULATOR")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.purple)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.purple.opacity(0.12)))
    }
}
