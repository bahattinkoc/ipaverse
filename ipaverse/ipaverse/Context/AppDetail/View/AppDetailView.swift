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
    @ObservedObject private var queue = DownloadQueue.shared

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
        .task {
            viewModel.setup(modelContext: modelContext, loginViewModel: loginViewModel)
            await viewModel.loadVersions()
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
                    HStack(spacing: 6) {
                        if let date = version.releaseDate {
                            Text(date, format: .dateTime.year().month(.abbreviated).day())
                        }
                        if let minOS = version.minimumOSVersion {
                            if version.releaseDate != nil {
                                Text("·")
                            }
                            Text("iOS \(minOS)+")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 6) {
                        if version.metadataFinished {
                            Image(systemName: "info.circle").help("Version metadata unavailable. You can still download this build.")
                        } else { ProgressView().scaleEffect(0.6) }
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
            if let job = downloadJob {
                if job.state == .downloading || job.state == .processing {
                    DownloadProgressView(job: job)
                } else {
                    HStack(spacing: 6) {
                        if job.state == .preparing { ProgressView().controlSize(.small) }
                        Text(job.message ?? job.state.label)
                            .font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                    }
                }
            } else if let message = viewModel.queuedMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: { viewModel.initiateDownload() }) {
                Label("Add to Queue", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(downloadJob?.isPending == true)
        }
        .padding()
    }

    private var downloadJob: DownloadJob? {
        guard let id = viewModel.downloadJobID else { return nil }
        return queue.jobs.first { $0.id == id }
    }
}
