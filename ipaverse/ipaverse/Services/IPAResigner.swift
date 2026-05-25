//
//  IPAResigner.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import Foundation

// MARK: - Models

struct ResignerCertificate: Identifiable, Hashable {
    let id: String    // SHA1 hash — used as -s argument to codesign
    let name: String  // "Apple Development: Ad Soyad (TEAMID)"

    var teamID: String? {
        guard let open = name.lastIndex(of: "("),
              let close = name.lastIndex(of: ")"),
              open < close else { return nil }
        let start = name.index(after: open)
        let value = String(name[start..<close])
        return value.isEmpty ? nil : value
    }

    var isDevelopment: Bool { name.hasPrefix("Apple Development:") }
    var isDistribution: Bool { name.hasPrefix("iPhone Distribution:") || name.hasPrefix("Apple Distribution:") }

    var displayName: String {
        if isDevelopment { return "⚙ \(name)" }
        if isDistribution { return "📦 \(name)" }
        return name
    }
}

struct ResignConfig {
    let certificate: ResignerCertificate
    let plistEdits: [String: Any]
    let fileReplacements: [String: Data]
    let provisioningProfileURL: URL?
}

struct IPAFileNode: Identifiable {
    let id: String   // = path (IPA içindeki relative path)
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [IPAFileNode]?
}

enum IPAResignError: LocalizedError {
    case appBundleNotFound
    case infoPlistNotFound
    case provisioningProfileRequired
    case fairPlayEncrypted
    case processFailure(executable: String, stderr: String)
    case codesignFailed(String)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound: "No .app bundle found inside Payload"
        case .infoPlistNotFound: "Info.plist not found"
        case .provisioningProfileRequired: "A provisioning profile (.mobileprovision) is required to install on a device"
        case .fairPlayEncrypted:
            "This IPA is encrypted with FairPlay DRM. Re-signing does not work with encrypted App Store IPAs — only your own builds or decrypted IPAs can be signed."
        case .processFailure(let exe, let err): "\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(err)"
        case .codesignFailed(let msg): "Signing failed: \(msg)"
        }
    }
}

// MARK: - IPAResigner

struct IPAResigner {

    // MARK: - Static helpers

