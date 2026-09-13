import Foundation
import CryptoKit

struct ComparisonInput: Identifiable {
    let id = UUID()
    let left: String
    let right: String
}

struct IPAComparisonChange: Codable, Identifiable {
    var id: String { category + "|" + path }
    let category: String
    let path: String
    let kind: String
    let before: String?
    let after: String?
}

struct IPAComparisonReport: Codable {
    let rulesVersion: String
    let leftName: String
    let rightName: String
    let changes: [IPAComparisonChange]
    let notes: [String]
}

enum IPAComparison {
    struct Snapshot {
        var files: [String: String] = [:]
        var plist: [String: String] = [:]
        var entitlements: [String: String] = [:]
        var frameworks: [String: String] = [:]
        var findings: [String: String] = [:]
        var notes: [String] = []
    }

    static func compare(left: URL, right: URL, progress: @escaping (String) -> Void) throws -> IPAComparisonReport {
        progress("Reading first IPA…")
        let first = try snapshot(left)
        try Task.checkCancellation()
        progress("Reading second IPA…")
        let second = try snapshot(right)
        return diff(first, second, leftName: left.lastPathComponent, rightName: right.lastPathComponent)
    }

    static func diff(_ left: Snapshot, _ right: Snapshot, leftName: String, rightName: String) -> IPAComparisonReport {
        var changes: [IPAComparisonChange] = []
        for (category, first, second) in [("Info.plist", left.plist, right.plist),
            ("Entitlements", left.entitlements, right.entitlements), ("Frameworks", left.frameworks, right.frameworks),
            ("Files", left.files, right.files), ("Security findings", left.findings, right.findings)] {
            for key in Set(first.keys).union(second.keys).sorted() where first[key] != second[key] {
                let safeValues = category == "Files" || category == "Frameworks" || category == "Security findings" || key.hasSuffix("/CFBundleShortVersionString") || key.hasSuffix("/CFBundleVersion") || key.hasSuffix("/MinimumOSVersion")
                changes.append(IPAComparisonChange(category: category, path: key,
                    kind: first[key] == nil ? "Added" : second[key] == nil ? "Removed" : "Changed",
                    before: first[key].map { safeValues ? $0 : "Present (value hidden)" },
                    after: second[key].map { safeValues ? $0 : "Present (value hidden)" }))
            }
        }
        return IPAComparisonReport(rulesVersion: "ipaverse-2.5.1", leftName: leftName, rightName: rightName, changes: changes,
            notes: ["ZIP timestamps, compression and the main .app folder name are ignored. Code signature resource files are excluded. Configuration values are hidden by default."] + left.notes + right.notes)
    }

    static func snapshot(_ url: URL) throws -> Snapshot {
        try IPASecurityScanner.validateArchiveLimits(ipaPath: url.path)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        _ = try ProcessRunner.run("/usr/bin/unzip", ["-q", url.path, "-d", work.path])
        try IPASecurityScanner.validateExtractedTree(at: work)
        let payload = work.appendingPathComponent("Payload")
        guard let app = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw IPAResignError.appBundleNotFound
        }
        var result = Snapshot()
        guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in files {
            try Task.checkCancellation()
            let path = String(file.path.dropFirst(app.path.count + 1))
            if path.split(separator: "/").contains("_CodeSignature") { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if file.pathExtension == "framework" { result.frameworks[path] = "Framework" }
            guard values.isRegularFile == true else { continue }
            result.files[path] = "\(values.fileSize ?? 0) bytes · SHA-256 \(try LibraryRepository.fileHash(file))"
            if file.lastPathComponent == "Info.plist" {
                guard (values.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw PackageDownloadError.invalidPackage }
                let data = try Data(contentsOf: file)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                flatten(plist, prefix: path, into: &result.plist)
                if let dict = plist as? [String: Any], let executable = dict["CFBundleExecutable"] as? String,
                   !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"), executable != ".", executable != ".." {
                    let binary = file.deletingLastPathComponent().appendingPathComponent(executable)
                    if FileManager.default.fileExists(atPath: binary.path) {
                        let entitlements = IPAResigner.extractSignedEntitlements(fromBinaryAt: binary)
                        if entitlements.isEmpty { result.notes.append("\(url.lastPathComponent): no readable entitlements for \(path).") }
                        flatten(entitlements, prefix: path, into: &result.entitlements)
                    }
                }
            }
        }
        let scan = try IPASecurityScanner.scanExtracted(at: work, appName: app.lastPathComponent, progress: { _ in })
        for finding in scan.findings {
            // UUIDs and temporary/.app directory names do not identify a rule.
            // Hash evidence so exported comparisons never include raw secrets.
            func normalized(_ text: String) -> String {
                text.replacingOccurrences(of: "Payload/" + app.lastPathComponent + "/", with: "")
                    .replacingOccurrences(of: app.lastPathComponent + "/", with: "")
                    .replacingOccurrences(of: work.path, with: "")
            }
            let rule = fingerprint(finding.category + "|" + finding.title)
            let evidence = fingerprint(normalized(finding.rawValue ?? finding.snippet ?? ""))
            let key = finding.category + "/" + normalized(finding.location ?? "App") + "/" + rule + "/" + evidence
            result.findings[key] = finding.severity.label
        }
        result.notes.append("Security findings are local heuristics; evidence is represented by SHA-256 fingerprints. Scanner rules: ipaverse-2.5.1.")
        return result
    }

    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func flatten(_ value: Any, prefix: String, into values: inout [String: String]) {
        if let dict = value as? [String: Any] {
            if dict.isEmpty { values[prefix] = "{}" }
            for key in dict.keys.sorted() { flatten(dict[key]!, prefix: prefix + "/" + key, into: &values) }
        } else if let array = value as? [Any] {
            if array.isEmpty { values[prefix] = "[]" }
            for (index, value) in array.enumerated() { flatten(value, prefix: prefix + "/[\(index)]", into: &values) }
        } else if let data = value as? Data {
            values[prefix] = "data:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else if let date = value as? Date { values[prefix] = "date:" + ISO8601DateFormatter().string(from: date) }
        else { values[prefix] = String(describing: value) }
    }
}
