//
//  SettingsVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 18.08.2025.
//

import SwiftUI
import SwiftData

@MainActor
final class SettingsVM: ObservableObject {
    @Published var settings: SettingsModel
    @EnvironmentObject var loginViewModel: LoginVM
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = SettingsModel()
        loadSettings()
    }

    func loadSettings() {
        settings = defaults.data(forKey: SettingsModel.storageKey)
            .flatMap { try? JSONDecoder().decode(SettingsModel.self, from: $0) } ?? SettingsModel()
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: SettingsModel.storageKey)
        }
    }

    func updateDownloadPath(_ path: String) {
        settings.defaultDownloadPath = path
        saveSettings()
    }

    func updateDownloadType(_ type: DownloadType) {
        settings.defaultDownloadType = type
        saveSettings()
    }

    func toggleSearchHistory() {
        settings.searchHistoryEnabled.toggle()
        saveSettings()
        NotificationCenter.default.post(name: .searchHistoryCleared, object: nil)
    }

    func clearSearchHistory() {
        SearchHistoryStore(defaults: defaults).clear()
        NotificationCenter.default.post(name: .searchHistoryCleared, object: nil)
    }

    func selectDownloadPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the download folder"
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            if let url = panel.url {
                updateDownloadPath(url.path)
            }
        }
    }
}

extension Notification.Name {
    static let searchHistoryCleared = Notification.Name("searchHistoryCleared")
}
