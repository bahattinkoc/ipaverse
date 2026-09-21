import XCTest
@testable import ipaverse

final class MacPackageExportTests: XCTestCase {
    private var directory: URL!
    private let bundleID = "com.example.export-fixture"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func application(at url: URL, identifier: String? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier ?? bundleID, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Fixture", "CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "234"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let binary = url.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data("resource bytes".utf8).write(to: url.appendingPathComponent("Contents/Resources/data.txt"))
        try fm.createSymbolicLink(atPath: url.appendingPathComponent("Contents/Resources/linked.txt").path, withDestinationPath: "data.txt")
    }

    private func package() throws -> URL {
        let root = directory.appendingPathComponent("Root")
        try application(at: root.appendingPathComponent("Fixture.app"))
        let scripts = directory.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let postinstall = scripts.appendingPathComponent("postinstall")
        try Data("#!/bin/sh\ntouch '\(directory.appendingPathComponent("INSTALLER-RAN").path)'\n".utf8).write(to: postinstall)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postinstall.path)
        let pkg = directory.appendingPathComponent("Fixture.pkg")
        _ = try ProcessRunner.run("/usr/bin/pkgbuild", ["--root", root.path, "--identifier", bundleID,
            "--version", "2.3.4", "--install-location", "/Applications", "--scripts", scripts.path, pkg.path])
        return pkg
    }

    func testSettingsKeepLegacyChoiceAndSeparatePlatforms() throws {
        let legacy = Data(#"{"defaultDownloadPath":"/tmp/downloads","defaultDownloadType":"zip","searchHistoryEnabled":false}"#.utf8)
        var settings = try JSONDecoder().decode(SettingsModel.self, from: legacy)
        XCTAssertEqual(settings.defaultDownloadPath, "/tmp/downloads")
        XCTAssertEqual(settings.defaultDownloadType, .zip)
        XCTAssertEqual(settings.defaultMacDownloadType, .pkg)
        XCTAssertFalse(settings.searchHistoryEnabled)
        for format in MacDownloadType.allCases {
            settings.defaultMacDownloadType = format
            let restored = try JSONDecoder().decode(SettingsModel.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.fileExtension(for: .macos), format.rawValue)
            for platform in [AppPlatform.ios, .ipados, .tvos, .visionos] {
                XCTAssertEqual(restored.fileExtension(for: platform), "zip")
            }
        }
        XCTAssertEqual(SettingsModel().fileExtension(for: .ios), "ipa")
    }

    func testAllMacFormatsContainTheCorrectArtifactWithoutInstalling() throws {
        let pkg = try package()
        let original = try Data(contentsOf: pkg)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/app.pkg")!, statusCode: 200,
                                      httpVersion: nil, headerFields: ["Content-Length": "\(original.count)"])!
        for format in MacDownloadType.allCases {
            let destination = directory.appendingPathComponent("Downloaded.\(format.rawValue)")
            var version: String?
            try PackageDownload.finish(temporary: pkg, response: response, destination: destination) { staged in
                try MacPackage.validate(staged)
                version = try MacPackageExport.prepare(staged, format: format, bundleID: bundleID)
            }
            switch format {
            case .pkg:
                XCTAssertEqual(try Data(contentsOf: destination), original)
                XCTAssertNil(version)
            case .app:
                XCTAssertEqual(version, "2.3.4")
                try assertApp(destination)
            case .zip:
                XCTAssertEqual(version, "2.3.4")
                XCTAssertEqual(try Data(contentsOf: destination).prefix(2), Data("PK".utf8))
                let unpacked = directory.appendingPathComponent("Unzipped")
                _ = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", destination.path, unpacked.path])
                try assertApp(unpacked.appendingPathComponent("Fixture.app"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("Source.pkg").path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("INSTALLER-RAN").path))
            try assertNoStaging()
        }
    }

    private func assertApp(_ app: URL) throws {
        XCTAssertEqual(try MacAppBundle.info(at: app)["CFBundleIdentifier"] as? String, bundleID)
        let binary = app.appendingPathComponent("Contents/MacOS/Fixture")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/data.txt")), Data("resource bytes".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Contents/Resources/linked.txt").path), "data.txt")
    }

    func testAtomicAppReplacementAndFailedExportPreservePreviousCopy() throws {
        let pkg = try package()
        let destination = directory.appendingPathComponent("Downloaded.app")
        try application(at: destination)
        let marker = destination.appendingPathComponent("old-copy.txt")
        try Data("keep until commit".utf8).write(to: marker)
        let originalHash = try MacAppBundle.hash(at: destination)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/app.pkg")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": "\(try Data(contentsOf: pkg).count)"])!
        XCTAssertThrowsError(try PackageDownload.finish(temporary: pkg, response: response, destination: destination) { staged in
            _ = try MacPackageExport.prepare(staged, format: .app, bundleID: "com.example.wrong-app")
        })
        XCTAssertEqual(try MacAppBundle.hash(at: destination), originalHash)
        try assertNoStaging()
        try PackageDownload.finish(temporary: pkg, response: response, destination: destination) { staged in
            _ = try MacPackageExport.prepare(staged, format: .app, bundleID: bundleID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try assertApp(destination)
        try assertNoStaging()
    }

    func testMatchingBundleIsSelectedAndDuplicatesAreRejected() throws {
        let first = directory.appendingPathComponent("First.app")
        let unrelated = directory.appendingPathComponent("Other.app")
        try application(at: first)
        try application(at: unrelated, identifier: "com.example.other")
        // Nested helpers are not independent export candidates.
        try application(at: first.appendingPathComponent("Contents/Helpers/Nested.app"))
        XCTAssertEqual(try MacPackageExport.application(in: directory, bundleID: bundleID).resolvingSymlinksInPath().path,
                       first.resolvingSymlinksInPath().path)
        try application(at: directory.appendingPathComponent("Duplicate.app"))
        XCTAssertThrowsError(try MacPackageExport.application(in: directory, bundleID: bundleID)) { error in
            guard case MacPackageExportError.ambiguousApplication = error else { return XCTFail("\(error)") }
        }
    }

    func testExternalLinksAreRejectedAndInternalLinksArePreserved() throws {
        let app = directory.appendingPathComponent("Fixture.app")
        try application(at: app)
        try MacAppBundle.validateContents(at: app)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/escape").path, withDestinationPath: "../../outside")
        XCTAssertThrowsError(try MacAppBundle.validateContents(at: app)) { error in
            guard case MacPackageExportError.unsafeLink = error else { return XCTFail("\(error)") }
        }
    }

    func testBundleSizeAndHashAreIndependentOfDestinationName() throws {
        let first = directory.appendingPathComponent("One.app")
        let second = directory.appendingPathComponent("Different name.app")
        try application(at: first)
        try FileManager.default.copyItem(at: first, to: second)
        XCTAssertGreaterThan(try MacAppBundle.size(at: first), 30)
        XCTAssertEqual(try MacAppBundle.size(at: first), try MacAppBundle.size(at: second))
        XCTAssertEqual(try MacAppBundle.hash(at: first), try MacAppBundle.hash(at: second))
        try Data("changed".utf8).write(to: second.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertNotEqual(try MacAppBundle.hash(at: first), try MacAppBundle.hash(at: second))
    }

    func testCancelledAppReplacementPreservesOriginal() async throws {
        let source = directory.appendingPathComponent(".ipaverse-staged.app")
        let destination = directory.appendingPathComponent("Saved.app")
        try application(at: source)
        try application(at: destination, identifier: "com.example.original")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AtomicFile.commit(source, to: destination)
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try MacAppBundle.info(at: destination)["CFBundleIdentifier"] as? String, "com.example.original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func assertNoStaging() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".ipaverse-") })
    }
}
