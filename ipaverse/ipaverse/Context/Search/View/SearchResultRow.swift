//
//  SearchResultRow.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 16.08.2025.
//

import SwiftUI

struct SearchResultRow: View {
    let app: AppStoreApp
    let isDownloading: Bool
    let downloadProgress: Double
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { image in
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
                Text(app.name ?? "-")
                    .font(.headline)
                    .lineLimit(1)

                Text(app.bundleID ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("v\(app.version ?? "-")")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let price = app.price, price > 0 {
                    Text("$\(price, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Free")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            if isDownloading {
                VStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.8)

                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(width: 50)
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }
        }
        .padding(.vertical, 4)
    }
}
