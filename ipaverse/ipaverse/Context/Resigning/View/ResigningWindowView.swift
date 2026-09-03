//
//  ResigningWindowView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 3.09.2026.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Hosts `ResigningView` in its own independent, resizable window (the
/// "resign" WindowGroup in ipaverseApp.swift) — reachable either from
/// Downloaded's "Edit & Resign" context menu (pre-filled via `appID`, a
/// `DownloadedApp.id`) or directly from the menu bar / Dock with nothing
/// loaded yet, in which case this view is itself a drop target for an .ipa
/// file before handing off to the editor.
struct ResigningWindowView: View {
    let appID: String?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var loginViewModel: LoginVM
    @State private var resolvedApp: DownloadedApp?
    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var installContext: IPAInstallContext?
    @State private var didLookUp = false
    @State private var isImporting = false

    var body: some View {
        Group {
            if let app = resolvedApp {
                ResigningView(downloadedApp: app) { signedPath in
                    installContext = IPAInstallContext(ipaPath: signedPath, appName: app.name)
                }
            } else {
                dropZone
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 700, idealHeight: 780)
        .onAppear(perform: lookUpInitialApp)
        .sheet(item: $installContext) { ctx in
            DeviceInstallView(ipaPath: ctx.ipaPath, appName: ctx.appName, activeAppleID: loginViewModel.currentAccount?.email)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var dropZone: some View {
        EmptyStateView(
            icon: "signature",
            title: "Resign an IPA",
            message: "Pick an .ipa file to edit its Info.plist, provisioning, and sign it for sideloading.",
            tone: .accent,
            actionTitle: "Browse…",
            action: presentImportPanel,
            dropHint: "or drag & drop an .ipa file here"
        )
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
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.15)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Importing…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isImporting)
    }

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
            Task { await importAndLoad(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "ipa" else { return }
            DispatchQueue.main.async { Task { await importAndLoad(url) } }
        }
        return true
    }

    private func importAndLoad(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let app = try await IPAImporter.importIPA(at: url, into: modelContext)
            resolvedApp = app
        } catch {
            importError = error.localizedDescription
        }
    }
}
