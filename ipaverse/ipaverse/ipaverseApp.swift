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
    var body: some Scene {
        Window("ipaverse", id: "main") {
            ContentView()
                .fixedWindow(width: 400, height: 700)
        }
        .windowResizability(.contentSize)
        .modelContainer(for: DownloadedApp.self)
    }
}
