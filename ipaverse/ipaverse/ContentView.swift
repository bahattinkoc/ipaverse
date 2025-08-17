//
//  ContentView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var loginViewModel = LoginVM()

    var body: some View {
        Group {
            switch loginViewModel.loginState {
            case .idle, .loading:
                SplashView()
                
            case .error, .requires2FA:
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

#Preview {
    ContentView()
        .modelContainer(for: DownloadedApp.self, inMemory: true)
}
