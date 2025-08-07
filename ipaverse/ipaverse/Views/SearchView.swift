//
//  SearchView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct SearchView: View {
    let account: Account
    @State private var searchText = ""
    @State private var searchResults: [AppStoreApp] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSearching = false

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
                            SearchResultRow(app: app) {
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            if !searchText.isEmpty {
                Button("Search") {
                    performSearch()
                }
                .buttonStyle(.borderedProminent)
            }
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
        Task {
            do {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let downloadedPath = documentsPath.appendingPathComponent("Downloaded")

                if !FileManager.default.fileExists(atPath: downloadedPath.path) {
                    try FileManager.default.createDirectory(at: downloadedPath, withIntermediateDirectories: true)
                }

                let fileName = "\(app.bundleID ?? "")_\(app.id ?? 0)_\(app.version ?? "").ipa"
                let outputPath = downloadedPath.appendingPathComponent(fileName).path

                let appStoreService = AppStoreService()

                // First try to purchase if needed, then download
                do {
                    try await appStoreService.purchase(app: app, account: account)
                    print("🛒 Purchase successful for: \(app.name ?? "")")
                } catch {
                    if !error.localizedDescription.contains("already exists") {
                        throw error
                    }
                    print("ℹ️ License already exists for: \(app.name ?? "")")
                }

                let output = try await appStoreService.download(
                    app: app,
                    account: account,
                    outputPath: outputPath
                )

                if output.success {
                    await MainActor.run {
                        print("✅ App downloaded successfully: \(app.name ?? "")")
                    }
                }

            } catch {
                await MainActor.run {
                    errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct SearchResultRow: View {
    let app: AppStoreApp
    let onDownload: () -> Void
    @State private var isDownloading = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { image in
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
                Text(app.name ?? "-")
                    .font(.headline)
                    .lineLimit(1)

                Text(app.bundleID ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("v\(app.version ?? "-")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let price = app.price, price > 0 {
                    Text("$\(price, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Free")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            Button(action: {
                isDownloading = true
                onDownload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isDownloading = false
                }
            }) {
                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SearchView(account: Account(
        email: "test@example.com",
        name: "Test User",
        storeFront: "143441",
        passwordToken: "token",
        directoryServicesID: "123456"
    ))
}
