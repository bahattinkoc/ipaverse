import Foundation

struct IPAComparisonAssetVersion: Codable {
    let metadata: [String: String]
    let digest: String?
    let preview: Data?
    let state: String
    let issue: String?

    var summary: String {
        let kind = metadata["Kind"] ?? "Asset"
        if let width = metadata["PixelWidth"], let height = metadata["PixelHeight"] { return "\(kind) · \(width) × \(height)" }
        return kind
    }
}

struct IPAComparisonAsset: Codable, Identifiable {
    var id: String { source + "|" + key }
    let source: String
    let key: String
    let name: String
    let variant: String
    let kind: String
    let before: IPAComparisonAssetVersion?
    let after: IPAComparisonAssetVersion?

    var rowID: String { "Asset catalogs|" + source + "|" + name + " [" + variant + "]" }
    var row: IPAComparisonChange {
        IPAComparisonChange(category: "Asset catalogs", source: source, path: name + " [" + variant + "]", kind: kind,
            before: before?.summary, after: after?.summary, valueType: "asset rendition")
    }
    var swapped: Self {
        Self(source: source, key: key, name: name, variant: variant,
            kind: kind == "Added" ? "Removed" : kind == "Removed" ? "Added" : kind, before: after, after: before)
    }
}

enum IPAComparisonAssets {
    struct Entry {
        let source: String
        let key: String
        let name: String
        let variant: String
        let version: IPAComparisonAssetVersion
        var id: String { source + "|" + key }
    }

    static func read(_ file: URL, source: String, budget: inout Int, into snapshot: inout IPAComparison.Snapshot) throws {
        var error: NSError?
        let records = IPAReadAssetCatalog(file, UInt(max(0, budget)), { Task.isCancelled }, &error)
        try Task.checkCancellation()
        guard let records else { throw error ?? IPAComparisonError.invalidData("Asset catalog could not be read") as NSError }
        let entries = try parse(records, source: source)
        for entry in entries { snapshot.assetEntries[entry.id] = entry }
        budget = max(0, budget - entries.reduce(0) { $0 + ($1.version.preview?.count ?? 0) })
        let unavailable = entries.filter { $0.version.state != "Complete" || $0.version.issue != nil }.count
        // Inventory is complete even if individual renditions have no renderable representation.
        snapshot.status("Asset catalogs", source, "Complete", "\(entries.count) asset variants · \(unavailable) without full visual coverage")
    }

    static func parse(_ records: [[String: Any]], source: String) throws -> [Entry] {
        var entries: [String: Entry] = [:]
        for record in records {
            guard let name = record["Name"] as? String, !name.isEmpty,
                  let rawVariant = record["Variant"] as? [String: Any] else { throw IPAComparisonError.invalidData("Invalid asset catalog rendition") }
            if name.hasPrefix("ZZ"), name.contains("PackedAsset") { continue }
            let variant = rawVariant.mapValues(string)
            let keyData = try JSONSerialization.data(withJSONObject: ["name": name, "variant": variant], options: [.sortedKeys])
            let key = String(decoding: keyData, as: UTF8.self)
            let label = variantLabel(variant)
            let metadata = (record["Metadata"] as? [String: Any] ?? [:]).mapValues(string)
                .filter { $0.key != "RenditionType" } // Storage encoding can change without changing the rendered asset.
            let version = IPAComparisonAssetVersion(metadata: metadata, digest: record["Digest"] as? String,
                preview: record["Preview"] as? Data, state: record["State"] as? String ?? "Unavailable", issue: record["Issue"] as? String)
            let entry = Entry(source: source, key: key, name: name, variant: label, version: version)
            if let previous = entries[key] {
                if equivalent(previous.version, version), previous.version.state == "Complete", version.state == "Complete" {
                    if previous.version.preview == nil { entries[key] = entry }
                    continue
                }
                // Never pair duplicate variant identities by unstable enumeration order.
                throw IPAComparisonError.invalidData("Ambiguous asset variant: \(name) [\(label)]")
            }
            entries[key] = entry
        }
        return entries.values.sorted { $0.key < $1.key }
    }

    static func compare(_ a: IPAComparison.Snapshot, _ b: IPAComparison.Snapshot) -> [IPAComparisonAsset] {
        Set(a.assetEntries.keys).union(b.assetEntries.keys).sorted().compactMap { key in
            let first = a.assetEntries[key], second = b.assetEntries[key]
            guard let entry = first ?? second else { return nil }
            let badInventory = [a.coverage["Asset catalogs|" + entry.source], b.coverage["Asset catalogs|" + entry.source]].compactMap { $0 }
                .contains { $0.state != "Complete" }
            let unavailable = [first?.version, second?.version].compactMap { $0 }.contains { $0.state != "Complete" || $0.digest == nil }
            let kind: String
            if badInventory { kind = "Not compared" }
            else if first == nil { kind = "Added" }
            else if second == nil { kind = "Removed" }
            else if unavailable { kind = "Not compared" }
            else { kind = equivalent(first!.version, second!.version) ? "Unchanged" : "Changed" }
            return IPAComparisonAsset(source: entry.source, key: entry.key, name: entry.name, variant: entry.variant,
                kind: kind, before: first?.version, after: second?.version)
        }
    }

    private static func equivalent(_ a: IPAComparisonAssetVersion, _ b: IPAComparisonAssetVersion) -> Bool {
        a.digest == b.digest && a.metadata == b.metadata
    }
    private static func string(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
    private static func variantLabel(_ variant: [String: String]) -> String {
        var parts: [String] = []
        if let scale = variant["Scale"] { parts.append("@\(scale)x") }
        if let idiom = variant["Idiom"] {
            parts.append(["1": "iPhone", "2": "iPad", "3": "TV", "4": "Car", "5": "Watch", "6": "Marketing" ][idiom] ?? "Idiom \(idiom)")
        } else { parts.append("Universal") }
        if let appearance = variant["Appearance"] { parts.append(appearance) }
        for key in variant.keys.sorted() where !["Scale", "Idiom", "Appearance"].contains(key) { parts.append(key + "=" + variant[key]!) }
        return parts.joined(separator: " · ")
    }
}
