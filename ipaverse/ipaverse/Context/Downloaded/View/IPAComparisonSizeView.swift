import SwiftUI

struct IPAComparisonSizeView: View {
    let report: IPAComparisonReport
    let files: [IPAComparisonFileSize]
    let changedOnly: Bool
    let openFile: (String) -> Void
    @Binding var grouping: String
    @Binding var direction: String
    @Binding var component: String?
    @State private var groups: [IPAComparisonSizeGroup] = []
    @State private var rankedFiles: [IPAComparisonFileSize] = []
    @State private var groupMaximum: Int64 = 1
    @State private var fileMaximum: Int64 = 1

    private var scoped: [IPAComparisonFileSize] { files.filter { component == nil || $0.component == component } }
    private func matches(_ delta: Int64) -> Bool { direction == "All" || (direction == "Growth" ? delta > 0 : delta < 0) }
    private func refresh() {
        groups = IPAComparisonSizeGroup.groups(files).filter { matches($0.delta) && (!changedOnly || $0.changedCount > 0) }
        rankedFiles = scoped.filter { matches($0.delta) && (!changedOnly || $0.kind != "Unchanged") }.sorted {
            abs($0.delta) == abs($1.delta) ? $0.source < $1.source : abs($0.delta) > abs($1.delta)
        }
        groupMaximum = groups.map { abs($0.delta) }.max() ?? 1
        fileMaximum = rankedFiles.map { abs($0.delta) }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Size impact").font(.headline)
                Text("Extracted bytes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Group by", selection: $grouping) {
                    Text("Components").tag("Components")
                    Text("Files").tag("Files")
                }.pickerStyle(.segmented).frame(width: 200)
            }
            HStack(spacing: 14) {
                metric("IPA Δ · total", report.right.archiveBytes - report.left.archiveBytes)
                metric("Extracted Δ · total", report.right.extractedBytes - report.left.extractedBytes)
                metric("Growth · filtered files", files.reduce(0) { $0 + max(0, $1.delta) })
                metric("Reduction · filtered files", files.reduce(0) { $0 + min(0, $1.delta) })
            }
            HStack {
                Picker("Direction", selection: $direction) {
                    Text("All").tag("All")
                    Text("Growth").tag("Growth")
                    Text("Reduction").tag("Reduction")
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                Text("Filtered net: " + IPAComparisonSizeFormat.signed(files.reduce(0) { $0 + $1.delta }))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let component, grouping == "Files" {
                HStack {
                    Text(component == "." ? "Main app" : component).font(.caption).lineLimit(1).truncationMode(.middle)
                    Button("All components") { self.component = nil }.font(.caption)
                }
            }
            if grouping == "Components" { componentTable } else { fileTable }
        }.padding(14)
            .onAppear { refresh() }
            .onChange(of: files) { _, _ in refresh() }
            .onChange(of: changedOnly) { _, _ in refresh() }
            .onChange(of: direction) { _, _ in refresh() }
            .onChange(of: component) { _, _ in refresh() }
    }

    private var componentTable: some View {
        Table(groups) {
            TableColumn("Component") { group in
                Button {
                    component = group.id; grouping = "Files"
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.id == "." ? "Main app" : group.id).lineLimit(2).truncationMode(.middle)
                        Text("\(group.changedCount) changed / \(group.files.count) files").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("Show files owned by " + (group.id == "." ? "Main app" : group.id))
            }.width(min: 170, ideal: 250)
            TableColumn("A") { group in size(group.before) }.width(min: 70, ideal: 90)
            TableColumn("B") { group in size(group.after) }.width(min: 70, ideal: 90)
            TableColumn("Δ") { group in delta(group.delta, maximum: groupMaximum) }.width(min: 100, ideal: 140)
            TableColumn("Growth / Reduction") { group in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(IPAComparisonSizeFormat.signed(group.growth)).foregroundStyle(.orange)
                    Text(IPAComparisonSizeFormat.signed(group.reduction)).foregroundStyle(.green)
                }.font(.caption.monospacedDigit()).help("Growth: \(IPAComparisonSizeFormat.exact(group.growth))\nReduction: \(IPAComparisonSizeFormat.exact(group.reduction))")
            }.width(min: 100, ideal: 125)
        }.overlay { if groups.isEmpty { empty } }
    }

    private var fileTable: some View {
        Table(rankedFiles) {
            TableColumn("File") { file in
                Button { openFile(file.source) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.source).lineLimit(2).truncationMode(.middle)
                        Text(file.kind).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("Inspect " + file.source)
            }.width(min: 180, ideal: 320)
            TableColumn("A") { file in size(file.before) }.width(min: 70, ideal: 95)
            TableColumn("B") { file in size(file.after) }.width(min: 70, ideal: 95)
            TableColumn("Δ") { file in delta(file.delta, maximum: fileMaximum) }.width(min: 100, ideal: 150)
        }.overlay { if rankedFiles.isEmpty { empty } }
    }
    private var empty: some View {
        Text("No size changes match the current filters").foregroundStyle(.secondary)
            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    private func metric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(IPAComparisonSizeFormat.signed(value)).font(.title3.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).help(IPAComparisonSizeFormat.exact(value))
    }
    private func size(_ value: Int64?) -> some View {
        Text(value.map(IPAComparisonSizeFormat.bytes) ?? "—").font(.caption.monospacedDigit())
            .help(value.map(IPAComparisonSizeFormat.exact) ?? "Not present")
    }
    private func delta(_ value: Int64, maximum: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(IPAComparisonSizeFormat.signed(value)).font(.caption.monospacedDigit())
            GeometryReader { geometry in
                Capsule().fill(value > 0 ? Color.orange : value < 0 ? Color.green : Color.secondary)
                    .frame(width: geometry.size.width * CGFloat(abs(value)) / CGFloat(max(1, maximum)))
            }.frame(height: 3)
        }.padding(.vertical, 4).help(IPAComparisonSizeFormat.exact(value))
    }
}
