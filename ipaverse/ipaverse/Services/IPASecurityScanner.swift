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

/// One file or binary's worth of extracted text, kept in memory (not on
/// disk — the extraction tmpDir is removed as soon as `scan()` returns) so
/// the manual search box can grep across everything the automatic scan
/// already read, without re-extracting the IPA.
struct SearchCorpusEntry {
    let location: String
    let text: String
}

struct SecurityScanResult {
    let appName: String
    let findings: [SecurityFinding]
    let scannedFileCount: Int
    let date: Date
    /// Relative paths of Mach-O binaries that are still FairPlay-encrypted.
    let encryptedBinaries: [String]
    /// Total Mach-O binaries found in the bundle (encrypted + decrypted) —
    /// compared against `encryptedBinaries.count` to tell "nothing's been
    /// dumped yet" (uninteresting, matches what Downloaded already shows)
    /// apart from "some binaries decrypted, some not" (a real surprise
    /// worth a banner — e.g. an appex that Dump can't reach).
    let totalBinariesScanned: Int
    let searchCorpus: [SearchCorpusEntry]

    /// Only true when decryption is inconsistent across the bundle — not
    /// merely "this hasn't been dumped" (Downloaded's own tag already says
    /// that) and not "fully dumped" (nothing left to warn about).
    var hasPartiallyEncryptedBinaries: Bool {
        !encryptedBinaries.isEmpty && encryptedBinaries.count < totalBinariesScanned
    }

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
    var encryptedBinaryPaths = Set<String>()
    var searchCorpus: [SearchCorpusEntry] = []

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
                    acc.searchCorpus.append(SearchCorpusEntry(location: rel, text: text))
                }
            }
        }

        // 5. Mach-O binaries (main executable + frameworks + appex + dylibs)
        progress("Scanning app binaries…")
        let machOTargets = machOBinaries(in: appURL)
        for binURL in machOTargets {
            let rel = displayPath(binURL.path)
            let isMain = binURL.deletingLastPathComponent().standardizedFileURL == appURL.standardizedFileURL
            scanMachO(at: binURL, location: rel, isMainExecutable: isMain, into: acc)
        }

        // 6. Emit aggregated network/endpoint findings
        progress("Summarizing network endpoints…")
        emitNetworkFindings(acc)

        return SecurityScanResult(
            appName: appName,
            findings: acc.findings,
            scannedFileCount: scannedFiles,
            date: Date(),
            encryptedBinaries: acc.encryptedBinaryPaths.sorted(),
            totalBinariesScanned: machOTargets.count,
            searchCorpus: acc.searchCorpus
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
    /// Not private: reused by `ClassDumper` so bundle-walking logic (and its
    /// Mach-O detection) has exactly one implementation.
    static func machOBinaries(in appURL: URL) -> [URL] {
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

    static func isMachO(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        guard let magic = head.safeUInt32(at: 0) else { return false }
        // 32/64-bit thin (BE/LE) + fat (universal) magics.
        let machos: Set<UInt32> = [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE,
                                   0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA]
        return machos.contains(magic)
    }

    private static func scanMachO(at url: URL, location: String, isMainExecutable: Bool, into acc: ScanAccumulator) {
        // FairPlay only encrypts __TEXT (code + literal strings + ObjC
        // selector names) of the main executable and, occasionally, a
        // bundled framework. When encrypted, `strings`/marker matching over
        // that range is noise — flag it and skip the string-content-dependent
        // passes below, but still run the imported-symbol pass (unencrypted
        // __LINKEDIT works regardless).
        let encrypted = IPAResigner.isFairPlayEncrypted(binaryURL: url)
        if encrypted {
            acc.encryptedBinaryPaths.insert(location)
            acc.add(SecurityFinding(
                severity: isMainExecutable ? .medium : .info,
                category: "Binary",
                title: isMainExecutable
                    ? "Main binary is FairPlay-encrypted — deep analysis unavailable"
                    : "Embedded binary is FairPlay-encrypted",
                detail: "This binary is still DRM-protected, so hardcoded secrets, endpoints, and jailbreak/pinning-detection strings compiled into its own code can't be recovered from static analysis. Use \"Dump Decrypted Copy\" (Evil Mode, requires a jailbroken source device over USB) to produce a DRM-free copy, then re-scan for full results.",
                location: location, snippet: nil))
        }

        // Primary pass: default (7/8-bit ASCII) strings extraction — this is
        // the workhorse and must not depend on `-e`, which the `strings`
        // Xcode's Command Line Tools ships (routed through the `xcrun` shim
        // at /usr/bin/strings) rejects outright ("unknown flag: -e") on
        // current toolchains, silently producing empty output and skipping
        // every binary-string-derived finding — secrets, endpoints, and the
        // anti-analysis/pinning markers below — without any visible error.
        var asciiText: String?
        let primary = runProcess("/usr/bin/strings", ["-a", "-n", "6", url.path])
        if let out = String(data: primary, encoding: .utf8) ?? String(data: primary, encoding: .isoLatin1),
           !out.isEmpty {
            scanText(out, location: location, source: "binary", into: acc)
            acc.searchCorpus.append(SearchCorpusEntry(location: location, text: out))
            asciiText = out
        }

        // Best-effort 16-bit (UTF-16LE) pass — some strings only live in this
        // form. Kept behind `-e`, so on a toolchain that rejects the flag it
        // just yields empty output and is silently skipped; the primary pass
        // above no longer depends on it succeeding.
        let wide = runProcess("/usr/bin/strings", ["-a", "-n", "6", "-e", "l", url.path])
        if let out = String(data: wide, encoding: .utf8) ?? String(data: wide, encoding: .isoLatin1),
           !out.isEmpty {
            scanText(out, location: location, source: "binary", into: acc)
        }

        // Imported-symbol pass: the symbol table lives in __LINKEDIT, which
        // FairPlay never touches, so this works even on an encrypted binary.
        scanImportedSymbols(at: url, location: location, into: acc)

        // Marker passes need real string content to match against — pointless
        // on an encrypted __TEXT (would just match ciphertext noise).
        if !encrypted, let text = asciiText {
            scanMarkers(antiAnalysisMarkers, in: text, location: location, into: acc)
            scanMarkers(pinningMarkers, in: text, location: location, into: acc)
        }
    }

    // MARK: - Pass 5b: Imported symbols (works even on an encrypted binary)

    private struct ImportRule {
        let symbol: String
        let category: String
        let severity: FindingSeverity
        let title: String
        let detail: String
    }

    /// Curated set of C functions / Obj-C classes whose mere presence in the
    /// import table is a meaningful signal: anti-debug/anti-jailbreak checks,
    /// custom TLS trust evaluation (pinning), weak hash primitives, and
    /// hardware-backed attestation/biometrics. All of these names live in
    /// __LINKEDIT's undefined-symbol table, so `nm -u` sees them regardless
    /// of whether __TEXT is FairPlay-encrypted.
    private static let importRules: [ImportRule] = [
        ImportRule(symbol: "_ptrace", category: "Anti-Analysis", severity: .medium,
                   title: "Imports ptrace — likely anti-debugger check",
                   detail: "PT_DENY_ATTACH via ptrace() is the classic iOS anti-debugging trick; a debugger (including some Frida usage) attaching may cause the app to exit."),
        ImportRule(symbol: "_sysctl", category: "Anti-Analysis", severity: .medium,
                   title: "Imports sysctl — possible debugger/jailbreak detection",
                   detail: "sysctl(KERN_PROC) is commonly used to check the P_TRACED flag (debugger attached) or to fingerprint the device for jailbreak detection."),
        ImportRule(symbol: "_sysctlbyname", category: "Anti-Analysis", severity: .medium,
                   title: "Imports sysctlbyname — possible debugger/jailbreak detection",
                   detail: "Same purpose as sysctl(): often used to read kernel/process state for anti-debug or anti-jailbreak checks."),
        ImportRule(symbol: "_csops", category: "Anti-Analysis", severity: .medium,
                   title: "Imports csops — possible debugger detection (CS_DEBUGGED)",
                   detail: "csops() can query the CS_DEBUGGED code-signing flag to detect an attached debugger."),
        ImportRule(symbol: "_SecTrustSetAnchorCertificates", category: "Pinning", severity: .medium,
                   title: "Imports SecTrustSetAnchorCertificates — custom trust anchors",
                   detail: "The app installs its own trust anchors instead of relying solely on the system trust store — a common building block of certificate pinning. Security Testing Mode's ATS bypass alone will not defeat this; the pinning logic itself needs to be patched or hooked."),
        ImportRule(symbol: "_SecTrustSetPolicies", category: "Pinning", severity: .medium,
                   title: "Imports SecTrustSetPolicies — custom trust evaluation policy",
                   detail: "A custom SecPolicy is applied to trust evaluation — often part of a certificate/public-key pinning implementation."),
        ImportRule(symbol: "_SecTrustEvaluateWithError", category: "Pinning", severity: .info,
                   title: "Imports SecTrustEvaluateWithError — manual TLS trust evaluation",
                   detail: "The app evaluates server trust itself rather than only relying on URLSession's default handling — check whether it implements pinning, and whether it can be tricked into trusting anything."),
        ImportRule(symbol: "_CC_MD5", category: "Crypto", severity: .low,
                   title: "Links CC_MD5 — MD5 is cryptographically broken",
                   detail: "MD5 should not be used for anything security-sensitive (integrity, signatures, password hashing). May be legitimate for non-security checksums — verify the call site once decrypted."),
        ImportRule(symbol: "_CC_SHA1", category: "Crypto", severity: .low,
                   title: "Links CC_SHA1 — SHA-1 is deprecated for security use",
                   detail: "SHA-1 collision attacks are practical; it shouldn't be used for signatures or integrity guarantees. May be legitimate for non-security use — verify the call site once decrypted."),
        ImportRule(symbol: "_OBJC_CLASS_$_LAContext", category: "Biometric", severity: .info,
                   title: "Uses LAContext — biometric/passcode authentication",
                   detail: "The app calls into LocalAuthentication (Face ID / Touch ID / device passcode). Check whether the result is trusted locally only or re-verified server-side."),
        ImportRule(symbol: "_OBJC_CLASS_$_DCAppAttestService", category: "Attestation", severity: .info,
                   title: "Uses DeviceCheck App Attest",
                   detail: "App Attest is Apple's hardware-backed anti-tampering/anti-emulation attestation — expect requests to fail on a jailbroken, emulated, or resigned build unless this is bypassed server-side or hooked."),
        ImportRule(symbol: "_OBJC_CLASS_$_DCDevice", category: "Attestation", severity: .info,
                   title: "Uses DeviceCheck",
                   detail: "DeviceCheck can be used for device reputation / anti-fraud / anti-abuse — expect it to behave differently on a resigned or jailbroken device."),
        ImportRule(symbol: "_OBJC_CLASS_$_ASAuthorizationAppleIDProvider", category: "Info", severity: .info,
                   title: "Supports Sign in with Apple",
                   detail: "The app integrates Sign in with Apple."),
    ]

    private static func scanImportedSymbols(at url: URL, location: String, into acc: ScanAccumulator) {
        let data = runProcess("/usr/bin/nm", ["-u", url.path])
        guard let out = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !out.isEmpty else { return }
        for rule in importRules where out.contains(rule.symbol) {
            acc.add(SecurityFinding(severity: rule.severity, category: rule.category,
                                    title: rule.title, detail: rule.detail,
                                    location: location, snippet: rule.symbol))
        }
    }

    // MARK: - Pass 5c: Anti-analysis & pinning string markers (needs decrypted __TEXT)

    private struct MarkerRule {
        let regex: NSRegularExpression
        let category: String
        let severity: FindingSeverity
        let title: String
        let detail: String
    }

    private static func marker(_ p: String, _ category: String, _ severity: FindingSeverity, _ title: String, _ detail: String) -> MarkerRule {
        MarkerRule(regex: rx(p), category: category, severity: severity, title: title, detail: detail)
    }

    private static let antiAnalysisMarkers: [MarkerRule] = [
        marker("(?i)frida-server", "Anti-Analysis", .high,
               "References \"frida-server\" — actively detects Frida",
               "The binary contains a literal check for the Frida server process/binary name. Many hardened apps (banking apps especially) exit silently the moment they see this — often mistaken for a crash, not a detection. Renaming frida-server (and its LaunchDaemon) on the jailbroken device, keeping the same port, usually defeats a name-based check like this."),
        marker("(?i)fridagadget", "Anti-Analysis", .high,
               "References \"FridaGadget\" — actively detects the Frida gadget",
               "The binary checks for the Frida Gadget dylib by name — relevant if you're using ipaverse's \"Inject Frida Gadget\" feature, since the gadget is loaded under this name by default."),
        marker("(?i)\\bcynject\\b", "Anti-Analysis", .medium,
               "References \"cynject\" — Cydia Substrate injection detection",
               "Checks for Cydia Substrate's injector, a common jailbreak-tooling fingerprint."),
        marker("(?i)mobilesubstrate|libsubstrate", "Anti-Analysis", .medium,
               "References MobileSubstrate — jailbreak/tweak-injection detection",
               "Checks for the MobileSubstrate/Substrate hooking framework used by most jailbreak tweaks."),
        marker("/Applications/Cydia\\.app", "Anti-Analysis", .medium,
               "Checks for Cydia.app — jailbreak detection",
               "A hardcoded filesystem check for Cydia is a classic jailbreak-detection heuristic."),
        marker("(?i)/private/var/(lib/apt|stash|lib/cydia)", "Anti-Analysis", .medium,
               "Checks jailbreak filesystem paths",
               "Hardcoded checks against common jailbreak filesystem artifacts (APT's package DB, Cydia's stash, etc.)."),
        marker("(?i)\\bcycript\\b", "Anti-Analysis", .low,
               "References \"cycript\" — reverse-engineering tool detection",
               "Checks for the Cycript runtime-exploration tool."),
    ]

    private static let pinningMarkers: [MarkerRule] = [
        marker("\\bTrustKit\\b", "Pinning", .medium,
               "Bundles TrustKit — certificate pinning library",
               "TrustKit implements SSL pinning with pin-set enforcement and reporting. ATS bypass alone will not defeat this; the pin set (Info.plist TSKConfiguration, or code) needs to be patched or hooked at runtime."),
        marker("AFSecurityPolicy", "Pinning", .medium,
               "Uses AFNetworking's AFSecurityPolicy — possible certificate pinning",
               "AFSecurityPolicy can be configured for certificate or public-key pinning (SSLPinningMode). Check whether it's set to .none (no pinning) or an active pinning mode."),
        marker("(?i)pinnedcertificates|pinnedpublickeys", "Pinning", .medium,
               "References pinned certificates/public keys",
               "A pinning implementation appears to ship its own trusted certificate or public-key set."),
        marker("kTSKConfiguration", "Pinning", .medium,
               "TrustKit pin configuration key present",
               "The TSKConfiguration dictionary key suggests TrustKit pinning is configured, likely in Info.plist or in code."),
    ]

    private static func scanMarkers(_ rules: [MarkerRule], in text: String, location: String, into acc: ScanAccumulator) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        for rule in rules {
            guard let m = rule.regex.firstMatch(in: text, options: [], range: full) else { continue }
            let snippet = (text as NSString).substring(with: m.range)
            acc.add(SecurityFinding(severity: rule.severity, category: rule.category,
                                    title: rule.title, detail: rule.detail,
                                    location: location, snippet: snippet))
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

    static func extract(ipaPath: String, to dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", ipaPath, dir.path]
        process.useUTF8Locale()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Both streams must be drained concurrently, not one after the
        // other: the old code left stdout completely unread, so a `ditto`
        // run that writes anything past the 64KB kernel pipe buffer to
        // stdout (unusual entries — resource forks, xattrs, overwrite
        // notices — can trigger this on some IPAs) blocks on that write
        // forever, and since it can then never finish writing stderr or
        // exit either, the stderr read below hangs right along with it.
        let (_, err) = drainConcurrently(outPipe, errPipe)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SecurityScanError.extractionFailed(String(data: err, encoding: .utf8) ?? "exit \(process.terminationStatus)")
        }
    }

    /// Reads `primary` and `secondary` concurrently (one on a background
    /// queue, one on the caller's thread) so neither can block the other's
    /// producer by leaving its pipe undrained while it fills — the classic
    /// deadlock a naive "read A fully, then read B" sequence risks whenever
    /// a process writes enough to both streams.
    static func drainConcurrently(_ primary: Pipe, _ secondary: Pipe) -> (primary: Data, secondary: Data) {
        let queue = DispatchQueue(label: "ipaverse.IPASecurityScanner.drain")
        var secondaryData = Data()
        let done = DispatchSemaphore(value: 0)
        queue.async {
            secondaryData = secondary.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let primaryData = primary.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (primaryData, secondaryData)
    }

    private static func decodeMobileProvision(at url: URL) -> [String: Any]? {
        let data = runProcess("/usr/bin/security", ["cms", "-D", "-i", url.path])
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Runs a CLI tool and returns stdout. UTF-8 safe; reads before waiting to
    /// avoid pipe-buffer deadlock on large output (e.g. `strings` on a big binary).
    static func runProcess(_ launchPath: String, _ args: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.useUTF8Locale()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            print("⚙️ [IPASecurityScanner] failed to launch \(launchPath): \(error)")
            return Data()
        }
        // Concurrent, not sequential (`outPipe` fully, then `errPipe`) —
        // see `drainConcurrently`'s doc comment for why the sequential form
        // that used to be here can deadlock.
        let (data, errData) = drainConcurrently(outPipe, errPipe)
        process.waitUntilExit()
        // A failing tool invocation (unsupported flag, missing binary, bad
        // input) otherwise looks identical to "found nothing" — this class of
        // bug is easy to ship silently and hard to diagnose after the fact
        // (see: the `strings -e` flag rejection this logging caught).
        if process.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print("⚙️ [IPASecurityScanner] \(launchPath) \(args.joined(separator: " ")) exited \(process.terminationStatus): \(err)")
        }
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

// MARK: - Manual search

/// One hit from `SecurityScanResult.search` — a curated regex list can never
/// anticipate everything a specific engagement is hunting for (an internal
/// hostname, a suspected leaked term, an SDK's own config key), so this lets
/// the analyst grep the same already-extracted text (every Mach-O binary's
/// strings + every text/plist/config file) for anything, on demand.
struct ManualSearchHit: Identifiable {
    let id = UUID()
    let location: String
    let snippet: String
}

extension SecurityScanResult {

    /// Case-insensitive plain-substring search (not regex — the point of
    /// this box is "type the thing you're looking for", not another syntax
    /// to learn). Capped at `maxResults` total hits so a common short query
    /// against a large corpus can't produce an unbounded list.
    func search(_ query: String, maxResults: Int = 300) -> [ManualSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var hits: [ManualSearchHit] = []
        let contextChars = 40
        for entry in searchCorpus {
            let text = entry.text
            var searchStart = text.startIndex
            while let range = text.range(of: trimmed, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                let snippetStart = text.index(range.lowerBound, offsetBy: -contextChars, limitedBy: text.startIndex) ?? text.startIndex
                let snippetEnd = text.index(range.upperBound, offsetBy: contextChars, limitedBy: text.endIndex) ?? text.endIndex
                var snippet = String(text[snippetStart..<snippetEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                if snippetStart != text.startIndex { snippet = "…" + snippet }
                if snippetEnd != text.endIndex { snippet += "…" }
                hits.append(ManualSearchHit(location: entry.location, snippet: snippet))
                if hits.count >= maxResults { return hits }
                searchStart = range.upperBound
            }
        }
        return hits
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
        if hasPartiallyEncryptedBinaries {
            out += "\n> ⚠️ Still FairPlay-encrypted: \(encryptedBinaries.joined(separator: ", ")). Results for these binaries are limited — dump a decrypted copy and re-scan for full coverage.\n"
        }

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
            "encryptedBinaries": encryptedBinaries,
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
