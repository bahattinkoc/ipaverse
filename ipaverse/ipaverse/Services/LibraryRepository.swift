import Foundation
import SwiftData
import CryptoKit

enum LibraryRepository {
    @MainActor
    @discardableResult
    static func upsertFile(app: AppStoreApp, filePath: String, context: ModelContext,
                           version: String? = nil, hash: String? = nil) throws -> DownloadedApp {
        let path = URL(fileURLWithPath: filePath).standardizedFileURL.path
        let descriptor = FetchDescriptor<DownloadedApp>(predicate: #Predicate { $0.filePath == path })
        let existing = try context.fetch(descriptor).first
        let record = existing ?? DownloadedApp(app: app, filePath: path, versionOverride: version)
        if existing == nil { context.insert(record) }
        record.bundleID = app.bundleID ?? record.bundleID
        record.name = app.name ?? record.name
        record.version = version ?? app.version ?? record.version
        record.platform = app.platform?.rawValue ?? record.platform
        record.fileSize = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        record.downloadDate = Date()
        record.importedAt = record.importedAt ?? Date()
        if let hash, let previousHash = record.sha256, hash != previousHash {
            record.sourceTag = nil
            record.parentArtifactID = nil
            record.externalVersionID = nil
            record.appId = app.id ?? 0
        }
        record.sha256 = hash
        try context.save()
        return record
    }

    @MainActor
    static func recordDownload(app: AppStoreApp, filePath: String, version: String?,
                               externalVersionID: String?, context: ModelContext) async throws -> String? {
        let details = await Task.detached { () -> (String?, String?, Date?, String?) in
            let plist = app.platform == .macos ? nil : try? IPAResigner.loadInfoPlist(ipaPath: filePath)
            return (plist?["CFBundleShortVersionString"] as? String, plist?["CFBundleVersion"] as? String,
                    app.platform == .macos ? nil : IPAResigner.appBuildDate(ipaPath: filePath),
                    try? fileHash(URL(fileURLWithPath: filePath)))
        }.value
        let record = try upsertFile(app: app, filePath: filePath, context: context,
            version: details.0 ?? version ?? externalVersionID.map { "Build \($0)" } ?? app.version, hash: details.3)
        record.appId = app.id ?? 0
        record.sourceTag = nil
        record.parentArtifactID = nil
        record.externalVersionID = externalVersionID
        record.buildVersion = details.1
        record.buildDate = details.2
        record.sha256 = details.3
        try context.save()
        // Return the readable version, never the synthetic "Build <store ID>" fallback.
        return details.0 ?? version ?? (externalVersionID == nil ? app.version : nil)
    }

    static func fileHash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func relink(_ record: DownloadedApp, to url: URL, context: ModelContext) async throws {
        let originalID = record.id
        let expectedBundle = record.bundleID
        let expectedVersion = record.version
        let details = try await Task.detached { () -> (AppStoreApp, String) in
            (try IPAImporter.metadata(for: url), try fileHash(url))
        }.value
        guard details.0.bundleID == expectedBundle else {
            throw CocoaError(.validationMissingMandatoryProperty, userInfo: [NSLocalizedDescriptionKey: "Choose a file for \(expectedBundle)."])
        }
        if let hash = record.sha256, hash != details.1 {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This is a different copy. Import it as a new library item instead."])
        }
        if record.sha256 == nil, !expectedVersion.isEmpty, details.0.version != expectedVersion {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Choose version \(expectedVersion), or import this file as a new copy."])
        }
        let path = url.standardizedFileURL.path
        let duplicates = try context.fetch(FetchDescriptor<DownloadedApp>(predicate: #Predicate { $0.filePath == path }))
        guard !duplicates.contains(where: { $0.id != originalID }) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "This file already belongs to another library copy."])
        }
        guard record.id == originalID else { return }
        record.filePath = path
        record.sha256 = details.1
        record.fileSize = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        try context.save()
    }
}
