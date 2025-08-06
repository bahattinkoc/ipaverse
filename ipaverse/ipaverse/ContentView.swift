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

// MARK: - Main View (Placeholder)
struct MainView: View {
    let account: Account
    @EnvironmentObject var loginViewModel: LoginViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Welcome, \(account.name)!")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Apple ID: \(account.email)")
                    .font(.body)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Log Out") {
                    Task {
                        await loginViewModel.logout()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("ipaverse")
        }
    }
}

#Preview {
    ContentView()
}
