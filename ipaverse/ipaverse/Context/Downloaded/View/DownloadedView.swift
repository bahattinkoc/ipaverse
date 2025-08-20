//
//  DownloadedView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

struct DownloadedView: View {
    let account: Account
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var downloadedApps: [DownloadedApp]
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                        DownloadedAppRow(downloadedApp: downloadedApp) {
                            redownloadApp(downloadedApp)
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
    }

    private func loadDownloadedApps() {
        isLoading = true
        errorMessage = nil
        
        Task {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func redownloadApp(_ downloadedApp: DownloadedApp) {
        Task {
            do {
                let appStoreService = AppStoreService()
                let app = AppStoreApp(
                    id: downloadedApp.appId,
                    bundleID: downloadedApp.bundleID,
                    name: downloadedApp.name,
                    version: downloadedApp.version,
                    price: downloadedApp.price,
                    iconURL: downloadedApp.iconURL
                )
                
                let output = try await appStoreService.download(
                    app: app,
                    account: account,
                    outputPath: downloadedApp.filePath,
                    modelContext: modelContext
                )

                if output.success {
                    await MainActor.run {
                        loadDownloadedApps()
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to redownload: \(error.localizedDescription)"
                }
            }
        }
    }
}
