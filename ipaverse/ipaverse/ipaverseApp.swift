//
//  ipaverseApp.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI
import SwiftData
import AppKit

/// Only the main window should ever appear at launch. macOS's "reopen windows
/// from last session" restoration (independent of SwiftUI's own scene
/// restoration, and not something the macOS 14 SDK's Scene APIs let us opt
/// out of per-scene) can resurrect a Resign window that was left open —
/// close anything that isn't "main" right after launch finishes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows where window.identifier?.rawValue != "main" {
            window.close()
        }
    }
}

/// Which tab of the main window is selected — lives outside `MainView` so
/// menu-bar commands (declared at the App/Scene level) can jump to a tab in
/// the already-open main window instead of only being reachable by clicking
/// inside it.
final class AppNavigationState: ObservableObject {
    @Published var selectedTab = 0
}

@main
struct ipaverseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var loginViewModel = LoginVM()
    @StateObject private var navigationState = AppNavigationState()
    @Environment(\.openWindow) private var openWindow

    // A single, explicitly-shared ModelContainer — letting SwiftUI create one
    // per `.modelContainer(for:)` call (even pointed at the same store file)
    // gives each window its own ModelContext, and cross-context change
    // notifications between them don't integrate cleanly with SwiftUI's
    // @Query diffing/animation, causing layout glitches on insert. Sharing
    // one container's mainContext across every window avoids that entirely.
    private let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: DownloadedApp.self)
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        Window("ipaverse", id: "main") {
            ContentView()
                .environmentObject(loginViewModel)
                .environmentObject(navigationState)
                .fixedWindow(width: 560, height: 820)
        }
        .windowResizability(.contentSize)
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Resign IPA…") {
                    openWindow(id: "resign")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Downloaded") {
                    openWindow(id: "main")
                    navigationState.selectedTab = 0
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Search") {
                    openWindow(id: "main")
                    navigationState.selectedTab = 1
                }
                .keyboardShortcut("2", modifiers: .command)
            }
        }

        WindowGroup(id: "resign", for: String.self) { $appID in
            ResigningWindowView(appID: appID)
                .environmentObject(loginViewModel)
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
                .environmentObject(loginViewModel)
        }
    }
}