    static func listCertificates() throws -> [ResignerCertificate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Line format: "  1) HASH "Name""
        var certs: [ResignerCertificate] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let parenIdx = trimmed.firstIndex(of: ")") else { continue }
            let rest = trimmed[trimmed.index(after: parenIdx)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("\"") || rest.count >= 40 else { continue }

            // rest = "HASH \"Name\"" or "HASH \"Name\" (TEAMID)"
            let parts = rest.components(separatedBy: " ")
            guard let hash = parts.first, hash.count == 40 else { continue }

            let quotedName = parts.dropFirst().joined(separator: " ")
            let name = quotedName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !name.isEmpty else { continue }
            certs.append(ResignerCertificate(id: hash, name: name))
        }
        // Development certificates first, then Distribution, duplicates removed
        var seen = Set<String>()
        return certs
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.isDevelopment && !$1.isDevelopment }
    }

    static func loadInfoPlist(ipaPath: String) throws -> [String: Any] {
        let entries = try listEntries(ipaPath: ipaPath)
        guard let plistEntry = entries.first(where: { isMainInfoPlist($0) }) else {
            throw IPAResignError.infoPlistNotFound
        }
        let data = try readEntry(ipaPath: ipaPath, entryName: plistEntry)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw IPAResignError.infoPlistNotFound
        }
        return plist
    }

    static func buildFileTree(ipaPath: String) throws -> [IPAFileNode] {
        let entries = try listEntries(ipaPath: ipaPath)
        return buildTree(from: entries)
    }

    // MARK: - Sign

    func sign(
        ipaPath: String,
        config: ResignConfig,
        outputPath: String,
        progress: @escaping (String) -> Void
    ) throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1. Extract IPA
        progress("Opening IPA...")
        try runProcess(executable: "/usr/bin/unzip", arguments: ["-q", ipaPath, "-d", workDir.path])

        // 2. .app bundle'ı bul
        let appURL = try findAppBundle(in: workDir.appendingPathComponent("Payload"))
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")

        // 2.1 FairPlay encryption check — encrypted binaries cannot be re-signed
        let appName = appURL.deletingPathExtension().lastPathComponent
        let mainBinaryURL = appURL.appendingPathComponent(appName)
        print("⚙️ [IPAResigner] Checking FairPlay: \(mainBinaryURL.lastPathComponent)")
        if isFairPlayEncrypted(binaryURL: mainBinaryURL) {
            print("⚙️ [IPAResigner] ❌ FairPlay encrypted (cryptid=1) — signing aborted")
            throw IPAResignError.fairPlayEncrypted
        }
        print("⚙️ [IPAResigner] ✓ Not FairPlay encrypted (cryptid=0)")

        // 3. Apply Info.plist edits
        if !config.plistEdits.isEmpty {
            progress("Applying changes...")
            var plist = (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoPlistURL), options: [], format: nil
            ) as? [String: Any]) ?? [:]
            let originalBundleID = plist["CFBundleIdentifier"] as? String ?? ""
            for (key, value) in config.plistEdits { plist[key] = value }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: infoPlistURL)

            // If bundle ID changed, update PlugIns and XPC extensions too
            if let newBundleID = config.plistEdits["CFBundleIdentifier"] as? String,
               !originalBundleID.isEmpty, newBundleID != originalBundleID {
                updateNestedBundleIDs(in: appURL, oldPrefix: originalBundleID, newPrefix: newBundleID)
            }
        }

        // 4. Apply file replacements
        if !config.fileReplacements.isEmpty {
            if config.plistEdits.isEmpty { progress("Applying changes...") }
            for (relativePath, data) in config.fileReplacements {
                let fileURL = workDir.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: fileURL)
            }
        }

        // 5. Remove old signatures and original mobileprovision
        progress("Removing old signatures...")
        removeCodeSignatures(in: appURL)
        // Original IPA's distribution profile causes signature mismatch — always remove
        try? FileManager.default.removeItem(at: appURL.appendingPathComponent("embedded.mobileprovision"))

        // 6. Embed provisioning profile (required)
        guard let profileURL = config.provisioningProfileURL else {
            throw IPAResignError.provisioningProfileRequired
        }
        try FileManager.default.copyItem(at: profileURL, to: appURL.appendingPathComponent("embedded.mobileprovision"))
        print("⚙️ [IPAResigner] mobileprovision embedded: \(profileURL.lastPathComponent)")

        // 7. Read final bundle ID (for entitlements)
        let finalPlist = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoPlistURL), options: [], format: nil
        ) as? [String: Any]) ?? [:]
        let bundleID = finalPlist["CFBundleIdentifier"] as? String ?? ""

        // 8. Entitlements — derive from provisioning profile (no unauthorized entitlements added)
        let profileEntitlements = (try? extractEntitlements(from: profileURL)) ?? [:]

        // Team ID: extract from profile (authoritative source), not from certificate name
        let teamID: String = {
            if let t = profileEntitlements["com.apple.developer.team-identifier"] as? String, !t.isEmpty { return t }
            if let appID = profileEntitlements["application-identifier"] as? String {
                let prefix = appID.components(separatedBy: ".").first ?? ""
                if !prefix.isEmpty && prefix != "*" { return prefix }
            }
            return config.certificate.teamID ?? ""
        }()
        print("⚙️ [IPAResigner] teamID=\(teamID) (profile: \(profileEntitlements["com.apple.developer.team-identifier"] as? String ?? "—"), cert: \(config.certificate.teamID ?? "—"))")

        let entitlements = buildSigningEntitlements(from: profileEntitlements, bundleID: bundleID, teamID: teamID)
        let entsURL = workDir.appendingPathComponent("entitlements.plist")
        let entsData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entsData.write(to: entsURL)
        print("⚙️ [IPAResigner] entitlements (profile-based): \(entitlements.keys.sorted())")

        // 9. Sign — inside-out: Frameworks → PlugIns/.appex → main .app
        progress("Signing...")
        try signInsideOut(appURL: appURL, certificate: config.certificate.id,
                          mainEntitlementsURL: entsURL, profileEntitlements: profileEntitlements,
                          newTeamID: teamID, workDir: workDir)

        // 10. Create new IPA
        // -0: store without compression — binaries must not change through zip/unzip (page hash matching)
        // -X: no macOS metadata (__MACOSX, ._* files)
        progress("Creating IPA...")
        try runProcess(
            executable: "/usr/bin/zip",
            workingDirectory: workDir,
            arguments: ["-qrX0", outputPath, "Payload"]
        )
    }

    // MARK: - Private helpers

    @discardableResult
    private func runProcess(executable: String, workingDirectory: URL? = nil, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory { process.currentDirectoryURL = wd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IPAResignError.processFailure(
                executable: executable,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
            )
        }
        return out
    }

    private func runProcessCapturingError(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IPAResignError.codesignFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return err
    }

    private func signInsideOut(
        appURL: URL,
        certificate: String,
        mainEntitlementsURL: URL,
        profileEntitlements: [String: Any],
        newTeamID: String,
        workDir: URL
    ) throws {
        let fm = FileManager.default

        // 1. Main app's Frameworks directory — sign without entitlements
        let frameworksURL = appURL.appendingPathComponent("Frameworks")
        if let items = try? fm.contentsOfDirectory(at: frameworksURL, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "framework" || item.pathExtension == "dylib" {
                let err = (try? runProcessCapturingError(executable: "/usr/bin/codesign",
                                                         arguments: ["-f", "-s", certificate, item.path])) ?? ""
                print("⚙️ [IPAResigner] codesign \(item.lastPathComponent): \(err.isEmpty ? "OK" : err)")
            }
        }

        // 2. .appex bundles inside PlugIns — each signed with its own patched entitlements
        let pluginsURL = appURL.appendingPathComponent("PlugIns")
        if let appexes = try? fm.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) {
            for appex in appexes where appex.pathExtension == "appex" {
                // Sign appex's own Frameworks directory first if present
                let appexFW = appex.appendingPathComponent("Frameworks")
                if let fwItems = try? fm.contentsOfDirectory(at: appexFW, includingPropertiesForKeys: nil) {
                    for item in fwItems where item.pathExtension == "framework" || item.pathExtension == "dylib" {
                        let err = (try? runProcessCapturingError(executable: "/usr/bin/codesign",
                                                                  arguments: ["-f", "-s", certificate, item.path])) ?? ""
                        print("⚙️ [IPAResigner] codesign \(item.lastPathComponent): \(err.isEmpty ? "OK" : err)")
                    }
                }
                // Derive appex's own entitlements from the profile
                let appexEntsURL = entitlementsURL(for: appex, profileEntitlements: profileEntitlements, newTeamID: newTeamID, workDir: workDir)
                let err = try runProcessCapturingError(
                    executable: "/usr/bin/codesign",
                    arguments: ["-f", "-s", certificate, "--entitlements", appexEntsURL.path, appex.path]
                )
                print("⚙️ [IPAResigner] codesign \(appex.lastPathComponent): \(err.isEmpty ? "OK" : err)")
            }
        }

        // 3. Sign the main .app last
        let err = try runProcessCapturingError(
            executable: "/usr/bin/codesign",
            arguments: ["-f", "-s", certificate, "--entitlements", mainEntitlementsURL.path, appURL.path]
        )
        print("⚙️ [IPAResigner] codesign \(appURL.lastPathComponent): \(err.isEmpty ? "OK" : err)")
    }

    private func entitlementsURL(for bundleURL: URL, profileEntitlements: [String: Any], newTeamID: String, workDir: URL) -> URL {
        let bundleID = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundleURL.appendingPathComponent("Info.plist")), options: [], format: nil
        ) as? [String: Any])?["CFBundleIdentifier"] as? String ?? ""
        let ents = buildSigningEntitlements(from: profileEntitlements, bundleID: bundleID, teamID: newTeamID)
        let url = workDir.appendingPathComponent("ents_\(bundleURL.lastPathComponent).plist")
        let data = (try? PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0)) ?? Data()
        try? data.write(to: url)
        return url
    }

    private func updateNestedBundleIDs(in appURL: URL, oldPrefix: String, newPrefix: String) {
        // iOS requires all .appex bundle IDs to start with the main bundle ID prefix.
        // Watch extensions, notification extensions, intents, etc. live under PlugIns.
        // Some apps may also contain XPCServices.
        let searchDirs = ["PlugIns", "XPCServices"]
        for dir in searchDirs {
            let dirURL = appURL.appendingPathComponent(dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil
            ) else { continue }
            for bundleURL in contents where bundleURL.pathExtension == "appex" || bundleURL.pathExtension == "xpc" {
                rewriteBundleID(in: bundleURL.appendingPathComponent("Info.plist"),
                                oldPrefix: oldPrefix, newPrefix: newPrefix)
            }
        }
    }

    private func rewriteBundleID(in plistURL: URL, oldPrefix: String, newPrefix: String) {
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let current = plist["CFBundleIdentifier"] as? String,
              current.hasPrefix(oldPrefix) else { return }
        let suffix = String(current.dropFirst(oldPrefix.count))
        plist["CFBundleIdentifier"] = newPrefix + suffix
        if let written = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
            try? written.write(to: plistURL)
        }
    }

    private func isFairPlayEncrypted(binaryURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: binaryURL), data.count > 8 else {
            print("⚙️ [IPAResigner] FairPlay: binary unreadable or too small — \(binaryURL.lastPathComponent)")
            return false
        }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        var offsets: [Int] = []
        let fatMagic: UInt32 = 0xCAFEBABE
        let fatMagicSwapped: UInt32 = 0xBEBAFECA
        let macho64: UInt32 = 0xFEEDFACF
        let macho64Swapped: UInt32 = 0xCFFAEDFE
        let macho32: UInt32 = 0xFEEDFACE
        let macho32Swapped: UInt32 = 0xCEFAEDFE

        if magic == fatMagic || magic == fatMagicSwapped {
            let count = data.withUnsafeBytes { ptr -> UInt32 in
                let v = ptr.load(fromByteOffset: 4, as: UInt32.self)
                return magic == fatMagic ? v.byteSwapped : v
            }
            print("⚙️ [IPAResigner] FairPlay: fat binary, \(count) slices")
            for i in 0..<Int(count) {
                let base = 8 + i * 20
                guard base + 8 <= data.count else { break }
                let offset = data.withUnsafeBytes { ptr -> UInt32 in
                    let v = ptr.load(fromByteOffset: base + 8, as: UInt32.self)
                    return v.byteSwapped
                }
                offsets.append(Int(offset))
            }
        } else if magic == macho64 || magic == macho64Swapped || magic == macho32 || magic == macho32Swapped {
            let arch = (magic == macho64 || magic == macho64Swapped) ? "arm64" : "arm32"
            print("⚙️ [IPAResigner] FairPlay: thin binary (\(arch))")
            offsets.append(0)
        } else {
            print("⚙️ [IPAResigner] FairPlay: unknown binary format (magic=0x\(String(magic, radix: 16)))")
            return false
        }

        for offset in offsets {
            if checkEncryptionInMacho(data: data, offset: offset) { return true }
        }
        return false
    }

    private func checkEncryptionInMacho(data: Data, offset: Int) -> Bool {
        guard offset + 16 <= data.count else { return false }
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        let needsSwap = magic == 0xCFFAEDFE || magic == 0xCEFAEDFE
        func u32(at byteOffset: Int) -> UInt32 {
            let v = data.withUnsafeBytes { $0.load(fromByteOffset: byteOffset, as: UInt32.self) }
            return needsSwap ? v.byteSwapped : v
        }
        let ncmds = Int(u32(at: offset + 16))
        let is64 = magic == 0xFEEDFACF || magic == 0xCFFAEDFE
        var cmdOffset = offset + (is64 ? 32 : 28)
        for _ in 0..<ncmds {
            guard cmdOffset + 8 <= data.count else { break }
            let cmd = u32(at: cmdOffset)
            let cmdsize = Int(u32(at: cmdOffset + 4))
            // LC_ENCRYPTION_INFO = 0x21, LC_ENCRYPTION_INFO_64 = 0x2C
            if (cmd == 0x21 || cmd == 0x2C) && cmdOffset + 20 <= data.count {
                let cryptid = u32(at: cmdOffset + 16)
                let cmdName = cmd == 0x2C ? "LC_ENCRYPTION_INFO_64" : "LC_ENCRYPTION_INFO"
                print("⚙️ [IPAResigner] FairPlay: \(cmdName) found — cryptid=\(cryptid)")
                if cryptid == 1 { return true }
            }
            guard cmdsize >= 8 else { break }
            cmdOffset += cmdsize
        }
        return false
    }

    // Expands profile entitlements wildcards and prepares them for signing.
    // Only entitlements authorized by the profile are used; no unauthorized keys are added.
    private func buildSigningEntitlements(from profileEntitlements: [String: Any], bundleID: String, teamID: String) -> [String: Any] {
        func expandWildcard(_ s: String) -> String {
            // "TEAMID.*" → "TEAMID.bundleID"
            s.hasSuffix(".*") ? String(s.dropLast(2)) + "." + bundleID : s
        }

        var result: [String: Any] = [:]

        for (key, value) in profileEntitlements {
            switch key {
            case "application-identifier":
                let raw = value as? String ?? ""
                result[key] = expandWildcard(raw)
            case "keychain-access-groups":
                if let groups = value as? [String] {
                    result[key] = groups.map(expandWildcard)
                }
            case "com.apple.security.application-groups":
                if let groups = value as? [String] {
                    result[key] = groups.map(expandWildcard)
                }
            case "aps-environment":
                // Only include if present in profile; downgrade to development
                result[key] = "development"
            default:
                result[key] = value
            }
        }

        // Minimum required entitlements — fallback if profile is empty
        if result["application-identifier"] == nil {
            result["application-identifier"] = teamID.isEmpty ? bundleID : "\(teamID).\(bundleID)"
        }
        result["com.apple.developer.team-identifier"] = teamID
        result["get-task-allow"] = true

        return result
    }

    private func extractEntitlements(from profileURL: URL) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", profileURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let profile = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let ents = profile["Entitlements"] as? [String: Any] else { return [:] }
        return ents
    }

    private func findAppBundle(in payloadURL: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: payloadURL, includingPropertiesForKeys: nil
        )
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw IPAResignError.appBundleNotFound
        }
        return appURL
    }

    private func removeCodeSignatures(in directory: URL) {
        let fm = FileManager.default
        // Do NOT use skipsPackageDescendants — must recurse into .app/.framework/.appex
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        var toRemove: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "_CodeSignature" {
                toRemove.append(url)
                enumerator.skipDescendants() // no need to enumerate inside _CodeSignature
            }
        }
        for url in toRemove {
            try? fm.removeItem(at: url)
            print("⚙️ [IPAResigner] _CodeSignature removed: \(url.path)")
        }
    }

    // MARK: - Static zip helpers (unzip -Z1 pattern)

    private static func listEntries(ipaPath: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", ipaPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func readEntry(ipaPath: String, entryName: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", ipaPath, entryName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private static func isMainInfoPlist(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
    }

    private static func buildTree(from entries: [String]) -> [IPAFileNode] {
        var dirPaths = Set<String>()
        var allPaths: [String] = []

        for entry in entries {
            if entry.hasSuffix("/") {
                let clean = String(entry.dropLast())
                dirPaths.insert(clean)
                allPaths.append(clean)
            } else {
                allPaths.append(entry)
            }
        }

        var childrenMap: [String: [String]] = ["": []]
        for path in allPaths.sorted() {
            let parts = path.components(separatedBy: "/")
            let parent = parts.dropLast().joined(separator: "/")
            childrenMap[parent, default: []].append(path)
            if dirPaths.contains(path) {
                childrenMap[path] = childrenMap[path] ?? []
            }
        }

        func buildNodes(at parent: String) -> [IPAFileNode] {
            guard let paths = childrenMap[parent] else { return [] }
            return paths.map { path in
                let name = path.components(separatedBy: "/").last ?? path
                let isDir = dirPaths.contains(path)
                return IPAFileNode(
                    id: path, name: name, path: path, isDirectory: isDir,
                    children: isDir ? buildNodes(at: path) : nil
                )
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return buildNodes(at: "")
    }
}
