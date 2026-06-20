//
//  SettingsModel.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 18.08.2025.
//

import Foundation

struct SettingsModel: Codable {
    var defaultDownloadPath: String
    var defaultDownloadType: DownloadType
    var searchHistoryEnabled: Bool
    var searchResultLimit: SearchResultLimit

    init() {
        defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        defaultDownloadType = .ipa
        searchHistoryEnabled = true
        searchResultLimit = .fifty
    }

    // Backward-compatible decoding: settings saved before `searchResultLimit`
    // existed lack that key, so fall back to the default instead of failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SettingsModel()
        defaultDownloadPath = try container.decodeIfPresent(String.self, forKey: .defaultDownloadPath) ?? fallback.defaultDownloadPath
        defaultDownloadType = try container.decodeIfPresent(DownloadType.self, forKey: .defaultDownloadType) ?? fallback.defaultDownloadType
        searchHistoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .searchHistoryEnabled) ?? fallback.searchHistoryEnabled
        searchResultLimit = try container.decodeIfPresent(SearchResultLimit.self, forKey: .searchResultLimit) ?? fallback.searchResultLimit
    }

    static let storageKey = "UserSettings"

    /// Loads the persisted settings, or defaults if none/undecodable.
    static func load() -> SettingsModel {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SettingsModel.self, from: data) else {
            return SettingsModel()
        }
        return decoded
    }
}

enum SearchResultLimit: Int, CaseIterable, Codable, Identifiable {
    case five = 5
    case fifty = 50
    case hundred = 100
    case twoHundred = 200

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)" }
}

enum DownloadType: String, CaseIterable, Codable {
    case ipa = "ipa"
    case zip = "zip"

    var displayName: String {
        switch self {
        case .ipa: ".ipa"
        case .zip: ".zip"
        }
    }
}
