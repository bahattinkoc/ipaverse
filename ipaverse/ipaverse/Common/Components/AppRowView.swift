//
//  AppRowView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.08.2025.
//

import SwiftUI

protocol AppRowData {
    var rowId: String { get }
    var rowBundleID: String { get }
    var rowName: String { get }
    var rowVersion: String { get }
    var rowIconURL: String? { get }
}

extension AppStoreApp: AppRowData {
    var rowId: String { String(self.id ?? 0) }
    var rowBundleID: String { self.bundleID ?? "" }
    var rowName: String { self.name ?? "" }
    var rowVersion: String { self.version ?? "" }
    var rowIconURL: String? { self.iconURL }
}

extension DownloadedApp: AppRowData {
    var rowId: String { self.id }
    var rowBundleID: String { self.bundleID }
    var rowName: String { self.name }
    var rowVersion: String { self.version }
    var rowIconURL: String? { self.iconURL }
}

enum AppRowType {
    case search(DownloadState)
    case downloaded(DownloadState)
}

struct AppRowView: View {
    let app: AppRowData
    let appRowType: AppRowType
    let onDownload: () -> Void
    let onRedownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            appIconView

            appInfoView

            Spacer()

            actionView
        }
        .padding(.vertical, 4)
    }

    private var appIconView: some View {
        AsyncImage(url: URL(string: app.rowIconURL ?? "")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    Image(systemName: "app.fill")
                        .foregroundColor(.gray)
                )
        }
        .frame(width: 50, height: 50)
        .cornerRadius(8)
    }

    private var appInfoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.rowName.isEmpty ? "-" : app.rowName)
                .font(.headline)
                .lineLimit(1)

            Text(app.rowBundleID.isEmpty ? "-" : app.rowBundleID)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text("v\(app.rowVersion.isEmpty ? "-" : app.rowVersion)")
                .font(.caption)
                .foregroundColor(.secondary)

            switch appRowType {
            case .search:
                if let appStoreApp = app as? AppStoreApp {
                    if let price = appStoreApp.price, price > 0 {
                        Text("$\(price, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Free")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            case .downloaded:
                if let downloadedApp = app as? DownloadedApp {
                    Text(downloadedApp.downloadDate, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch appRowType {
        case .search(let downloadState):
            downloadStateView(downloadState, action: onDownload)
        case .downloaded(let downloadState):
            downloadStateView(downloadState, action: onRedownload)
        }
    }

    @ViewBuilder
    private func downloadStateView(_ downloadState: DownloadState, action: @escaping () -> Void) -> some View {
        switch downloadState {
        case .idle:
            Button(action: action) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
                    .font(.title2)
            }
            .buttonStyle(.plain)

        case .purchasing:
            VStack(spacing: 4) {
                Text("Purchasing...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
            }
            .frame(width: 60)

        case .downloading(let progress, let bytesWritten, let totalBytes):
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.2), lineWidth: 3)
                        .frame(width: 24, height: 24)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }

                VStack(spacing: 2) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 2) {
                        Text(formatFileSize(bytesWritten))
                            .font(.system(.caption2, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(width: 55, alignment: .trailing)

                        Text("/\(formatFileSize(totalBytes))")
                            .font(.system(.caption2, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(width: 70, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 60, maxWidth: 120)
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.formattingContext = .standalone
        return formatter.string(fromByteCount: bytes)
    }
}
