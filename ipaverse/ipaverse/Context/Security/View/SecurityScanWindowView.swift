//
//  SecurityScanWindowView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Hosts `ReverseEngineerView` in its own independent, resizable window (the
/// "securityScan" WindowGroup in ipaverseApp.swift — kept as the internal id
/// to avoid an unrelated rename churn) — reachable from Downloaded's
/// "Reverse Engineer" context menu (pre-filled via `appID`, a
/// `DownloadedApp.id`), or directly from the menu bar / Dock with nothing
/// loaded yet, in which case this view lets the analyst either drop an .ipa
/// or pick one already sitting in Downloaded before handing off. Mirrors
/// `ResigningWindowView`'s shape.
struct SecurityScanWindowView: View {
    let appID: String?

    @Environment(\.modelContext) private var modelContext
    @AppStorage("evilModeEnabled") private var isEvilMode = false
    @State private var resolvedApp: DownloadedApp?
    @State private var droppedIPA: (path: String, name: String)?
    @State private var isDropTargeted = false
    @State private var didLookUp = false
    @State private var showPicker = false

    var body: some View {
        Group {
            if !isEvilMode {
                lockedScreen
            } else if let app = resolvedApp {
                ReverseEngineerView(ipaPath: app.filePath, appName: app.name)
            } else if let dropped = droppedIPA {
                ReverseEngineerView(ipaPath: dropped.path, appName: dropped.name)
            } else {
                entryScreen
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 640, idealHeight: 780)
        .onAppear(perform: lookUpInitialApp)
        .sheet(isPresented: $showPicker) {
            DownloadedAppPicker { app in
                resolvedApp = app
                showPicker = false
            }
        }
    }

    private var lockedScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "flame.slash")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("Evil Mode Required")
                .font(.title2.weight(.semibold))
            Text("Enable Evil Mode in the main window before using reverse-engineering tools.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Entry screen (no app loaded yet)

    private var entryScreen: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "binoculars.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            VStack(spacing: 6) {
                Text("Reverse Engineer")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Static analysis, a live Frida toolkit, and external tool shortcuts for digging into an .ipa.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            HStack(spacing: 10) {
                Button("Browse…", action: presentImportPanel)
                    .buttonStyle(.borderedProminent)
                Button("Choose from Downloaded…") { showPicker = true }
                    .buttonStyle(.bordered)
            }

            DropHintBox(text: "or drag & drop an .ipa file here")
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Resolution

    private func lookUpInitialApp() {
        guard !didLookUp, let appID else { return }
        didLookUp = true
        let descriptor = FetchDescriptor<DownloadedApp>(predicate: #Predicate { $0.id == appID })
        resolvedApp = try? modelContext.fetch(descriptor).first
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "ipa") {
            panel.allowedContentTypes = [type]
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            droppedIPA = (path: url.path, name: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "ipa" else { return }
            DispatchQueue.main.async {
                droppedIPA = (path: url.path, name: url.deletingPathExtension().lastPathComponent)
            }
        }
        return true
    }
}

// MARK: - "Choose from Downloaded" picker

/// Lightweight sheet reusing `AppRowView` so the picker looks identical to
/// the Downloaded tab it's sourced from — search-filtered, tap to select.
private struct DownloadedAppPicker: View {
    let onSelect: (DownloadedApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var apps: [DownloadedApp]
    @State private var searchText = ""

    private var filtered: [DownloadedApp] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an App to Scan")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if apps.isEmpty {
                EmptyStateView(
                    icon: "arrow.down.circle",
                    title: "No Downloaded Apps",
                    message: "Download or import an .ipa first, or drop one directly onto the Security Scan window."
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Search downloaded apps", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                .padding(.horizontal)
                .padding(.top, 10)

                List(filtered) { app in
                    AppRowView(app: app, appRowType: .downloaded(.idle), onDownload: {}, onRedownload: {})
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(app) }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 480, height: 520)
    }
}
