//
//  AppModel.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import SwiftData

enum AppPlatform: String, CaseIterable, Codable, Sendable {
    case ios = "iOS"
    case ipados = "iPadOS"
    case macos = "macOS"
    case tvos = "tvOS"
    case visionos = "visionOS"

    var iconName: String {
        switch self {
        case .ios: return "iphone"
        case .ipados: return "ipad"
        case .macos: return "macbook"
        case .tvos: return "tv"
        case .visionos: return "vision.pro"
        }
    }
}

struct AppStoreApp: Codable, Identifiable, Equatable, Sendable {
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
    /// Set when `filePath` is a derivative copy rather than the plain
    /// downloaded/imported original — "Decrypted" (FridaDumper output) or
    /// "Resigned" (IPAResigner output). Nil for a plain download/import.
    var sourceTag: String?
    // Optional additive fields allow a lightweight migration from the 2.4 store.
    var parentArtifactID: String?
    var buildVersion: String?
    var externalVersionID: String?
    var fileSize: Int64?
    var sha256: String?
    var importedAt: Date?
    var buildDate: Date?

    var artifactSource: String { sourceTag ?? (appId == 0 ? "Imported" : "Downloaded") }
    var libraryGroupID: String { "\(platform ?? "iOS")|\(bundleID)" }
    var supportsIPAOperations: Bool { platform != AppPlatform.macos.rawValue && URL(fileURLWithPath: filePath).pathExtension.lowercased() != "pkg" }
    var storeApp: AppStoreApp {
        AppStoreApp(id: appId, bundleID: bundleID, name: name, version: version, price: price,
                    iconURL: iconURL, platform: platform.flatMap(AppPlatform.init(rawValue:)))
    }

    init(app: AppStoreApp, downloadDate: Date = Date(), filePath: String, versionOverride: String? = nil) {
        let resolvedVersion = versionOverride ?? app.version ?? ""
        self.id = UUID().uuidString
        self.appId = app.id ?? 0
        self.bundleID = app.bundleID ?? ""
        self.name = app.name ?? ""
        self.version = resolvedVersion
        self.price = app.price ?? 0.0
        self.iconURL = app.iconURL
        self.platform = app.platform?.rawValue
        self.downloadDate = downloadDate
        self.filePath = filePath
        self.importedAt = downloadDate
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
    var version: String? = nil
}

struct AppVersion: Identifiable {
    let id: String
    let isLatest: Bool
    var displayVersion: String?
    var releaseDate: Date?
    var minimumOSVersion: String?
    var metadataFinished = false
}

struct VersionDisplayInfo {
    let versionString: String
    let releaseDate: Date?
    let minimumOSVersion: String?
}

enum VersionsLoadState {
    case loading
    case loaded([AppVersion])
    case error(String)
}

struct VersionsOutput {
    let versionIds: [String]
    let latestVersionId: String
}
