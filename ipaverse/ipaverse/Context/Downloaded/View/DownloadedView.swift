import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct DownloadedView: View {
    let account: Account?
    @EnvironmentObject private var loginViewModel: LoginVM
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \DownloadedApp.downloadDate, order: .reverse) private var downloadedApps: [DownloadedApp]
    @ObservedObject private var queue = DownloadQueue.shared
    @State private var showDownloadQueue = false
    @State private var groupVersions = false
    @State private var query = ""
    @State private var source = "All"
    @State private var platform = "All"
    @State private var selection: Set<String> = []
    @State private var missingPaths: Set<String> = []
    @State private var selectedApp: AppStoreApp?
    @State private var installContext: IPAInstallContext?
    @State private var appToDump: DownloadedApp?
    @State private var comparison: ComparisonInput?
    @State private var isDropTargeted = false
    @State private var importingCount = 0
    @State private var error: String?
    @State private var removalIDs: Set<String> = []
    @State private var confirmRemoval = false
    @AppStorage("evilModeEnabled") private var isEvilMode = false

    private var filtered: [DownloadedApp] {
        downloadedApps.filter {
            (query.isEmpty || "\($0.name) \($0.bundleID) \($0.version) \($0.buildVersion ?? "")".localizedCaseInsensitiveContains(query)) &&
            (source == "All" || $0.artifactSource == source) &&
            (platform == "All" || $0.platform == platform)
        }
    }
    private var groups: [(key: String, apps: [DownloadedApp])] {
        Dictionary(grouping: filtered, by: \.libraryGroupID)
            .map { (key: $0.key, apps: $0.value) }
            .sorted { ($0.apps.first?.name ?? "").localizedStandardCompare($1.apps.first?.name ?? "") == .orderedAscending }
    }
    private var selected: [DownloadedApp] { downloadedApps.filter { selection.contains($0.id) } }
    private var canCompare: Bool { selected.count == 2 && selected.allSatisfy { $0.supportsIPAOperations && !missingPaths.contains($0.filePath) } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if downloadedApps.isEmpty {
                EmptyStateView(icon: "arrow.down.circle", title: "No Downloaded Apps", message: "Apps you download or import will appear here", tone: .accent, dropHint: "or drag & drop an .ipa file here")
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matching copies", message: "Try another search or filter.")
            } else {
                List(selection: $selection) {
                    DropHintBox(text: "Drag & drop an .ipa file here to add it", compact: true)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
                    if groupVersions {
                        ForEach(groups, id: \.key) { group in
                            Section(group.apps.first?.name ?? "App") {
                                ForEach(group.apps) { app in libraryRow(app) }
                            }
                        }
                    } else {
                        ForEach(filtered) { app in libraryRow(app) }
                    }
                }
            }
            if !selection.isEmpty {
                HStack {
                    Text("\(selection.count) selected").font(.caption)
                    Spacer()
                    Button {
                        guard canCompare else { return }
                        comparison = ComparisonInput(left: selected[0].filePath, right: selected[1].filePath)
                    } label: { Label("Compare", systemImage: "square.on.square") }
                        .disabled(!canCompare).help("Select two IPA copies to compare")
                    Button(role: .destructive) { removalIDs = selection; confirmRemoval = true } label: {
                        Label("Remove", systemImage: "trash")
                    }.help("Remove selected records; keep files on disk")
                }.padding(10)
            }
        }
        .sheet(isPresented: $showDownloadQueue) { DownloadQueueView() }
        .onAppear(perform: refreshFiles)
        .onChange(of: downloadedApps.map(\.filePath)) { _, _ in refreshFiles() }
        .onChange(of: query) { _, _ in selection.removeAll() }
        .onChange(of: source) { _, _ in selection.removeAll() }
        .onChange(of: platform) { _, _ in selection.removeAll() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4).allowsHitTesting(false) }
            if importingCount > 0 { ProgressView("Importing…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .sheet(item: $selectedApp) { app in
            if let account = loginViewModel.currentAccount { AppDetailView(app: app, account: account) }
        }
        .sheet(item: $installContext) { ctx in
            DeviceInstallView(ipaPath: ctx.ipaPath, appName: ctx.appName, activeAppleID: loginViewModel.currentAccount?.email)
        }
        .sheet(item: $appToDump) { DumpView(downloadedApp: $0) }
        .sheet(item: $comparison) { IPAComparisonView(input: $0) }
        .confirmationDialog("Remove selected copies from the library? Files will remain on disk.", isPresented: $confirmRemoval) {
            Button("Remove from Library", role: .destructive) {
                for app in downloadedApps where removalIDs.contains(app.id) { modelContext.delete(app) }
                do { try modelContext.save(); selection.subtract(removalIDs) }
                catch { self.error = error.localizedDescription }
            }
        }
        .alert("Library", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search downloaded apps", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Picker("Source", selection: $source) {
                    ForEach(["All", "Downloaded", "Imported", "Resigned", "Decrypted"], id: \.self) { Text($0) }
                }
                Picker("Platform", selection: $platform) {
                    Text("All").tag("All")
                    ForEach(AppPlatform.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Group Versions & Copies", isOn: $groupVersions)
                if source != "All" || platform != "All" {
                    Button("Clear Filters") { source = "All"; platform = "All" }
                }
                Divider()
                Button { refreshFiles() } label: { Label("Check File Locations", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: source == "All" && platform == "All" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton).fixedSize().help("Filter and group copies")
            Button(action: chooseImports) { Label("Import IPA…", systemImage: "square.and.arrow.down") }
                .labelStyle(.iconOnly).help("Import IPA…")
            Button { showDownloadQueue = true } label: {
                Label(queueCount == 0 ? "Queue" : "Queue (\(queueCount))", systemImage: "tray.and.arrow.down")
            }.help("Open the download queue")
        }.padding(.horizontal).padding(.vertical, 8)
    }

    private var queueCount: Int {
        queue.jobs.filter { $0.state.active || $0.state == .queued || $0.state == .waitingForAccount }.count
    }

    private func libraryRow(_ app: DownloadedApp) -> some View {
        DownloadedAppRow(
            downloadedApp: app,
            downloadState: .idle,
            activeAppleID: loginViewModel.currentAccount?.email,
            onRedownload: { selectedApp = app.storeApp },
            canRedownload: loginViewModel.currentAccount != nil,
            isFileMissing: missingPaths.contains(app.filePath),
            onLocateFile: app.supportsIPAOperations ? { relink(app) } : nil
        )
        .tag(app.id)
        .contextMenu { actions(app) }
        .help(copyDetails(app))
    }

    private func copyDetails(_ app: DownloadedApp) -> String {
        var details = [app.filePath, app.artifactSource]
        if let size = app.fileSize { details.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let parentID = app.parentArtifactID {
            let parent = downloadedApps.first { $0.id == parentID }
            details.append("From " + (parent.map { URL(fileURLWithPath: $0.filePath).lastPathComponent } ?? "original copy"))
        }
        return details.joined(separator: "\n")
    }

    @ViewBuilder private func actions(_ app: DownloadedApp) -> some View {
        let available = !missingPaths.contains(app.filePath)
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.filePath)]) } label: {
            Label("Show in Finder", systemImage: "folder")
        }.disabled(!available)
        Button { relink(app) } label: { Label("Locate File…", systemImage: "folder.badge.questionmark") }
            .disabled(!app.supportsIPAOperations)
        Button { openWindow(id: "resign", value: app.id) } label: { Label("Edit & Resign", systemImage: "signature") }
            .disabled(!available || !app.supportsIPAOperations)
        Button { installContext = IPAInstallContext(ipaPath: app.filePath, appName: app.name) } label: {
            Label("Install to Device", systemImage: "iphone.and.arrow.forward")
        }.disabled(!available || !app.supportsIPAOperations || (app.platform != nil && app.platform != "iOS" && app.platform != "iPadOS"))
        Button { selectedApp = app.storeApp } label: { Label("Version History…", systemImage: "clock.arrow.circlepath") }
            .disabled(app.appId == 0 || loginViewModel.currentAccount == nil)
        Button { openWindow(id: "securityScan", value: app.id) } label: { Label("Reverse Engineer", systemImage: "binoculars.fill") }
            .disabled(!isEvilMode || !available || !app.supportsIPAOperations)
            .help(isEvilMode ? "" : "Enable Evil Mode from the toolbar to use this.")
        Button { appToDump = app } label: { Label("Dump Decrypted Copy", systemImage: "lock.open.trianglebadge.exclamationmark") }
            .disabled(!isEvilMode || !available || !app.supportsIPAOperations)
            .help(isEvilMode ? "" : "Enable Evil Mode from the toolbar to use this.")
        Divider()
        Button(role: .destructive) { removalIDs = [app.id]; confirmRemoval = true } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }

    private func refreshFiles() {
        missingPaths = Set(downloadedApps.map(\.filePath).filter { !FileManager.default.fileExists(atPath: $0) })
    }
    private func chooseImports() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { result in
            if result == .OK { Task { await importFiles(panel.urls) } }
        }
    }
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "ipa" else { return }
                Task { @MainActor in await importFiles([url]) }
            }
        }
        return providers.contains { $0.canLoadObject(ofClass: URL.self) }
    }
    private func importFiles(_ urls: [URL]) async {
        importingCount += 1
        defer { importingCount -= 1; refreshFiles() }
        for url in urls {
            do { _ = try await IPAImporter.importIPA(at: url, into: modelContext) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func relink(_ app: DownloadedApp) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.canChooseDirectories = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await LibraryRepository.relink(app, to: url, context: modelContext); refreshFiles() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
