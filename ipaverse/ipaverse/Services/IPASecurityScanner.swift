//
//  IPASecurityScanner.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//
//  Inspects a downloaded .ipa for security-sensitive content: provisioning
//  profile entitlements, Info.plist misconfigurations, hardcoded API keys /
//  secrets (known-provider prefixes + entropy/keyword heuristics), embedded
//  certificates & keys, secrets compiled into Mach-O binaries, and a network
//  endpoint inventory (Firebase / S3 / internal hosts / cleartext HTTP).
//
//  All work is local (no network calls — no live key verification). Findings
//  are heuristic: they flag things worth a human review, not confirmed
//  compromise.
//

import Foundation

// MARK: - Models

enum FindingSeverity: Int, Comparable, CaseIterable {
    case info = 0, low, medium, high, critical

    static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .critical: return "Critical"
        case .high:     return "High"
        case .medium:   return "Medium"
        case .low:      return "Low"
        case .info:     return "Info"
        }
    }
}

struct SecurityFinding: Identifiable {
    let id = UUID()
    let severity: FindingSeverity
    let category: String   // "Provisioning", "Info.plist", "Secret", "Embedded File", "Binary", "Network"
    let title: String
    let detail: String
    let location: String?  // relative path inside the IPA
    let snippet: String?   // redacted match, shown by default
    var rawValue: String?  // unredacted value, revealed on demand (secrets only)
}

struct SecurityScanResult {
    let appName: String
    let findings: [SecurityFinding]
    let scannedFileCount: Int
    let date: Date

    var sortedFindings: [SecurityFinding] {
        findings.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.title < $1.title
        }
    }

    func count(of severity: FindingSeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }
}

enum SecurityScanError: LocalizedError {
    case extractionFailed(String)
    case appBundleNotFound

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let m): return "Could not extract the IPA: \(m)"
        case .appBundleNotFound:       return "No .app bundle found inside the IPA (is this a valid IPA?)."
        }
    }
}

// MARK: - Scan accumulator

/// Collects findings (deduplicated) and network endpoints across all passes so
/// endpoint findings can be emitted once, aggregated, at the end.
private final class ScanAccumulator {
    var findings: [SecurityFinding] = []
    private var seen = Set<String>()

    var httpsHosts = Set<String>()
    var cleartextURLs = Set<String>()
    var firebaseHosts = Set<String>()
    var awsEndpoints = Set<String>()
    var internalHosts = Set<String>()

    func add(_ f: SecurityFinding) {
        let key = "\(f.severity.rawValue)|\(f.category)|\(f.title)|\(f.location ?? "")|\(f.snippet ?? "")"
        if seen.insert(key).inserted { findings.append(f) }
    }
}

// MARK: - Scanner

struct IPASecurityScanner {

    static func scan(
        ipaPath: String,
        appName: String,
        progress: @escaping (String) -> Void
    ) throws -> SecurityScanResult {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("ipaverse-secscan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpDir) }

        progress("Extracting IPA…")
        try extract(ipaPath: ipaPath, to: tmpDir)

        let payloadURL = tmpDir.appendingPathComponent("Payload", isDirectory: true)
        guard let appURL = (try? fm.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            throw SecurityScanError.appBundleNotFound
        }
        let acc = ScanAccumulator()

        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        let infoPlist = (try? Data(contentsOf: infoPlistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) }
            as? [String: Any] ?? [:]

        // 1. Provisioning profile
        progress("Analyzing provisioning profile…")
        let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: profileURL.path) {
            scanProvisioningProfile(at: profileURL, into: acc)
        }

        // 2. Info.plist security config
        progress("Analyzing Info.plist…")
        scanInfoPlist(infoPlist, into: acc)

        // 3 + 4. Walk the tree: embedded sensitive files + secret/endpoint scan of text files
        progress("Scanning files for secrets…")
        var scannedFiles = 0
        if let enumerator = fm.enumerator(at: tmpDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                scannedFiles += 1
                let rel = displayPath(url.path)
                let size = values?.fileSize ?? 0

                scanEmbeddedFile(url: url, relativePath: rel, profileURL: profileURL, into: acc)

                if isTextLike(url: url, size: size), let text = readText(at: url) {
                    scanText(text, location: rel, source: "file", into: acc)
                }
            }
        }

