import SwiftUI
import SwiftData
import SQLite3

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var error: String?
    private(set) var storeURL: URL?

    init() { open() }

    func open() {
        do {
            let schema = Schema(versionedSchema: LibrarySchemaV2.self)
            if ProcessInfo.processInfo.environment["IPAVERSE_TESTING"] == "1" {
                container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
                return
            }
            let configuration = ModelConfiguration(schema: schema)
            storeURL = configuration.url
            try Self.backupBeforeMigration(configuration.url)
            container = try ModelContainer(for: schema, migrationPlan: LibraryMigrationPlan.self,
                                           configurations: configuration)
            error = nil
        } catch {
            self.error = "The library could not be opened. Your files have not been deleted.\n\(error.localizedDescription)"
        }
    }

    /// SQLite's backup API includes committed WAL pages, unlike copying just the .store file.
    static func backupBeforeMigration(_ source: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let backup = source.deletingLastPathComponent().appendingPathComponent("library-before-2.5.sqlite")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        let staging = AtomicFile.stagingURL(for: backup)
        defer { try? FileManager.default.removeItem(at: staging) }
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(input)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open(staging.path, &output) == SQLITE_OK else {
            sqlite3_close(output)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(output) }
        guard let operation = sqlite3_backup_init(output, "main", input, "main") else { throw CocoaError(.fileWriteUnknown) }
        let status = sqlite3_backup_step(operation, -1)
        let finish = sqlite3_backup_finish(operation)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        // Close/checkpoint the destination before moving its main database file.
        let closeStatus = sqlite3_close(output)
        if closeStatus == SQLITE_OK { output = nil }
        guard closeStatus == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try AtomicFile.commit(staging, to: backup)
    }
}

struct LibraryRecoveryView: View {
    @ObservedObject var library: LibraryStore
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
            Text("Library needs attention").font(.headline)
            Text(library.error ?? "Library unavailable").textSelection(.enabled)
            HStack {
                Button("Retry") { library.open() }
                Button("Show Library in Finder") {
                    if let url = library.storeURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }.padding(32).frame(minWidth: 560, minHeight: 400)
    }
}
