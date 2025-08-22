//
//  SettingsView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 18.08.2025.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsVM()
    @EnvironmentObject var loginViewModel: LoginVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    downloadSettingsSection
                    searchHistorySection
                    databaseSection
                    logoutSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(.windowBackgroundColor))
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(.body, design: .default, weight: .medium))
                }
            }
        }
    }

    private var downloadSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Download Settings")

            VStack(spacing: 12) {
                downloadPathCard
                downloadTypeCard
            }
        }
    }

    private var downloadPathCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .default))

                Text("Default Save Path")
                    .font(.system(.body, design: .default, weight: .medium))

                Spacer()
            }

            Button {
                viewModel.selectDownloadPath()
            } label: {
                HStack {
                    Text(viewModel.settings.defaultDownloadPath.isEmpty ? "Select Folder" : viewModel.settings.defaultDownloadPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(.subheadline, design: .default))
                        .foregroundColor(viewModel.settings.defaultDownloadPath.isEmpty ? .secondary : .primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }

    private var downloadTypeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .default))

                Text("Default Download Type")
                    .font(.system(.body, design: .default, weight: .medium))

                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(DownloadType.allCases, id: \.self) { type in
                    Button {
                        viewModel.updateDownloadType(type)
                    } label: {
                        Text(type.displayName)
                            .font(.system(.subheadline, design: .default, weight: .medium))
                            .foregroundColor(viewModel.settings.defaultDownloadType == type ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.settings.defaultDownloadType == type ?
                                Color.accentColor : Color(.controlBackgroundColor)
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(10)
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Search History")

            VStack(spacing: 12) {
                if viewModel.settings.searchHistoryEnabled {
                    clearHistoryCard
                }
            }
        }
    }

    private var clearHistoryCard: some View {
        Button {
            viewModel.clearSearchHistory()
        } label: {
            HStack {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.system(.body, design: .default))

                Text("Clear Search History")
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundColor(.red)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var logoutSection: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await loginViewModel.logout()
                }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(.body, design: .default))

                    Text("Sign Out")
                        .font(.system(.body, design: .default, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.red)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
    }

    private var databaseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Database")

            VStack(spacing: 12) {
                clearDatabaseCard
            }
        }
    }

    private var clearDatabaseCard: some View {
        Button {
            viewModel.clearAllSwiftData()
        } label: {
            HStack {
                Image(systemName: "trash.circle")
                    .foregroundColor(.orange)
                    .font(.system(.body, design: .default))

                Text("Clear All Downloaded Apps")
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundColor(.orange)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
}
