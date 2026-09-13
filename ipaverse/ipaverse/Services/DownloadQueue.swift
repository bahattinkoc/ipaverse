import Foundation
import SwiftUI
import SwiftData

struct DownloadJob: Codable, Identifiable {
    enum State: String, Codable {
        case queued, preparing, downloading, processing, completed, failed, cancelled, interrupted, waitingForAccount
        var active: Bool { self == .preparing || self == .downloading || self == .processing }
        var label: String {
            switch self {
            case .queued: return "Queued"
            case .preparing: return "Preparing download"
            case .processing: return "Preparing package"
            case .downloading: return "Downloading"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .interrupted: return "Interrupted — retry to restart"
            case .waitingForAccount: return "Sign in to the matching account and region"
            }
        }
    }
    var id = UUID()
    var app: AppStoreApp
    var accountEmail: String
    var storefront: String
    var versionID: String?
    var displayVersion: String?
    var destination: String
    var createdAt = Date()
    var state: State = .queued
    var message: String?
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var versionLabel: String {
        // A catalog version is only a fallback for an unpinned (latest) download.
        // An older, explicitly selected Store ID must never acquire that label.
        let version = readableVersion(displayVersion) ?? (versionID == nil ? readableVersion(app.version) : nil)
        return version.map { $0.hasPrefix("v") ? $0 : "v" + $0 } ?? "Version unavailable"
    }
    func readableVersion(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value != versionID, value != versionID.map({ "Build " + $0 }) else { return nil }
        return value
    }
    var isPending: Bool { state.active || state == .queued || state == .waitingForAccount }
    var progress: Double { totalBytes > 0 ? min(1, Double(bytesWritten) / Double(totalBytes)) : 0 }
    var eta: TimeInterval? { bytesPerSecond > 0 && totalBytes > bytesWritten ? Double(totalBytes - bytesWritten) / bytesPerSecond : nil }
}

