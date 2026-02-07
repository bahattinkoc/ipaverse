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

    init() {
        self.settings = SettingsModel()
        loadSettings()
    }

    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let decodedSettings = try? JSONDecoder().decode(SettingsModel.self, from: data) {
            self.settings = decodedSettings
        }
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: "UserSettings")
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
    }

    func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: "SearchHistory")
        NotificationCenter.default.post(name: .searchHistoryCleared, object: nil)
        
        // Clear all downloaded apps from SwiftData
        do {
            let context = try ModelContext(ModelContainer(for: DownloadedApp.self))
            try context.delete(model: DownloadedApp.self)
            try context.save()
        } catch {
            print("SwiftData clearing error: \(error)")
        }
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
