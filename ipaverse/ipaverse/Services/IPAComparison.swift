import Foundation
import CryptoKit
import CoreFoundation

struct ComparisonInput: Identifiable, Codable, Hashable {
    var id = UUID()
    let left: String
    let right: String
    var leftSource: String? = nil
    var rightSource: String? = nil
}

struct IPAComparisonChange: Codable, Identifiable {
    var id: String { category + "|" + source + "|" + path }
    let category: String
    let source: String
    let path: String
    let kind: String
    let before: String?
    let after: String?
    var valueType: String = "string"
    var signingArtifact = false
    var uuid = false
}

struct IPAComparisonCoverage: Codable, Identifiable {
    var id: String { category + "|" + source }
    let category: String
    let source: String
    let state: String
    let detail: String
}

struct IPAComparisonIdentity: Codable {
    var name = ""
    var bundleID = ""
    var version = ""
    var build = ""
    var archiveBytes: Int64 = 0
    var extractedBytes: Int64 = 0
}

struct IPAComparisonPreview: Codable, Identifiable {
    var id: String { source }
    let source: String
    let before: Data?
    let after: Data?
}

struct IPAComparisonReport: Codable {
    let rulesVersion: String
    let leftName: String
    let rightName: String
    let left: IPAComparisonIdentity
    let right: IPAComparisonIdentity
    let rows: [IPAComparisonChange]
    let leftCoverage: [IPAComparisonCoverage]
    let rightCoverage: [IPAComparisonCoverage]
    let deepAnalysis: Bool
    let notes: [String]
    var previews: [IPAComparisonPreview] = []
    var assets: [IPAComparisonAsset] = []
    var fileSizes: [IPAComparisonFileSize] = []
    var changes: [IPAComparisonChange] { rows.filter { $0.kind != "Unchanged" && $0.kind != "Not compared" } }
}

enum IPAComparisonError: LocalizedError {
    case missingBundleID, differentBundleIDs(String, String), ambiguousPayload, invalidData(String)
    var errorDescription: String? {
        switch self {
        case .missingBundleID: return "Both IPAs must contain a non-empty CFBundleIdentifier."
        case let .differentBundleIDs(a, b): return "Bundle IDs do not match: \(a) / \(b)."
        case .ambiguousPayload: return "The IPA must contain exactly one main app in Payload."
        case .invalidData(let detail): return detail
        }
    }
}

enum IPAComparison {
    static let categories = ["Files", "Info.plist", "Entitlements", "Signing", "Mach-O", "Components", "Resources", "Asset catalogs", "Binary content", "Symbols", "Classes", "Strings", "Endpoints", "Security findings"]
    static let deepCategories = ["Symbols", "Classes", "Strings", "Endpoints"]

    struct Value {
        let category: String
        let source: String
        let path: String
        let text: String
        var type = "string"
        var signing = false
        var uuid = false
        var id: String { category + "|" + source + "|" + path }
    }
    struct Snapshot {
        var identity = IPAComparisonIdentity()
        var values: [String: Value] = [:]
        var coverage: [String: IPAComparisonCoverage] = [:]
        var notes: [String] = []
        var resourceStrings: [String: [String]] = [:]
        var imagePreviews: [String: Data] = [:]
        var assetEntries: [String: IPAComparisonAssets.Entry] = [:]
        var fileSizes: [String: Int64] = [:]
        mutating func add(_ category: String, _ source: String, _ path: String, _ text: String,
                          type: String = "string", signing: Bool = false, uuid: Bool = false) {
            let value = Value(category: category, source: source, path: path, text: text, type: type, signing: signing, uuid: uuid)
            values[value.id] = value
            if type == "string", category == "Resources" || category == "Info.plist" {
                resourceStrings[source, default: []].append(text)
            }
        }
        mutating func status(_ category: String, _ source: String, _ state: String = "Complete", _ detail: String = "") {
            let item = IPAComparisonCoverage(category: category, source: source, state: state, detail: detail)
            coverage[item.id] = item
        }
        mutating func capture(_ category: String, _ source: String, body: (inout Snapshot) throws -> Void) throws {
            do {
                try Task.checkCancellation()
                try body(&self)
                if coverage[category + "|" + source] == nil { status(category, source) }
            } catch is CancellationError { throw CancellationError() }
            catch { status(category, source, "Failed", error.localizedDescription) }
        }
    }

