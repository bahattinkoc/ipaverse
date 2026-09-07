//
//  DataDumpView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 7.09.2026.
//
//  Reverse Engineer's dedicated view for the three Data Dump scripts
//  (userdefaults-dump, keychain-dump, sandbox-files) — replaces the generic
//  free-text log (a wall of "[script-name] key = value" lines) with an
//  actual key/value layout, since that's genuinely what all three scripts
//  already produce (`FridaToolkitVM.DumpEntry`/`DumpField`).
//
//  userdefaults-dump reports exactly one field per entry (a real key=value
//  pair), so that case gets a real macOS `Table` — resizable, draggable
//  columns and click-to-sort, not just two aligned `Text` views in a List
//  row (which can't be resized or sorted). keychain-dump/sandbox-files
//  report several named fields per entry (account/service/server/label,
//  or path/size), which doesn't fit a two-column table the same way, so
//  those keep the grouped-list layout, each entry as a small label/value
//  stack. sandbox-files entries also get a Download button (wired to
//  `FridaToolkitVM.downloadSandboxFile`) — the script can read a file's
//  real bytes off the device and hand them back for saving to disk,
//  verified end-to-end (a real local file, including non-ASCII content,
//  round-tripped byte-for-byte) before shipping; only works while the
//  script is still attached, since it's a live request, not something
//  captured up front during the dump.
//
//  A filter field and an Export menu (plain text or full-content JSON,
//  everything parsed so far — not just what's currently visible/filtered)
//  match the pattern already used in Static Analysis's findings list /
//  report export.

import SwiftUI

struct DataDumpView: View {
    @ObservedObject var viewModel: FridaToolkitVM
    @State private var searchText = ""

