import Foundation
import Security

extension IPAComparison {
    static func snapshot(app: URL, identity: IPAComparisonIdentity, deep: Bool, progress: @escaping (String) -> Void) throws -> Snapshot {
        var result = Snapshot()
        result.identity = identity
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var binaries: [(URL, String)] = []
        var textBudget = 32 * 1024 * 1024
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let source = String(file.path.dropFirst(app.path.count + 1))
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true {
                result.add("Files", source, "Symlink", try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                continue
            }
            guard attributes.isRegularFile == true else { continue }
            let size = attributes.fileSize ?? 0
            result.fileSizes[source] = Int64(size)
            result.identity.extractedBytes += Int64(size)
            let signing = source.split(separator: "/").contains("_CodeSignature") || file.lastPathComponent == "embedded.mobileprovision"
            progress(source)
            result.add("Files", source, "Content", "\(size) bytes · SHA-256 \(try LibraryRepository.fileHash(file))", type: "file", signing: signing)
            result.status("Files", source)
            if IPASecurityScanner.isMachO(file) {
                binaries.append((file, source))
                continue
            }
            if file.lastPathComponent == "embedded.mobileprovision" {
                try result.capture("Signing", source) { snapshot in try profile(file, source: source, into: &snapshot) }
                continue
            }
            if signing {
                if file.lastPathComponent == "CodeResources" {
                    try result.capture("Signing", source) { snapshot in
                        flatten(try readPlist(file), category: "Signing", source: source, signing: true, into: &snapshot)
                    }
                }
                continue
            }
            if file.lastPathComponent == "Info.plist" {
                try result.capture("Info.plist", source) { snapshot in
                    let plist = try readPlist(file)
                    flatten(plist, category: "Info.plist", source: source, into: &snapshot)
                    if let dict = plist as? [String: Any] {
                        let component = source == "Info.plist" ? "." : String(source.dropLast("/Info.plist".count))
                        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleExecutable", "CFBundlePackageType"] {
                            if let value = dict[key] { snapshot.add("Components", source, component + "/" + key, String(describing: value)) }
                        }
                        snapshot.status("Components", source)
                    }
                }
            } else {
                try resource(file, source: source, size: size, budget: &textBudget, into: &result)
            }
            if deep {
                let coverage = result.coverage["Resources|" + source] ?? result.coverage["Info.plist|" + source]
                if let coverage, coverage.state != "Complete" {
                    for category in ["Strings", "Endpoints"] { result.status(category, source, coverage.state, coverage.detail) }
                } else if let text = result.values["Resources|" + source + "|Text"]?.text {
                    try analyzeStrings(text, source: source, into: &result)
                } else if let texts = result.resourceStrings[source] {
                    try analyzeStrings(texts.joined(separator: "\n"), source: source, into: &result)
                }
            }
            result.resourceStrings.removeValue(forKey: source)
        }
        for (binary, source) in binaries {
            try Task.checkCancellation()
            progress("Binary · " + source)
            try signing(binary, source: source, into: &result)
            try binaryMetadata(binary, source: source, deep: deep, into: &result)
        }
        if !deep {
            for category in deepCategories { result.status(category, "*", "Skipped", "Run Deep Analysis") }
        }
        progress("Security findings…")
        let root = app.deletingLastPathComponent().deletingLastPathComponent()
        try result.capture("Security findings", "*") { snapshot in
            let scan = try IPASecurityScanner.scanExtracted(at: root, appName: app.lastPathComponent, strictTools: true, progress: progress)
            func normalized(_ text: String) -> String {
                text.replacingOccurrences(of: "Payload/" + app.lastPathComponent + "/", with: "")
                    .replacingOccurrences(of: app.lastPathComponent + "/", with: "")
                    .replacingOccurrences(of: root.path, with: "")
            }
            // Stable rule + location identity; evidence/severity changes remain a Changed row.
            let grouped = Dictionary(grouping: scan.findings) { finding in
                normalized(finding.location ?? "App") + "/" + finding.category + "/" + finding.title
            }
            for (key, findings) in grouped {
                let values = Set(findings.map { finding in
                    finding.severity.label + " · " + normalized(finding.snippet ?? "") +
                        (finding.rawValue.map { " · evidence SHA-256 " + fingerprint(normalized($0)) } ?? "")
                }).sorted()
                snapshot.add("Security findings", "*", key, values.joined(separator: "\n"), type: "finding")
            }
            var issues = scan.analysisIssues.map(normalized)
            if !scan.encryptedBinaries.isEmpty { issues.append("Encrypted binaries: " + scan.encryptedBinaries.map(normalized).joined(separator: ", ")) }
            if !issues.isEmpty {
                snapshot.status("Security findings", "*", "Partial", issues.joined(separator: "\n"))
            }
        }
        return result
    }

    static func signing(_ binary: URL, source: String, into result: inout Snapshot) throws {
        var unsigned = false
        try result.capture("Signing", source) { snapshot in
            let response: ProcessRunner.Result
            do { response = try ProcessRunner.run("/usr/bin/codesign", ["-d", "--verbose=4", binary.path], timeout: 30) }
            catch ProcessRunner.Failure.failed(_, _, let detail) where detail.contains("not signed at all") {
                unsigned = true
                snapshot.add("Signing", source, "Signature", "Unsigned", signing: true)
                return
            }
            let text = String(decoding: response.error + response.output, as: UTF8.self)
            var authorityIndex = 0
            let keys: Set<String> = ["Identifier", "Format", "CodeDirectory", "Signature", "TeamIdentifier", "CDHash", "CandidateCDHash", "Hash choices", "CMSDigest", "CMSDigestType", "Timestamp", "Signed Time", "Sealed Resources", "Internal requirements"]
            for line in text.components(separatedBy: .newlines) {
                guard let separator = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<separator]), value = String(line[line.index(after: separator)...])
                if key == "Authority" { snapshot.add("Signing", source, "Authority/[\(authorityIndex)]", value, signing: true); authorityIndex += 1 }
                else if keys.contains(key) { snapshot.add("Signing", source, key, value, signing: true) }
            }
            if text.contains("Signature=adhoc") {
                snapshot.add("Signing", source, "Certificates/Count", "0", type: "number", signing: true)
                return
            }
            // Extract the actual certificate chain, not only codesign's subject labels.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-cert-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let prefix = directory.appendingPathComponent("cert")
            _ = try ProcessRunner.run("/usr/bin/codesign", ["-d", "--extract-certificates", prefix.path, binary.path], timeout: 30)
            let certificates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
            snapshot.add("Signing", source, "Certificates/Count", String(certificates.count), type: "number", signing: true)
            for file in certificates {
                certificate(try Data(contentsOf: file), prefix: "Certificates/" + file.lastPathComponent, source: source, into: &snapshot)
            }
        }
        if unsigned {
            result.add("Entitlements", source, "/", "{}", type: "dictionary")
            result.status("Entitlements", source)
            return
        }
        try result.capture("Entitlements", source) { snapshot in
            let response = try ProcessRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", binary.path], timeout: 30)
            if response.output.isEmpty { snapshot.add("Entitlements", source, "/", "{}", type: "dictionary"); return }
            let plist = try PropertyListSerialization.propertyList(from: response.output, format: nil)
            flatten(plist, category: "Entitlements", source: source, into: &snapshot)
            let profileURL = binary.deletingLastPathComponent().appendingPathComponent("embedded.mobileprovision")
            let profileSource = (source as NSString).deletingLastPathComponent
            let profileKey = profileSource.isEmpty ? "embedded.mobileprovision" : profileSource + "/embedded.mobileprovision"
            if FileManager.default.fileExists(atPath: profileURL.path), let signed = plist as? [String: Any] {
                // Compare signed/profile values without pretending wildcard grants are exact equality.
                let profileValues = snapshot.values.values.filter { $0.category == "Signing" && $0.source == profileKey && $0.path.hasPrefix("/Entitlements/") }
                for value in profileValues { snapshot.add("Entitlements", source, "/Profile" + value.path.dropFirst("/Entitlements".count), value.text, type: value.type, signing: true) }
                for key in signed.keys.sorted() {
                    snapshot.add("Signing", source, "Signed entitlement keys/" + escaped(key), key, signing: true)
                }
            }
        }
    }

    static func profile(_ file: URL, source: String, into result: inout Snapshot) throws {
        let output = try ProcessRunner.run("/usr/bin/security", ["cms", "-D", "-i", file.path], timeout: 30).output
        guard var plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any] else {
            throw IPAComparisonError.invalidData("Invalid provisioning profile")
        }
        let certificates = plist.removeValue(forKey: "DeveloperCertificates") as? [Data] ?? []
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let type = (plist["ProvisionsAllDevices"] as? Bool == true) ? "Enterprise" :
            (plist["ProvisionedDevices"] != nil ? (entitlements["get-task-allow"] as? Bool == true ? "Development" : "Ad Hoc") : "App Store")
        result.add("Signing", source, "Profile type (inferred)", type, signing: true)
        flatten(plist, category: "Signing", source: source, signing: true, into: &result)
        for data in certificates { certificate(data, prefix: "DeveloperCertificates/" + hash(data), source: source, into: &result) }
    }

    static func certificate(_ data: Data, prefix: String, source: String, into result: inout Snapshot) {
        result.add("Signing", source, prefix + "/SHA-256", hash(data), signing: true)
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return }
        if let name = SecCertificateCopySubjectSummary(certificate) { result.add("Signing", source, prefix + "/Subject", name as String, signing: true) }
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter]
        if let fields = SecCertificateCopyValues(certificate, keys as CFArray, nil) as? [String: Any] {
            for (key, label) in [(kSecOIDX509V1ValidityNotBefore, "Not Before"), (kSecOIDX509V1ValidityNotAfter, "Not After")] {
                if let field = fields[key as String] as? [String: Any], let raw = field[kSecPropertyKeyValue as String] {
                    let date = (raw as? Date) ?? (raw as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
                    result.add("Signing", source, prefix + "/" + label, date.map { ISO8601DateFormatter().string(from: $0) } ?? String(describing: raw), signing: true)
                }
            }
        }
    }
}
