//
//  ResigningView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import SwiftUI
import AppKit

struct ResigningView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ResigningVM

    init(downloadedApp: DownloadedApp) {
        self._viewModel = StateObject(wrappedValue: ResigningVM(downloadedApp: downloadedApp))
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
        .frame(width: 580, height: 560)
        .onAppear { Task { await viewModel.load() } }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.state = .idle } }
        )) {
            Button("OK") { viewModel.state = .idle }
        } message: {
            Text(viewModel.errorMessage ?? "")
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
                        isReplaced: viewModel.fileReplacements[node.path] != nil
                    ) {
                        viewModel.replaceFile(at: node.path)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let msg = viewModel.signingMessage {
                ProgressView()
                    .scaleEffect(0.75)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                viewModel.pickProvisioningProfile()
            } label: {
                if let url = viewModel.provisioningProfileURL {
                    Label(url.deletingPathExtension().lastPathComponent, systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Select Profile", systemImage: "seal")
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Select a provisioning profile (.mobileprovision)")

            if certificates.isEmpty {
                Text("No certificates found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: $viewModel.selectedCertificate) {
                    ForEach(viewModel.certificates) { cert in
                        Text(cert.displayName)
                            .tag(Optional(cert))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSigning)

            Button {
                viewModel.initiateSign()
            } label: {
                Label("Sign & Save", systemImage: "signature")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedCertificate == nil || viewModel.provisioningProfileURL == nil || viewModel.isSigning)
        }
        .padding()
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
    let onReplace: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : iconForFile(node.name))
                .foregroundColor(node.isDirectory ? .accentColor : Color(NSColor.secondaryLabelColor))
                .font(.system(size: 13))
                .frame(width: 16)

            Text(node.name)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isReplaced ? .orange : .primary)
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

            Spacer()

            if !node.isDirectory {
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
