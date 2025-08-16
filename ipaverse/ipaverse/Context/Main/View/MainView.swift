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
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
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
                    Button("Log Out") {
                        Task {
                            await loginViewModel.logout()
                        }
                    }
                }
            }
        }
    }
}
