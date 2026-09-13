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
        MainView(account: loginViewModel.currentAccount)

    }
}

#Preview {
    ContentView()
        .environmentObject(LoginVM())
        .modelContainer(for: DownloadedApp.self, inMemory: true)
}
