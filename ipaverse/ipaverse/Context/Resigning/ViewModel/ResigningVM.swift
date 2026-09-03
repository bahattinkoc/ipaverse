//
//  ResigningVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import SwiftUI
@preconcurrency import AppKit

// MARK: - PlistEntry

struct PlistEntry: Identifiable, @unchecked Sendable {
    var id = UUID()
    var key: String
    var editValue: String
    let type: ValueType
    var originalValue: Any

    enum ValueType { case string, bool, integer, real, complex }

    var isEditable: Bool { type != .complex }
    var isBool: Bool { type == .bool }
    var boolValue: Bool {
        get { editValue.lowercased() == "true" }
        set { editValue = newValue ? "true" : "false" }
    }

    func toAny() -> Any {
        switch type {
        case .string:  return editValue
        case .bool:    return editValue.lowercased() == "true"
        case .integer: return Int(editValue) ?? (originalValue as? Int ?? 0)
        case .real:    return Double(editValue) ?? (originalValue as? Double ?? 0.0)
        case .complex: return originalValue
        }
    }

    static func entries(from plist: [String: Any]) -> [PlistEntry] {
        let priorityKeys = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
                            "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"]
        return plist.map { key, value -> PlistEntry in
            switch value {
            case let v as Bool:
                return PlistEntry(key: key, editValue: v ? "true" : "false", type: .bool, originalValue: v)
            case let v as Int:
                return PlistEntry(key: key, editValue: String(v), type: .integer, originalValue: v)
            case let v as Double:
                return PlistEntry(key: key, editValue: String(v), type: .real, originalValue: v)
            case let v as String:
                return PlistEntry(key: key, editValue: v, type: .string, originalValue: v)
            default:
                let desc = "(complex — \(Swift.type(of: value)))"
                return PlistEntry(key: key, editValue: desc, type: .complex, originalValue: value)
            }
        }.sorted { a, b in
            let ai = priorityKeys.firstIndex(of: a.key) ?? Int.max
            let bi = priorityKeys.firstIndex(of: b.key) ?? Int.max
            if ai != bi { return ai < bi }
            return a.key < b.key
        }
    }
}

// MARK: - ResigningVM

@MainActor
final class ResigningVM: ObservableObject {

    enum Tab { case properties, files }

