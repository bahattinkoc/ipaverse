//
//  ExternalToolsView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  "Install it, don't reimplement it": a catalog of external reverse-
//  engineering tools (disassemblers, MITM proxies, Frida's own CLI,
//  libimobiledevice extras) the Reverse Engineer area hands off to, each
//  with a live installed/not-installed status and an Install/Uninstall
//  action backed by Homebrew (or pip for the one Python-only tool).

import SwiftUI

struct ExternalToolsView: View {
    @StateObject private var viewModel = ExternalToolsVM()

    var body: some View {
        Form {
            if !viewModel.homebrewAvailable {
                homebrewMissingBanner
            }
            ForEach(ToolCategory.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ExternalToolManager.catalog.filter { $0.category == category }) { tool in
                        ToolRow(tool: tool, viewModel: viewModel)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.refreshAll() }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var homebrewMissingBanner: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Homebrew not found")
                        .fontWeight(.semibold)
                    Text("Most tools below install via Homebrew. Install it from brew.sh, then reopen this tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("brew.sh") {
                    NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                }
            }
        }
    }
}

// MARK: - ToolRow

private struct ToolRow: View {
    let tool: ExternalTool
    @ObservedObject var viewModel: ExternalToolsVM

    private var status: ToolStatus { viewModel.status(for: tool) }
    private var isBusy: Bool { viewModel.busyToolID == tool.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tool.name)
                            .fontWeight(.medium)
                        statusBadge
                    }
                    Text(tool.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actionButton
            }
            if isBusy, let line = viewModel.lastLogLine[tool.id] {
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundColor(.green)
                .help("Installed")
        case .notInstalled:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch tool.installer {
        case .manualDownload(let url):
            Button("Open Website") { NSWorkspace.shared.open(url) }
                .buttonStyle(.bordered)
                .controlSize(.small)

        default:
            switch status {
            case .installed:
                Button("Remove", role: .destructive) { viewModel.uninstall(tool) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
            case .notInstalled, .unknown:
                Button("Install") { viewModel.install(tool) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
            case .checking:
                Button(isBusy ? "Working…" : "Install") { }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            }
        }
    }
}
