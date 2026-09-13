//
//  SearchView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    let account: Account
    @EnvironmentObject var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: SearchVM
    @State private var selectedIDs: Set<Int64> = []
    @State private var queueMessage: String?

    init(account: Account) {
        self.account = account
        self._viewModel = StateObject(wrappedValue: SearchVM(account: account))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                platformSelector

                if !viewModel.searchHistory.isEmpty {
                    recentSearches
                }

                Group {
                    if viewModel.isLoading {
                        ProgressView("Searching...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = viewModel.errorMessage {
                        EmptyStateView(
                            icon: "exclamationmark.triangle",
                            title: "Search Error",
                            message: error,
                            tone: .warning,
                            actionTitle: "Retry"
                        ) {
                            viewModel.performSearch()
                        }
                    } else if viewModel.searchResults.isEmpty && !viewModel.searchText.isEmpty && !viewModel.isSearching {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No Results",
                            message: viewModel.selectedPlatform == .visionos && !viewModel.isLookupMode
                                ? "Apple's search API doesn't index native visionOS-only apps by name. Enter the app's exact Bundle ID instead (e.g. com.example.app) to find it."
                                : "Try searching for a different app"
                        )
                    } else if viewModel.searchText.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "Search Apps",
                            message: "Enter an app name to search",
                            tone: .accent
                        )
                    } else {
                        List(selection: $selectedIDs) {
                          ForEach(viewModel.searchResults) { app in
                            SearchResultRow(
                                app: app,
                                downloadState: .idle
                            ) {
                                viewModel.downloadApp(app)
                            }
                            .tag(app.id ?? 0)
                          }
                        }
                        .refreshable {
                            viewModel.performSearch()
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .onChange(of: viewModel.searchResults) { _, _ in selectedIDs.removeAll() }
            .safeAreaInset(edge: .bottom) {
                if !selectedIDs.isEmpty {
                    HStack {
                        Text("\(selectedIDs.count) selected").font(.caption)
                        Spacer()
                        Button("Queue Selected…", action: queueSelected)
                    }.padding(10).background(.bar)
                }
            }
            .alert("Downloads", isPresented: Binding(get: { queueMessage != nil }, set: { if !$0 { queueMessage = nil } })) {
                Button("OK") { queueMessage = nil }
            } message: { Text(queueMessage ?? "") }
            .onAppear {
                viewModel.setup(modelContext: modelContext, loginViewModel: loginViewModel)
            }
        }
        .sheet(item: $viewModel.selectedDetailApp) { app in
            AppDetailView(app: app, account: loginViewModel.currentAccount ?? account)
        }
    }

    private func queueSelected() {
        let apps = viewModel.searchResults.filter { selectedIDs.contains($0.id ?? 0) }
        guard let active = loginViewModel.currentAccount, !apps.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.begin { result in
            guard result == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                guard loginViewModel.currentAccount == active else { queueMessage = "The active account changed. Select the apps again."; return }
                var count = 0
                do {
                    for app in apps {
                        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
                        let stem = (app.bundleID ?? String(app.id ?? 0)).unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
                        let ext = app.platform == .macos ? "pkg" : SettingsModel.load().defaultDownloadType.rawValue
                        var candidate = directory.appendingPathComponent(stem + "." + ext)
                        var suffix = 1
                        while FileManager.default.fileExists(atPath: candidate.path) || DownloadQueue.shared.jobs.contains(where: { $0.destination == candidate.path }) {
                            candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
                            suffix += 1
                        }
                        try DownloadQueue.shared.enqueue(app: app, account: active, destination: candidate)
                        count += 1
                    }
                    queueMessage = "Added \(count) apps to the queue. Open Downloaded → Queue to track progress."
                    selectedIDs.removeAll()
                } catch { queueMessage = "Added \(count) apps. " + error.localizedDescription }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: viewModel.isLookupMode ? "tag" : "magnifyingglass")
                    .foregroundColor(viewModel.isLookupMode ? .accentColor : .gray)
                    .animation(.easeInOut(duration: 0.15), value: viewModel.isLookupMode)

                if viewModel.isLookupMode {
                    Text("Bundle ID")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                        .transition(.scale.combined(with: .opacity))
                }

                TextField(viewModel.isLookupMode ? "com.example.app" : "Search apps...", text: $viewModel.searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onSubmit {
                        viewModel.performSearch()
                    }

                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .animation(.easeInOut(duration: 0.15), value: viewModel.isLookupMode)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Searches")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    viewModel.clearHistory()
                } label: {
                    Text("Clear")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.searchHistory, id: \.self) { searchTerm in
                        Button(action: {
                            viewModel.selectSearchTerm(searchTerm)
                        }) {
                            Text(searchTerm)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
    }

    private var platformSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Platform")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(AppPlatform.allCases, id: \.self) { platform in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.selectedPlatform = platform
                                if !viewModel.searchText.isEmpty {
                                    viewModel.performSearch()
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: platform.iconName)
                                    .font(.system(size: 10, weight: .medium))

                                Text(platform.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(viewModel.selectedPlatform == platform ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(viewModel.selectedPlatform == platform ?
                                          Color.accentColor :
                                            Color(NSColor.controlBackgroundColor))
                                    .shadow(color: viewModel.selectedPlatform == platform ?
                                            Color.accentColor.opacity(0.2) :
                                                Color.clear,
                                            radius: 2, x: 0, y: 1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(viewModel.selectedPlatform == platform ?
                                            Color.clear :
                                                Color(NSColor.separatorColor),
                                            lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(viewModel.selectedPlatform == platform ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: viewModel.selectedPlatform)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }
}