    private var filteredEntries: [DumpEntry] {
        guard !searchText.isEmpty else { return viewModel.dumpEntries }
        return viewModel.dumpEntries.filter { entry in
            (entry.category?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            entry.fields.contains {
                $0.key.localizedCaseInsensitiveContains(searchText) ||
                $0.value.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    /// True for userdefaults-dump (every entry is exactly one key=value
    /// pair) — false for keychain-dump/sandbox-files (several named fields
    /// per entry). Checked structurally, not by script id, so any future
    /// Data Dump script with the same one-field-per-entry shape gets the
    /// table layout automatically.
    private var isFlatKeyValue: Bool {
        !viewModel.dumpEntries.isEmpty && viewModel.dumpEntries.allSatisfy { $0.fields.count == 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.dumpEntries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No Matches")
            } else if isFlatKeyValue {
                KeyValueTable(entries: filteredEntries, viewModel: viewModel)
            } else {
                groupedList
            }
        }
    }

    private var groupedList: some View {
        List {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if let category = group.category {
                    Section(category) {
                        ForEach(group.entries) { DumpEntryRow(entry: $0, viewModel: viewModel) }
                    }
                } else {
                    ForEach(group.entries) { DumpEntryRow(entry: $0, viewModel: viewModel) }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Groups consecutive entries sharing a category (the scripts already
    /// emit entries in a sensible order — e.g. all Generic Password items
    /// before Internet Password ones — so a simple consecutive-run group
    /// preserves that instead of alphabetizing categories away from it).
    private var groups: [(category: String?, entries: [DumpEntry])] {
        var result: [(category: String?, entries: [DumpEntry])] = []
        for entry in filteredEntries {
            if let last = result.indices.last, result[last].category == entry.category {
                result[last].entries.append(entry)
            } else {
                result.append((entry.category, [entry]))
            }
        }
        return result
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("Filter…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            .frame(maxWidth: 240)

            Spacer()

            Text("\(filteredEntries.count) of \(viewModel.dumpEntries.count)")
                .font(.caption)
                .foregroundColor(.secondary)

            if !viewModel.dumpEntries.isEmpty {
                Menu {
                    Button("Text (.txt)") { viewModel.exportDumpText() }
                    Button("JSON (.json)") { viewModel.exportDumpJSON() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(viewModel.isRunning ? "Waiting for the dump…" : "Pick a process and hit Run.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - KeyValueTable (userdefaults-dump)

private struct KeyValueRow: Identifiable {
    let id: UUID
    let key: String
    let value: String
    let editable: Bool
    let valueType: String
}

private struct KeyValueTable: View {
    let entries: [DumpEntry]
    @ObservedObject var viewModel: FridaToolkitVM
    @State private var sortOrder = [KeyPathComparator(\KeyValueRow.key)]
    /// Writing a value back to the device changes the target app's actual
    /// state (not a passive read), same class of action as Security Testing
    /// Mode/Frida Gadget injection/Move to New Identity/Dump Decrypted Copy
    /// elsewhere in ipaverse — gated the same way, for the same reason.
    @AppStorage("evilModeEnabled") private var isEvilMode = false

    private var rows: [KeyValueRow] {
        let unsorted = entries.compactMap { entry -> KeyValueRow? in
            guard let field = entry.fields.first else { return nil }
            return KeyValueRow(id: entry.id, key: field.key, value: field.value,
                                editable: entry.editable, valueType: entry.valueType ?? "string")
        }
        return unsorted.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Key", value: \.key) { row in
                Text(row.key)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .width(min: 120, ideal: 240)
            TableColumn("Value", value: \.value) { row in
                if row.editable && isEvilMode {
                    EditableValueCell(viewModel: viewModel, key: row.key, valueType: row.valueType, initialValue: row.value)
                } else {
                    Text(row.value)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .help(row.editable ? "Turn on Evil Mode to edit this value on the device." : "")
                }
            }
            .width(min: 160, ideal: 420)
        }
    }
}

private struct EditableValueCell: View {
    @ObservedObject var viewModel: FridaToolkitVM
    let key: String
    let valueType: String

    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(viewModel: FridaToolkitVM, key: String, valueType: String, initialValue: String) {
        self.viewModel = viewModel
        self.key = key
        self.valueType = valueType
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text) { save() }
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .disabled(isSaving)
            if isSaving {
                ProgressView().controlSize(.small)
            } else if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help(errorMessage)
            }
        }
    }

    private func save() {
        errorMessage = nil
        isSaving = true
        viewModel.updateUserDefault(key: key, valueType: valueType, newValue: text) { result in
            isSaving = false
            if case .failure(let error) = result {
                errorMessage = error.errorDescription
            }
        }
    }
}

// MARK: - DumpEntryRow (keychain-dump / sandbox-files)

private struct DumpEntryRow: View {
    let entry: DumpEntry
    @ObservedObject var viewModel: FridaToolkitVM

    @State private var isDownloading = false
    @State private var downloadError: String?

    /// Only sandbox-files entries carry a "path" field — that's the signal
    /// to show a Download button, rather than checking the script id.
    private var pathField: DumpField? {
        entry.fields.first { $0.key == "path" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.fields) { field in
                        HStack(alignment: .top, spacing: 8) {
                            Text(field.key)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Text(field.value)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if let pathField {
                    Spacer(minLength: 8)
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            download(pathField.value)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!viewModel.isRunning)
                        .help(viewModel.isRunning
                              ? "Save this file to your Mac"
                              : "The script isn't running anymore — re-run the dump first.")
                    }
                }
            }
            if let downloadError {
                Text(downloadError)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func download(_ path: String) {
        isDownloading = true
        downloadError = nil
        viewModel.downloadSandboxFile(path: path) { result in
            isDownloading = false
            switch result {
            case .success(let data):
                let panel = NSSavePanel()
                panel.nameFieldStringValue = (path as NSString).lastPathComponent
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                } catch {
                    downloadError = "Couldn't save: \(error.localizedDescription)"
                }
            case .failure(let error):
                downloadError = error.errorDescription
            }
        }
    }
}
