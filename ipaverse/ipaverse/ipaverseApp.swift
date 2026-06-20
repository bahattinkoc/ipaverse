//
//  ipaverseApp.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData

@main
struct ipaverseApp: App {
    @StateObject private var loginViewModel = LoginVM()

    var body: some Scene {
        Window("ipaverse", id: "main") {
            ContentView()
                .environmentObject(loginViewModel)
                .fixedWindow(width: 450, height: 820)
        }
        .windowResizability(.contentSize)
        .modelContainer(for: DownloadedApp.self)

        Settings {
            SettingsView()
                .environmentObject(loginViewModel)
        }
    }
}