        // 5. Mach-O binaries (main executable + frameworks + appex + dylibs)
        progress("Scanning app binaries…")
        for binURL in machOBinaries(in: appURL) {
            let rel = displayPath(binURL.path)
            scanMachO(at: binURL, location: rel, into: acc)
        }

        // 6. Emit aggregated network/endpoint findings
        progress("Summarizing network endpoints…")
        emitNetworkFindings(acc)

        return SecurityScanResult(
            appName: appName,
            findings: acc.findings,
            scannedFileCount: scannedFiles,
            date: Date()
        )
    }

    // MARK: - Pass 1: Provisioning profile

    private static func scanProvisioningProfile(at url: URL, into acc: ScanAccumulator) {
        guard let plist = decodeMobileProvision(at: url) else {
            acc.add(SecurityFinding(severity: .info, category: "Provisioning",
                                    title: "Provisioning profile present but could not be decoded",
                                    detail: "embedded.mobileprovision exists but `security cms -D` failed to decode it.",
                                    location: "Payload/*.app/embedded.mobileprovision", snippet: nil))
            return
        }
        let ents = plist["Entitlements"] as? [String: Any] ?? [:]
        let getTaskAllow = ents["get-task-allow"] as? Bool ?? false
        let provisionsAll = plist["ProvisionsAllDevices"] as? Bool ?? false
        let provisionedDevices = plist["ProvisionedDevices"] as? [String]

        let type: String
        if provisionsAll { type = "Enterprise (In-House)" }
        else if getTaskAllow, provisionedDevices != nil { type = "Development" }
        else if provisionedDevices != nil { type = "Ad-Hoc Distribution" }
        else { type = "App Store Distribution" }
        acc.add(SecurityFinding(severity: .info, category: "Provisioning",
                                title: "Profile type: \(type)",
                                detail: "Provisioning profile name: \(plist["Name"] as? String ?? "—").",
                                location: "embedded.mobileprovision", snippet: nil))

        if getTaskAllow {
            acc.add(SecurityFinding(severity: .high, category: "Provisioning",
                                    title: "App is debuggable (get-task-allow = true)",
                                    detail: "The entitlement get-task-allow is enabled, meaning a debugger can attach to the running process and dump memory. This should never be set on a production/App Store build.",
                                    location: "embedded.mobileprovision", snippet: nil))
        }

        if let devices = provisionedDevices, !devices.isEmpty {
            let sample = devices.prefix(3).map { redact($0) }.joined(separator: ", ")
            acc.add(SecurityFinding(severity: .medium, category: "Provisioning",
                                    title: "\(devices.count) provisioned device UDID(s) embedded",
                                    detail: "Ad-hoc / development profiles embed the UDIDs of every provisioned device, leaking hardware identifiers of the developer's test fleet.",
                                    location: "embedded.mobileprovision", snippet: sample))
        }

        if let teamID = (plist["TeamIdentifier"] as? [String])?.first ?? ents["com.apple.developer.team-identifier"] as? String {
            acc.add(SecurityFinding(severity: .info, category: "Provisioning",
                                    title: "Team Identifier: \(teamID)",
                                    detail: "Apple Developer team that signed this build.",
                                    location: "embedded.mobileprovision", snippet: nil))
        }

        if let appID = ents["application-identifier"] as? String, appID.hasSuffix("*") {
            acc.add(SecurityFinding(severity: .medium, category: "Provisioning",
                                    title: "Wildcard application-identifier (\(appID))",
                                    detail: "The profile is bound to a wildcard App ID, which is overly broad and disables App-ID-specific entitlements like keychain sharing isolation.",
                                    location: "embedded.mobileprovision", snippet: nil))
        }

        if let exp = plist["ExpirationDate"] as? Date {
            let expired = exp < Date()
            let df = DateFormatter(); df.dateStyle = .medium
            acc.add(SecurityFinding(severity: expired ? .low : .info, category: "Provisioning",
                                    title: expired ? "Provisioning profile expired (\(df.string(from: exp)))"
                                                   : "Provisioning profile expires \(df.string(from: exp))",
                                    detail: expired ? "The signing profile is past its expiration date." : "",
                                    location: "embedded.mobileprovision", snippet: nil))
        }

        let sensitiveKeys: [(String, String)] = [
            ("keychain-access-groups", "Shared keychain access groups"),
            ("com.apple.security.application-groups", "Shared app groups (shared container)"),
            ("com.apple.developer.associated-domains", "Associated domains (universal links / web credentials)"),
            ("aps-environment", "Push notification environment"),
            ("com.apple.developer.networking.networkextension", "Network Extension (VPN / packet filter)"),
        ]
        for (key, label) in sensitiveKeys where ents[key] != nil {
            let val = ents[key]
            let snippet = (val as? [String])?.joined(separator: ", ") ?? "\(val ?? "")"
            acc.add(SecurityFinding(severity: .info, category: "Provisioning",
                                    title: "Entitlement: \(label)",
                                    detail: "Declared entitlement `\(key)`.",
                                    location: "embedded.mobileprovision",
                                    snippet: snippet.isEmpty ? nil : String(snippet.prefix(200))))
        }
    }

    // MARK: - Pass 2: Info.plist

    private static func scanInfoPlist(_ plist: [String: Any], into acc: ScanAccumulator) {
        if let ats = plist["NSAppTransportSecurity"] as? [String: Any] {
            if ats["NSAllowsArbitraryLoads"] as? Bool == true {
                acc.add(SecurityFinding(severity: .high, category: "Info.plist",
                                        title: "App Transport Security disabled (NSAllowsArbitraryLoads)",
                                        detail: "ATS is globally disabled, allowing plaintext HTTP and weak TLS connections app-wide.",
                                        location: "Info.plist", snippet: nil))
            }
            if let exceptions = ats["NSExceptionDomains"] as? [String: Any], !exceptions.isEmpty {
                acc.add(SecurityFinding(severity: .medium, category: "Info.plist",
                                        title: "ATS exception domains (\(exceptions.count))",
                                        detail: "Specific domains are exempted from App Transport Security and may permit insecure connections.",
                                        location: "Info.plist",
                                        snippet: exceptions.keys.sorted().prefix(10).joined(separator: ", ")))
            }
        }

        if plist["UIFileSharingEnabled"] as? Bool == true {
            acc.add(SecurityFinding(severity: .medium, category: "Info.plist",
                                    title: "iTunes file sharing enabled (UIFileSharingEnabled)",
                                    detail: "The app's Documents directory is exposed via Finder/iTunes file sharing, potentially leaking user data.",
                                    location: "Info.plist", snippet: nil))
        }

        if let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] {
            let schemes = urlTypes.compactMap { $0["CFBundleURLSchemes"] as? [String] }.flatMap { $0 }
            if !schemes.isEmpty {
                acc.add(SecurityFinding(severity: .info, category: "Info.plist",
                                        title: "Custom URL scheme(s): \(schemes.count)",
                                        detail: "Custom URL schemes can be registered by other apps; deep-link handlers should validate all input.",
                                        location: "Info.plist", snippet: schemes.joined(separator: ", ")))
            }
        }

        let perms = plist.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted()
        if !perms.isEmpty {
            acc.add(SecurityFinding(severity: .info, category: "Info.plist",
                                    title: "Declared privacy permissions (\(perms.count))",
                                    detail: "Permissions the app requests at runtime.",
                                    location: "Info.plist",
                                    snippet: perms.map { $0.replacingOccurrences(of: "UsageDescription", with: "")
                                        .replacingOccurrences(of: "NS", with: "") }.joined(separator: ", ")))
        }
    }

    // MARK: - Pass 3: Embedded sensitive files

    private static let certKeyExtensions: Set<String> = [
        "p12", "pfx", "pem", "cer", "der", "key", "crt", "keystore", "jks", "pkcs12"
    ]
    private static let databaseExtensions: Set<String> = ["sqlite", "sqlite3", "db", "realm"]
    private static let configFileNames: Set<String> = [
        "googleservice-info.plist", ".env", "env", "secrets.plist", "secrets.json",
        "credentials.json", "config.json", "firebase.json", "appsettings.json"
    ]

    private static func scanEmbeddedFile(
        url: URL, relativePath rel: String, profileURL: URL, into acc: ScanAccumulator
    ) {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if url.path == profileURL.path { return }

        if certKeyExtensions.contains(ext) {
            acc.add(SecurityFinding(severity: .high, category: "Embedded File",
                                    title: "Certificate / private-key material shipped in app",
                                    detail: "A .\(ext) file is bundled inside the IPA. Private keys or certificates embedded in a client app can be extracted by anyone who downloads it.",
                                    location: rel, snippet: nil))
        } else if configFileNames.contains(name) || ext == "mobileprovision" {
            acc.add(SecurityFinding(severity: .medium, category: "Embedded File",
                                    title: "Embedded config / credentials file: \(url.lastPathComponent)",
                                    detail: "Configuration files frequently contain API keys, client secrets or backend endpoints. Its contents were also scanned for secrets.",
                                    location: rel, snippet: nil))
        } else if databaseExtensions.contains(ext) {
            acc.add(SecurityFinding(severity: .info, category: "Embedded File",
                                    title: "Embedded database: \(url.lastPathComponent)",
                                    detail: "A prepackaged database is bundled with the app; verify it contains no sensitive seed data.",
                                    location: rel, snippet: nil))
        }
    }

    // MARK: - Pass 4: Secret detection (provider rules + entropy/keyword + base64)

    private struct SecretRule {
        let name: String
        let regex: NSRegularExpression
        let severity: FindingSeverity
        /// Index of the capture group holding the secret value (0 = whole match).
        let valueGroup: Int
    }

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [])
    }

    /// Curated, provider-aware ruleset. Severity reflects real risk: a key that
    /// is public by design (e.g. a Firebase/Google *client* API key, Stripe
    /// publishable key) is Low/Info; a true server secret is Critical.
    private static let secretRules: [SecretRule] = [
        // --- Critical: server-side secrets ---
        SecretRule(name: "Private key block", regex: rx("-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"), severity: .critical, valueGroup: 0),
        SecretRule(name: "AWS secret access key", regex: rx("(?i)aws(.{0,20})?(?:secret|access).{0,20}?[\"'=:\\s]([A-Za-z0-9/+]{40})"), severity: .critical, valueGroup: 1),
        SecretRule(name: "OpenAI API key", regex: rx("sk-(?:proj-)?[A-Za-z0-9_-]{20,}T3BlbkFJ[A-Za-z0-9_-]{20,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Anthropic API key", regex: rx("sk-ant-[A-Za-z0-9_-]{20,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Stripe live secret key", regex: rx("[rs]k_live_[0-9A-Za-z]{24,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "GitHub token", regex: rx("gh[pousr]_[0-9A-Za-z]{36,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "GitHub fine-grained PAT", regex: rx("github_pat_[0-9A-Za-z_]{60,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "GitLab personal access token", regex: rx("glpat-[0-9A-Za-z_-]{20}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Slack token", regex: rx("xox[baprs]-[0-9A-Za-z-]{10,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "SendGrid API key", regex: rx("SG\\.[A-Za-z0-9_-]{22}\\.[A-Za-z0-9_-]{43}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Shopify access token", regex: rx("shp(?:at|ca|pa|ss)_[0-9a-fA-F]{32}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Square access token", regex: rx("sq0(?:atp|csp)-[0-9A-Za-z_-]{22,}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "npm access token", regex: rx("npm_[0-9A-Za-z]{36}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Firebase Cloud Messaging key", regex: rx("AAAA[A-Za-z0-9_-]{7}:[A-Za-z0-9_-]{140}"), severity: .critical, valueGroup: 0),
        SecretRule(name: "Telegram bot token", regex: rx("[0-9]{8,10}:AA[A-Za-z0-9_-]{32,}"), severity: .critical, valueGroup: 0),

        // --- High ---
        SecretRule(name: "AWS access key ID", regex: rx("A(?:KIA|SIA|GPA|IDA|ROA|IPA|NPA|NVA)[0-9A-Z]{16}"), severity: .high, valueGroup: 0),
        SecretRule(name: "Slack webhook URL", regex: rx("https://hooks\\.slack\\.com/services/[A-Za-z0-9_/]+"), severity: .high, valueGroup: 0),
        SecretRule(name: "Twilio API key", regex: rx("SK[0-9a-fA-F]{32}"), severity: .high, valueGroup: 0),
        SecretRule(name: "Mailgun API key", regex: rx("key-[0-9a-zA-Z]{32}"), severity: .high, valueGroup: 0),
        SecretRule(name: "Mapbox secret token", regex: rx("sk\\.eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}"), severity: .high, valueGroup: 0),
        SecretRule(name: "Facebook access token", regex: rx("EAACEdEose0cBA[0-9A-Za-z]+"), severity: .high, valueGroup: 0),
        SecretRule(name: "Discord bot token", regex: rx("[MNO][A-Za-z0-9_-]{23}\\.[A-Za-z0-9_-]{6}\\.[A-Za-z0-9_-]{27}"), severity: .high, valueGroup: 0),

        // --- Medium / Low / Info: identifiers often public by design ---
        SecretRule(name: "JSON Web Token (JWT)", regex: rx("eyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"), severity: .medium, valueGroup: 0),
        SecretRule(name: "Google API key", regex: rx("AIza[0-9A-Za-z\\-_]{35}"), severity: .low, valueGroup: 0),
        SecretRule(name: "Stripe publishable key", regex: rx("pk_live_[0-9A-Za-z]{24,}"), severity: .info, valueGroup: 0),
        SecretRule(name: "Google OAuth client ID", regex: rx("[0-9]+-[0-9A-Za-z_]{32}\\.apps\\.googleusercontent\\.com"), severity: .info, valueGroup: 0),
        SecretRule(name: "Twilio Account SID", regex: rx("AC[0-9a-fA-F]{32}"), severity: .info, valueGroup: 0),
    ]

    /// Keyword-anchored secret: `apiKey = "<high-entropy value>"`. Catches the
    /// app's own backend secrets, which have no recognizable provider prefix.
    private static let keywordSecretRegex = rx(
        "(?i)(?:api[_-]?key|secret|token|passwd|password|pwd|auth[_-]?token|access[_-]?key|client[_-]?secret|private[_-]?key|bearer|credential)[\"']?\\s*[:=]{1,2}\\s*[\"']([^\"'\\s]{12,128})[\"']"
    )

    private static let base64TokenRegex = rx("[A-Za-z0-9+/]{24,}={0,2}")
    private static let maxMatchesPerRulePerFile = 15
    private static let maxBase64Decodes = 400

    private static func scanText(
        _ text: String, location: String, source: String,
        into acc: ScanAccumulator, allowBase64: Bool = true
    ) {
        let category = (source == "binary") ? "Binary" : "Secret"
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // a) Provider rules
        for rule in secretRules {
            var count = 0
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, stop in
                guard let m = match, count < maxMatchesPerRulePerFile else {
                    if count >= maxMatchesPerRulePerFile { stop.pointee = true }
                    return
                }
                let valueRange = rule.valueGroup < m.numberOfRanges ? m.range(at: rule.valueGroup) : m.range
                guard valueRange.location != NSNotFound else { return }
                let value = ns.substring(with: valueRange)
                if isLikelyPlaceholder(value) { return }
                count += 1
                acc.add(finding(rule.severity, category,
                                title: "\(rule.name) found\(source == "binary" ? " in binary" : "")",
                                detail: rule.severity >= .high
                                    ? "Matched \(rule.name). Review whether this is a live secret that should not ship in a client app."
                                    : "Matched \(rule.name). This identifier is often public by design; included for completeness.",
                                location: location, value: value, binary: source == "binary"))
            }
        }

        // b) Entropy + keyword proximity (custom / no-prefix secrets)
        var kwCount = 0
        keywordSecretRegex.enumerateMatches(in: text, options: [], range: full) { match, _, stop in
            guard let m = match, m.numberOfRanges > 1, kwCount < maxMatchesPerRulePerFile else {
                if kwCount >= maxMatchesPerRulePerFile { stop.pointee = true }
                return
            }
            let value = ns.substring(with: m.range(at: 1))
            guard !isLikelyPlaceholder(value), shannonEntropy(value) >= 3.2 else { return }
            kwCount += 1
            acc.add(finding(.high, category,
                            title: "Possible hardcoded secret (high entropy)\(source == "binary" ? " in binary" : "")",
                            detail: "A keyword (api key / secret / token / password) is assigned a high-entropy value. Likely a custom backend credential — verify it is not live.",
                            location: location, value: value, binary: source == "binary"))
        }

        // c) Endpoint inventory
        collectEndpoints(from: ns, full: full, into: acc)

        // d) Base64 decode pass — re-run provider/keyword rules on decoded blobs
        if allowBase64 {
            var decodes = 0
            base64TokenRegex.enumerateMatches(in: text, options: [], range: full) { match, _, stop in
                guard let m = match, decodes < maxBase64Decodes else {
                    if decodes >= maxBase64Decodes { stop.pointee = true }
                    return
                }
                let token = ns.substring(with: m.range)
                guard token.count % 4 == 0,
                      let data = Data(base64Encoded: token),
                      let decoded = String(data: data, encoding: .utf8),
                      isMostlyPrintable(decoded), decoded.count >= 12 else { return }
                decodes += 1
                // Scan decoded text but don't recurse into another base64 layer.
                scanText(decoded, location: "\(location) (base64-decoded)", source: source,
                         into: acc, allowBase64: false)
            }
        }
    }

    private static func finding(
        _ severity: FindingSeverity, _ category: String,
        title: String, detail: String, location: String, value: String, binary: Bool
    ) -> SecurityFinding {
        SecurityFinding(severity: severity, category: category, title: title, detail: detail,
                        location: location, snippet: redactSecret(value),
                        rawValue: String(value.prefix(200)))
    }

    // MARK: - Pass 5: Mach-O binaries

    /// All Mach-O binaries inside the app bundle: main executable, framework /
    /// appex executables, and dylibs. Detected by magic bytes, not extension.
    private static func machOBinaries(in appURL: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        guard let en = fm.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            // Executables are extensionless; also pick up dylibs explicitly.
            if ext.isEmpty || ext == "dylib", isMachO(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // 32/64-bit thin (BE/LE) + fat (universal) magics.
        let machos: Set<UInt32> = [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE,
                                   0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA]
        return machos.contains(magic)
    }

    private static func scanMachO(at url: URL, location: String, into acc: ScanAccumulator) {
        // Two string encodings: 7/8-bit (S) and 16-bit little-endian (l).
        for encoding in ["S", "l"] {
            let data = runProcess("/usr/bin/strings", ["-a", "-n", "6", "-e", encoding, url.path])
            guard let out = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !out.isEmpty else { continue }
            scanText(out, location: location, source: "binary", into: acc)
        }
    }

    // MARK: - Pass 6: Network endpoints

    private static let urlRegex = rx("(?i)\\b(https?)://([A-Za-z0-9.\\-]+)(?::[0-9]+)?(/[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]*)?")

    private static func collectEndpoints(from ns: NSString, full: NSRange, into acc: ScanAccumulator) {
        urlRegex.enumerateMatches(in: ns as String, options: [], range: full) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let scheme = ns.substring(with: m.range(at: 1)).lowercased()
            let host = ns.substring(with: m.range(at: 2)).lowercased()
            guard !host.isEmpty, host.contains(".") || host == "localhost" else { return }
            let fullURL = ns.substring(with: m.range)

            if scheme == "http" { acc.cleartextURLs.insert(String(fullURL.prefix(200))) }
            if host.hasSuffix("firebaseio.com") || host.hasSuffix("firebasedatabase.app") {
                acc.firebaseHosts.insert(host)
            } else if host.hasSuffix("amazonaws.com") || host.contains(".s3.") || host.hasPrefix("s3.") {
                acc.awsEndpoints.insert(host)
            } else if isInternalHost(host) {
                acc.internalHosts.insert(host)
            } else if scheme == "https" {
                acc.httpsHosts.insert(host)
            }
        }
    }

    private static func emitNetworkFindings(_ acc: ScanAccumulator) {
        for host in acc.firebaseHosts.sorted() {
            acc.add(SecurityFinding(severity: .high, category: "Network",
                                    title: "Firebase Realtime Database endpoint",
                                    detail: "Test for unauthenticated read access: open https://\(host)/.json — if it returns data, the database rules are world-readable.",
                                    location: nil, snippet: host))
        }
        if !acc.internalHosts.isEmpty {
            acc.add(SecurityFinding(severity: .medium, category: "Network",
                                    title: "Internal / private network host(s) referenced (\(acc.internalHosts.count))",
                                    detail: "The app references RFC1918 / localhost addresses — possible leftover dev/staging endpoints.",
                                    location: nil, snippet: acc.internalHosts.sorted().prefix(15).joined(separator: ", ")))
        }
        if !acc.cleartextURLs.isEmpty {
            acc.add(SecurityFinding(severity: .medium, category: "Network",
                                    title: "Cleartext HTTP endpoint(s) (\(acc.cleartextURLs.count))",
                                    detail: "URLs using plaintext http:// were found; traffic to these is interceptable.",
                                    location: nil, snippet: acc.cleartextURLs.sorted().prefix(10).joined(separator: "\n")))
        }
        if !acc.awsEndpoints.isEmpty {
            acc.add(SecurityFinding(severity: .info, category: "Network",
                                    title: "AWS / S3 endpoint(s) (\(acc.awsEndpoints.count))",
                                    detail: "Check referenced S3 buckets for public/list permissions.",
                                    location: nil, snippet: acc.awsEndpoints.sorted().prefix(15).joined(separator: ", ")))
        }
        if !acc.httpsHosts.isEmpty {
            acc.add(SecurityFinding(severity: .info, category: "Network",
                                    title: "External endpoints referenced (\(acc.httpsHosts.count))",
                                    detail: "Inventory of HTTPS hosts the app talks to — useful for mapping the attack surface.",
                                    location: nil, snippet: acc.httpsHosts.sorted().prefix(30).joined(separator: ", ")))
        }
    }

    // MARK: - Heuristic helpers

    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// Filters obvious non-secrets: placeholders, repeated chars, low variety.
    private static func isLikelyPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        let markers = ["example", "sample", "your_", "your-", "yourkey", "placeholder",
                       "changeme", "change_me", "replace", "dummy", "xxxx", "0000",
                       "1234", "<", ">", "{{", "todo", "insert", "test_key", "notarealkey",
                       "abcdef", "aaaa", "deadbeef"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        if Set(value).count <= 2 { return true } // e.g. "aaaaaaaa"
        return false
    }

    private static func isMostlyPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let printable = s.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || ($0.value >= 32 && $0.value < 127) }.count
        return Double(printable) / Double(s.unicodeScalars.count) >= 0.9
    }

    private static func isInternalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    // MARK: - Process / IO helpers

    private static func extract(ipaPath: String, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", ipaPath, dir.path]
        process.useUTF8Locale()
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        try process.run()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SecurityScanError.extractionFailed(String(data: err, encoding: .utf8) ?? "exit \(process.terminationStatus)")
        }
    }

    private static func decodeMobileProvision(at url: URL) -> [String: Any]? {
        let data = runProcess("/usr/bin/security", ["cms", "-D", "-i", url.path])
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Runs a CLI tool and returns stdout. UTF-8 safe; reads before waiting to
    /// avoid pipe-buffer deadlock on large output (e.g. `strings` on a big binary).
    private static func runProcess(_ launchPath: String, _ args: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.useUTF8Locale()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return Data() }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static let textExtensions: Set<String> = [
        "plist", "json", "xml", "js", "html", "htm", "txt", "strings", "stringsdict",
        "env", "yml", "yaml", "cfg", "ini", "conf", "config", "properties", "pem",
        "cer", "crt", "key", "mobileprovision", "md", "csv", "sql", "graphql", "map",
        "css", "svg", "entitlements"
    ]

    private static func isTextLike(url: URL, size: Int) -> Bool {
        guard size <= 2_000_000 else { return false }
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        if ext.isEmpty && size <= 200_000 { return true }
        return false
    }

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Trims the temp-extraction prefix so locations read from the .app bundle,
    /// e.g. "Gencraft.app/StoreKitTestCertificate.cer". Robust against the
    /// /var ↔ /private/var symlink (which breaks naive prefix stripping).
    private static func displayPath(_ path: String) -> String {
        if let r = path.range(of: "/Payload/") {
            return String(path[r.upperBound...])
        }
        return (path as NSString).lastPathComponent
    }

    private static func redact(_ s: String) -> String {
        guard s.count > 8 else { return String(repeating: "•", count: s.count) }
        let head = s.prefix(4)
        return "\(head)…\(String(repeating: "•", count: 6))"
    }

    private static func redactSecret(_ s: String) -> String {
        let trimmed = s.count > 120 ? String(s.prefix(120)) + "…" : s
        if let eq = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) {
            let key = trimmed[..<trimmed.index(after: eq)]
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return "\(key) \(redact(value))"
        }
        return redact(trimmed)
    }
}

// MARK: - Report serialization

extension SecurityScanResult {

    func markdownReport() -> String {
        let df = ISO8601DateFormatter()
        var out = "# Security Scan Report\n\n"
        out += "**App:** \(appName)\n\n"
        out += "**Date:** \(df.string(from: date))\n\n"
        out += "**Files scanned:** \(scannedFileCount)\n\n"
        out += "**Total findings:** \(findings.count) "
        out += "(Critical: \(count(of: .critical)), High: \(count(of: .high)), "
        out += "Medium: \(count(of: .medium)), Low: \(count(of: .low)), Info: \(count(of: .info)))\n\n"
        out += "> Findings are heuristic and may include false positives. Review each item before acting. Secret values are redacted.\n"

        for severity in FindingSeverity.allCases.reversed() {
            let items = sortedFindings.filter { $0.severity == severity }
            guard !items.isEmpty else { continue }
            out += "\n## \(severity.label)\n\n"
            for f in items {
                out += "- **\(f.title)** _(\(f.category))_\n"
                if !f.detail.isEmpty { out += "  - \(f.detail)\n" }
                if let loc = f.location { out += "  - Location: `\(loc)`\n" }
                if let snip = f.snippet { out += "  - Match: `\(snip)`\n" }
            }
        }
        return out
    }

    func jsonReport() throws -> Data {
        let df = ISO8601DateFormatter()
        let dict: [String: Any] = [
            "app": appName,
            "date": df.string(from: date),
            "scannedFileCount": scannedFileCount,
            "summary": [
                "critical": count(of: .critical),
                "high": count(of: .high),
                "medium": count(of: .medium),
                "low": count(of: .low),
                "info": count(of: .info),
            ],
            "findings": sortedFindings.map { f -> [String: Any] in
                var d: [String: Any] = [
                    "severity": f.severity.label,
                    "category": f.category,
                    "title": f.title,
                    "detail": f.detail,
                ]
                if let loc = f.location { d["location"] = loc }
                if let snip = f.snippet { d["snippet"] = snip }
                return d
            },
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
}
