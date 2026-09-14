import SwiftUI

struct IPAComparisonFileDetail: View {
    let file: IPAComparisonChange
    let rows: [IPAComparisonChange]
    let allContentCount: Int
    let hasContentChanges: Bool
    let leftCoverage: [IPAComparisonCoverage]
    let rightCoverage: [IPAComparisonCoverage]
    let preview: IPAComparisonPreview?
    let assets: [IPAComparisonAsset]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(file.source).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    Button("Copy changes") {
                        let text = rows.map { "\($0.path)\nA: \($0.before ?? "—")\nB: \($0.after ?? "—")" }.joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.source + "\n\n" + text, forType: .string)
                    }.disabled(rows.isEmpty)
                }
                if let preview {
                    IPAComparisonImageView(before: preview.before, after: preview.after,
                        beforeMissing: file.before == nil ? "Not present" : "Preview unavailable",
                        afterMissing: file.after == nil ? "Not present" : "Preview unavailable")
                    Text("First frame").font(.caption).foregroundStyle(.secondary)
                }
                coverageIssues(leftCoverage, side: "A")
                coverageIssues(rightCoverage, side: "B")
                if rows.isEmpty, preview == nil, assets.isEmpty {
                    Text(allContentCount > 0 ? (!hasContentChanges && file.kind == "Changed" ? "Parsed values are unchanged; encoded file bytes differ." : "No parsed value changes match the current filters.") : "No decoded content is available for this file.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(assets) { asset in IPAComparisonAssetCard(asset: asset) }
                ForEach(rows.filter { $0.category != "Asset catalogs" }) { row in
                    ComparisonContentChange(row: row)
                }
                DisclosureGroup("File metadata · size and SHA-256") {
                    HStack(alignment: .top, spacing: 16) {
                        rawValue(file.before, title: "A · Before")
                        rawValue(file.after, title: "B · After")
                    }.padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func coverageIssues(_ coverage: [IPAComparisonCoverage], side: String) -> some View {
        ForEach(coverage.filter { $0.category != "Files" && ($0.state != "Complete" || !$0.detail.isEmpty) }) { item in
            HStack(alignment: .top, spacing: 6) {
                Text(side + " · " + item.category + " · " + item.state).fontWeight(.medium)
                Text(item.detail).textSelection(.enabled)
            }.font(.caption).foregroundStyle(item.state == "Complete" ? Color.secondary : .orange)
        }
    }
    private func rawValue(_ text: String?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            Text(text ?? "—").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ComparisonContentChange: View {
    let row: IPAComparisonChange
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(row.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Text(row.kind).font(.caption).foregroundStyle(color)
            }
            Text(row.category + " · " + row.valueType).font(.caption).foregroundStyle(.secondary)
            if row.valueType == "text" {
                ComparisonInlineDiff(before: row.before, after: row.after)
                DisclosureGroup("Full A / B values") { valueColumns }
                    .font(.caption)
            } else { valueColumns }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
    private var valueColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            value(row.before, title: "A · Before", tint: .red)
            value(row.after, title: "B · After", tint: .green)
        }
    }
    private func value(_ text: String?, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text.map { $0.isEmpty ? "\"\"" : $0 } ?? (row.kind == "Not compared" ? "Unavailable" : "—"))
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(8).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(tint.opacity(row.kind == "Unchanged" ? 0 : 0.07), in: RoundedRectangle(cornerRadius: 5))
    }
    private var color: Color {
        switch row.kind { case "Added": .green; case "Removed": .red; case "Changed": .orange; default: .secondary }
    }
}

struct ComparisonInlineDiff: View {
    let before: String?
    let after: String?
    var body: some View {
        let lines = ComparisonTextDiff.contextLines(before: before, after: after)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let color: Color = line.hasPrefix("+ ") ? .green : line.hasPrefix("− ") ? .red : .secondary
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2).padding(.horizontal, 6)
                    .foregroundStyle(color).background(color.opacity(line.hasPrefix("+ ") || line.hasPrefix("− ") ? 0.08 : 0))
            }
        }
    }
}
