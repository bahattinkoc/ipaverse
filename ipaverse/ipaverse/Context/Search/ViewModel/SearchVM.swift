//
//  SearchVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI
import SwiftData

enum DownloadState {
    case idle
    case purchasing
    case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
}

@MainActor
final class SearchVM: ObservableObject {
    @Published var searchText = ""
    @Published var searchResults: [AppStoreApp] = []
    @Published var searchHistory: [String] = []
    @Published var isLoading = false
    @Published var isSearching = false
    @Published var errorMessage: String?
    @Published var showingSavePanel = false
    @Published var downloadState: DownloadState = .idle
    @Published var selectedPlatform: AppPlatform = .ios

    var currentDownloadApp: AppStoreApp?
    private let account: Account
    private var modelContext: ModelContext?
    private var loginViewModel: LoginVM?

    init(account: Account) {
        self.account = account
        loadSearchHistory()
        setupNotificationObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setup(modelContext: ModelContext, loginViewModel: LoginVM) {
        self.modelContext = modelContext
        self.loginViewModel = loginViewModel
    }

    private func setupNotificationObserver() {
        NotificationCenter.default.addObserver(
            forName: .searchHistoryCleared,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.searchHistory = []
            }
        }
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
                    limit: 5,
                    platform: selectedPlatform
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

        downloadState = .purchasing

        Task {
            do {
                let appStoreService = AppStoreService()
                let _ = try await appStoreService.download(
                    app: app,
                    account: account,
                    outputPath: url.path,
                    progress: { progress, bytesWritten, totalBytes in
                        Task { @MainActor in
                            if progress >= 1.0 {
                                self.downloadState = .idle
                            } else {
                                self.downloadState = .downloading(progress: progress, bytesWritten: bytesWritten, totalBytes: totalBytes)
                            }
                        }
                    },
                    modelContext: modelContext
                )
            } catch {
                if let loginError = error as? LoginError, loginError == .tokenExpired {
                    await loginViewModel?.logout(withMessage: "Session expired. Please login again.")
                } else {
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    downloadState = .idle
                }
            }
        }
    }

    func showSavePanel() {
        guard let app = currentDownloadApp else { return }
        
        let savePanel = NSSavePanel()
        savePanel.title = "Save App File"

        let downloadType = getDownloadTypeFromSettings()
        let fileExtension = downloadType.rawValue
        let fileName = "\(app.bundleID ?? "")_\(app.version ?? "").\(fileExtension)"

        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [.init(filenameExtension: fileExtension)!]
        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                self?.startDownload(at: url)
            }
            self?.showingSavePanel = false
        }
    }

    private func getDownloadTypeFromSettings() -> DownloadType {
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let settings = try? JSONDecoder().decode(SettingsModel.self, from: data) {
            return settings.defaultDownloadType
        }
        return .ipa
    }

    func refreshSearchHistory() {
        loadSearchHistory()
    }
}
