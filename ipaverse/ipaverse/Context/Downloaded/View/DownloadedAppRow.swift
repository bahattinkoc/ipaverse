//
//  DownloadedAppRow.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.08.2025.
//

import SwiftUI

struct DownloadedAppRow: View {
    let downloadedApp: DownloadedApp
    let onRedownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: downloadedApp.iconURL ?? "")) { image in
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

            VStack(alignment: .leading, spacing: 4) {
                Text(downloadedApp.name.isEmpty ? "-" : downloadedApp.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(downloadedApp.bundleID.isEmpty ? "-" : downloadedApp.bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("v\(downloadedApp.version.isEmpty ? "-" : downloadedApp.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(downloadedApp.downloadDate, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onRedownload) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
