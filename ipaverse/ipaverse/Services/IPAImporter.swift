//
//  IPAImporter.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//

import Foundation
import SwiftData
import AppKit
import ImageIO

// MARK: - IPAImportError

enum IPAImportError: LocalizedError {
    case notAnIPA(String)
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .notAnIPA(let name): "\"\(name)\" is not an .ipa file"
        case .missingBundleIdentifier: "Could not read CFBundleIdentifier from the IPA's Info.plist"
        }
    }
}

// MARK: - IPAImporter

/// Imports an arbitrary `.ipa` file from disk into the Downloaded list so it can be
/// edited, re-signed, and installed exactly like a store-downloaded app.
struct IPAImporter {

    /// Reads the IPA's Info.plist and builds an `AppStoreApp` describing it.
    /// Imported IPAs are not tied to an App Store record, so `id`/`price` are 0 and
    /// `iconURL` is nil.
    static func metadata(for ipaURL: URL) throws -> AppStoreApp {
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw IPAImportError.notAnIPA(ipaURL.lastPathComponent)
        }

        let plist = try IPAResigner.loadInfoPlist(ipaPath: ipaURL.path)

        guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw IPAImportError.missingBundleIdentifier
        }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? ipaURL.deletingPathExtension().lastPathComponent
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? ""

        return AppStoreApp(
            id: 0,
            bundleID: bundleID,
            name: name,
            version: version,
            price: 0,
            iconURL: nil,
            platform: .ios
        )
    }

    /// Imports the IPA at `ipaURL` into SwiftData. If a record with the same identity
    /// (`appId_bundleID_version`) already exists, its file path and date are updated
    /// instead of inserting a duplicate. Returns the inserted/updated record so
    /// callers can tag it (e.g. `sourceTag`) without a second fetch.
    ///
    /// The actual file work (unzip listing, Info.plist parsing, icon
    /// extraction) runs off the main actor — those calls were previously made
    /// directly from this `@MainActor` function and could visibly freeze the
    /// UI for a couple of seconds on a large IPA. Only the SwiftData
    /// fetch/insert/save at the end touches `context`, which needs to stay
    /// on the main actor.
    @discardableResult
    @MainActor
    static func importIPA(at ipaURL: URL, into context: ModelContext) async throws -> DownloadedApp {
        let imported = try await Task.detached(priority: .userInitiated) { () -> DownloadedApp in
            let app = try metadata(for: ipaURL)
            // Prefer the app's build date (from the IPA) over "now" for imported apps.
            let date = IPAResigner.appBuildDate(ipaPath: ipaURL.path) ?? Date()
            let prepared = DownloadedApp(app: app, downloadDate: date, filePath: ipaURL.path)
            // Extract the embedded app icon to a local cache so the row shows it.
            // Best-effort: a missing icon must not fail the import.
            prepared.iconURL = cacheIcon(for: prepared.id, ipaURL: ipaURL)
            return prepared
        }.value

        let identity = imported.id
        let descriptor = FetchDescriptor<DownloadedApp>(
            predicate: #Predicate<DownloadedApp> { $0.id == identity }
        )

        let result: DownloadedApp
        if let existing = try context.fetch(descriptor).first {
            existing.filePath = imported.filePath
            existing.downloadDate = imported.downloadDate
            if let iconURLString = imported.iconURL { existing.iconURL = iconURLString }
            result = existing
        } else {
            context.insert(imported)
            result = imported
        }
        try context.save()
        return result
    }

    /// Whether the IPA's main binary is *not* FairPlay-encrypted — i.e. it's
    /// already a decrypted, re-signable copy rather than a raw App Store
    /// download. Pulls just the main executable out of the zip (same
    /// approach as `ResigningVM`'s entitlement check) instead of extracting
    /// the whole IPA. Returns `false` (don't tag) if this can't be determined.
    static func isDecrypted(ipaURL: URL) -> Bool {
        guard let entries = try? IPAResigner.listEntries(ipaPath: ipaURL.path),
              let appDirEntry = entries.first(where: {
                  $0.hasSuffix(".app/") && $0.hasPrefix("Payload/") && $0.components(separatedBy: "/").count == 3
              })
        else { return false }

        let appName = String(appDirEntry.dropFirst("Payload/".count).dropLast(".app/".count))
        let binaryEntry = "Payload/\(appName).app/\(appName)"
        guard let data = try? IPAResigner.readEntry(ipaPath: ipaURL.path, entryName: binaryEntry), !data.isEmpty else {
            return false
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? data.write(to: tempURL)) != nil else { return false }
        return !IPAResigner.isFairPlayEncrypted(binaryURL: tempURL)
    }

    // MARK: - Icon cache

    /// Extracts the IPA's app icon, re-encodes it to a standard PNG (ImageIO
    /// transparently handles Apple's CgBI format), writes it to the on-disk icon
    /// cache, and returns a file-URL string for `DownloadedApp.iconURL`.
    private static func cacheIcon(for identity: String, ipaURL: URL) -> String? {
        guard let raw = try? IPAResigner.extractRawAppIcon(ipaPath: ipaURL.path),
              let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let directory = iconCacheDirectory()
        let safeName = identity.replacingOccurrences(of: "/", with: "_")
        let fileURL = directory.appendingPathComponent("\(safeName).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: fileURL)
            return fileURL.absoluteString
        } catch {
            return nil
        }
    }

    private static func iconCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ipaverse/Icons", isDirectory: true)
    }
}
