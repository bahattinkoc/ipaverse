import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IPAComparisonVM: ObservableObject {
    @Published var report: IPAComparisonReport?
    @Published var message = "Preparing comparison…"
    @Published var error: String?
    @Published var isRunning = false
    private var work: Task<Void, Never>?
    private var generation = UUID()

    func run(_ input: ComparisonInput, deep: Bool = false) {
        cancel()
        let generation = UUID()
        self.generation = generation
        error = nil
        isRunning = true
        message = deep ? "Preparing deep analysis…" : "Preparing comparison…"
        work = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var lastProgress = Date.distantPast
                let report = try IPAComparison.compare(left: URL(fileURLWithPath: input.left), right: URL(fileURLWithPath: input.right), deep: deep) { [weak self] text in
                    guard Date().timeIntervalSince(lastProgress) >= 0.25 else { return }
                    lastProgress = Date()
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.message = text
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.report = report
                    self.isRunning = false
                }
            } catch {
                let cancelled = error is CancellationError
                let description = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.isRunning = false
                    if !cancelled { self.error = description }
                }
            }
        }
    }
    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        isRunning = false
    }
    func swap() {
        guard let r = report else { return }
        report = IPAComparisonReport(rulesVersion: r.rulesVersion, leftName: r.rightName, rightName: r.leftName,
            left: r.right, right: r.left, rows: r.rows.map { row in
                IPAComparisonChange(category: row.category, source: row.source, path: row.path,
                    kind: row.kind == "Added" ? "Removed" : row.kind == "Removed" ? "Added" : row.kind,
                    before: row.after, after: row.before,
                    valueType: row.valueType.components(separatedBy: " → ").reversed().joined(separator: " → "),
                    signingArtifact: row.signingArtifact, uuid: row.uuid)
            }, leftCoverage: r.rightCoverage, rightCoverage: r.leftCoverage, deepAnalysis: r.deepAnalysis, notes: r.notes,
            previews: r.previews.map { IPAComparisonPreview(source: $0.source, before: $0.after, after: $0.before) },
            assets: r.assets.map(\.swapped), fileSizes: r.fileSizes.map(\.swapped))
    }
    func export(rows: [IPAComparisonChange]? = nil, fileSizes: [IPAComparisonFileSize]? = nil) {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = rows == nil ? "ipa-comparison.json" : "ipa-comparison-filtered.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data: Data
                if let rows {
                    let sources = Set(rows.map(\.source)), rowIDs = Set(rows.map(\.id))
                    let filtered = IPAComparisonReport(rulesVersion: report.rulesVersion, leftName: report.leftName, rightName: report.rightName,
                        left: report.left, right: report.right, rows: rows, leftCoverage: report.leftCoverage, rightCoverage: report.rightCoverage,
                        deepAnalysis: report.deepAnalysis, notes: report.notes + [fileSizes == nil
                            ? "Filtered export: visible rows and their linked file content, using the active change/signing/UUID filters."
                            : "Size impact export: file rows and extracted byte records contributing to the visible groups or files, using the active size filters."],
                        previews: report.previews.filter { sources.contains($0.source) },
                        assets: report.assets.filter { rowIDs.contains($0.rowID) },
                        fileSizes: fileSizes ?? report.fileSizes.filter { sources.contains($0.source) })
                    data = try encoder.encode(filtered)
                } else { data = try encoder.encode(report) }
                try data.write(to: url, options: .atomic)
            } catch { self?.error = error.localizedDescription }
        }
    }
}

struct IPAComparisonView: View {
    let input: ComparisonInput
    @StateObject private var model = IPAComparisonVM()
    @State private var category: String? = "Files"
    @State private var query = ""
    @State private var sourceFilter = ""
    @State private var changedOnly = true
    @State private var ignoreSigning = false
    @State private var ignoreUUID = false
    @State private var selection: String?
    @State private var reversed = false
    @State private var detailMode = "Values"
    @State private var showAllCoverage = false
    @State private var filteredRows: [IPAComparisonChange] = []
    @State private var visibleRows: [IPAComparisonChange] = []
    @State private var categoryCounts: [String: Int] = [:]
    @State private var fileTree: [ComparisonFileNode] = []
    @State private var contentIndex: [String: [IPAComparisonChange]] = [:]
    @State private var sizeGrouping = "Components"
    @State private var sizeDirection = "All"
    @State private var sizeComponent: String?
    @State private var sizeFiles: [IPAComparisonFileSize] = []

