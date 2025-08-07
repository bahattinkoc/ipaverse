//
//  DownloadedView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct DownloadedView: View {
    let account: Account
    @State private var downloadedApps: [DownloadedApp] = []
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
            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let downloadedPath = documentsPath.appendingPathComponent("Downloaded")

                if !FileManager.default.fileExists(atPath: downloadedPath.path) {
                    try FileManager.default.createDirectory(at: downloadedPath, withIntermediateDirectories: true)
                }

                let files = try FileManager.default.contentsOfDirectory(at: downloadedPath, includingPropertiesForKeys: [.creationDateKey])

                var apps: [DownloadedApp] = []

                for file in files where file.pathExtension == "ipa" {
                    let fileName = file.deletingPathExtension().lastPathComponent
                    let components = fileName.components(separatedBy: "_")

                    if components.count >= 3 {
                        let bundleID = components[0]
                        let appID = Int64(components[1]) ?? 0
                        let version = components[2]

                        let app = AppStoreApp(
                            id: appID,
                            bundleID: bundleID,
                            name: bundleID,
                            version: version,
                            price: 0.0
                        )

                        let creationDate = try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date()

                        let downloadedApp = DownloadedApp(
                            app: app,
                            downloadDate: creationDate,
                            filePath: file.path
                        )

                        apps.append(downloadedApp)
                    }
                }

                await MainActor.run {
                    downloadedApps = apps.sorted { $0.downloadDate > $1.downloadDate }
                    isLoading = false
                }

            } catch {
                await MainActor.run {
                    errorMessage = "Failed to load downloaded apps: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func redownloadApp(_ downloadedApp: DownloadedApp) {
        Task {
            do {
                let appStoreService = AppStoreService()
                let output = try await appStoreService.download(
                    app: downloadedApp.app,
                    account: account,
                    outputPath: downloadedApp.filePath
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

struct DownloadedAppRow: View {
    let downloadedApp: DownloadedApp
    let onRedownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: downloadedApp.app.iconURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "app.fill")
                            .foregroundColor(.gray)
                    )
            }
            .frame(width: 50, height: 50)
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(downloadedApp.app.name ?? "-")
                    .font(.headline)
                    .lineLimit(1)

                Text(downloadedApp.app.bundleID ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("v\(downloadedApp.app.version ?? "-")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(downloadedApp.downloadDate, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onRedownload) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    DownloadedView(account: Account(
        email: "test@example.com",
        name: "Test User",
        storeFront: "143441",
        passwordToken: "token",
        directoryServicesID: "123456"
    ))
}
