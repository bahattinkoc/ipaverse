//
//  DownloadedAppRow.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.08.2025.
//

import SwiftUI

struct DownloadedAppRow: View {
    let downloadedApp: DownloadedApp
    let downloadState: DownloadState
    let onRedownload: () -> Void

    var body: some View {
        AppRowView(
            app: downloadedApp,
            appRowType: .downloaded(downloadState),
            onDownload: onRedownload,
            onRedownload: onRedownload
        )
    }
}
