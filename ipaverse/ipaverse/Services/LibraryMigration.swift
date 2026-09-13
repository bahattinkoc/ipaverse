import Foundation
import SwiftData

/// Exact 2.4 model: keep frozen so existing unversioned stores can migrate.
enum LibrarySchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [DownloadedApp.self] }
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

        init(app: AppStoreApp, downloadDate: Date = Date(), filePath: String, versionOverride: String? = nil) {
            let resolvedVersion = versionOverride ?? app.version ?? ""
            self.id = "\(app.id ?? 0)_\(app.bundleID ?? "")_\(resolvedVersion)"
            self.appId = app.id ?? 0
            self.bundleID = app.bundleID ?? ""
            self.name = app.name ?? ""
            self.version = resolvedVersion
            self.price = app.price ?? 0.0
            self.iconURL = app.iconURL
            self.platform = app.platform?.rawValue
            self.downloadDate = downloadDate
            self.filePath = filePath
        }
    }
}

enum LibrarySchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [DownloadedApp.self] }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self, LibrarySchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: LibrarySchemaV1.self, toVersion: LibrarySchemaV2.self)] }
}