    enum State: Equatable {
        case idle
        case loading
        case signing(message: String)
        case signed(outputPath: String)
        case fairPlayWarning
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.fairPlayWarning, .fairPlayWarning): return true
            case (.signing(let a), .signing(let b)): return a == b
            case (.signed(let a), .signed(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var certificates: [ResignerCertificate] = []
    @Published var selectedCertificate: ResignerCertificate?
    @Published var plistEntries: [PlistEntry] = []
    @Published var fileTree: [IPAFileNode] = []
    @Published var fileReplacements: [String: Data] = [:]
    @Published var provisioningProfileURL: URL? {
        didSet {
            refreshProfileCertificateFingerprints()
            refreshEntitlementWarnings()
        }
    }
    /// SHA1 fingerprints of the certificates embedded in `provisioningProfileURL`'s
    /// DeveloperCertificates array — empty until the profile is parsed, and
    /// stays empty if it couldn't be read.
    @Published private(set) var profileCertificateFingerprints: Set<String> = []
    /// Capabilities the original app's own signature had (App Groups, Push,
    /// Associated Domains, ...) that the selected profile doesn't grant —
    /// surfaced before signing instead of discovered via an on-device crash.
    @Published private(set) var entitlementWarnings: [String] = []
    /// Config files (outside Info.plist) that embed the app's own bundle ID or
    /// a derived App-Group identifier — e.g. a 3rd-party SDK's own config
    /// plist. See BundleIdentityMigrator.
    @Published private(set) var identityReferences: [IdentityReference] = []
    @Published var isScanningIdentity = false
    @Published var newBundleIdentifier = "" {
        didSet {
            // Suggest a matching App Group once, without fighting a manual edit.
            if newAppGroupName.isEmpty, !newBundleIdentifier.isEmpty {
                newAppGroupName = "group.\(newBundleIdentifier)"
            }
        }
    }
    @Published var newAppGroupName = ""
    @Published var showIdentityMigrationSheet = false
    @Published var state: State = .idle
    @Published var activeTab: Tab = .properties
    @Published var isAddingKey = false
    @Published var newKeyName = ""
    @Published var newKeyValue = ""
    @Published var enableSecurityTestingMode = false
    @Published var enableFridaGadgetInjection = false
    /// Bare framework/dylib names (no extension) flagged for removal — see
    /// FrameworkStripper. Populated from the Files tab.
    @Published var frameworksToRemove: Set<String> = []

    let downloadedApp: DownloadedApp

    // Pending values retained so the user can retry after FairPlay warning
    private var pendingCertificate: ResignerCertificate?
    private var pendingOutputPath: String?

    /// The original app's own signed entitlements, extracted once at load()
    /// from its still-untouched signature — the baseline for
    /// `entitlementWarnings`.
    private var originalEntitlements: [String: Any] = [:]
    /// The bundle ID `identityReferences` was scanned for — captured at scan
    /// time so `applyIdentityMigration()` knows the exact old→new string map
    /// even if the user has since edited CFBundleIdentifier in Properties.
    private var scannedOriginalBundleID: String?
    /// Old → new strings from the last applied "Move to New Identity" — lets
    /// `refreshEntitlementWarnings()` compare against what the identifiers
    /// *should* be post-migration instead of the untouched original.
    private var appliedIdentityReplacements: [String: String] = [:]

    init(downloadedApp: DownloadedApp) {
        self.downloadedApp = downloadedApp
    }

    var isSigning: Bool {
        if case .signing = state { return true }
        return false
    }

    var signingMessage: String? {
        if case .signing(let msg) = state { return msg }
        return nil
    }

    var signedOutputPath: String? {
        if case .signed(let path) = state { return path }
        return nil
    }

    var isFairPlayWarning: Bool { state == .fairPlayWarning }

    /// Certificates authorized by the selected provisioning profile. Falls back to
    /// the full list when no profile is selected yet or the profile couldn't be parsed.
    var matchingCertificates: [ResignerCertificate] {
        guard provisioningProfileURL != nil, !profileCertificateFingerprints.isEmpty else { return certificates }
        return certificates.filter { profileCertificateFingerprints.contains($0.id.uppercased()) }
    }

    /// True once a profile is selected and none of the locally available certificates
    /// are in its DeveloperCertificates list — signing would fail on-device.
    var hasNoCertificateMatchingProfile: Bool {
        provisioningProfileURL != nil && !profileCertificateFingerprints.isEmpty && matchingCertificates.isEmpty
    }

    var errorMessage: String? {
        if case .error(let msg) = state { return msg }
        return nil
    }

    // MARK: - Load

    func load() async {
        state = .loading
        let ipaPath = downloadedApp.filePath

        let (certs, entries, tree, entitlements) = await Task.detached {
            let certs = (try? IPAResigner.listCertificates()) ?? []
            let rawPlist = (try? IPAResigner.loadInfoPlist(ipaPath: ipaPath)) ?? [:]
            let entries = PlistEntry.entries(from: rawPlist)
            let tree = (try? IPAResigner.buildFileTree(ipaPath: ipaPath)) ?? []
            let entitlements = Self.extractOriginalEntitlements(ipaPath: ipaPath)
            return (certs, entries, tree, entitlements)
        }.value

        certificates = certs
        selectedCertificate = certificates.first(where: { $0.isDevelopment }) ?? certificates.first
        plistEntries = entries
        fileTree = tree
        originalEntitlements = entitlements
        state = .idle
    }

    /// Extracts the currently-signed entitlements from the IPA's main
    /// executable by pulling just that one file out to a temp location —
    /// avoids a full IPA extraction just to answer "what did this app used to
    /// be allowed to do".
    private nonisolated static func extractOriginalEntitlements(ipaPath: String) -> [String: Any] {
        guard let entries = try? IPAResigner.listEntries(ipaPath: ipaPath),
              let appDirEntry = entries.first(where: {
                  $0.hasSuffix(".app/") && $0.hasPrefix("Payload/") && $0.components(separatedBy: "/").count == 3
              })
        else { return [:] }

        let appName = String(appDirEntry.dropFirst("Payload/".count).dropLast(".app/".count))
        let binaryEntry = "Payload/\(appName).app/\(appName)"
        guard let data = try? IPAResigner.readEntry(ipaPath: ipaPath, entryName: binaryEntry), !data.isEmpty else {
            return [:]
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard (try? data.write(to: tempURL)) != nil else { return [:] }
        return IPAResigner.extractSignedEntitlements(fromBinaryAt: tempURL)
    }

    // MARK: - Plist editing

    func updateEntry(_ entry: PlistEntry) {
        guard let idx = plistEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        plistEntries[idx] = entry
    }

    func deleteEntry(_ entry: PlistEntry) {
        plistEntries.removeAll { $0.id == entry.id }
    }

    func commitNewKey() {
        let key = newKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newKeyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        plistEntries.append(PlistEntry(key: key, editValue: value, type: .string, originalValue: value))
        newKeyName = ""
        newKeyValue = ""
        isAddingKey = false
    }

    // MARK: - Provisioning profile

    func pickProvisioningProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select provisioning profile"
        if let type = UTType(filenameExtension: "mobileprovision") {
            panel.allowedContentTypes = [type]
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.provisioningProfileURL = url }
        }
    }

    private func refreshProfileCertificateFingerprints() {
        guard let url = provisioningProfileURL else {
            profileCertificateFingerprints = []
            return
        }
        Task.detached { [weak self] in
            let fingerprints = IPAResigner.developerCertificateFingerprints(from: url)
            await MainActor.run {
                guard let self, self.provisioningProfileURL == url else { return }
                self.profileCertificateFingerprints = fingerprints
                // Selected certificate no longer authorized by the new profile — switch
                // to one that is, if any is available, so the picker doesn't stay stale.
                if let selected = self.selectedCertificate,
                   !fingerprints.isEmpty, !fingerprints.contains(selected.id.uppercased()) {
                    self.selectedCertificate = self.matchingCertificates.first
                }
            }
        }
    }

    // MARK: - Entitlement diff

    /// Capabilities (App ID, human label) worth warning about when the original
    /// signature had them but the selected profile can't grant them —
    /// deliberately not exhaustive, just the ones known to cause silent
    /// runtime failures (crashes or dead features) rather than install-time
    /// rejection.
    private static let watchedEntitlements: [(key: String, label: String)] = [
        ("com.apple.security.application-groups", "App Groups"),
        ("aps-environment", "Push Notifications"),
        ("com.apple.developer.associated-domains", "Associated Domains"),
        ("com.apple.developer.devicecheck.appattest-environment", "DeviceCheck / App Attest"),
        ("com.apple.developer.nfc.readersession.formats", "NFC"),
        ("com.apple.developer.healthkit", "HealthKit"),
        ("com.apple.developer.in-app-payments", "Apple Pay"),
    ]

    private func refreshEntitlementWarnings() {
        guard let profileURL = provisioningProfileURL, !originalEntitlements.isEmpty else {
            entitlementWarnings = []
            return
        }
        let original = originalEntitlements
        let identityReplacements = appliedIdentityReplacements
        Task.detached { [weak self] in
            let profileEntitlements = (try? IPAResigner.extractEntitlements(from: profileURL)) ?? [:]
            let warnings = Self.diffEntitlements(original: original, profile: profileEntitlements, identityReplacements: identityReplacements)
            await MainActor.run {
                guard let self, self.provisioningProfileURL == profileURL else { return }
                self.entitlementWarnings = warnings
            }
        }
    }

    /// `identityReplacements` (old → new, from an applied "Move to New Identity")
    /// is applied to each ORIGINAL string value before comparing against the
    /// profile — otherwise, after an intentional App-Group migration, this
    /// would keep "finding" the old group name missing from the new profile,
    /// which is expected and correct, not a real gap.
    private nonisolated static func diffEntitlements(
        original: [String: Any], profile: [String: Any], identityReplacements: [String: String]
    ) -> [String] {
        var warnings: [String] = []
        for (key, label) in watchedEntitlements {
            guard let originalValue = original[key] else { continue }
            if let originalArray = originalValue as? [Any], originalArray.isEmpty { continue }

            guard let profileValue = profile[key] else {
                warnings.append("\(label) is in the original signature but missing entirely from the selected profile.")
                continue
            }
            if let originalArray = originalValue as? [String] {
                let expectedArray = originalArray.map { identityReplacements[$0] ?? $0 }
                let profileArray = (profileValue as? [String]) ?? []
                if profileArray.isEmpty {
                    warnings.append("\(label) is an empty array in the profile — attach the resource to the App ID's capability and regenerate the profile.")
                } else {
                    let missing = Set(expectedArray).subtracting(profileArray)
                    if !missing.isEmpty {
                        warnings.append("\(label): missing from the profile — \(missing.sorted().joined(separator: ", "))")
                    }
                }
            }
        }
        return warnings
    }

    // MARK: - Identity migration (bundle ID / App Group)

    /// Scans the IPA for config files (outside Info.plist) that embed the
    /// app's own bundle ID or a `group.<bundleID>`-style App Group identifier
    /// — e.g. a 3rd-party SDK's own config plist. Opens the migration sheet
    /// with whatever it finds (possibly nothing).
    func scanForIdentityMigration() {
        guard let originalBundleID = plistEntries.first(where: { $0.key == "CFBundleIdentifier" })?.originalValue as? String,
              !originalBundleID.isEmpty else { return }

        scannedOriginalBundleID = originalBundleID
        isScanningIdentity = true
        let ipaPath = downloadedApp.filePath
        let profileURL = provisioningProfileURL
        let needles = [originalBundleID, "group.\(originalBundleID)"]

        Task.detached { [weak self] in
            let refs = (try? BundleIdentityMigrator.scanForIdentityReferences(ipaPath: ipaPath, needles: needles)) ?? []
            let derived = profileURL.flatMap { Self.deriveIdentity(fromProfileAt: $0) }
            await MainActor.run {
                guard let self else { return }
                self.identityReferences = refs
                // A selected profile already declares its own bundle ID and
                // App Group — if the user already picked one, they've already
                // made this decision on the portal, no need to ask again (and
                // no risk of a typo/mismatch between what's typed here and
                // what the profile actually authorizes).
                if let derived {
                    self.newBundleIdentifier = derived.bundleID
                    if let appGroup = derived.appGroup { self.newAppGroupName = appGroup }
                }
                self.isScanningIdentity = false
                self.showIdentityMigrationSheet = true
            }
        }
    }

    /// Reads the new bundle ID and (if any) App Group directly out of a
    /// provisioning profile's own entitlements — `application-identifier` is
    /// "TEAMID.bundle.id" (or "TEAMID.*" for a wildcard profile, which can't
    /// name a concrete bundle ID and is treated as non-derivable).
    private nonisolated static func deriveIdentity(fromProfileAt url: URL) -> (bundleID: String, appGroup: String?)? {
        guard let entitlements = try? IPAResigner.extractEntitlements(from: url),
              let appID = entitlements["application-identifier"] as? String
        else { return nil }

        let parts = appID.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        let bundleID = parts.dropFirst().joined(separator: ".")
        guard bundleID != "*", !bundleID.hasSuffix(".*") else { return nil }

        let appGroup = (entitlements["com.apple.security.application-groups"] as? [String])?.first
        return (bundleID, appGroup)
    }

    /// Applies `newBundleIdentifier`/`newAppGroupName`: updates the
    /// CFBundleIdentifier plist entry and queues a text-substituted
    /// replacement for every file `scanForIdentityMigration()` found —
    /// reuses the exact same `fileReplacements` dictionary the Files tab's
    /// manual Replace button writes to, so the rest of the sign pipeline
    /// needs no changes.
    func applyIdentityMigration() {
        guard !newBundleIdentifier.isEmpty, let originalBundleID = scannedOriginalBundleID else { return }

        if let idx = plistEntries.firstIndex(where: { $0.key == "CFBundleIdentifier" }) {
            var entry = plistEntries[idx]
            entry.editValue = newBundleIdentifier
            updateEntry(entry)
        }

        let ipaPath = downloadedApp.filePath
        let references = identityReferences
        var replacements = [originalBundleID: newBundleIdentifier]
        if !newAppGroupName.isEmpty {
            replacements["group.\(originalBundleID)"] = newAppGroupName
        }
        appliedIdentityReplacements = replacements
        refreshEntitlementWarnings()

        showIdentityMigrationSheet = false
        Task.detached { [weak self] in
            let files = (try? BundleIdentityMigrator.applyReplacements(
                ipaPath: ipaPath, references: references, replacements: replacements
            )) ?? [:]
            await MainActor.run {
                guard let self else { return }
                for (path, data) in files { self.fileReplacements[path] = data }
            }
        }
    }

    // MARK: - Framework removal

    /// `name` is the bare framework/dylib name (no extension) — e.g. a
    /// Frameworks/NetmeraCore.framework node's `name` with the extension
    /// dropped.
    func toggleFrameworkRemoval(_ name: String) {
        if frameworksToRemove.contains(name) {
            frameworksToRemove.remove(name)
        } else {
            frameworksToRemove.insert(name)
        }
    }

    // MARK: - File replacement

    func replaceFile(at path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a new file to replace the existing one"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                self?.fileReplacements[path] = data
            }
        }
    }

    // MARK: - Sign

    func initiateSign() {
        guard let cert = selectedCertificate else { return }

        let panel = NSSavePanel()
        panel.title = "Save Signed IPA"
        panel.canCreateDirectories = true
        let original = URL(fileURLWithPath: downloadedApp.filePath)
        let stem = original.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)_signed.ipa"
        if let contentType = UTType(filenameExtension: "ipa") {
            panel.allowedContentTypes = [contentType]
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.performSign(certificate: cert, outputPath: url.path)
            }
        }
    }

    // Called when user taps "Continue Anyway" on the FairPlay warning
    func continueDespiteFairPlay() {
        guard let cert = pendingCertificate, let path = pendingOutputPath else { return }
        pendingCertificate = nil
        pendingOutputPath = nil
        performSign(certificate: cert, outputPath: path, allowFairPlayEncrypted: true)
    }

    // Called when user taps "Cancel" on the FairPlay warning
    func cancelFairPlayWarning() {
        pendingCertificate = nil
        pendingOutputPath = nil
        state = .idle
    }

    private func performSign(
        certificate: ResignerCertificate,
        outputPath: String,
        allowFairPlayEncrypted: Bool = false
    ) {
        let config = ResignConfig(
            certificate: certificate,
            plistEdits: Dictionary(uniqueKeysWithValues: plistEntries
                .filter { $0.isEditable }
                .map { ($0.key, $0.toAny()) }
            ),
            fileReplacements: fileReplacements,
            provisioningProfileURL: provisioningProfileURL,
            enableSecurityTestingMode: enableSecurityTestingMode,
            enableFridaGadgetInjection: enableFridaGadgetInjection,
            removedFrameworks: Array(frameworksToRemove)
        )
        let ipaPath = downloadedApp.filePath

        Task.detached { [self] in
            do {
                try IPAResigner().sign(
                    ipaPath: ipaPath,
                    config: config,
                    outputPath: outputPath,
                    allowFairPlayEncrypted: allowFairPlayEncrypted
                ) { message in
                    Task { @MainActor [self] in self.state = .signing(message: message) }
                }
                await MainActor.run { self.state = .signed(outputPath: outputPath) }
            } catch IPAResignError.fairPlayEncrypted {
                await MainActor.run {
                    self.pendingCertificate = certificate
                    self.pendingOutputPath = outputPath
                    self.state = .fairPlayWarning
                }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
    }
}

import UniformTypeIdentifiers
