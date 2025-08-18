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

    init() {
        defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        defaultDownloadType = .ipa
        searchHistoryEnabled = true
    }
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