    private var currentInput: ComparisonInput {
        reversed ? ComparisonInput(left: input.right, right: input.left, leftSource: input.rightSource, rightSource: input.leftSource) : input
    }
    private var filtered: [IPAComparisonChange] { filteredRows }
    private var visible: [IPAComparisonChange] { visibleRows }
    private var selectedRow: IPAComparisonChange? {
        guard let selection else { return nil }
        return visibleRows.first { $0.id == selection }
    }
    private func refreshRows(_ report: IPAComparisonReport?) {
        sizeFiles = (report?.fileSizes ?? []).filter { file in
            (!ignoreSigning || !file.signingArtifact) &&
            (sourceFilter.isEmpty || file.source == sourceFilter || file.source.hasPrefix(sourceFilter + "/")) &&
            (query.isEmpty || file.source.localizedCaseInsensitiveContains(query))
        }
        filteredRows = (report?.rows ?? []).filter { row in
            (!changedOnly || row.kind != "Unchanged") && (!ignoreSigning || !row.signingArtifact) && (!ignoreUUID || !row.uuid) &&
            (sourceFilter.isEmpty || row.source == sourceFilter || row.source.hasPrefix(sourceFilter + "/") || row.source.hasPrefix(sourceFilter + " [")) &&
            matchesSearch(row)
        }
        updateVisibleRows()
        categoryCounts = Dictionary(grouping: filteredRows.filter { $0.kind != "Unchanged" && $0.kind != "Not compared" }, by: \.category).mapValues(\.count)
    }

    private func matchesSearch(_ row: IPAComparisonChange) -> Bool {
        guard !query.isEmpty else { return true }
        func matches(_ item: IPAComparisonChange) -> Bool {
            (item.source + " " + item.path + " " + (item.before ?? "") + " " + (item.after ?? "")).localizedCaseInsensitiveContains(query)
        }
        return matches(row) || (row.category == "Files" && (contentIndex[row.source] ?? []).contains(where: matches))
    }

    private func visibleSizeFiles() -> [IPAComparisonFileSize] {
        func matches(_ delta: Int64) -> Bool {
            sizeDirection == "All" || (sizeDirection == "Growth" ? delta > 0 : delta < 0)
        }
        if sizeGrouping == "Components" {
            return IPAComparisonSizeGroup.groups(sizeFiles)
                .filter { matches($0.delta) && (!changedOnly || $0.changedCount > 0) }.flatMap(\.files)
        }
        return sizeFiles.filter {
            (sizeComponent == nil || $0.component == sizeComponent) && matches($0.delta) && (!changedOnly || $0.kind != "Unchanged")
        }
    }

    private func updateVisibleRows() {
        visibleRows = filteredRows.filter { category == "All" || $0.category == category }.sorted {
            if category == "Files" {
                if ($0.source == "Info.plist") != ($1.source == "Info.plist") { return $0.source == "Info.plist" }
                return $0.source < $1.source
            }
            let a = IPAComparisonPresentation.rank($0), b = IPAComparisonPresentation.rank($1)
            return a == b ? $0.id < $1.id : a < b
        }
        if selection == nil || !visibleRows.contains(where: { $0.id == selection }) { selection = visibleRows.first?.id }
    }

    private func fileContent(_ row: IPAComparisonChange) -> [IPAComparisonChange] {
        (contentIndex[row.source] ?? []).filter {
            (!changedOnly || $0.kind != "Unchanged") && (!ignoreSigning || !$0.signingArtifact) && (!ignoreUUID || !$0.uuid)
        }
    }

