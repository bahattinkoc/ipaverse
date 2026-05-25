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
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): return true
            case (.signing(let a), .signing(let b)): return a == b
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
    @Published var provisioningProfileURL: URL?
    @Published var state: State = .idle
    @Published var activeTab: Tab = .properties
    @Published var isAddingKey = false
    @Published var newKeyName = ""
    @Published var newKeyValue = ""

    let downloadedApp: DownloadedApp

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

    var errorMessage: String? {
        if case .error(let msg) = state { return msg }
        return nil
    }

    // MARK: - Load

    func load() async {
        state = .loading
        let ipaPath = downloadedApp.filePath

        let (certs, entries, tree) = await Task.detached {
            let certs = (try? IPAResigner.listCertificates()) ?? []
            let rawPlist = (try? IPAResigner.loadInfoPlist(ipaPath: ipaPath)) ?? [:]
            let entries = PlistEntry.entries(from: rawPlist)
            let tree = (try? IPAResigner.buildFileTree(ipaPath: ipaPath)) ?? []
            return (certs, entries, tree)
        }.value

        certificates = certs
        selectedCertificate = certificates.first(where: { $0.isDevelopment }) ?? certificates.first
        plistEntries = entries
        fileTree = tree
        state = .idle
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

    private func performSign(certificate: ResignerCertificate, outputPath: String) {
        let config = ResignConfig(
            certificate: certificate,
            plistEdits: Dictionary(uniqueKeysWithValues: plistEntries
                .filter { $0.isEditable }
                .map { ($0.key, $0.toAny()) }
            ),
            fileReplacements: fileReplacements,
            provisioningProfileURL: provisioningProfileURL
        )
        let ipaPath = downloadedApp.filePath

        Task.detached { [self] in
            do {
                try IPAResigner().sign(ipaPath: ipaPath, config: config, outputPath: outputPath) { message in
                    Task { @MainActor [self] in self.state = .signing(message: message) }
                }
                await MainActor.run { self.state = .idle }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
    }
}

import UniformTypeIdentifiers
