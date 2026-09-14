import SwiftUI

struct IPAComparisonAssetCard: View {
    let asset: IPAComparisonAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.headline).textSelection(.enabled)
                    Text(asset.variant).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(asset.kind).font(.caption.bold()).foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(statusColor.opacity(0.1), in: Capsule())
            }
            IPAComparisonImageView(before: asset.before?.preview, after: asset.after?.preview,
                beforeMissing: asset.before == nil ? "Not present" : "Preview unavailable",
                afterMissing: asset.after == nil ? "Not present" : "Preview unavailable")
            HStack(alignment: .top, spacing: 14) {
                versionSummary(asset.before)
                versionSummary(asset.after)
            }
            DisclosureGroup("Asset properties") {
                let keys = Set(asset.before?.metadata.keys.map { $0 } ?? []).union(asset.after?.metadata.keys.map { $0 } ?? [])
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top) {
                            Text(key).frame(width: 140, alignment: .leading)
                            Text(asset.before?.metadata[key] ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                            Text(asset.after?.metadata[key] ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                        }.textSelection(.enabled)
                    }
                }.padding(.top, 8).font(.system(.caption, design: .monospaced))
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func versionSummary(_ version: IPAComparisonAssetVersion?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let version {
                Text(version.summary).font(.caption).foregroundStyle(.secondary)
                if let issue = version.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var statusColor: Color {
        switch asset.kind { case "Added": .green; case "Removed": .red; case "Changed": .orange; default: .secondary }
    }
}
