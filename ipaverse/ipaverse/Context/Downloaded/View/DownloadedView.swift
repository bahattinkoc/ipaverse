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

struct DownloadedView: View {
    let account: Account
    @EnvironmentObject private var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var downloadedApps: [DownloadedApp]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedApp: AppStoreApp?
    @State private var installContext: IPAInstallContext?
    @State private var appToScan: DownloadedApp?
    @State private var appToDump: DownloadedApp?
    @State private var isDropTargeted = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading downloaded apps...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Error",
                        message: error,
                        tone: .warning,
                        actionTitle: "Retry"
                    ) {
                        loadDownloadedApps()
                    }
                } else if downloadedApps.isEmpty {
                    EmptyStateView(
                        icon: "arrow.down.circle",
                        title: "No Downloaded Apps",
                        message: "Apps you download will appear here",
                        tone: .accent,
                        dropHint: "or drag & drop an .ipa file here"
                    )
                } else {
                    List {
                        DropHintBox(text: "Drag & drop an .ipa file here to add it", compact: true)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))

                        ForEach(downloadedApps) { downloadedApp in
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
                                openWindow(id: "resign", value: downloadedApp.id)
                            } label: {
                                Label("Edit & Resign", systemImage: "signature")
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

                            Button {
                                appToDump = downloadedApp
                            } label: {
                                Label("Dump Decrypted Copy", systemImage: "lock.open.trianglebadge.exclamationmark")
                            }

                            Divider()

                            Button(role: .destructive) {
                                modelContext.delete(downloadedApp)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        }
                    }
                    .refreshable {
                        loadDownloadedApps()
                    }
                }
            }
            .navigationTitle("Downloaded")
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
        .sheet(item: $appToDump) { app in
            DumpView(downloadedApp: app)
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
