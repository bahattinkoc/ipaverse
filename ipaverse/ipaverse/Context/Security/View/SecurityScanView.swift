//
//  SecurityScanView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//

import SwiftUI

/// The static-analysis engine's UI — embedded as the "Static Analysis" tab
/// of `ReverseEngineerView` (which supplies the window chrome/identity), so
/// this has no header/dismiss of its own beyond a slim Re-scan control.
struct SecurityScanView: View {
    private enum ViewMode: Hashable {
        case findings
        case search
    }

    /// Owned by `ReverseEngineerView` (not this view) so switching to another
    /// tab and back doesn't tear it down and lose the scan result.
    @ObservedObject var viewModel: SecurityScanVM
    @State private var revealSecrets = false
    @State private var searchText = ""
    @State private var categoryFilter: String?
    @State private var viewMode: ViewMode = .findings

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let result = viewModel.result, result.hasPartiallyEncryptedBinaries {
                encryptedBanner(result)
                Divider()
            }
            content
            Divider()
            footer
        }
        .onAppear { viewModel.runIfNeeded() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if case .done(let result) = viewModel.state {
                Picker("", selection: $viewMode) {
                    Text("Findings (\(result.findings.count))").tag(ViewMode.findings)
                    Text("Search Binary").tag(ViewMode.search)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if case .done = viewModel.state {
                Button {
                    viewModel.run()
                } label: {
                    Label("Re-scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Encrypted-binary banner

    private func encryptedBanner(_ result: SecurityScanResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundColor(.orange)
            Text("\(result.encryptedBinaries.count) of \(result.totalBinariesScanned) binaries are still FairPlay-encrypted — those results are incomplete. Dump a decrypted copy to cover them too (see \"Binary\" findings for which ones).")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
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
            switch viewMode {
            case .findings:
                if result.findings.isEmpty {
                    cleanView
                } else {
                    findingsList(result)
                }
            case .search:
                searchView(result)
            }
        }
    }

    // MARK: - Manual search

    private func searchView(_ result: SecurityScanResult) -> some View {
        VStack(spacing: 0) {
            searchBar(result)
            Divider()
            searchResults(result)
        }
    }

    private func searchBar(_ result: SecurityScanResult) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search extracted strings across the whole app…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                if viewModel.isSearching {
                    ProgressView().controlSize(.small)
                } else if !viewModel.searchQuery.isEmpty {
                    Button { viewModel.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))

            Text("\(result.searchCorpus.count) files/binaries indexed")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func searchResults(_ result: SecurityScanResult) -> some View {
        let query = viewModel.searchQuery.trimmingCharacters(in: .whitespaces)
        if query.count < 2 {
            VStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("Search for a token, key name, hostname, or anything else you're hunting for")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Searches every extracted file and Mach-O binary's strings — not just the findings above")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.searchHits.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text(viewModel.isSearching ? "Searching…" : "No matches for \"\(query)\"")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(viewModel.searchHits) { hit in
                SearchHitRow(hit: hit, query: query)
            }
            .listStyle(.inset)
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
            Button("Retry") { viewModel.run() }
                .buttonStyle(.bordered)
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

    // MARK: - Findings list + filtering

    private func filteredFindings(_ result: SecurityScanResult) -> [SecurityFinding] {
        result.sortedFindings.filter { f in
            (categoryFilter == nil || f.category == categoryFilter) &&
            (searchText.isEmpty ||
             f.title.localizedCaseInsensitiveContains(searchText) ||
             f.detail.localizedCaseInsensitiveContains(searchText) ||
             (f.location ?? "").localizedCaseInsensitiveContains(searchText) ||
             (f.snippet ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    private func availableCategories(_ result: SecurityScanResult) -> [String] {
        Array(Set(result.findings.map(\.category))).sorted()
    }

    private func findingsList(_ result: SecurityScanResult) -> some View {
        VStack(spacing: 0) {
            severitySummary(result)
            Divider()
            filterBar(result)
            Divider()
            let visible = filteredFindings(result)
            if visible.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No findings match your filter")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(FindingSeverity.allCases.reversed(), id: \.self) { severity in
                        let items = visible.filter { $0.severity == severity }
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

    private func filterBar(_ result: SecurityScanResult) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Filter findings…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            .frame(maxWidth: 280)

            Picker("", selection: $categoryFilter) {
                Text("All Categories").tag(String?.none)
                ForEach(availableCategories(result), id: \.self) { cat in
                    Text("\(cat) (\(result.findings.filter { $0.category == cat }.count))").tag(String?.some(cat))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Spacer()
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
                        .background(Capsule().fill(categoryColor(finding.category).opacity(0.15)))
                        .foregroundColor(categoryColor(finding.category))
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

// MARK: - SearchHitRow

private struct SearchHitRow: View {
    let hit: ManualSearchHit
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.location)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(NSColor.separatorColor)))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("\(hit.location): \(hit.snippet)", forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy match")
        }
        .padding(.vertical, 3)
    }

    /// Bolds the matched substring within the snippet so a hit is scannable
    /// without reading every character of surrounding context.
    private var highlighted: AttributedString {
        var attributed = AttributedString(hit.snippet)
        if let range = attributed.range(of: query, options: .caseInsensitive) {
            attributed[range].font = .system(.caption, design: .monospaced).bold()
            attributed[range].foregroundColor = .accentColor
        }
        return attributed
    }
}

// MARK: - Severity / category presentation

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

/// Distinct accent per finding category so a growing findings list (secrets,
/// network, anti-analysis, pinning, crypto, biometric, attestation, ...)
/// stays visually scannable at a glance.
private func categoryColor(_ category: String) -> Color {
    switch category {
    case "Anti-Analysis": return .red
    case "Pinning":        return .purple
    case "Crypto":         return .teal
    case "Biometric":      return .indigo
    case "Attestation":    return .brown
    case "Binary":         return .orange
    case "Network":        return .blue
    case "Secret":         return .pink
    case "Provisioning":   return .cyan
    case "Info.plist":     return .mint
    default:                return .secondary
    }
}