    private func tableValue(_ row: IPAComparisonChange, before: Bool) -> String {
        if row.category == "Files", row.path == "Content" {
            if let preview = model.report?.previews.first(where: { $0.source == row.source }) {
                if (before ? row.before : row.after) == nil { return "—" }
                return (before ? preview.before : preview.after) == nil ? "Image · preview unavailable" : "Image · preview below"
            }
            let content = (contentIndex[row.source] ?? []).filter { (!ignoreSigning || !$0.signingArtifact) && (!ignoreUUID || !$0.uuid) }
            return IPAComparisonPresentation.fileValue(row, content: content, before: before)
        }
        if row.valueType == "text" {
            return ComparisonTextDiff.preview(before: row.before, after: row.after, beforeSide: before)
        }
        return (before ? row.before : row.after).map { $0.isEmpty ? "\"\"" : $0 } ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = model.report {
                HSplitView {
                    sidebar(report)
                        .frame(minWidth: 170, idealWidth: 195, maxWidth: 260)
                    VStack(spacing: 0) {
                        filters
                        Divider()
                        if category == "Overview" { overview(report) }
                        else if category == "Size impact" {
                            IPAComparisonSizeView(report: report, files: sizeFiles, changedOnly: changedOnly,
                                openFile: { source in
                                    let file = model.report?.rows.first { $0.category == "Files" && $0.source == source && $0.path == "Content" }
                                    query = ""; sourceFilter = source; category = "Files"
                                    // Same-size files can still be opened from the unfiltered size inventory.
                                    if file?.kind == "Unchanged" { changedOnly = false }
                                    refreshRows(model.report)
                                    selection = file?.id
                                }, grouping: $sizeGrouping, direction: $sizeDirection, component: $sizeComponent)
                        } else {
                            VSplitView {
                                resultsTable
                                    .frame(minHeight: 180)
                                detail
                                    .frame(minHeight: 240, idealHeight: 360)
                            }
                        }
                    }.frame(minWidth: 650)
                }
            } else {
                Spacer()
                if model.isRunning { ProgressView(model.message) }
                else if model.error == nil {
                    Text("Comparison cancelled").foregroundStyle(.secondary)
                    Button("Run Comparison") { model.run(currentInput) }
                }
                Spacer()
            }
            if model.isRunning {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.message).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }.padding(10)
            }
            if let error = model.error {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { model.run(currentInput, deep: model.report?.deepAnalysis ?? false) }.disabled(model.isRunning)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .task(id: input) { model.run(input) }
        .onDisappear { model.cancel() }
        .onReceive(model.$report) { report in
            contentIndex = report.map(IPAComparisonPresentation.contentIndex) ?? [:]
            refreshRows(report)
            fileTree = ComparisonFileNode.tree((report?.rows ?? []).filter { $0.category == "Files" }.map(\.source))
        }
        .onChange(of: category) { _, _ in
            selection = nil
            updateVisibleRows()
        }
        .onChange(of: query) { _, _ in refreshRows(model.report) }
        .onChange(of: sourceFilter) { _, _ in refreshRows(model.report) }
        .onChange(of: changedOnly) { _, _ in refreshRows(model.report) }
        .onChange(of: ignoreSigning) { _, _ in refreshRows(model.report) }
        .onChange(of: ignoreUUID) { _, _ in refreshRows(model.report) }
        .onChange(of: selection) { _, _ in detailMode = selectedRow?.valueType == "text" ? "Diff" : "Values" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.report?.left.name ?? "Compare IPA Copies").font(.title2.bold())
                    if let report = model.report { Text(report.left.bundleID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer()
                Button(model.report?.deepAnalysis == true ? "Rerun Deep Analysis" : "Run Deep Analysis") {
                    model.run(currentInput, deep: true)
                }.disabled(model.isRunning || model.report == nil)
                Menu {
                    Button("Full Report (JSON)") { model.export() }
                    Button("Visible Rows (JSON)") {
                        if category == "Size impact", let report = model.report {
                            let files = visibleSizeFiles()
                            let sources = Set(files.map(\.source))
                            model.export(rows: report.rows.filter { $0.category == "Files" && sources.contains($0.source) }, fileSizes: files)
                            return
                        }
                        let rows = IPAComparisonPresentation.includingFileContent(category == "Overview" ? filtered : visible, index: contentIndex)
                            .filter { (!changedOnly || $0.kind != "Unchanged") && (!ignoreSigning || !$0.signingArtifact) && (!ignoreUUID || !$0.uuid) }
                        model.export(rows: rows)
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(model.report == nil)
            }
            HStack(spacing: 14) {
                identityCard("A", identity: model.report?.left, file: model.report?.leftName ?? URL(fileURLWithPath: currentInput.left).lastPathComponent)
                Button {
                    reversed.toggle()
                    model.swap()
                } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap A and B").disabled(model.isRunning || model.report == nil)
                identityCard("B", identity: model.report?.right, file: model.report?.rightName ?? URL(fileURLWithPath: currentInput.right).lastPathComponent)
            }
        }.padding(16)
    }

    private func identityCard(_ side: String, identity: IPAComparisonIdentity?, file: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(side).font(.headline).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(identity.map { "\($0.version) (\($0.build))" } ?? "—").font(.headline)
                    if let source = side == "A" ? currentInput.leftSource : currentInput.rightSource {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(file).font(.caption).lineLimit(1).truncationMode(.middle).help(file).textSelection(.enabled)
                if let identity {
                    Text("IPA \(bytes(identity.archiveBytes)) · Extracted \(bytes(identity.extractedBytes))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sidebar(_ report: IPAComparisonReport) -> some View {
        return List(selection: $category) {
            Text("Overview").tag("Overview")
            Label("Size impact", systemImage: "chart.bar.xaxis").tag("Size impact")
            Text("All").tag("All")
            Section("Categories") {
                ForEach(IPAComparison.categories, id: \.self) { item in
                    HStack {
                        Text(item)
                        Spacer()
                        Text(IPAComparison.deepCategories.contains(item) && !report.deepAnalysis ? "—" : String(categoryCounts[item, default: 0]))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.tag(item)
                }
            }
            if category == "Files" {
                Section("File tree") {
                    OutlineGroup(fileTree, children: \.children) { node in
                        Button { sourceFilter = node.id } label: {
                            Label(node.name, systemImage: node.children == nil ? "doc" : "folder")
                                .lineLimit(1).font(.caption)
                        }.buttonStyle(.plain).help(node.id)
                    }
                }
            }
        }.listStyle(.sidebar)
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(category == "Size impact" ? "Search file paths" : "Search keys, paths and values", text: $query)
                Toggle("Changed only", isOn: $changedOnly).toggleStyle(.checkbox)
                Menu {
                    Toggle("Ignore signing artifacts", isOn: $ignoreSigning)
                    Toggle("Ignore Mach-O UUID", isOn: $ignoreUUID).disabled(category == "Size impact")
                } label: { Label("Filters", systemImage: ignoreSigning || ignoreUUID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                .fixedSize()
            }
            if !sourceFilter.isEmpty {
                HStack {
                    Text("Source: " + sourceFilter).font(.caption).lineLimit(1)
                    Button("Clear") { sourceFilter = "" }.font(.caption)
                    Spacer()
                }
            }
        }.padding(10)
    }

    private var resultsTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text(category ?? "All").font(.headline)
                Text("\(visible.count) rows").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(10)
            Table(visible, selection: $selection) {
                TableColumn("Status") { row in
                    Text(row.kind).font(.caption).foregroundStyle(statusColor(row.kind))
                }.width(min: 75, ideal: 92, max: 110)
                TableColumn("Key / Path") { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.category == "Files" ? row.source : row.valueType == "string literal" ? (row.after ?? row.before ?? row.path) : row.path).lineLimit(2)
                        if row.category == "Files" {
                            Text("\(fileContent(row).count) content rows").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(row.source).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.font(.system(.caption, design: .monospaced)).help(row.source + "\n" + row.path)
                }.width(min: 180, ideal: 300)
                TableColumn("A · Before") { row in Text(tableValue(row, before: true)).font(.system(.caption, design: .monospaced)).lineLimit(3) }.width(min: 100, ideal: 220)
                TableColumn("B · After") { row in Text(tableValue(row, before: false)).font(.system(.caption, design: .monospaced)).lineLimit(3) }.width(min: 100, ideal: 220)
            }
            .overlay {
                if visible.isEmpty {
                    VStack(spacing: 6) {
                        Text("No matching rows").font(.headline)
                        if let report = model.report, IPAComparison.deepCategories.contains(category ?? ""), !report.deepAnalysis {
                            Button("Run Deep Analysis") { model.run(currentInput, deep: true) }.disabled(model.isRunning)
                        }
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = selectedRow {
            if row.category == "Asset catalogs", let asset = model.report?.assets.first(where: { $0.rowID == row.id }) {
                ScrollView { IPAComparisonAssetCard(asset: asset).padding(14) }
            } else if row.category == "Files", row.path == "Content", let report = model.report {
                IPAComparisonFileDetail(file: row, rows: fileContent(row),
                    allContentCount: contentIndex[row.source]?.count ?? 0,
                    hasContentChanges: (contentIndex[row.source] ?? []).contains { $0.kind != "Unchanged" },
                    leftCoverage: report.leftCoverage.filter { $0.source == row.source || $0.source.hasPrefix(row.source + " [") },
                    rightCoverage: report.rightCoverage.filter { $0.source == row.source || $0.source.hasPrefix(row.source + " [") },
                    preview: report.previews.first { $0.source == row.source },
                    assets: report.assets.filter { $0.source == row.source && (!changedOnly || $0.kind != "Unchanged") })
                    .id(row.source)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(row.category + " · " + row.valueType).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Filter Source") { sourceFilter = componentSource(row) }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(row.source)\n\(row.path)\nA: \(row.before ?? "—")\nB: \(row.after ?? "—")", forType: .string)
                    }
                    Picker("Detail", selection: $detailMode) {
                        Text("A / B").tag("Values")
                        Text("Line Diff").tag("Diff")
                    }.pickerStyle(.segmented).frame(width: 160)
                }
                Text(row.source + " · " + row.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                if detailMode == "Diff" {
                    ScrollView([.horizontal, .vertical]) { ComparisonInlineDiff(before: row.before, after: row.after) }
                } else {
                    HSplitView {
                        valuePane("A", row.before)
                        valuePane("B", row.after)
                    }
                }
            }.padding(12)
            }
        } else { Text("Select a row").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private func valuePane(_ name: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.bold())
            ScrollView([.horizontal, .vertical]) {
                Text(value.map { $0.isEmpty ? "\"\"" : $0 } ?? "—").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func overview(_ report: IPAComparisonReport) -> some View {
        let changes = filtered.filter { $0.kind != "Unchanged" && $0.kind != "Not compared" }
        let files = Set(changes.filter { $0.category == "Files" }.map(\.source)).count
        let coverage = ComparisonCoverageRow.rows(report, summarize: !showAllCoverage)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    metric("Changed files", String(files))
                    metric("Structural rows", String(changes.filter { $0.category != "Files" }.count))
                    metric("IPA Δ", signedBytes(report.right.archiveBytes - report.left.archiveBytes))
                    metric("Extracted Δ", signedBytes(report.right.extractedBytes - report.left.extractedBytes))
                }
                HStack {
                    Text(report.deepAnalysis ? "Base + Deep Analysis" : "Base Analysis").font(.headline)
                    Spacer()
                    Toggle("Show all sources", isOn: $showAllCoverage).toggleStyle(.checkbox).font(.caption)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow { Text("Category / Source").bold(); Text("A").bold(); Text("B").bold() }
                    ForEach(coverage) { row in
                        GridRow {
                            VStack(alignment: .leading) {
                                Text(row.category).font(.caption.bold())
                                Text(row.source).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            coverageCell(row.left)
                            coverageCell(row.right)
                        }
                        Divider()
                    }
                }
                ForEach(report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func coverageCell(_ coverage: IPAComparisonCoverage?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(coverage?.state ?? "Absent").foregroundStyle(coverage?.state.hasPrefix("Complete") == true ? Color.secondary : Color.orange)
            if let detail = coverage?.detail, !detail.isEmpty { Text(detail).foregroundStyle(.secondary).lineLimit(3).help(detail) }
        }.font(.caption).textSelection(.enabled)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.title2.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func componentSource(_ row: IPAComparisonChange) -> String {
        if row.category == "Components" {
            let directory = (row.source as NSString).deletingLastPathComponent
            return directory == "." ? "" : directory
        }
        return row.source
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func signedBytes(_ count: Int64) -> String { (count > 0 ? "+" : "") + bytes(count) }
    private func statusColor(_ kind: String) -> Color {
        switch kind { case "Added": .green; case "Removed": .red; case "Changed": .orange; default: .secondary }
    }
}

private struct ComparisonCoverageRow: Identifiable {
    var id: String { category + "|" + source }
    let category: String
    let source: String
    let left: IPAComparisonCoverage?
    let right: IPAComparisonCoverage?
    static func rows(_ report: IPAComparisonReport, summarize: Bool) -> [Self] {
        func summarized(_ values: [IPAComparisonCoverage]) -> [IPAComparisonCoverage] {
            guard summarize else { return values }
            let completed = Dictionary(grouping: values.filter { $0.state == "Complete" }, by: \.category)
            return values.filter { $0.state != "Complete" } + completed.map { category, sources in
                IPAComparisonCoverage(category: category, source: "Completed sources", state: "Complete (\(sources.count))", detail: "")
            }
        }
        let a = Dictionary(uniqueKeysWithValues: summarized(report.leftCoverage).map { ($0.id, $0) })
        let b = Dictionary(uniqueKeysWithValues: summarized(report.rightCoverage).map { ($0.id, $0) })
        return Set(a.keys).union(b.keys).sorted().compactMap { key in
            guard let value = a[key] ?? b[key] else { return nil }
            return Self(category: value.category, source: value.source, left: a[key], right: b[key])
        }
    }
}

private struct ComparisonFileNode: Identifiable {
    let id: String
    let name: String
    var children: [ComparisonFileNode]?
    static func tree(_ paths: [String], prefix: String = "") -> [Self] {
        let grouped = Dictionary(grouping: Set(paths)) { $0.split(separator: "/").first.map(String.init) ?? $0 }
        return grouped.keys.sorted().map { name in
            let rest = grouped[name]!.compactMap { path -> String? in
                guard let slash = path.firstIndex(of: "/") else { return nil }
                return String(path[path.index(after: slash)...])
            }
            let id = prefix.isEmpty ? name : prefix + "/" + name
            return Self(id: id, name: name, children: rest.isEmpty ? nil : tree(rest, prefix: id))
        }
    }
}
