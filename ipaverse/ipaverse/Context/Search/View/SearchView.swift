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

                platformSelector

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
                                downloadState: .idle
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
        .sheet(item: $viewModel.selectedDetailApp) { app in
            AppDetailView(app: app, account: account)
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
                                Image(systemName: platform == .ios ? "iphone" : "macbook")
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
