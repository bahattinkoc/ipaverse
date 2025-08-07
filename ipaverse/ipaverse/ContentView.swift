//
//  ContentView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var loginViewModel = LoginViewModel()

    var body: some View {
        Group {
            switch loginViewModel.loginState {
            case .idle, .loading, .error, .requires2FA:
                LoginView()
                    .environmentObject(loginViewModel)

            case .success(let account):
                MainView(account: account)
                    .environmentObject(loginViewModel)
            }
        }
        .animation(.easeInOut, value: loginViewModel.loginState)
    }
}

// MARK: - Main View
struct MainView: View {
    let account: Account
    @EnvironmentObject var loginViewModel: LoginViewModel
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

#Preview {
    ContentView()
}