/// Credentials stay in memory/Keychain. The journal contains only user-visible job metadata.
@MainActor
final class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var journalError: String?
    private let journalURL: URL
    private var context: ModelContext?
    private var account: Account?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var starts: [UUID: Date] = [:]
    private var lastProgress: [UUID: Date] = [:]
    private let concurrency = 2

    init(journalURL: URL? = nil) {
        self.journalURL = journalURL ?? (ProcessInfo.processInfo.environment["IPAVERSE_TESTING"] == "1"
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-test-jobs-\(UUID().uuidString).json")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ipaverse/download-jobs.json"))
        do {
            if FileManager.default.fileExists(atPath: self.journalURL.path) {
                jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: self.journalURL))
                for index in jobs.indices where jobs[index].state.active { jobs[index].state = .interrupted }
            }
        } catch { journalError = "Saved downloads could not be read. The journal has been preserved. \(error.localizedDescription)" }
    }

    var activeCount: Int { jobs.filter { $0.state.active || $0.state == .queued }.count }
    func configure(context: ModelContext, account: Account?) {
        self.context = context
        restoreCompletedVersions(context: context)
        updateAccount(account)
    }

    private func restoreCompletedVersions(context: ModelContext) {
        guard let records = try? context.fetch(FetchDescriptor<DownloadedApp>()) else { return }
        // Only the newest completed job at a destination can describe its current file.
        let latestJobs = Dictionary(grouping: jobs, by: \.destination)
            .compactMapValues { $0.max { $0.createdAt < $1.createdAt }?.id }
        for index in jobs.indices where jobs[index].state == .completed && latestJobs[jobs[index].destination] == jobs[index].id {
            let job = jobs[index]
            guard let record = records.first(where: {
                $0.filePath == job.destination && $0.appId == job.app.id && $0.bundleID == job.app.bundleID &&
                $0.externalVersionID == job.versionID && $0.sourceTag == nil && $0.downloadDate >= job.createdAt
            }), let version = job.readableVersion(record.version) else { continue }
            jobs[index].displayVersion = version
        }
    }

    func updateDisplayVersion(_ id: UUID, versionID: String, version: String) {
        guard let job = jobs.first(where: { $0.id == id }), job.versionID == versionID,
              job.state != .completed, let readable = job.readableVersion(version) else { return }
        mutate(id) { $0.displayVersion = readable }
        persist()
    }

    func updateAccount(_ newAccount: Account?) {
        if account != newAccount {
            for (id, task) in running {
                task.cancel()
                mutate(id) { $0.state = .waitingForAccount; $0.message = nil }
            }
        }
        account = newAccount
        for index in jobs.indices where jobs[index].state == .waitingForAccount && matches(jobs[index]) {
            jobs[index].state = .queued
        }
        persist()
        schedule()
    }

    @discardableResult
    func enqueue(app: AppStoreApp, account: Account, destination: URL, versionID: String? = nil, displayVersion: String? = nil) throws -> UUID {
        guard journalError == nil else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: journalError!]) }
        let path = destination.standardizedFileURL.path
        guard !jobs.contains(where: { $0.destination == path && ($0.state.active || $0.state == .queued || $0.state == .waitingForAccount) }) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "Another queued download is using this destination."])
        }
        let job = DownloadJob(app: app, accountEmail: account.email, storefront: account.storeFront,
                              versionID: versionID, displayVersion: displayVersion, destination: path)
        jobs.append(job)
        do { try save() } catch { jobs.removeAll { $0.id == job.id }; throw error }
        schedule()
        return job.id
    }

    func cancel(_ id: UUID) {
        running[id]?.cancel()
        mutate(id) { $0.state = .cancelled; $0.message = nil }
        persist()
        schedule()
    }
    func retry(_ id: UUID) {
        guard running[id] == nil, let job = jobs.first(where: { $0.id == id }), !job.state.active else { return }
        // Never allow two jobs to write the same destination, including retries.
        guard !jobs.contains(where: { $0.id != id && $0.destination == job.destination && ($0.state.active || $0.state == .queued || $0.state == .waitingForAccount) }) else { return }
        mutate(id) { $0.state = .queued; $0.message = nil; $0.bytesWritten = 0; $0.totalBytes = 0; $0.bytesPerSecond = 0 }
        persist()
        schedule()
    }
    func removeFinished() {
        jobs.removeAll { [.completed, .failed, .cancelled].contains($0.state) && running[$0.id] == nil }
        persist()
    }

    private func matches(_ job: DownloadJob) -> Bool {
        guard let account else { return false }
        return account.email.caseInsensitiveCompare(job.accountEmail) == .orderedSame && account.storeFront == job.storefront
    }
    private func schedule() {
        guard journalError == nil, let context else { return }
        for job in jobs where job.state == .queued && running[job.id] == nil {
            guard running.count < concurrency else { break }
            guard matches(job), let account else {
                mutate(job.id) { $0.state = .waitingForAccount }
                continue
            }
            let id = job.id
            mutate(id) { $0.state = .preparing; $0.bytesWritten = 0; $0.totalBytes = 0; $0.bytesPerSecond = 0 }
            running[id] = Task {
                defer {
                    running[id] = nil; starts[id] = nil; lastProgress[id] = nil
                    persist(); schedule()
                }
                do {
                    let result = try await AppStoreService(isolatedCookies: true).download(app: job.app, account: account, outputPath: job.destination,
                        externalVersionId: job.versionID, downloadedVersion: job.displayVersion,
                        progress: { _, bytes, total in
                            Task { @MainActor in self.receiveProgress(id, bytes: bytes, total: total) }
                        }, modelContext: context)
                    guard !Task.isCancelled else { return }
                    mutate(id) {
                        $0.state = .completed
                        if let version = $0.readableVersion(result.version) { $0.displayVersion = version }
                        $0.bytesWritten = max($0.bytesWritten, $0.totalBytes)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    mutate(id) {
                        $0.state = (error as? LoginError) == .tokenExpired ? .waitingForAccount : .failed
                        $0.message = error.localizedDescription
                    }
                }
            }
        }
        persist()
    }
    private func receiveProgress(_ id: UUID, bytes: Int64, total: Int64) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.active, bytes >= job.bytesWritten else { return }
        let now = Date()
        guard (job.bytesWritten == 0 && bytes > 0) || now.timeIntervalSince(lastProgress[id] ?? .distantPast) >= 0.1 || (total > 0 && bytes >= total) else { return }
        lastProgress[id] = now
        if starts[id] == nil { starts[id] = now }
        let elapsed = max(0.1, now.timeIntervalSince(starts[id] ?? now))
        mutate(id) {
            $0.state = total > 0 && bytes >= total ? .processing : .downloading; $0.bytesWritten = bytes; $0.totalBytes = total
            $0.bytesPerSecond = Double(bytes) / elapsed
        }
    }
    private func mutate(_ id: UUID, _ update: (inout DownloadJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { update(&jobs[index]) }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: journalURL, options: .atomic)
    }
    private func persist() {
        guard journalError == nil else { return }
        do { try save() } catch { journalError = "Could not save download state: \(error.localizedDescription)" }
    }
}
