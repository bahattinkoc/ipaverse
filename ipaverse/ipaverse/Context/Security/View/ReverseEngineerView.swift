//
//  ReverseEngineerView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Container for the Reverse Engineer window: static analysis (the former
//  standalone Security Scan), a class browser, and a Frida toolkit for live
//  bypasses/traces. One window, one app in context, one sidebar over all
//  three — this used to be a top segmented tab bar with Frida Toolkit's
//  script catalog hidden behind a second, nested sidebar of its own; folding
//  Static Analysis and Class Browser into that same sidebar (alongside the
//  script catalog's existing Bypass/Data Dump/Live Inspection groups) cuts
//  that down to one navigation layer instead of two. No separate name for
//  the sidebar+detail area itself is needed now that it *is* the whole
//  window's content — the header below still just says "Reverse Engineer".
//  (The external-tool catalog lives in Settings only — it's app-wide
//  configuration, not something scoped to "this app I'm reverse-engineering
//  right now".)

import SwiftUI

struct ReverseEngineerView: View {
    let ipaPath: String
    let appName: String
    @AppStorage("evilModeEnabled") private var isEvilMode = false

    private enum SidebarItem: Hashable {
        case staticAnalysis
        case classBrowser
        case script(String)
    }

    @State private var selection: SidebarItem = .staticAnalysis
    // Owned here, not by each pane's view, so switching sidebar items
    // doesn't tear down an in-progress scan/dump or an attached Frida
    // session — see SecurityScanView/FridaScriptDetailView's doc comments.
    @StateObject private var securityScanVM: SecurityScanVM
    @StateObject private var classBrowserVM: ClassBrowserVM
    @StateObject private var fridaToolkitVM: FridaToolkitVM

    init(ipaPath: String, appName: String) {
        self.ipaPath = ipaPath
        self.appName = appName
        _securityScanVM = StateObject(wrappedValue: SecurityScanVM(ipaPath: ipaPath, appName: appName))
        _classBrowserVM = StateObject(wrappedValue: ClassBrowserVM(ipaPath: ipaPath))
        _fridaToolkitVM = StateObject(wrappedValue: FridaToolkitVM(appName: appName))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
        }
        .onChange(of: isEvilMode) { _, enabled in
            if !enabled { fridaToolkitVM.stop() }
        }
        .onDisappear {
            fridaToolkitVM.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "binoculars.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reverse Engineer")
                    .font(.headline)
                Text(appName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// There's only one live Frida session per `FridaToolkitVM` — navigating
    /// to a *different* script while one is attached stops it first, rather
    /// than either silently blocking the navigation (confusing: "I clicked,
    /// why didn't anything happen?") or leaving the detail pane's shown
    /// config mismatched against whatever's actually still attached.
    /// Switching to the *same* already-running script, or to Static
    /// Analysis/Class Browser, is untouched — neither depends on Frida's
    /// run state, and the point of leaving those reachable while a script
    /// runs is to let you check them *alongside* an ongoing capture.
    private func prepareToSwitchScript(to id: String) {
        if fridaToolkitVM.isRunning && fridaToolkitVM.selectedScriptID != id {
            fridaToolkitVM.stop(clearingData: true)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<SidebarItem?>(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                if case .script(let id) = newValue {
                    prepareToSwitchScript(to: id)
                    fridaToolkitVM.selectedScriptID = id
                }
                selection = newValue
            }
        )) {
            Section("Analysis") {
                Label("Static Analysis", systemImage: "doc.text.magnifyingglass")
                    .tag(SidebarItem.staticAnalysis)
                Label("Class Browser", systemImage: "curlybraces")
                    .tag(SidebarItem.classBrowser)
            }
            ForEach(FridaScriptCategory.allCases) { category in
                let scripts = FridaScriptLibrary.scripts.filter { $0.category == category }
                if !scripts.isEmpty {
                    Section(category.rawValue) {
                        ForEach(scripts) { script in
                            Label(script.title, systemImage: script.icon)
                                .lineLimit(1)
                                .tag(SidebarItem.script(script.id))
                                .help(fridaToolkitVM.isRunning && fridaToolkitVM.selectedScriptID != script.id
                                      ? "Switching stops the currently running script (\(fridaToolkitVM.selectedScript.title))."
                                      : "")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 240)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .staticAnalysis:
            SecurityScanView(viewModel: securityScanVM)
        case .classBrowser:
            ClassBrowserView(viewModel: classBrowserVM) { rawClassName, methodSelector in
                prepareToSwitchScript(to: "class-method-tracer")
                fridaToolkitVM.selectedScriptID = "class-method-tracer"
                fridaToolkitVM.className = rawClassName
                // A bare r2 selector (no "- "/"+ " prefix) still matches as
                // a substring of the tracer's "- selector"/"+ selector"
                // method names, so no reformatting needed here.
                fridaToolkitVM.methodFilter = methodSelector ?? ""
                selection = .script("class-method-tracer")
            }
        case .script:
            FridaScriptDetailView(viewModel: fridaToolkitVM) { rawClassName in
                prepareToSwitchScript(to: "class-method-tracer")
                fridaToolkitVM.selectedScriptID = "class-method-tracer"
                fridaToolkitVM.className = rawClassName
                fridaToolkitVM.methodFilter = ""
                selection = .script("class-method-tracer")
            }
        }
    }
}
