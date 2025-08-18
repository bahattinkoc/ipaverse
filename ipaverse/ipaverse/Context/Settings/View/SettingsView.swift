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
                VStack(spacing: 24) {
                    downloadSettingsSection
                    searchHistorySection
                    logoutSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.windowBackgroundColor))
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("Close") {
                        dismiss()
                    }
                    .font(.system(.body, design: .rounded, weight: .medium))
                }
            }
        }
    }

    private var downloadSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Download Settings", icon: "arrow.down.circle.fill", color: .blue)

            VStack(spacing: 16) {
                downloadPathCard
                downloadTypeCard
            }
        }
    }

    private var downloadPathCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
                    .font(.title3)

                Text("Default Save Path")
                    .font(.system(.body, design: .rounded, weight: .medium))

                Spacer()
            }

            Button {
                viewModel.selectDownloadPath()
            } label: {
                HStack {
                    Text(viewModel.settings.defaultDownloadPath.isEmpty ? "Select Folder" : viewModel.settings.defaultDownloadPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(viewModel.settings.defaultDownloadPath.isEmpty ? .secondary : .primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private var downloadTypeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.green)
                    .font(.title3)

                Text("Default Download Type")
                    .font(.system(.body, design: .rounded, weight: .medium))

                Spacer()
            }

            HStack(spacing: 12) {
                ForEach(DownloadType.allCases, id: \.self) { type in
                    Button {
                        viewModel.updateDownloadType(type)
                    } label: {
                        Text(type.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundColor(viewModel.settings.defaultDownloadType == type ? .white : .primary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(
                                viewModel.settings.defaultDownloadType == type ?
                                Color.blue : Color(.controlBackgroundColor)
                            )
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Search History", icon: "clock.fill", color: .orange)

            VStack(spacing: 16) {
                searchHistoryToggleCard

                if viewModel.settings.searchHistoryEnabled {
                    clearHistoryCard
                }
            }
        }
    }

    private var searchHistoryToggleCard: some View {
        HStack {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Save Search History")
                        .font(.system(.body, design: .rounded, weight: .medium))

                    Text("Keep track of your recent searches")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $viewModel.settings.searchHistoryEnabled)
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                .onChange(of: viewModel.settings.searchHistoryEnabled) { _, _ in
                    viewModel.saveSettings()
                }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    private var clearHistoryCard: some View {
        Button {
            viewModel.clearSearchHistory()
        } label: {
            HStack {
                Image(systemName: "trash.fill")
                    .foregroundColor(.red)
                    .font(.title3)

                Text("Clear Search History")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundColor(.red)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .padding(16)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var logoutSection: some View {
        VStack(spacing: 16) {
            Button {
                Task {
                    await loginViewModel.logout()
                }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.title3)

                    Text("Log out")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [.red, .red.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(16)
                .shadow(color: .red.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title2)

            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundColor(.primary)
        }
    }
}
