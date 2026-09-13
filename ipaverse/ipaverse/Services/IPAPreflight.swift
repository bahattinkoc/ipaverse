import Foundation
import CryptoKit

struct PreflightCheck: Identifiable, Sendable {
    enum Status: String, Sendable { case passed, warning, blocked }
    var id: String { title + "|" + detail }
    let status: Status
    let title: String
    let detail: String
}

struct ProvisioningProfile: @unchecked Sendable {
    let name: String
    let expiration: Date
    let entitlements: [String: Any]
    let certificates: Set<String>
    let devices: [String]?
    let allDevices: Bool

    init(plist: [String: Any]) throws {
        guard let expiration = plist["ExpirationDate"] as? Date,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String, !appID.isEmpty,
              let certificates = plist["DeveloperCertificates"] as? [Data], !certificates.isEmpty else {
            throw IPAPreflight.Failure.invalidProfile
        }
        self.name = plist["Name"] as? String ?? "Profile"
        self.expiration = expiration
        self.entitlements = entitlements
        self.certificates = Set(certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() })
        self.devices = plist["ProvisionedDevices"] as? [String]
        self.allDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
    }
    static func read(_ url: URL) throws -> ProvisioningProfile {
        let output = try ProcessRunner.run("/usr/bin/security", ["cms", "-D", "-i", url.path], maxOutputBytes: 8 * 1024 * 1024).output
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any] else { throw IPAPreflight.Failure.invalidProfile }
        return try ProvisioningProfile(plist: plist)
    }
    var teamID: String {
        (entitlements["com.apple.developer.team-identifier"] as? String) ?? appIDPrefix
    }
    var appIDPrefix: String { (entitlements["application-identifier"] as? String)?.components(separatedBy: ".").first ?? "" }
    func allows(bundleID: String) -> Bool {
        guard let applicationID = entitlements["application-identifier"] as? String,
              let separator = applicationID.firstIndex(of: ".") else { return false }
        let pattern = String(applicationID[applicationID.index(after: separator)...])
        if pattern == "*" { return !bundleID.isEmpty }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast())) }
        return pattern == bundleID
    }
    func checks(bundleID: String, certificateID: String? = nil, deviceID: String? = nil, now: Date = Date()) -> [PreflightCheck] {
        var result = [
            PreflightCheck(status: expiration > now ? .passed : .blocked, title: "\(bundleID) — profile expiration", detail: "\(name): \(expiration.formatted(date: .abbreviated, time: .omitted))"),
            PreflightCheck(status: allows(bundleID: bundleID) ? .passed : .blocked, title: "\(bundleID) — application identifier", detail: entitlements["application-identifier"] as? String ?? "Missing")
        ]
        if let certificateID {
            result.append(PreflightCheck(status: certificates.contains(certificateID.uppercased()) ? .passed : .blocked,
                title: "\(bundleID) — signing certificate", detail: "Certificate must be authorized by this profile."))
        }
        if let deviceID {
            let included = allDevices || devices?.contains(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame }) == true
            result.append(PreflightCheck(status: included ? .passed : .blocked, title: "\(bundleID) — device registration",
                detail: included ? "The profile permits this device." : "This profile does not permit direct installation on this device."))
        } else {
            result.append(PreflightCheck(status: .warning, title: "Device registration", detail: "Select a device during installation to check its UDID."))
        }
        return result
    }

    /// Expand only allowed wildcard values; preserve distribution/debug/push policy.
    func signingEntitlements(bundleID: String) throws -> [String: Any] {
        guard allows(bundleID: bundleID), expiration > Date() else { throw IPAPreflight.Failure.invalidProfile }
        var result = entitlements
        result["application-identifier"] = appIDPrefix + "." + bundleID
        if let groups = entitlements["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = groups.map { $0.hasSuffix(".*") ? String($0.dropLast()) + bundleID : $0 }
        }
        return result
    }
}

