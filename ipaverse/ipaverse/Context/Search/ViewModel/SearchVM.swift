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
    private var historyObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?

    init(account: Account) {
        self.account = account
        loadSearchHistory()
        setupNotificationObserver()
    }

    deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    func setup(modelContext: ModelContext, loginViewModel: LoginVM) {
        self.modelContext = modelContext
        self.loginViewModel = loginViewModel
    }

    private func setupNotificationObserver() {
        historyObserver = NotificationCenter.default.addObserver(
            forName: .searchHistoryCleared,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadSearchHistory()
            }
        }
    }

    func loadSearchHistory() {
        searchHistory = SearchHistoryStore().load()
    }

    func saveSearchHistory() {
        SearchHistoryStore().record(searchText)
        loadSearchHistory()
    }

    var isLookupMode: Bool {
        Self.isBundleID(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func isBundleID(_ text: String) -> Bool {
        // Bundle identifiers are not limited to common domain prefixes (e.g. alvr.client).
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        isSearching = true

        if !Self.isBundleID(trimmed) { saveSearchHistory() }

        searchTask?.cancel()
        searchTask = Task {
            do {
                let service = AppStoreService()
                let searchAccount = effectiveAccount
                if Self.isBundleID(trimmed) {
                    let app = try await service.lookup(bundleID: trimmed, account: searchAccount, platform: selectedPlatform)
                    guard !Task.isCancelled else { return }
                    searchResults = [app]
                } else {
                    let limit = SettingsModel.load().searchResultLimit.rawValue
                    let result = try await service.search(term: trimmed, account: searchAccount, limit: limit, platform: selectedPlatform)
                    guard !Task.isCancelled else { return }
                    searchResults = result.results ?? []
                }
                isLoading = false
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                let msg = Self.isBundleID(trimmed)
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
