//
//  SecurityScanView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//

import SwiftUI

struct SecurityScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SecurityScanVM
    @State private var revealSecrets = false

    init(ipaPath: String, appName: String) {
        self._viewModel = StateObject(wrappedValue: SecurityScanVM(ipaPath: ipaPath, appName: appName))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 640)
        .onAppear { viewModel.run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Security Scan")
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
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .scanning:
            scanningView
        case .failed(let message):
            errorView(message: message)
        case .done(let result):
            if result.findings.isEmpty {
                cleanView
            } else {
                findingsList(result)
            }
        }
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(viewModel.scanStep ?? "Scanning…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Scan Failed")
                .font(.title3).fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cleanView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("No issues found")
                .font(.title3).fontWeight(.semibold)
            Text("The scan did not surface any security-sensitive content.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func findingsList(_ result: SecurityScanResult) -> some View {
        VStack(spacing: 0) {
            severitySummary(result)
            Divider()
            List {
                ForEach(FindingSeverity.allCases.reversed(), id: \.self) { severity in
                    let items = result.sortedFindings.filter { $0.severity == severity }
                    if !items.isEmpty {
                        Section(header: sectionHeader(severity, count: items.count)) {
                            ForEach(items) { FindingRow(finding: $0, reveal: revealSecrets) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func severitySummary(_ result: SecurityScanResult) -> some View {
        HStack(spacing: 10) {
            ForEach(FindingSeverity.allCases.reversed(), id: \.self) { severity in
                let n = result.count(of: severity)
                if n > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(severity.color).frame(width: 8, height: 8)
                        Text("\(n) \(severity.label)")
                            .font(.caption).fontWeight(.medium)
                    }
                }
            }
            Spacer()
            Text("\(result.scannedFileCount) files scanned")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ severity: FindingSeverity, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: severity.iconName)
                .foregroundColor(severity.color)
            Text("\(severity.label) (\(count))")
                .font(.subheadline).fontWeight(.semibold)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .done = viewModel.state {
                Toggle("Reveal values", isOn: $revealSecrets)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Show unredacted secret values for analysis")
            }
            Spacer()

            if viewModel.result != nil {
                Menu {
                    Button("Markdown (.md)") { viewModel.exportMarkdown() }
                    Button("JSON (.json)") { viewModel.exportJSON() }
                } label: {
                    Label("Export Report", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

// MARK: - FindingRow

private struct FindingRow: View {
    let finding: SecurityFinding
    let reveal: Bool

    /// Show the raw value when the analyst asks to reveal and one exists,
    /// otherwise the redacted snippet.
    private var displaySnippet: String? {
        if reveal, let raw = finding.rawValue { return raw }
        return finding.snippet
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity.iconName)
                .foregroundColor(finding.severity.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.callout).fontWeight(.medium)
                    Text(finding.category)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(NSColor.quaternaryLabelColor).opacity(0.5)))
                        .foregroundColor(.secondary)
                }
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let location = finding.location {
                    Text("Location: \(location)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let snippet = displaySnippet {
                    Text(snippet)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(NSColor.textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(NSColor.separatorColor)))
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(copyText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy finding")
        }
        .padding(.vertical, 3)
    }

    private var copyText: String {
        var parts = ["[\(finding.severity.label)] \(finding.title) (\(finding.category))"]
        if !finding.detail.isEmpty { parts.append(finding.detail) }
        if let l = finding.location { parts.append("Location: \(l)") }
        if let s = displaySnippet { parts.append("Match: \(s)") }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Severity presentation

extension FindingSeverity {
    var color: Color {
        switch self {
        case .critical: return .red
        case .high:     return .orange
        case .medium:   return .yellow
        case .low:      return .blue
        case .info:     return .secondary
        }
    }

    var iconName: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .high:     return "exclamationmark.triangle.fill"
        case .medium:   return "exclamationmark.circle.fill"
        case .low:      return "info.circle.fill"
        case .info:     return "info.circle"
        }
    }
}
