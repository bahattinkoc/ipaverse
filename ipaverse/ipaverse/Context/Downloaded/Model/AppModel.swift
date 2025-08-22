//
//  AppModel.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import SwiftData

enum AppPlatform: String, CaseIterable, Codable {
    case ios = "iOS"
    case macos = "macOS"
}

struct AppStoreApp: Codable, Identifiable, Equatable {
    let id: Int64?
    let bundleID: String?
    let name: String?
    let version: String?
    let price: Double?
    let iconURL: String?
    let platform: AppPlatform?

    enum CodingKeys: String, CodingKey {
        case id = "trackId"
        case bundleID = "bundleId"
        case name = "trackName"
        case version
        case price
        case iconURL = "artworkUrl100"
        case platform
    }

    init(id: Int64, bundleID: String, name: String, version: String, price: Double, iconURL: String? = nil, platform: AppPlatform? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.price = price
        self.iconURL = iconURL
        self.platform = platform
    }
}

@Model
final class DownloadedApp {
    @Attribute(.unique) var id: String
    var appId: Int64
    var bundleID: String
    var name: String
    var version: String
    var price: Double
    var iconURL: String?
    var platform: String?
    var downloadDate: Date
    var filePath: String

    init(app: AppStoreApp, downloadDate: Date = Date(), filePath: String) {
        self.id = "\(app.id ?? 0)_\(app.bundleID ?? "")_\(app.version ?? "")"
        self.appId = app.id ?? 0
        self.bundleID = app.bundleID ?? ""
        self.name = app.name ?? ""
        self.version = app.version ?? ""
        self.price = app.price ?? 0.0
        self.iconURL = app.iconURL
        self.platform = app.platform?.rawValue
        self.downloadDate = downloadDate
        self.filePath = filePath
    }
}

struct SearchResult: Codable {
    let count: Int?
    let results: [AppStoreApp]?

    enum CodingKeys: String, CodingKey {
        case count = "resultCount"
        case results
    }
}

struct DownloadInput {
    let account: Account
    let app: AppStoreApp
    let outputPath: String?
}

struct DownloadOutput {
    let destinationPath: String
    let success: Bool
    let error: String?
}
