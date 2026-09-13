//
//  DownloadedAppRow.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.08.2025.
//

import SwiftUI

/// Caches the FairPlay-bound Apple ID per IPA path so scrolling the list doesn't
/// re-read the zip for rows that have already been resolved. A present key means
/// "resolved" — its value may legitimately be nil (DRM-free / no binding).
@MainActor
private enum BoundAppleIDCache {
    private static var cache: [String: String?] = [:]

    static func resolved(_ path: String) -> (isResolved: Bool, value: String?) {
        if let value = cache[path] { return (true, value) }
        return (false, nil)
    }

    static func store(_ path: String, _ value: String?) { cache[path] = value }
}

struct DownloadedAppRow: View {
    let downloadedApp: DownloadedApp
    let downloadState: DownloadState
    /// Apple ID currently signed into ipaverse, to flag IPAs bound to another one.
    var activeAppleID: String? = nil
    let onRedownload: () -> Void
    var canRedownload = true
    var isFileMissing = false
    var onLocateFile: (() -> Void)? = nil

    @State private var boundAppleID: String?
    @State private var didResolve = false

    /// True when this IPA is FairPlay-bound to an Apple ID other than the active
    /// one — it would crash on launch if installed under the active account.
    private var mismatch: Bool {
        guard didResolve,
              let bound = boundAppleID, let active = activeAppleID,
              !bound.isEmpty, !active.isEmpty else { return false }
        return bound.caseInsensitiveCompare(active) != .orderedSame
    }

    var body: some View {
        AppRowView(
            app: downloadedApp,
            appRowType: .downloaded(downloadState),
            onDownload: onRedownload,
            onRedownload: onRedownload,
            canRedownload: canRedownload,
            isFileMissing: isFileMissing,
            onLocateFile: onLocateFile
        )
        .overlay(alignment: .topTrailing) {
            if mismatch {
                mismatchBadge
                    .padding(.top, 2)
                    .padding(.trailing, 2)
            }
        }
        .task(id: bindingKey) { await resolveBinding() }
    }

    private var bindingKey: String {
        "\(downloadedApp.filePath)|\(downloadedApp.sha256 ?? "")|\(downloadedApp.downloadDate.timeIntervalSince1970)|\(isFileMissing)"
    }

    private var mismatchBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
            Text("Other Apple ID")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.orange.opacity(0.12)))
        .help("Bound to \(boundAppleID ?? "another Apple ID"). The device's App Store account and license must be checked on the device.")
    }

    private func resolveBinding() async {
        boundAppleID = nil
        didResolve = false
        guard !isFileMissing, downloadedApp.supportsIPAOperations else { return }
        let path = downloadedApp.filePath
        let key = bindingKey

        let cached = BoundAppleIDCache.resolved(key)
        if cached.isResolved {
            boundAppleID = cached.value
            didResolve = true
            return
        }

        let resolved = await Task.detached { IPAResigner.boundAppleID(ipaPath: path) }.value
        guard !Task.isCancelled else { return }
        BoundAppleIDCache.store(key, resolved)
        boundAppleID = resolved
        didResolve = true
    }
}
