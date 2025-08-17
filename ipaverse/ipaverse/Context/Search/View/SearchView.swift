//
//  SearchView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    let account: Account
    @EnvironmentObject var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    @State private var searchResults: [AppStoreApp] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var showingSavePanel = false
    @State private var currentDownloadApp: AppStoreApp?
    @State private var downloadProgress: Double = 0
    @State private var isDownloading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                Group {
                    if isLoading {
                        ProgressView("Searching...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = errorMessage {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundColor(.orange)

                            Text("Search Error")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(error)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            Button("Retry") {
                                performSearch()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchResults.isEmpty && !searchText.isEmpty && !isSearching {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)

                            Text("No Results")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Try searching for a different app")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if searchText.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.blue)

                            Text("Search Apps")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Enter an app name to search")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(searchResults) { app in
                            SearchResultRow(app: app, isDownloading: isDownloading && currentDownloadApp?.id == app.id, downloadProgress: downloadProgress) {
                                downloadApp(app)
                            }
                        }
                        .refreshable {
                            performSearch()
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .onChange(of: showingSavePanel) { _, newValue in
                if newValue {
                    showSavePanel()
                }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)

                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onSubmit {
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button(action: {
                        searchText = ""
                        searchResults = []
                        errorMessage = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoading = true
        errorMessage = nil
        isSearching = true

        Task {
            do {
                let appStoreService = AppStoreService()
                let result = try await appStoreService.search(
                    term: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                    account: account,
                    limit: 5
                )

                guard let results = result.results else { return }

                await MainActor.run {
                    searchResults = results
                    isLoading = false
                    isSearching = false
                }

            } catch {
                await MainActor.run {
                    errorMessage = "Search failed: \(error.localizedDescription)"
                    isLoading = false
                    isSearching = false
                }
            }
        }
    }

    private func downloadApp(_ app: AppStoreApp) {
        currentDownloadApp = app
        showingSavePanel = true
    }

    private func startDownload(at url: URL) {
        guard let app = currentDownloadApp else { return }

        isDownloading = true
        downloadProgress = 0

        Task {
            do {
                let appStoreService = AppStoreService()
                let output = try await appStoreService.download(
                    app: app,
                    account: account,
                    outputPath: url.path,
                    progress: { progress in
                        Task { @MainActor in
                            downloadProgress = progress
                        }
                    },
                    modelContext: modelContext
                )

                if output.success {
                    await MainActor.run {
                        isDownloading = false
                        downloadProgress = 1.0
                    }
                }

            } catch {
                if let loginError = error as? LoginError, loginError == .tokenExpired {
                    await loginViewModel.logout(withMessage: "Session expired. Please login again.")
                } else {
                    await MainActor.run {
                        errorMessage = "Download failed: \(error.localizedDescription)"
                        isDownloading = false
                        downloadProgress = 0
                    }
                }
            }
        }
    }

    private func showSavePanel() {
        guard let app = currentDownloadApp else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Save IPA File"
        savePanel.nameFieldStringValue = "\(app.bundleID ?? "")_\(app.version ?? "").ipa"
        savePanel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                startDownload(at: url)
            }
            showingSavePanel = false
        }
    }
}
