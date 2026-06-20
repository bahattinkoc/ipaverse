//
//  SecurityScanVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class SecurityScanVM: ObservableObject {

    enum State {
        case idle
        case scanning(step: String)
        case done(SecurityScanResult)
        case failed(String)
    }

    @Published var state: State = .idle

    let ipaPath: String
    let appName: String

    init(ipaPath: String, appName: String) {
        self.ipaPath = ipaPath
        self.appName = appName
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    var scanStep: String? {
        if case .scanning(let step) = state { return step }
        return nil
    }

    var result: SecurityScanResult? {
        if case .done(let r) = state { return r }
        return nil
    }

    // MARK: - Scan

    func run() {
        guard !isScanning else { return }
        state = .scanning(step: "Starting…")
        let path = ipaPath
        let name = appName

        Task {
            do {
                let result = try await Self.scan(ipaPath: path, appName: name) { [weak self] step in
                    self?.state = .scanning(step: step)
                }
                state = .done(result)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs the synchronous scan off the main thread. Static so it captures no
    /// `self`, leaving the result/error handling on the MainActor in `run()`.
    private static func scan(
        ipaPath: String,
        appName: String,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> SecurityScanResult {
        try await Task.detached(priority: .userInitiated) {
            try IPASecurityScanner.scan(ipaPath: ipaPath, appName: appName) { step in
                Task { @MainActor in onProgress(step) }
            }
        }.value
    }

    // MARK: - Export

    func exportMarkdown() {
        guard let result = result else { return }
        save(data: Data(result.markdownReport().utf8),
             suggestedName: "\(safeName)-security-report.md",
             contentType: UTType(filenameExtension: "md") ?? .plainText)
    }

    func exportJSON() {
        guard let result = result, let data = try? result.jsonReport() else { return }
        save(data: data,
             suggestedName: "\(safeName)-security-report.json",
             contentType: .json)
    }

    private var safeName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = appName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).isEmpty ? "app" : String(cleaned)
    }

    private func save(data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
