//
//  SearchResultRow.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 16.08.2025.
//

import SwiftUI

struct SearchResultRow: View {
    let app: AppStoreApp
    let downloadState: DownloadState
    let onDownload: () -> Void

    var body: some View {
        AppRowView(
            app: app,
            appRowType: .search(downloadState),
            onDownload: onDownload,
            onRedownload: {}
        )
    }
}
