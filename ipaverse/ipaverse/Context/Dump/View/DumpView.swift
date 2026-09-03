//
//  DumpView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//

import SwiftUI
import SwiftData

struct DumpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: DumpVM

    /// Called after the decrypted copy has been imported into Downloaded.
    var onImported: (() -> Void)?

    init(downloadedApp: DownloadedApp, onImported: (() -> Void)? = nil) {
        self._viewModel = StateObject(wrappedValue: DumpVM(downloadedApp: downloadedApp))
        self.onImported = onImported
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 480, height: 420)
        .onAppear { viewModel.run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .foregroundColor(.accentColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dump Decrypted Copy")
                    .font(.headline)
                Text(viewModel.appName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .dumping:
            VStack(spacing: 12) {
                ProgressView()
                Text(viewModel.dumpStep ?? "Starting…")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Make sure \"\(viewModel.appName)\" is open and in use on the jailbroken device connected over USB — FairPlay only decrypts code as it actually runs, so a freshly-launched app may not dump completely. This also applies per-framework: if a bundled SDK loads lazily (e.g. only once push notifications are used), trigger that feature too before dumping, or the dump will fail for that framework.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.largeTitle)
                Text("Dump Failed")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .done:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.largeTitle)
                Text("Decrypted Copy Ready")
                    .font(.headline)
                Text("This app's entry in Downloaded now points to the decrypted copy — re-signing it won't show the FairPlay warning anymore.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if case .failed = viewModel.state {
                Button("Retry") { viewModel.run() }
                    .buttonStyle(.bordered)
            }
            Button(viewModel.outputFilePath == nil ? "Cancel" : "Done") {
                if let path = viewModel.outputFilePath {
                    let imported = try? IPAImporter.importIPA(at: URL(fileURLWithPath: path), into: modelContext)
                    imported?.sourceTag = "Decrypted"
                    try? modelContext.save()
                    onImported?()
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isDumping)
        }
        .padding()
    }
}
