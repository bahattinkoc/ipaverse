//
//  BundleIdentityMigrator.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 3.09.2026.
//

import Foundation

struct IdentityReference: Identifiable, Sendable {
    var id: String { path }
    let path: String              // zip entry path, e.g. "Payload/X.app/Netmera-Config.plist"
    let matchedStrings: [String]  // which needles were found in this file
}

enum BundleIdentityMigratorError: LocalizedError {
    case appBundleNotFound

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound: "No .app bundle found inside Payload"
        }
    }
}

/// Finds and rewrites config files that embed the app's own bundle ID or an
/// App-Group identifier derived from it — e.g. a 3rd-party SDK's own config
/// plist telling it which shared container to use. Resigning under a
/// different bundle ID/App Group (because the original isn't registrable
/// under the new signing identity's team) silently breaks anything still
/// pointing at the old identifiers, exactly like NetmeraCore's
/// `app_group_name` did. Not tied to any specific SDK — this scans generically.
struct BundleIdentityMigrator {

    /// Scans every `.plist`/`.json` file in the IPA (main app + app
    /// extensions) for occurrences of any `needle` string as plain text.
    /// Skips `Info.plist` — its `CFBundleIdentifier` is already managed
    /// through the resigner's own plist-edit mechanism, and double-editing it
    /// here would just create a second, conflicting source of truth.
    static func scanForIdentityReferences(ipaPath: String, needles: [String]) throws -> [IdentityReference] {
        let nonEmptyNeedles = needles.filter { !$0.isEmpty }
        guard !nonEmptyNeedles.isEmpty else { return [] }

        let entries = try IPAResigner.listEntries(ipaPath: ipaPath)
        var results: [IdentityReference] = []

        for entry in entries {
            guard !entry.hasSuffix("/") else { continue }
            let ext = (entry as NSString).pathExtension.lowercased()
            guard ext == "plist" || ext == "json" else { continue }
            guard (entry as NSString).lastPathComponent != "Info.plist" else { continue }

            guard let data = try? IPAResigner.readEntry(ipaPath: ipaPath, entryName: entry),
                  let text = decodedText(from: data, isPlist: ext == "plist") else { continue }

            let matched = nonEmptyNeedles.filter { text.contains($0) }
            if !matched.isEmpty {
                results.append(IdentityReference(path: entry, matchedStrings: matched))
            }
        }

        return results
    }

    /// Applies `replacements` (old → new) as text substitution to each
    /// referenced file's content, returning path → new content — ready to
    /// merge directly into `ResignConfig.fileReplacements`.
    static func applyReplacements(
        ipaPath: String, references: [IdentityReference], replacements: [String: String]
    ) throws -> [String: Data] {
        var results: [String: Data] = [:]
        for reference in references {
            let original = try IPAResigner.readEntry(ipaPath: ipaPath, entryName: reference.path)
            let isPlist = (reference.path as NSString).pathExtension.lowercased() == "plist"
            guard var text = decodedText(from: original, isPlist: isPlist) else { continue }
            for (old, new) in replacements where !old.isEmpty {
                text = text.replacingOccurrences(of: old, with: new)
            }
            results[reference.path] = Data(text.utf8)
        }
        return results
    }

    /// Plists on iOS are commonly stored in Apple's *binary* format, not XML —
    /// raw UTF8 decoding silently misses those (binary plists aren't valid
    /// UTF8 text), which would make the scan quietly skip exactly the kind of
    /// file this feature exists to catch. `PropertyListSerialization` parses
    /// either on-disk format transparently; re-serializing to XML always
    /// gives UTF8 text to search/replace, regardless of the original
    /// encoding. Output is always written back as XML plist — Foundation's
    /// plist-reading APIs (what any SDK uses) accept either format
    /// interchangeably, so this doesn't change runtime behavior.
    private static func decodedText(from data: Data, isPlist: Bool) -> String? {
        guard isPlist else { return String(data: data, encoding: .utf8) }  // JSON is already plain text
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xmlData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return nil }
        return String(data: xmlData, encoding: .utf8)
    }
}
