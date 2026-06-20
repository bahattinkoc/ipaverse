//
//  DownloadedView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

private struct IPAInstallContext: Identifiable {
    let id = UUID()
    let ipaPath: String
    let appName: String
}

struct DownloadedView: View {
    let account: Account
    @EnvironmentObject private var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var downloadedApps: [DownloadedApp]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedApp: AppStoreApp?
    @State private var appToSign: DownloadedApp?
    @State private var installContext: IPAInstallContext?
    @State private var appToScan: DownloadedApp?
    @State private var isDropTargeted = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading downloaded apps...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        Text("Error")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text(error)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Retry") {
                            loadDownloadedApps()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if downloadedApps.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                        
                        Text("No Downloaded Apps")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Apps you download will appear here")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(downloadedApps) { downloadedApp in
                        DownloadedAppRow(
                            downloadedApp: downloadedApp,
                            downloadState: .idle,
                            activeAppleID: loginViewModel.currentAccount?.email ?? account.email
                        ) {
                            openDetailSheet(for: downloadedApp)
                        }
                        .contextMenu {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: downloadedApp.filePath)]
                                )
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }

                            Button {
                                appToSign = downloadedApp
                            } label: {
                                Label("Edit & Sign", systemImage: "signature")
                            }

                            Button {
                                installContext = IPAInstallContext(
                                    ipaPath: downloadedApp.filePath,
                                    appName: downloadedApp.name
                                )
                            } label: {
                                Label("Install to Device", systemImage: "iphone.and.arrow.forward")
                            }

                            Button {
                                appToScan = downloadedApp
                            } label: {
                                Label("Security Scan", systemImage: "shield.lefthalf.filled")
                            }

                            Divider()

                            Button(role: .destructive) {
                                modelContext.delete(downloadedApp)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .refreshable {
                        loadDownloadedApps()
                    }
                }
            }
            .navigationTitle("Downloaded")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        presentImportPanel()
                    } label: {
                        Label("Import IPA", systemImage: "square.and.arrow.down")
                    }
                    .help("Import an .ipa file from disk")
                }
            }
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
        .onAppear {
            loadDownloadedApps()
        }
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app, account: loginViewModel.currentAccount ?? account)
        }
        .sheet(item: $appToSign) { app in
            ResigningView(downloadedApp: app) { signedPath in
                installContext = IPAInstallContext(ipaPath: signedPath, appName: app.name)
            }
        }
        .sheet(item: $installContext) { ctx in
            DeviceInstallView(
                ipaPath: ctx.ipaPath,
                appName: ctx.appName,
                activeAppleID: loginViewModel.currentAccount?.email ?? account.email
            )
        }
        .sheet(item: $appToScan) { app in
            SecurityScanView(ipaPath: app.filePath, appName: app.name)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func loadDownloadedApps() {
        isLoading = true
        errorMessage = nil
        Task {
            await MainActor.run { isLoading = false }
        }
    }

    // MARK: - Import

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importIPAs(from: panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let ipaProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !ipaProviders.isEmpty else { return false }

        for provider in ipaProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "ipa" else { return }
                DispatchQueue.main.async {
                    importIPAs(from: [url])
                }
            }
        }
        return true
    }

    private func importIPAs(from urls: [URL]) {
        for url in urls {
            do {
                try IPAImporter.importIPA(at: url, into: modelContext)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func openDetailSheet(for downloadedApp: DownloadedApp) {
        selectedApp = AppStoreApp(
            id: downloadedApp.appId,
            bundleID: downloadedApp.bundleID,
            name: downloadedApp.name,
            version: downloadedApp.version,
            price: downloadedApp.price,
            iconURL: downloadedApp.iconURL,
            platform: downloadedApp.platform.flatMap { AppPlatform(rawValue: $0) }
        )
    }
}
