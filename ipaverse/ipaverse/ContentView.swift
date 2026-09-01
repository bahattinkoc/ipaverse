//
//  ContentView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var loginViewModel: LoginVM

    var body: some View {
        Group {
            if loginViewModel.isCheckingExistingSession {
                SplashView()
            } else {
                switch loginViewModel.loginState {
                case .loading, .idle, .error, .requires2FA:
                    LoginView()
                        .environmentObject(loginViewModel)

                case .success(let account):
                    MainView(account: account)
                        .environmentObject(loginViewModel)
                }
            }
        }
        .animation(.easeInOut, value: loginViewModel.loginState)
        .animation(.easeInOut, value: loginViewModel.isCheckingExistingSession)
    }
}

#Preview {
    ContentView()
        .environmentObject(LoginVM())
        .modelContainer(for: DownloadedApp.self, inMemory: true)
}
