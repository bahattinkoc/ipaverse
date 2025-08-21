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
    @State private var downloadStates: [String: DownloadState] = [:]
    
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
                            downloadState: downloadStates[downloadedApp.id] ?? .idle
                        ) {
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
        .onDisappear {
            downloadStates.removeAll()
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
        let appId = downloadedApp.id
        
        Task { @MainActor in
            downloadStates[appId] = .purchasing
        }
        
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
                
                let downloadType = getDownloadTypeFromSettings()
                let fileExtension = downloadType.rawValue
                let fileName = "\(downloadedApp.bundleID)_\(downloadedApp.version).\(fileExtension)"
                let outputPath = getOutputPath(fileName: fileName)
                
                let output = try await appStoreService.download(
                    app: app,
                    account: account,
                    outputPath: outputPath,
                    progress: { progress, bytesWritten, totalBytes in
                        Task { @MainActor in
                            if progress >= 1.0 {
                                downloadStates[appId] = .idle
                            } else {
                                downloadStates[appId] = .downloading(progress: progress, bytesWritten: bytesWritten, totalBytes: totalBytes)
                            }
                        }
                    },
                    modelContext: modelContext
                )
                
                await MainActor.run {
                    if !output.success {
                        errorMessage = "Redownload failed: \(output.error ?? "Unknown error")"
                    }
                }
            } catch {
                await MainActor.run {
                    downloadStates[appId] = .idle
                    errorMessage = "Failed to redownload: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func getDownloadTypeFromSettings() -> DownloadType {
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let settings = try? JSONDecoder().decode(SettingsModel.self, from: data) {
            return settings.defaultDownloadType
        }
        return .ipa
    }
    
    private func getOutputPath(fileName: String) -> String {
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let settings = try? JSONDecoder().decode(SettingsModel.self, from: data),
           !settings.defaultDownloadPath.isEmpty {
            return "\(settings.defaultDownloadPath)/\(fileName)"
        }
        
        let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        return "\(downloadsPath)/\(fileName)"
    }
}
