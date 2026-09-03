//
//  ResigningView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import SwiftUI
import AppKit
import SwiftData

struct ResigningView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: ResigningVM
    /// Gates the offensive/identity-altering resign features (ATS bypass,
    /// Frida injection, Move to New Identity, framework removal) behind the
    /// same Evil Mode switch in the main window's toolbar.
    @AppStorage("evilModeEnabled") private var isEvilMode = false

    /// Called when the user clicks "Install to Device" after a successful sign.
    /// Passes the signed IPA path; caller should dismiss this sheet then open DeviceInstallView.
    var onInstall: ((String) -> Void)?

    init(downloadedApp: DownloadedApp, onInstall: ((String) -> Void)? = nil) {
        self._viewModel = StateObject(wrappedValue: ResigningVM(downloadedApp: downloadedApp))
        self.onInstall = onInstall
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabSelector
            Divider()
            tabContent
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 700, idealHeight: 780)
        .onAppear { Task { await viewModel.load() } }
        .onChange(of: viewModel.state) { _, newValue in
            guard case .signed(let outputPath) = newValue else { return }
            // Surface the resigned output in Downloaded, tagged, instead of
            // leaving it as an invisible file the user has to know to look for.
            let imported = try? IPAImporter.importIPA(at: URL(fileURLWithPath: outputPath), into: modelContext)
            imported?.sourceTag = "Resigned"
            try? modelContext.save()
        }
        .alert("FairPlay Encrypted", isPresented: Binding(
            get: { viewModel.isFairPlayWarning },
            set: { if !$0 { viewModel.cancelFairPlayWarning() } }
        )) {
            Button("Cancel", role: .cancel) { viewModel.cancelFairPlayWarning() }
            Button("Continue Anyway", role: .destructive) { viewModel.continueDespiteFairPlay() }
        } message: {
            Text("This IPA is encrypted with FairPlay DRM. Re-signing an encrypted binary will likely produce a broken app that cannot launch on the device.\n\nYou can still continue if you know the binary has been decrypted.")
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.state = .idle } }
        )) {
            Button("OK") { viewModel.state = .idle }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $viewModel.showIdentityMigrationSheet) {
            IdentityMigrationSheet(viewModel: viewModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: viewModel.downloadedApp.iconURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "app.fill").foregroundColor(.gray))
            }
            .frame(width: 40, height: 40)
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.downloadedApp.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.downloadedApp.bundleID)
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

    // MARK: - Tab selector

    private var tabSelector: some View {
        Picker("", selection: $viewModel.activeTab) {
            Text("Properties").tag(ResigningVM.Tab.properties)
            Text("Files").tag(ResigningVM.Tab.files)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        if case .loading = viewModel.state {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.activeTab == .properties {
            propertiesTab
        } else {
            filesTab
        }
    }

    // MARK: - Properties tab

    private var propertiesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info.plist")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    withAnimation { viewModel.isAddingKey.toggle() }
                } label: {
                    Label("Add Key", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            List {
                if viewModel.isAddingKey {
                    newKeyRow
                }

                ForEach($viewModel.plistEntries) { $entry in
                    PlistEntryRow(entry: $entry) {
                        viewModel.deleteEntry(entry)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var newKeyRow: some View {
        HStack(spacing: 8) {
            TextField("Key", text: $viewModel.newKeyName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            TextField("Value", text: $viewModel.newKeyValue)
                .textFieldStyle(.roundedBorder)
            Button("Add") { viewModel.commitNewKey() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button { withAnimation { viewModel.isAddingKey = false } } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Files tab

    private var filesTab: some View {
        Group {
            if viewModel.fileTree.isEmpty {
                Text("Failed to load file tree")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.fileTree, children: \.children) { node in
                    FileNodeRow(
                        node: node,
                        isReplaced: viewModel.fileReplacements[node.path] != nil,
                        isMarkedForRemoval: viewModel.frameworksToRemove.contains(node.frameworkName ?? ""),
                        isEvilMode: isEvilMode,
                        onReplace: { viewModel.replaceFile(at: node.path) },
                        onToggleRemove: node.frameworkName.map { name in
                            { viewModel.toggleFrameworkRemoval(name) }
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            signingConfigSection
            Divider()
            actionRow
        }
    }

    private var signingConfigSection: some View {
        VStack(spacing: 10) {
            // Provisioning Profile
            HStack(spacing: 10) {
                Label("Profile", systemImage: "seal")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)

                Button { viewModel.pickProvisioningProfile() } label: {
                    HStack(spacing: 6) {
                        if let url = viewModel.provisioningProfileURL {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                        } else {
                            Text("Select a provisioning profile...")
                                .foregroundColor(Color(NSColor.placeholderTextColor))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .help("Select a provisioning profile (.mobileprovision)")

                Button {
                    viewModel.scanForIdentityMigration()
                } label: {
                    if viewModel.isScanningIdentity {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Move to New Identity", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
                .disabled(viewModel.isScanningIdentity || viewModel.provisioningProfileURL == nil || !isEvilMode)
                .help(isEvilMode
                    ? "Move the bundle ID to a new identity you own — automatically finds and updates other config files that reference it. The new bundle ID / App Group are read from the selected provisioning profile."
                    : "Enable Evil Mode from the main window to use this.")
            }

            if !viewModel.entitlementWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.entitlementWarnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.leading, 100)
            }

            // Certificate
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Label("Certificate", systemImage: "person.badge.key")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)

                    if certificates.isEmpty {
                        Text("No signing certificates found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Menu {
                            ForEach(viewModel.matchingCertificates) { cert in
                                Button(cert.displayName) {
                                    viewModel.selectedCertificate = cert
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if let cert = viewModel.selectedCertificate {
                                    Text(cert.displayName)
                                        .lineLimit(1)
                                        .foregroundColor(.primary)
                                } else {
                                    Text("Select a certificate...")
                                        .foregroundColor(Color(NSColor.placeholderTextColor))
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.hasNoCertificateMatchingProfile {
                    Label(
                        "None of your local certificates are authorized by this provisioning profile's DeveloperCertificates list. Re-download the profile after adding this certificate on the Apple Developer portal.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 100)
                }
            }

            // Security Testing Mode (gated behind Evil Mode)
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $viewModel.enableSecurityTestingMode) {
                    Label("Security Testing Mode", systemImage: "ladybug")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEvilMode)

                Text("Disables ATS (NSAllowsArbitraryLoads) so a proxy like Burp or mitmproxy can intercept this app's traffic. Signed builds are always debuggable (get-task-allow). Does not bypass in-app certificate pinning.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $viewModel.enableFridaGadgetInjection) {
                    Label("Inject Frida Gadget", systemImage: "syringe")
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 6)
                .disabled(!isEvilMode)

                Text("Embeds a Frida agent in the app for runtime instrumentation (e.g. bypassing SSL pinning) — no jailbreak needed. After install, attach from your Mac with: frida -H <device-ip>:27042 -n Gadget -l script.js")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isEvilMode {
                    Label("Enable Evil Mode from the main window to use these.", systemImage: "flame")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var actionRow: some View {
        if let path = viewModel.signedOutputPath {
            signedActionRow(outputPath: path)
        } else {
            signingActionRow
        }
    }

    private func signedActionRow(outputPath: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text("Signed successfully")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)

            Button {
                // Deliberately not dismissing here: ResigningView now lives
                // in its own independent window (not a sheet), and this
                // window hosts the install sheet triggered by `onInstall` —
                // closing it first would tear the sheet down before it can
                // ever appear.
                onInstall?(outputPath)
            } label: {
                Label("Install to Device", systemImage: "iphone.and.arrow.forward")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var signingActionRow: some View {
        HStack(spacing: 8) {
            if let msg = viewModel.signingMessage {
                ProgressView().scaleEffect(0.75)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSigning)

            Button { viewModel.initiateSign() } label: {
                Label("Sign & Save", systemImage: "signature")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.selectedCertificate == nil ||
                viewModel.provisioningProfileURL == nil ||
                viewModel.isSigning
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var certificates: [ResignerCertificate] { viewModel.certificates }
}

// MARK: - PlistEntryRow

private struct PlistEntryRow: View {
    @Binding var entry: PlistEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.key)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)

            if entry.isBool {
                Toggle("", isOn: Binding(
                    get: { entry.boolValue },
                    set: { entry.boolValue = $0 }
                ))
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if entry.isEditable {
                TextField("", text: $entry.editValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                Text(entry.editValue)
                    .font(.caption)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }

            Button { onDelete() } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .opacity(entry.type == .complex ? 0.4 : 1)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - FileNodeRow

private struct FileNodeRow: View {
    let node: IPAFileNode
    let isReplaced: Bool
    let isMarkedForRemoval: Bool
    let isEvilMode: Bool
    let onReplace: () -> Void
    let onToggleRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : iconForFile(node.name))
                .foregroundColor(node.isDirectory ? .accentColor : Color(NSColor.secondaryLabelColor))
                .font(.system(size: 13))
                .frame(width: 16)

            Text(node.name)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isMarkedForRemoval ? .red : (isReplaced ? .orange : .primary))
                .strikethrough(isMarkedForRemoval)
                .lineLimit(1)

            if isReplaced {
                Text("replaced")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(4)
            }
            if isMarkedForRemoval {
                Text("will be removed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(4)
            }

            Spacer()

            if let onToggleRemove {
                Button(isMarkedForRemoval ? "Undo" : "Remove") { onToggleRemove() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(isMarkedForRemoval ? .secondary : .red)
                    .disabled(!isMarkedForRemoval && !isEvilMode)
                    .help(isEvilMode || isMarkedForRemoval ? "" : "Enable Evil Mode from the main window to remove frameworks.")
            } else if !node.isDirectory {
                Button("Replace") { onReplace() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 1)
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "plist":       return "doc.text"
        case "png", "jpg", "jpeg", "heic": return "photo"
        case "car":         return "square.grid.2x2"
        case "dylib", "framework": return "puzzlepiece.extension"
        case "appex":       return "app.badge"
        default:            return "doc"
        }
    }
}

// MARK: - IdentityMigrationSheet

private struct IdentityMigrationSheet: View {
    @ObservedObject var viewModel: ResigningVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move to New Identity")
                .font(.headline)

            Text("Move the original bundle ID (and its App Group, if any) to a new identity you own on your own account. Other config files that reference these strings are listed below — they'll be updated automatically.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                if !viewModel.newBundleIdentifier.isEmpty {
                    Label("Read from the selected provisioning profile — edit if needed.", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("New Bundle ID").font(.subheadline)
                TextField("com.your-account.app", text: $viewModel.newBundleIdentifier)
                    .textFieldStyle(.roundedBorder)

                Text("New App Group").font(.subheadline)
                TextField("group.com.your-account.app", text: $viewModel.newAppGroupName)
                    .textFieldStyle(.roundedBorder)
            }

            if viewModel.identityReferences.isEmpty {
                Text("No other config file references the bundle ID — only CFBundleIdentifier will be updated.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Files found (\(viewModel.identityReferences.count))")
                    .font(.subheadline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.identityReferences) { ref in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ref.path)
                                    .font(.system(.caption, design: .monospaced))
                                Text(ref.matchedStrings.joined(separator: ", "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    viewModel.applyIdentityMigration()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.newBundleIdentifier.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: 420)
    }
}

