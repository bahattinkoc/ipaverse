//
//  MainView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 16.08.2025.
//

import SwiftUI

struct MainView: View {
    let account: Account
    @EnvironmentObject var loginViewModel: LoginVM
    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            TabView(selection: $navigationState.selectedTab) {
                DownloadedView(account: account)
                    .tabItem {
                        Image(systemName: "arrow.down.circle")
                        Text("Downloaded")
                    }
                    .tag(0)

                SearchView(account: account)
                    .tabItem {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                    }
                    .tag(1)
            }
            .navigationTitle("ipaverse")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(id: "resign")
                    } label: {
                        Image(systemName: "signature")
                            .font(.title2)
                    }
                    .help("Resign IPA…")
                }
                ToolbarItem(placement: .primaryAction) {
                    // Opens the standard, independent Settings window (the
                    // SwiftUI `Settings` scene) — same one ⌘, triggers.
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.title2)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(Bundle.main.appName)
                Spacer()
                Text("v\(Bundle.main.shortVersion)")
            }
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
