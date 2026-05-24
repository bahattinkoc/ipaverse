//
//  AppDetailView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import SwiftUI
import SwiftData

struct AppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var loginViewModel: LoginVM
    @StateObject private var viewModel: AppDetailVM

    init(app: AppStoreApp, account: Account) {
        self._viewModel = StateObject(wrappedValue: AppDetailVM(app: app, account: account))
    }

    var body: some View {
        VStack(spacing: 0) {
            appHeader

            Divider()

            versionsSection

            Divider()

            downloadSection
        }
        .frame(width: 380, height: 480)
        .onAppear {
            viewModel.setup(modelContext: modelContext, loginViewModel: loginViewModel)
            Task { await viewModel.loadVersions() }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var appHeader: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: viewModel.app.iconURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "app.fill").foregroundColor(.gray))
            }
            .frame(width: 56, height: 56)
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.app.name ?? "-")
                    .font(.headline)
                    .lineLimit(1)

                Text(viewModel.app.bundleID ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("v\(viewModel.app.version ?? "-")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    // MARK: - Versions Section

    @ViewBuilder
    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Version History")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            switch viewModel.versionsState {
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(viewModel.loadingMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .error(let message):
                VStack(spacing: 10) {
                    Image(systemName: "lock.circle")
                        .font(.system(size: 30))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let versions):
                List(versions, selection: Binding(
                    get: { viewModel.selectedVersionId },
                    set: { viewModel.selectedVersionId = $0 }
                )) { version in
                    versionRow(version)
                        .tag(version.id)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func versionRow(_ version: AppVersion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedVersionId == version.id
                  ? "checkmark.circle.fill"
                  : "circle")
                .foregroundColor(viewModel.selectedVersionId == version.id ? .accentColor : Color(NSColor.tertiaryLabelColor))
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                if let displayVersion = version.displayVersion {
                    Text(displayVersion)
                        .font(.body)
                        .foregroundColor(.primary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text(version.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if version.isLatest {
                Text("Latest")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .cornerRadius(5)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedVersionId = version.id
        }
    }

    // MARK: - Download Section

    private var downloadSection: some View {
        HStack(spacing: 12) {
            downloadProgressView

            Spacer()

            Button(action: { viewModel.initiateDownload() }) {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isDownloading)
        }
        .padding()
    }

    @ViewBuilder
    private var downloadProgressView: some View {
        switch viewModel.downloadState {
        case .purchasing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Preparing...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .downloading(let progress, let bytesWritten, let totalBytes):
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                        .frame(width: 22, height: 22)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(formatBytes(bytesWritten)) / \(formatBytes(totalBytes))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

        case .idle:
            EmptyView()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
