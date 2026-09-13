import SwiftUI

struct DownloadQueueView: View {
    @ObservedObject var queue = DownloadQueue.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Download Queue", systemImage: "tray.and.arrow.down").font(.headline)
                Spacer()
                Button { queue.removeFinished() } label: {
                    Label("Clear Finished", systemImage: "trash")
                }.disabled(!queue.jobs.contains { [.completed, .failed, .cancelled].contains($0.state) })
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if let error = queue.journalError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding()
            }
            if queue.jobs.isEmpty {
                EmptyStateView(icon: "arrow.down.circle", title: "No downloads", message: "Add apps from Search. You can close this panel while downloads continue.")
            } else {
                List(queue.jobs.reversed()) { job in queueRow(job) }
            }
            Divider()
            Text("Downloads continue when you close this panel.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 560, height: 540)
    }

    private func queueRow(_ job: DownloadJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppListIcon(urlString: job.app.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.app.name ?? job.app.bundleID ?? "App").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.versionLabel).lineLimit(1)
                    Text(job.state.label).foregroundStyle(job.state == .failed ? .red : .secondary)
                }.font(.caption).foregroundStyle(.secondary)
                if job.state == .downloading || job.state == .processing {
                    DownloadProgressView(job: job)
                } else if job.state == .preparing {
                    ProgressView().controlSize(.small)
                }
                if let message = job.message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                Text(URL(fileURLWithPath: job.destination).lastPathComponent)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            actions(job).buttonStyle(.borderless).font(.system(size: 18))
        }
        .padding(.vertical, 4)
        .help("\(job.accountEmail) · Storefront \(job.storefront)\n\(job.destination)")
    }

    @ViewBuilder private func actions(_ job: DownloadJob) -> some View {
        if job.state.active || job.state == .queued || job.state == .waitingForAccount {
            Button { queue.cancel(job.id) } label: { Label("Cancel", systemImage: "xmark.circle") }
                .labelStyle(.iconOnly).help("Cancel download")
        } else if job.state != .completed {
            Button { queue.retry(job.id) } label: { Label("Retry", systemImage: "arrow.clockwise.circle") }
                .labelStyle(.iconOnly).help("Retry download")
        } else {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.destination)]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }.labelStyle(.iconOnly).help("Show in Finder")
        }
    }
}

/// The detail window and queue render the same byte counts and transfer state.
struct DownloadProgressView: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 10) {
            if job.totalBytes > 0 {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: job.progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.15), value: job.progress)
                }.frame(width: 26, height: 26)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if job.totalBytes > 0 { Text("\(Int(job.progress * 100))%").fontWeight(.medium) }
                    if job.state == .processing { Text("Preparing package…") }
                    else if job.totalBytes == 0 { Text("Downloading…") }
                }.font(.caption)
                Text(byteSummary).font(.caption.monospacedDigit())
                if job.state == .downloading && job.bytesPerSecond > 0 {
                    HStack(spacing: 6) {
                        Text(Self.formatBytes(Int64(job.bytesPerSecond)) + "/s")
                        if let eta = job.eta { Text("~\(Int(eta))s remaining") }
                    }.font(.caption2.monospacedDigit())
                }
            }.foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var byteSummary: String {
        let written = Self.formatBytes(job.bytesWritten)
        return job.totalBytes > 0 ? written + " / " + Self.formatBytes(job.totalBytes) : written + " downloaded"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = true
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
