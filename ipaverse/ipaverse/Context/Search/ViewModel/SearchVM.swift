//
//  SearchVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI
import SwiftData

@MainActor
final class SearchVM: ObservableObject {
    @Published var searchText = ""
    @Published var searchResults: [AppStoreApp] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isSearching = false
    @Published var showingSavePanel = false
    @Published var currentDownloadApp: AppStoreApp?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var searchHistory: [String] = []
    
    private let account: Account
    var modelContext: ModelContext!
    var loginViewModel: LoginVM!
    
    init(account: Account) {
        self.account = account
        loadSearchHistory()
    }
    
    func setup(modelContext: ModelContext, loginViewModel: LoginVM) {
        self.modelContext = modelContext
        self.loginViewModel = loginViewModel
    }
    
    func loadSearchHistory() {
        if let history = UserDefaults.standard.array(forKey: "SearchHistory") as? [String] {
            searchHistory = Array(history.prefix(5))
        }
    }
    
    func saveSearchHistory() {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return }
        
        var history = UserDefaults.standard.array(forKey: "SearchHistory") as? [String] ?? []
        
        if let index = history.firstIndex(of: trimmedSearch) {
            history.remove(at: index)
        }
        
        history.insert(trimmedSearch, at: 0)
        history = Array(history.prefix(5))
        
        UserDefaults.standard.set(history, forKey: "SearchHistory")
        searchHistory = history
    }
    
    func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isLoading = true
        errorMessage = nil
        isSearching = true
        
        saveSearchHistory()

        Task {
            do {
                let appStoreService = AppStoreService()
                let result = try await appStoreService.search(
                    term: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                    account: account,
                    limit: 5
                )

                guard let results = result.results else { return }

                searchResults = results
                isLoading = false
                isSearching = false

            } catch {
                errorMessage = "Search failed: \(error.localizedDescription)"
                isLoading = false
                isSearching = false
            }
        }
    }
    
    func clearSearch() {
        searchText = ""
        searchResults = []
        errorMessage = nil
    }
    
    func selectSearchTerm(_ term: String) {
        searchText = term
        performSearch()
    }
    
    func downloadApp(_ app: AppStoreApp) {
        currentDownloadApp = app
        showingSavePanel = true
    }
    
    func startDownload(at url: URL) {
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
                            self.downloadProgress = progress
                        }
                    },
                    modelContext: modelContext
                )

                if output.success {
                    isDownloading = false
                    downloadProgress = 1.0
                }

            } catch {
                if let loginError = error as? LoginError, loginError == .tokenExpired {
                    await loginViewModel.logout(withMessage: "Session expired. Please login again.")
                } else {
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    isDownloading = false
                    downloadProgress = 0
                }
            }
        }
    }
    
    func showSavePanel() {
        guard let app = currentDownloadApp else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Save IPA File"
        savePanel.nameFieldStringValue = "\(app.bundleID ?? "")_\(app.version ?? "").ipa"
        savePanel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                self?.startDownload(at: url)
            }
            self?.showingSavePanel = false
        }
    }
}