    static func validateBundleIDs(_ left: String, _ right: String) throws {
        guard !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IPAComparisonError.missingBundleID }
        guard left == right else { throw IPAComparisonError.differentBundleIDs(left, right) }
    }

    static func compare(left: URL, right: URL, deep: Bool = false, progress: @escaping (String) -> Void) throws -> IPAComparisonReport {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        progress("Extracting A…")
        let firstApp = try extract(left, to: work.appendingPathComponent("A"))
        progress("Extracting B…")
        let secondApp = try extract(right, to: work.appendingPathComponent("B"))
        let firstID = try identity(firstApp, archive: left)
        let secondID = try identity(secondApp, archive: right)
        try validateBundleIDs(firstID.bundleID, secondID.bundleID)
        progress("Analyzing A…")
        var first = try snapshot(app: firstApp, identity: firstID, deep: deep, progress: { progress("A · " + $0) })
        progress("Analyzing B…")
        var second = try snapshot(app: secondApp, identity: secondID, deep: deep, progress: { progress("B · " + $0) })
        progress("Comparing binary content…")
        try compareOpaqueFiles(firstApp, secondApp, left: &first, right: &second)
        try Task.checkCancellation()
        return diff(first, second, leftName: left.lastPathComponent, rightName: right.lastPathComponent, deep: deep)
    }

    static func diff(_ left: Snapshot, _ right: Snapshot, leftName: String, rightName: String, deep: Bool = false) -> IPAComparisonReport {
        var rows = Set(left.values.keys).union(right.values.keys).sorted().compactMap { key -> IPAComparisonChange? in
            let a = left.values[key], b = right.values[key]
            guard let value = a ?? b else { return nil }
            // Missing values from a failed/skipped pass are unknown, never additions/removals.
            let incomplete = [coverage(for: value, in: left), coverage(for: value, in: right)].compactMap { $0 }
                .contains { $0.state != "Complete" }
            let kind = incomplete ? "Not compared" : a == nil ? "Added" : b == nil ? "Removed" :
                (a?.text == b?.text && a?.type == b?.type) ? "Unchanged" : "Changed"
            return IPAComparisonChange(category: value.category, source: value.source, path: value.path, kind: kind,
                before: a?.text, after: b?.text, valueType: a?.type == b?.type || a == nil || b == nil ? value.type : "\(a!.type) → \(b!.type)",
                signingArtifact: value.signing, uuid: value.uuid)
        }
        let assets = IPAComparisonAssets.compare(left, right)
        rows.append(contentsOf: assets.map(\.row))
        let previews = Set(left.imagePreviews.keys).union(right.imagePreviews.keys).sorted().compactMap { source -> IPAComparisonPreview? in
            guard left.values["Files|" + source + "|Content"]?.text != right.values["Files|" + source + "|Content"]?.text else { return nil }
            return IPAComparisonPreview(source: source, before: left.imagePreviews[source], after: right.imagePreviews[source])
        }
        let fileSizes = Set(left.fileSizes.keys).union(right.fileSizes.keys).sorted().map {
            IPAComparisonFileSize(source: $0, before: left.fileSizes[$0], after: right.fileSizes[$0])
        }
        return IPAComparisonReport(rulesVersion: "ipaverse-compare-6", leftName: leftName, rightName: rightName,
            left: left.identity, right: right.identity, rows: rows,
            leftCoverage: left.coverage.values.sorted { $0.id < $1.id }, rightCoverage: right.coverage.values.sorted { $0.id < $1.id },
            deepAnalysis: deep, notes: ["ZIP timestamps, compression and the main .app folder name are excluded from structural comparison. Raw file hashes include signatures and UUIDs.",
                "Security findings use local scanner rules; evidence is redacted. Symbols, classes and strings describe extracted static metadata, not runtime behavior."] + left.notes + right.notes, previews: previews, assets: assets, fileSizes: fileSizes)
    }

    private static func coverage(for value: Value, in snapshot: Snapshot) -> IPAComparisonCoverage? {
        if let exact = snapshot.coverage[value.category + "|" + value.source] { return exact }
        // A whole-binary failure also covers every architecture/method sub-pass.
        var source = value.source
        if source.hasSuffix(" / Methods") {
            source = String(source.dropLast(" / Methods".count))
            if let slice = snapshot.coverage[value.category + "|" + source] { return slice }
        }
        if let range = source.range(of: " [", options: .backwards), source.hasSuffix("]"),
           let binary = snapshot.coverage[value.category + "|" + source[..<range.lowerBound]] { return binary }
        return snapshot.coverage[value.category + "|*"]
    }

    private static func extract(_ archive: URL, to directory: URL) throws -> URL {
        try Task.checkCancellation()
        try IPASecurityScanner.validateArchiveLimits(ipaPath: archive.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try ProcessRunner.run("/usr/bin/unzip", ["-q", archive.path, "-d", directory.path])
        try IPASecurityScanner.validateExtractedTree(at: directory)
        let apps = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Payload"), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard apps.count == 1 else { throw IPAComparisonError.ambiguousPayload }
        return apps[0]
    }

    static func readPlist(_ file: URL) throws -> Any {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw IPAComparisonError.invalidData("Plist exceeds 8 MiB: \(file.lastPathComponent)") }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
    }

    private static func identity(_ app: URL, archive: URL) throws -> IPAComparisonIdentity {
        guard let plist = try readPlist(app.appendingPathComponent("Info.plist")) as? [String: Any] else {
            throw IPAComparisonError.missingBundleID
        }
        return IPAComparisonIdentity(name: plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? "App",
            bundleID: plist["CFBundleIdentifier"] as? String ?? "", version: plist["CFBundleShortVersionString"] as? String ?? "",
            build: plist["CFBundleVersion"] as? String ?? "", archiveBytes: Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    }

    static func fingerprint(_ text: String) -> String { hash(Data(text.utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // JSON Pointer escaping keeps keys containing slashes distinct from nested keys.
    static func escaped(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }

    static func flatten(_ value: Any, category: String, source: String, prefix: String = "", signing: Bool = false, into result: inout Snapshot) {
        func add(_ text: String, _ type: String) { result.add(category, source, prefix, text, type: type, signing: signing) }
        if let dict = value as? [String: Any] {
            if dict.isEmpty { add("{}", "dictionary") }
            for key in dict.keys.sorted() {
                flatten(dict[key]!, category: category, source: source, prefix: prefix + "/" + escaped(key), signing: signing, into: &result)
            }
        } else if let array = value as? [Any] {
            // Only known set-valued fields ignore ordering; arbitrary arrays retain their indexes.
            let setKeys: Set<String> = ["keychain-access-groups", "com.apple.security.application-groups", "com.apple.developer.associated-domains", "ProvisionedDevices", "UIBackgroundModes", "CFBundleURLSchemes", "UIDeviceFamily", "CFBundleSupportedPlatforms"]
            if array.isEmpty { add("[]", "array") }
            if setKeys.contains(prefix.components(separatedBy: "/").last ?? ""), array.allSatisfy({ $0 is String || $0 is NSNumber }) {
                for item in Set(array.map { String(describing: $0) }).sorted() {
                    result.add(category, source, prefix + "/" + escaped(item), item, type: "set member", signing: signing)
                }
            } else {
                for (index, item) in array.enumerated() { flatten(item, category: category, source: source, prefix: prefix + "/[\(index)]", signing: signing, into: &result) }
            }
        } else if let data = value as? Data { add(data.base64EncodedString(), "data (base64)") }
        else if let date = value as? Date { add(ISO8601DateFormatter().string(from: date), "date") }
        else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { add(number.boolValue ? "true" : "false", "boolean") }
            else { add(number.stringValue, "number") }
        } else if value is NSNull { add("null", "null") }
        else { add(String(describing: value), "string") }
    }
}
