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

    init(account: Account) {
        self.account = account
        self._viewModel = StateObject(wrappedValue: SearchVM(account: account))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar

                if !viewModel.searchHistory.isEmpty {
                    recentSearches
                }

                Group {
                    if viewModel.isLoading {
                        ProgressView("Searching...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = viewModel.errorMessage {
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 48))
                                .foregroundColor(.orange)

                            Text("Search Error")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(error)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            Button("Retry") {
                                viewModel.performSearch()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.searchResults.isEmpty && !viewModel.searchText.isEmpty && !viewModel.isSearching {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)

                            Text("No Results")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Try searching for a different app")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.searchText.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.blue)

                            Text("Search Apps")
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text("Enter an app name to search")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(viewModel.searchResults) { app in
                            SearchResultRow(
                                app: app,
                                isDownloading: viewModel.isDownloading && viewModel.currentDownloadApp?.id == app.id,
                                downloadProgress: viewModel.downloadProgress
                            ) {
                                viewModel.downloadApp(app)
                            }
                        }
                        .refreshable {
                            viewModel.performSearch()
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .onAppear {
                viewModel.setup(modelContext: modelContext, loginViewModel: loginViewModel)
            }
        }
        .onChange(of: viewModel.showingSavePanel) { _, newValue in
            if newValue {
                viewModel.showSavePanel()
            }
        }
    }

    private var searchBar: some View {
        HStack {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)

                TextField("Search apps...", text: $viewModel.searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .onSubmit {
                        viewModel.performSearch()
                    }

                if !viewModel.searchText.isEmpty {
                    Button(action: {
                        viewModel.clearSearch()
                    }) {
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Searches")
                .font(.caption)
                .foregroundColor(.secondary)
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
}
