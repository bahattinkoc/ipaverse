//
//  DumpVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//

import SwiftUI

@MainActor
final class DumpVM: ObservableObject {

    enum State {
        case idle
        case dumping(step: String)
        case done(outputPath: String)
        case failed(String)
    }

    @Published var state: State = .idle

    let ipaPath: String
    let appName: String
    let outputPath: String

    init(downloadedApp: DownloadedApp) {
        self.ipaPath = downloadedApp.filePath
        self.appName = downloadedApp.name
        let original = URL(fileURLWithPath: downloadedApp.filePath)
        let stem = original.deletingPathExtension().lastPathComponent
        self.outputPath = original.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_decrypted.ipa").path
    }

    var isDumping: Bool {
        if case .dumping = state { return true }
        return false
    }

    var dumpStep: String? {
        if case .dumping(let step) = state { return step }
        return nil
    }

    var outputFilePath: String? {
        if case .done(let path) = state { return path }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let msg) = state { return msg }
        return nil
    }

    func run() {
        guard !isDumping else { return }
        state = .dumping(step: "Starting…")
        let path = ipaPath
        let name = appName
        let output = outputPath

        Task {
            do {
                try await Self.dump(ipaPath: path, appName: name, outputPath: output) { [weak self] step in
                    self?.state = .dumping(step: step)
                }
                state = .done(outputPath: output)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs the synchronous, network-bound dump off the main thread, leaving
    /// result/error handling on the MainActor here in the VM.
    private static func dump(
        ipaPath: String,
        appName: String,
        outputPath: String,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FridaDumper.dumpDecrypted(ipaPath: ipaPath, appName: appName, outputPath: outputPath) { step in
                Task { @MainActor in onProgress(step) }
            }
        }.value
    }
}
