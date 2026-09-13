import XCTest
import SwiftData
@testable import ipaverse

final class WorkspaceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var app: AppStoreApp { AppStoreApp(id: 123, bundleID: "com.example.test", name: "Test", version: "1.0", price: 0, platform: .ios) }
    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
    private func response(_ status: Int, length: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/app.ipa")!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(length)])!
    }

    func testDownloadFailuresPreserveOriginal() throws {
        let original = Data("original IPA".utf8)
        let destination = try file("app.ipa", original)
        let incoming = try file("incoming", Data("new package".utf8))
        for status in [404, 500] {
            XCTAssertThrowsError(try PackageDownload.finish(temporary: incoming, response: response(status, length: 11), destination: destination) { _ in XCTFail("Must not prepare an HTTP error") })
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
        XCTAssertThrowsError(try PackageDownload.finish(temporary: incoming, response: response(200, length: 999), destination: destination) { _ in XCTFail("Must not prepare a truncated download") })
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertThrowsError(try PackageDownload.finish(temporary: incoming, response: response(200, length: 11), destination: destination) { staged in
            try Data("partially patched".utf8).write(to: staged)
            throw PackageDownloadError.preparation("fixture failure")
        })
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".ipaverse-") })
    }

    func testDownloadCommitsOnlyPreparedFile() throws {
        let destination = try file("app.ipa", Data("old".utf8))
        let incoming = try file("incoming", Data("new".utf8))
        try PackageDownload.finish(temporary: incoming, response: response(200, length: 3), destination: destination) { staged in
            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
            try Data("prepared".utf8).write(to: staged)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("prepared".utf8))
    }

    func testCancelledDownloadPreservesFile() async throws {
        let destination = try file("app.ipa", Data("old".utf8))
        let incoming = try file("incoming", Data("new".utf8))
        let response = response(200, length: 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PackageDownload.finish(temporary: incoming, response: response, destination: destination) { _ in XCTFail("Cancelled transfer cannot prepare") }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    func testStreamedDownloadReportsBytesBeforeCompletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["known-length", "unknown-length"] {
            let destination = try file(path + ".ipa", Data("original".utf8))
            var updates: [(Double, Int64, Int64)] = []
            try await PackageDownload.fetch(request: URLRequest(url: URL(string: "https://transfer.invalid/" + path)!),
                session: session, destination: destination,
                progress: { updates.append(($0, $1, $2)) }, prepare: { staged in
                    XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
                    XCTAssertEqual(try Data(contentsOf: staged), TransferFixtureProtocol.payload)
                    // Progress is delivered while streaming, before preparation or commit.
                    XCTAssertTrue(updates.contains { $0.1 > 0 && $0.1 < TransferFixtureProtocol.payload.count })
                })
            XCTAssertEqual(try Data(contentsOf: destination), TransferFixtureProtocol.payload)
            XCTAssertEqual(updates.last?.0, 1)
            XCTAssertEqual(updates.last?.1, Int64(TransferFixtureProtocol.payload.count))
            XCTAssertEqual(updates.last?.2, Int64(TransferFixtureProtocol.payload.count))
            if path == "known-length" {
                XCTAssertTrue(updates.contains { $0.0 > 0 && $0.0 < 1 && $0.2 == TransferFixtureProtocol.payload.count })
            } else {
                XCTAssertTrue(updates.contains { $0.1 > 0 && $0.2 == 0 })
            }
        }
    }

    func testCancelledStreamPreservesOriginalAndCleansStagingFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let destination = try file("cancelled.ipa", Data("original".utf8))
        let task = Task {
            try await PackageDownload.fetch(request: URLRequest(url: URL(string: "https://transfer.invalid/known-length")!),
                session: session, destination: destination, progress: { _, bytes, _ in
                    if bytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }, prepare: { _ in XCTFail("A cancelled transfer cannot prepare a package") })
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".ipaverse-") })
    }

    func testStreamHTTPFailurePreservesOriginal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let destination = try file("failed.ipa", Data("original".utf8))
        do {
            try await PackageDownload.fetch(request: URLRequest(url: URL(string: "https://transfer.invalid/failure")!),
                session: session, destination: destination, progress: { _, _, _ in XCTFail("HTTP errors are not transfer progress") },
                prepare: { _ in XCTFail("Must not prepare HTTP error content") })
            XCTFail("Expected HTTP error")
        } catch PackageDownloadError.http(let status) { XCTAssertEqual(status, 500) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
    }

    @MainActor
    func testHistoryPreferenceAndLibraryIsolation() throws {
        let suite = "ipaverse-history-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = SearchHistoryStore(defaults: defaults)
        history.record("first")
        var settings = SettingsModel(); settings.searchHistoryEnabled = false
        defaults.set(try JSONEncoder().encode(settings), forKey: SettingsModel.storageKey)
        history.record("must not persist")
        XCTAssertEqual(history.load(), [])
        XCTAssertEqual(defaults.stringArray(forKey: "SearchHistory"), ["first"])
        let container = try ModelContainer(for: DownloadedApp.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(DownloadedApp(app: app, filePath: "/fixture.ipa"))
        try container.mainContext.save()
        SettingsVM(defaults: defaults).clearSearchHistory()
        XCTAssertNil(defaults.object(forKey: "SearchHistory"))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DownloadedApp>()), 1)
    }

    @MainActor
    func testDistinctVersionsAndCopiesKeepIndependentIdentity() throws {
        let container = try ModelContainer(for: DownloadedApp.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let first = try LibraryRepository.upsertFile(app: app, filePath: directory.appendingPathComponent("original.ipa").path, context: context)
        let second = try LibraryRepository.upsertFile(app: app, filePath: directory.appendingPathComponent("signed.ipa").path, context: context)
        second.sourceTag = "Resigned"; second.parentArtifactID = first.id
        let next = try LibraryRepository.upsertFile(app: app, filePath: directory.appendingPathComponent("next.ipa").path, context: context, version: "2.0")
        XCTAssertEqual(Set([first.id, second.id, next.id]).count, 3)
        let reimport = try LibraryRepository.upsertFile(app: app, filePath: second.filePath, context: context)
        XCTAssertEqual(reimport.id, second.id)
        XCTAssertEqual(first.version, "1.0")
        XCTAssertEqual(next.version, "2.0")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DownloadedApp>()), 3)
    }

    @MainActor
    func testLegacyUnversionedStoreMigratesWithoutLosingRecords() throws {
        let url = directory.appendingPathComponent("legacy.store")
        try autoreleasepool {
            let legacy = try ModelContainer(for: LibrarySchemaV1.DownloadedApp.self, configurations: ModelConfiguration(url: url))
            let record = LibrarySchemaV1.DownloadedApp(app: app, filePath: "/original.ipa")
            record.id = "legacy-id"; record.sourceTag = "Resigned"
            legacy.mainContext.insert(record)
            try legacy.mainContext.save()
        }
        try LibraryStore.backupBeforeMigration(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-before-2.5.sqlite").path))
        try autoreleasepool {
            let backup = try ModelContainer(for: LibrarySchemaV1.DownloadedApp.self,
                configurations: ModelConfiguration(url: directory.appendingPathComponent("library-before-2.5.sqlite")))
            XCTAssertEqual(try backup.mainContext.fetch(FetchDescriptor<LibrarySchemaV1.DownloadedApp>()).first?.id, "legacy-id")
        }
        let migrated = try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV2.self),
            migrationPlan: LibraryMigrationPlan.self, configurations: ModelConfiguration(url: url))
        let records = try migrated.mainContext.fetch(FetchDescriptor<DownloadedApp>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "legacy-id")
        XCTAssertEqual(records.first?.filePath, "/original.ipa")
        XCTAssertEqual(records.first?.sourceTag, "Resigned")
        XCTAssertNil(records.first?.sha256)
        let copy = DownloadedApp(app: app, filePath: "/second.ipa")
        migrated.mainContext.insert(copy)
        try migrated.mainContext.save()
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<DownloadedApp>()), 2)
    }

    private func profile(pattern: String = "TEAM.com.example.*", expired: Bool = false) throws -> ProvisioningProfile {
        try ProvisioningProfile(plist: ["Name": "Fixture", "ExpirationDate": Date().addingTimeInterval(expired ? -60 : 3600),
            "DeveloperCertificates": [Data("certificate fixture".utf8)], "ProvisionedDevices": ["fixture-udid"],
            "Entitlements": ["application-identifier": pattern, "com.apple.developer.team-identifier": "TEAM",
                "get-task-allow": false, "aps-environment": "production", "keychain-access-groups": ["TEAM.*"]]])
    }

    func testProfileMatchingAndDistributionEntitlements() throws {
        let profile = try profile()
        XCTAssertTrue(profile.allows(bundleID: "com.example.test"))
        XCTAssertFalse(profile.allows(bundleID: "com.examples.test"))
        let signed = try profile.signingEntitlements(bundleID: "com.example.test")
        XCTAssertEqual(signed["get-task-allow"] as? Bool, false)
        XCTAssertEqual(signed["aps-environment"] as? String, "production")
        XCTAssertEqual(signed["application-identifier"] as? String, "TEAM.com.example.test")
        XCTAssertEqual(signed["keychain-access-groups"] as? [String], ["TEAM.com.example.test"])
        XCTAssertTrue(profile.checks(bundleID: "com.example.test", deviceID: "another-device").contains { $0.status == .blocked })
        XCTAssertFalse(profile.checks(bundleID: "com.example.test", deviceID: "fixture-udid").contains { $0.status == .blocked })
        XCTAssertFalse(try self.profile(pattern: "TEAM.com.example.test").allows(bundleID: "com.example.test.extension"))
        XCTAssertThrowsError(try self.profile(expired: true).signingEntitlements(bundleID: "com.example.test"))
    }

    @MainActor
    func testQueueJournalKeepsVersionsButNoCredentials() throws {
        let journal = directory.appendingPathComponent("jobs.json")
        let queue = DownloadQueue(journalURL: journal)
        let account = Account(email: "fixture@example.invalid", name: "Fixture", storeFront: "143441", passwordToken: "NEVER-PERSIST-THIS-TOKEN", directoryServicesID: "123456")
        let destination = directory.appendingPathComponent("app.ipa")
        let id = try queue.enqueue(app: app, account: account, destination: destination, versionID: "42", displayVersion: "1.0")
        XCTAssertThrowsError(try queue.enqueue(app: app, account: account, destination: destination))
        let saved = try String(contentsOf: journal)
        XCTAssertFalse(saved.contains(account.passwordToken))
        XCTAssertFalse(saved.contains("passwordToken"))
        let restored = DownloadQueue(journalURL: journal)
        XCTAssertEqual(restored.jobs.first?.id, id)
        XCTAssertEqual(restored.jobs.first?.versionID, "42")
        var job = restored.jobs[0]; job.state = .downloading
        try JSONEncoder().encode([job]).write(to: journal)
        XCTAssertEqual(DownloadQueue(journalURL: journal).jobs.first?.state, .interrupted)
    }

    func testQueueVersionLabelNeverUsesStoreIDOrLatestForOlderVersions() {
        var job = DownloadJob(app: app, accountEmail: "fixture@example.invalid", storefront: "143441",
            versionID: "891009506", destination: "/fixture.ipa")
        XCTAssertEqual(job.versionLabel, "Version unavailable")
        job.displayVersion = "19.32.0"
        XCTAssertEqual(job.versionLabel, "v19.32.0")
        job.displayVersion = "v19.32.0"
        XCTAssertEqual(job.versionLabel, "v19.32.0")
        job.displayVersion = "891009506"
        XCTAssertEqual(job.versionLabel, "Version unavailable")
        job.displayVersion = nil
        job.versionID = nil
        XCTAssertEqual(job.versionLabel, "v1.0")
    }

    @MainActor
    func testLateMetadataUpdatesOnlyTheMatchingQueuedVersion() throws {
        let journal = directory.appendingPathComponent("late-metadata.json")
        let queue = DownloadQueue(journalURL: journal)
        let account = Account(email: "fixture@example.invalid", name: "Fixture", storeFront: "143441", passwordToken: "fixture", directoryServicesID: "1")
        let id = try queue.enqueue(app: app, account: account, destination: directory.appendingPathComponent("late.ipa"), versionID: "891009506")
        queue.updateDisplayVersion(id, versionID: "different-version", version: "99.0")
        XCTAssertNil(queue.jobs.first?.displayVersion)
        queue.updateDisplayVersion(id, versionID: "891009506", version: "19.32.0")
        XCTAssertEqual(DownloadQueue(journalURL: journal).jobs.first?.versionLabel, "v19.32.0")
    }

    @MainActor
    func testCompletedQueueRestoresVersionFromMatchingDownloadedIPA() async throws {
        let file = try ipa("downloaded-version", version: "19.32.0", bundleName: "App")
        var job = DownloadJob(app: app, accountEmail: "fixture@example.invalid", storefront: "143441",
            versionID: "891009506", destination: file.path)
        job.state = .completed
        let container = try ModelContainer(for: DownloadedApp.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let resolved = try await LibraryRepository.recordDownload(app: app, filePath: file.path, version: "stale metadata",
            externalVersionID: job.versionID, context: container.mainContext)
        XCTAssertEqual(resolved, "19.32.0")
        let journal = directory.appendingPathComponent("completed-version.json")
        try JSONEncoder().encode([job]).write(to: journal)
        let queue = DownloadQueue(journalURL: journal)
        queue.configure(context: container.mainContext, account: nil)
        XCTAssertEqual(queue.jobs.first?.versionLabel, "v19.32.0")
        XCTAssertEqual(DownloadQueue(journalURL: journal).jobs.first?.displayVersion, "19.32.0")
        XCTAssertEqual(queue.jobs.first?.versionID, "891009506")

        // The same path may later contain another version; do not relabel history.
        job.versionID = "another-version"
        try JSONEncoder().encode([job]).write(to: journal)
        let mismatched = DownloadQueue(journalURL: journal)
        mismatched.configure(context: container.mainContext, account: nil)
        XCTAssertEqual(mismatched.jobs.first?.versionLabel, "Version unavailable")
    }

    func testProcessRunnerDrainsBothPipesAndTimesOut() throws {
        let result = try ProcessRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 4000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"])
        XCTAssertGreaterThan(result.output.count, 20000)
        XCTAssertGreaterThan(result.error.count, 20000)
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["3"], timeout: 0.05))
    }

    private func ipa(_ name: String, version: String, bundleName: String) throws -> URL {
        let root = directory.appendingPathComponent(name)
        let bundle = root.appendingPathComponent("Payload/\(bundleName).app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.test", "CFBundleShortVersionString": version], format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        let output = directory.appendingPathComponent(name + ".ipa")
        _ = try ProcessRunner.run("/usr/bin/zip", ["-qr", output.path, "Payload"], directory: root)
        return output
    }

    func testComparisonIgnoresArchiveContainerAndFindsPlistChange() throws {
        let first = try ipa("first", version: "1.0", bundleName: "First")
        let same = try ipa("same", version: "1.0", bundleName: "Renamed")
        let next = try ipa("next", version: "2.0", bundleName: "First")
        XCTAssertTrue(try IPAComparison.compare(left: first, right: same, progress: { _ in }).changes.isEmpty)
        let changes = try IPAComparison.compare(left: first, right: next, progress: { _ in }).changes
        XCTAssertEqual(changes.filter { $0.category == "Info.plist" }.count, 1)
        XCTAssertEqual(changes.first { $0.category == "Info.plist" }?.after, "2.0")
    }

    @MainActor
    func testNetworkHistoryBoundPreservesHeldRequests() throws {
        let model = FridaToolkitVM(appName: "Fixture")
        func send(_ type: String, id: String, body: String = "") throws {
            let data = try JSONSerialization.data(withJSONObject: ["payload": ["type": type, "id": id, "body": body]])
            model.handleNetworkMessage(String(decoding: data, as: UTF8.self))
        }
        try send("request-pending", id: "held")
        for index in 0..<600 { try send("request-log", id: String(index)) }
        XCTAssertEqual(model.networkExchanges.count, 500)
        XCTAssertEqual(model.networkExchanges.first?.id, "held")
        XCTAssertEqual(model.networkExchanges.first?.state, .pendingRequest)
        try send("response-log", id: "599")
        model.clearCompletedNetworkHistory()
        XCTAssertEqual(model.networkExchanges.count, 499)
        XCTAssertFalse(model.networkExchanges.contains { $0.id == "599" })
        try send("request-pending", id: "oversized", body: String(repeating: "a", count: 40000))
        XCTAssertEqual(model.networkExchanges.last?.state, .sent)
        XCTAssertLessThan(model.networkExchanges.last?.body?.utf8.count ?? 0, 33000)
    }

    func testRemoteMetadataRejectsIgnoredRangesAndOversizedDirectory() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for path in ["ignored-range", "large-directory"] {
            do {
                _ = try await PartialZIPReader(url: URL(string: "https://fixture.invalid/" + path)!, session: session).readVersionMetadata()
                XCTFail("Must reject \(path)")
            } catch let error as PartialZIPError {
                switch (path, error) {
                case ("ignored-range", .fileNotFound), ("large-directory", .resourceLimit): break
                default: XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
}

private final class RangeFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let ignored = request.url!.lastPathComponent == "ignored-range"
        let range = request.value(forHTTPHeaderField: "Range")!.dropFirst("bytes=".count)
        let bounds = range.split(separator: "-").compactMap { Int($0) }
        var data = Data(repeating: 0, count: bounds[1] - bounds[0] + 1)
        if data.count == 22 {
            data.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x05, 0x06])
            // A 33 MiB directory fits this remote file but exceeds our 32 MiB limit.
            data.replaceSubrange(12..<16, with: [0x00, 0x00, 0x10, 0x02])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: ignored ? 200 : 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(range)/100000000", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TransferFixtureProtocol: URLProtocol {
    static let payload = Data(repeating: 0x61, count: 256 * 1024)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transfer.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let headers = path == "unknown-length" ? [:] : ["Content-Length": String(Self.payload.count)]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "failure" ? 500 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
