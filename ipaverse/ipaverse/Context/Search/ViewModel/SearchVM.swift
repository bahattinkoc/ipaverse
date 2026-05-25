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
    @Published var selectedPlatform: AppPlatform = .ios
    @Published var selectedDetailApp: AppStoreApp?

    private let account: Account
    private var modelContext: ModelContext?
    private var loginViewModel: LoginVM?

    private var effectiveAccount: Account {
        loginViewModel?.currentAccount ?? account
    }
    private var searchTask: Task<Void, Never>?

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

    var isLookupMode: Bool {
        isBundleID(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isBundleID(_ text: String) -> Bool {
        guard !text.contains(" "), text.contains(".") else { return false }
        let lower = text.lowercased()
        return ["com.", "net.", "org.", "io.", "app.", "co.", "me."].contains(where: { lower.hasPrefix($0) })
    }

    func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        isSearching = true

        if !isBundleID(trimmed) { saveSearchHistory() }

        searchTask?.cancel()
        searchTask = Task {
            do {
                let service = AppStoreService()
                let searchAccount = effectiveAccount
                if isBundleID(trimmed) {
                    let app = try await service.lookup(bundleID: trimmed, account: searchAccount, platform: selectedPlatform)
                    guard !Task.isCancelled else { return }
                    searchResults = [app]
                } else {
                    let result = try await service.search(term: trimmed, account: searchAccount, limit: 5, platform: selectedPlatform)
                    guard !Task.isCancelled else { return }
                    searchResults = result.results ?? []
                }
                isLoading = false
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                let msg = isBundleID(trimmed)
                    ? "App not found: \(trimmed)"
                    : "Search failed: \(error.localizedDescription)"
                errorMessage = msg
                isLoading = false
                isSearching = false
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        searchResults = []
        errorMessage = nil
        isLoading = false
        isSearching = false
    }

    func selectSearchTerm(_ term: String) {
        searchText = term
        performSearch()
    }

    func downloadApp(_ app: AppStoreApp) {
        selectedDetailApp = app
    }

    func refreshSearchHistory() {
        loadSearchHistory()
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: "SearchHistory")
        searchHistory = []
    }
}
