import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IPAComparisonVM: ObservableObject {
    @Published var report: IPAComparisonReport?
    @Published var message = "Preparing comparison…"
    @Published var error: String?
    private var work: Task<IPAComparisonReport, Error>?
    func run(_ input: ComparisonInput) async {
        let task = Task.detached(priority: .userInitiated) {
            try IPAComparison.compare(left: URL(fileURLWithPath: input.left), right: URL(fileURLWithPath: input.right)) { text in
                Task { @MainActor in self.message = text }
            }
        }
        work = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if !Task.isCancelled { report = result }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func cancel() { work?.cancel() }
    func export() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ipa-comparison.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct IPAComparisonView: View {
    let input: ComparisonInput
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = IPAComparisonVM()
    @State private var category = "All"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare IPA Copies").font(.title2)
                Spacer()
                Button("Export JSON") { model.export() }.disabled(model.report == nil)
                Button("Close") { model.cancel(); dismiss() }
            }
            Text("\(URL(fileURLWithPath: input.left).lastPathComponent) → \(URL(fileURLWithPath: input.right).lastPathComponent)").font(.caption).textSelection(.enabled)
            if let report = model.report {
                Picker("Category", selection: $category) {
                    ForEach(["All", "Info.plist", "Entitlements", "Frameworks", "Files", "Security findings"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                Text(report.changes.isEmpty ? "No differences found" : "\(report.changes.count) differences").font(.headline)
                List(report.changes.filter { category == "All" || $0.category == category }) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(change.kind) · \(change.category)").font(.caption).foregroundStyle(.secondary)
                        Text(change.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if let before = change.before { Text("− " + before).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let after = change.after { Text("+ " + after).font(.caption).textSelection(.enabled) }
                    }.padding(.vertical, 3)
                }
                Text(report.notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(5)
            } else if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
            } else { Spacer(); ProgressView(model.message).frame(maxWidth: .infinity); Spacer() }
        }.padding(20).frame(minWidth: 760, minHeight: 600)
            .task { await model.run(input) }
            .onDisappear { model.cancel() }
    }
}
