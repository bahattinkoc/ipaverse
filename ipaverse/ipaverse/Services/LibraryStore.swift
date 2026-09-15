import SwiftUI
import SwiftData
import SQLite3

@MainActor
final class LibraryStore: ObservableObject {
    /// Never nil — if the real on-disk library fails to open, this holds an
    /// in-memory fallback so the rest of the app (tabs, windows) always has a
    /// container to render against instead of being locked behind a blocking
    /// error screen. `error` carries the failure for inline display.
    @Published private(set) var container: ModelContainer
    @Published private(set) var error: String?
    private(set) var storeURL: URL?
    private let schema = Schema(versionedSchema: LibrarySchemaV2.self)

    init() {
        if ProcessInfo.processInfo.environment["IPAVERSE_TESTING"] == "1" {
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            return
        }
        container = Self.makeInMemoryFallback(schema: schema)
        openReal()
    }

    /// Retries opening the real on-disk library (e.g. from a "Retry"
    /// button). Safe to call repeatedly — on failure the app keeps running
    /// against the in-memory fallback rather than being blocked.
    func open() { openReal() }

    /// Last resort when the store won't open even after Retry (e.g. a
    /// corrupted or partially-deleted .store/-wal/-shm set). Moves the
    /// existing store files aside into a timestamped "quarantine" folder —
    /// never deletes them — then opens a brand new, empty library in their
    /// place. Downloaded .ipa files on disk are untouched; only the catalog
    /// of library records is reset, so the user can re-import/re-download.
    func reset() {
        if let url = storeURL {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("quarantined-library-\(stamp)", isDirectory: true)
            try? FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
            for file in Self.storeFileURLs(for: url) where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.moveItem(at: file, to: quarantine.appendingPathComponent(file.lastPathComponent))
            }
        }
        openReal()
    }

    private func openReal() {
        let configuration = ModelConfiguration(schema: schema)
        storeURL = configuration.url
        do {
            try Self.backupBeforeMigration(configuration.url)
            container = try ModelContainer(for: schema, migrationPlan: LibraryMigrationPlan.self,
                                           configurations: configuration)
            error = nil
        } catch {
            self.error = "The library could not be opened, so it's running in a temporary mode and nothing will be saved until this is resolved. Your files have not been deleted.\n\(Self.describe(error))"
        }
    }

    /// SwiftDataError's `localizedDescription` is almost always a useless
    /// "The operation couldn't be completed." — the actual Core Data-level
    /// reason (unknown model version, missing file, disk I/O error, …) is
    /// buried in NSUnderlyingError, so surface that too when present.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(underlying.localizedDescription)
            if let reason = underlying.localizedFailureReason { parts.append(reason) }
        } else if let reason = nsError.localizedFailureReason {
            parts.append(reason)
        }
        return parts.joined(separator: "\n")
    }

    private static func storeFileURLs(for storeURL: URL) -> [URL] {
        [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
    }

    private static func makeInMemoryFallback(schema: Schema) -> ModelContainer {
        (try? ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
            ?? (try! ModelContainer(for: schema))
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

/// Inline, non-blocking warning shown at the top of whichever page's content
/// depends on the library (currently the Downloaded tab) when the on-disk
/// store failed to open. Unlike a full-screen error state, the rest of the
/// app — tabs, navigation — stays usable while this is visible.
struct LibraryWarningBanner: View {
    let message: String
    let onRetry: () -> Void
    let onShowInFinder: () -> Void
    let onReset: () -> Void
    @State private var confirmReset = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Library needs attention").font(.subheadline.bold())
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Retry", action: onRetry)
                    Button("Show Library in Finder", action: onShowInFinder)
                    Button("Reset Library…", role: .destructive) { confirmReset = true }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3)))
        .padding(.horizontal)
        .padding(.top, 8)
        .confirmationDialog("Reset the library?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Library", role: .destructive, action: onReset)
        } message: {
            Text("This moves the broken library database aside (it is not deleted) and starts a fresh, empty library. Your downloaded .ipa files on disk are not affected, but you'll need to re-import or re-download them to see them listed again.")
        }
    }
}
