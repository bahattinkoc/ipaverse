//
//  DownloadedView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData
import AppKit

struct DownloadedView: View {
    let account: Account
    @EnvironmentObject private var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var downloadedApps: [DownloadedApp]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedApp: AppStoreApp?
    @State private var appToSign: DownloadedApp?

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
                            downloadState: .idle
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
        }
        .onAppear {
            loadDownloadedApps()
        }
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app, account: loginViewModel.currentAccount ?? account)
        }
        .sheet(item: $appToSign) { app in
            ResigningView(downloadedApp: app)
        }
    }

    private func loadDownloadedApps() {
        isLoading = true
        errorMessage = nil
        Task {
            await MainActor.run { isLoading = false }
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
