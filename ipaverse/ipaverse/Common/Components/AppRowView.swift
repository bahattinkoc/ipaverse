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
    var rowPlatform: String? { get }
    var rowIsImported: Bool { get }
}

extension AppStoreApp: AppRowData {
    var rowId: String { String(self.id ?? 0) }
    var rowBundleID: String { self.bundleID ?? "" }
    var rowName: String { self.name ?? "" }
    var rowVersion: String { self.version ?? "" }
    var rowIconURL: String? { self.iconURL }
    var rowPlatform: String? { self.platform?.rawValue }
    var rowIsImported: Bool { false }
}

extension DownloadedApp: AppRowData {
    var rowId: String { self.id }
    var rowBundleID: String { self.bundleID }
    var rowName: String { self.name }
    var rowVersion: String { self.version }
    var rowIconURL: String? { self.iconURL }
    var rowPlatform: String? { self.platform }
    // Imported IPAs are not tied to an App Store record (appId == 0), so they
    // cannot be re-downloaded.
    var rowIsImported: Bool { self.appId == 0 }
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

    @ViewBuilder
    private var appIconView: some View {
        Group {
            // Imported apps store a local file URL; AsyncImage is unreliable for
            // file:// URLs, so load those directly. Remote store icons use AsyncImage.
            if let urlString = app.rowIconURL,
               let url = URL(string: urlString), url.isFileURL {
                if let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    iconPlaceholder
                }
            } else {
                AsyncImage(url: URL(string: app.rowIconURL ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    iconPlaceholder
                }
            }
        }
        .frame(width: 50, height: 50)
        .cornerRadius(8)
    }

    private var iconPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.3))
            .overlay(
                Image(systemName: "app.fill")
                    .foregroundColor(.gray)
            )
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

            HStack(spacing: 4) {
                Text("v\(app.rowVersion.isEmpty ? "-" : app.rowVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let platform = app.rowPlatform {
                    HStack(spacing: 4) {
                        Image(systemName: platform == "iOS" ? "iphone" : "macbook")
                            .font(.system(size: 8, weight: .medium))

                        Text(platform)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(platform == "iOS" ? .blue : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(platform == "iOS" ?
                                  Color.blue.opacity(0.1) :
                                    Color.orange.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(platform == "iOS" ?
                                    Color.blue.opacity(0.3) :
                                        Color.orange.opacity(0.3),
                                    lineWidth: 0.5)
                    )
                }
            }

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
            switch downloadState {
            case .idle:
                searchGetButton
            default:
                downloadStateView(downloadState, action: onDownload)
            }
        case .downloaded(let downloadState):
            switch downloadState {
            case .idle:
                // Imported apps have no store license to re-download from.
                if !app.rowIsImported {
                    redownloadButton
                }
            default:
                downloadStateView(downloadState, action: onRedownload)
            }
        }
    }

    private var searchGetButton: some View {
        Button(action: onDownload) {
            Text("GET")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var redownloadButton: some View {
        Button(action: onRedownload) {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 20))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func downloadStateView(_ downloadState: DownloadState, action: @escaping () -> Void) -> some View {
        switch downloadState {
        case .idle:
            EmptyView()

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
