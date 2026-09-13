import Foundation

struct SearchHistoryStore {
    var defaults: UserDefaults = .standard
    var enabled: Bool {
        guard let data = defaults.data(forKey: SettingsModel.storageKey),
              let settings = try? JSONDecoder().decode(SettingsModel.self, from: data) else { return true }
        return settings.searchHistoryEnabled
    }
    func load() -> [String] {
        enabled ? Array((defaults.stringArray(forKey: "SearchHistory") ?? []).prefix(5)) : []
    }
    func record(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !query.isEmpty else { return }
        var history = load().filter { $0 != query }
        history.insert(query, at: 0)
        defaults.set(Array(history.prefix(5)), forKey: "SearchHistory")
    }
    func clear() { defaults.removeObject(forKey: "SearchHistory") }
}
