//
//  AppModels.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation

struct AppStoreApp: Codable, Identifiable, Equatable {
    let id: Int64?
    let bundleID: String?
    let name: String?
    let version: String?
    let price: Double?
    let iconURL: String?

    enum CodingKeys: String, CodingKey {
        case id = "trackId"
        case bundleID = "bundleId"
        case name = "trackName"
        case version
        case price
        case iconURL = "artworkUrl100"
    }

    init(id: Int64, bundleID: String, name: String, version: String, price: Double, iconURL: String? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.price = price
        self.iconURL = iconURL
    }
}

struct DownloadedApp: Codable, Identifiable, Equatable {
    var id = UUID()
    let app: AppStoreApp
    let downloadDate: Date
    let filePath: String

    init(app: AppStoreApp, downloadDate: Date = Date(), filePath: String) {
        self.app = app
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