enum IPAPreflight {
    enum Failure: LocalizedError {
        case invalidProfile, blocked(String)
        var errorDescription: String? {
            switch self {
            case .invalidProfile: return "The provisioning profile is invalid, expired, or does not match the app."
            case .blocked(let message): return message
            }
        }
    }
    struct BundleInfo: Sendable {
        let path: String
        let bundleID: String
        let executable: String?
    }
    static func bundles(ipaPath: String, newMainID: String? = nil) throws -> [BundleInfo] {
        try IPASecurityScanner.validateArchiveLimits(ipaPath: ipaPath)
        let entries = try IPAResigner.listEntries(ipaPath: ipaPath)
        let infoPaths = entries.filter {
            $0.hasPrefix("Payload/") && ($0.hasSuffix(".app/Info.plist") || $0.hasSuffix(".appex/Info.plist") || $0.hasSuffix(".xpc/Info.plist"))
        }.sorted { $0.count < $1.count }
        let mainPaths = infoPaths.filter { $0.split(separator: "/").count == 3 && $0.hasSuffix(".app/Info.plist") }
        guard mainPaths.count == 1, infoPaths.first == mainPaths.first else { throw IPAResignError.appBundleNotFound }
        var result: [BundleInfo] = []
        var oldMainID: String?
        for path in infoPaths {
            let data = try IPAResigner.readEntry(ipaPath: ipaPath, entryName: path)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  var bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { throw PackageDownloadError.invalidPackage }
            if oldMainID == nil { oldMainID = bundleID }
            if let newMainID, let old = oldMainID, bundleID == old || bundleID.hasPrefix(old + ".") {
                bundleID = newMainID + bundleID.dropFirst(old.count)
            }
            result.append(BundleInfo(path: String(path.dropLast("Info.plist".count)), bundleID: bundleID, executable: plist["CFBundleExecutable"] as? String))
        }
        guard !result.isEmpty else { throw IPAResignError.appBundleNotFound }
        return result
    }

    static func signing(ipaPath: String, profileURL: URL?, certificate: ResignerCertificate?,
                        newMainID: String?, extensionProfiles: [String: URL]) throws -> [PreflightCheck] {
        let bundles = try bundles(ipaPath: ipaPath, newMainID: newMainID)
        guard let profileURL, let certificate else {
            return [PreflightCheck(status: .blocked, title: "Signing identity", detail: "Choose a certificate and provisioning profile.")]
        }
        var checks: [PreflightCheck] = []
        for (index, bundle) in bundles.enumerated() {
            let url = index == 0 ? profileURL : extensionProfiles[bundle.bundleID] ?? profileURL
            do {
                let profile = try ProvisioningProfile.read(url)
                checks += profile.checks(bundleID: bundle.bundleID, certificateID: certificate.id)
            } catch {
                checks.append(PreflightCheck(status: .blocked, title: bundle.bundleID, detail: error.localizedDescription))
            }
        }
        checks.append(PreflightCheck(status: .warning, title: "Launch verification", detail: "FairPlay and runtime behavior are checked separately. Passing these checks does not guarantee launch."))
        return checks
    }

    static func installation(ipaPath: String, device: ConnectedDevice) throws -> [PreflightCheck] {
        let bundles = try bundles(ipaPath: ipaPath)
        let plist = try IPAResigner.loadInfoPlist(ipaPath: ipaPath)
        var checks: [PreflightCheck] = []
        let platforms = plist["CFBundleSupportedPlatforms"] as? [String] ?? []
        checks.append(PreflightCheck(status: platforms.isEmpty ? .warning : platforms.contains("iPhoneOS") ? .passed : .blocked,
            title: "Platform", detail: platforms.isEmpty ? "The package does not declare a platform." : platforms.joined(separator: ", ")))
        if let minimum = plist["MinimumOSVersion"] as? String {
            checks.append(PreflightCheck(status: minimum.compare(device.osVersion, options: .numeric) != .orderedDescending ? .passed : .blocked,
                title: "Minimum OS", detail: "Requires \(minimum); device has \(device.osVersion)."))
        } else { checks.append(PreflightCheck(status: .warning, title: "Minimum OS", detail: "The package does not declare a minimum OS.")) }
        let entries = Set(try IPAResigner.listEntries(ipaPath: ipaPath))
        for bundle in bundles {
            let entry = bundle.path + "embedded.mobileprovision"
            guard entries.contains(entry) else {
                checks.append(PreflightCheck(status: .warning, title: bundle.bundleID, detail: "No embedded profile. Store licensing may apply; device validation is required."))
                continue
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobileprovision")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try IPAResigner.readEntry(ipaPath: ipaPath, entryName: entry).write(to: temporary)
            let profile = try ProvisioningProfile.read(temporary)
            // Store-distributed profiles do not list device UDIDs. Preserve original Store installs.
            let checkDevice = profile.devices != nil || profile.allDevices
            checks += profile.checks(bundleID: bundle.bundleID, deviceID: checkDevice ? device.id : nil)
        }
        checks.append(PreflightCheck(status: .warning, title: "Apple Account on device", detail: "ipaverse cannot verify the device's App Store account or FairPlay license."))
        return checks
    }
}
