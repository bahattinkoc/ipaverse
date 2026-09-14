import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ipaverse

final class IPAComparisonTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("comparison-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, bundleID: String? = "com.example.compare", prepare: (URL) throws -> Void = { _ in }) throws -> URL {
        let root = directory.appendingPathComponent(name)
        let app = root.appendingPathComponent("Payload/\(name).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var plist = ["CFBundleName": "Fixture", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "10"]
        plist["CFBundleIdentifier"] = bundleID
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try prepare(app)
        let archive = directory.appendingPathComponent(name + ".ipa")
        _ = try ProcessRunner.run("/usr/bin/zip", ["-qr", archive.path, "Payload"], directory: root)
        return archive
    }

    func testRejectsDifferentAndMissingBundleIDsFromActualArchives() throws {
        let a = try fixture("a")
        for b in [try fixture("different", bundleID: "com.example.other"), try fixture("missing", bundleID: nil), try fixture("blank", bundleID: " ")] {
            XCTAssertThrowsError(try IPAComparison.compare(left: a, right: b, progress: { _ in })) { error in
                XCTAssertTrue(error is IPAComparisonError)
            }
        }
    }

    func testTypedStructuralDiffAndSetOrdering() {
        var a = IPAComparison.Snapshot(), b = IPAComparison.Snapshot()
        IPAComparison.flatten(["get-task-allow": false, "com.apple.security.application-groups": ["group.a", "group.b"], "nested/key": ["enabled": true], "number": 1] as [String: Any], category: "Entitlements", source: "App", into: &a)
        IPAComparison.flatten(["get-task-allow": true, "com.apple.security.application-groups": ["group.b", "group.a"], "nested/key": ["enabled": true], "number": "1"] as [String: Any], category: "Entitlements", source: "App", into: &b)
        let report = IPAComparison.diff(a, b, leftName: "A", rightName: "B")
        XCTAssertEqual(report.changes.count, 2)
        let entitlement = report.changes.first { $0.path == "/get-task-allow" }
        XCTAssertEqual(entitlement?.before, "false")
        XCTAssertEqual(entitlement?.after, "true")
        XCTAssertEqual(report.changes.first { $0.path == "/number" }?.valueType, "number → string")
        XCTAssertTrue(report.rows.contains { $0.path == "/nested~1key/enabled" })
    }

    func testFailedAndEncryptedPassesNeverBecomeRemovedRows() {
        var a = IPAComparison.Snapshot(), b = IPAComparison.Snapshot()
        a.add("Classes", "App [arm64] / Methods", "Class/method", "method")
        a.add("Symbols", "App [arm64]", "Imported/function", "function")
        b.status("Classes", "App [arm64]", "Encrypted", "cryptid=1")
        b.status("Symbols", "App", "Failed", "tool unavailable")
        let report = IPAComparison.diff(a, b, leftName: "A", rightName: "B")
        XCTAssertTrue(report.changes.isEmpty)
        XCTAssertEqual(report.rows.map(\.kind), ["Not compared", "Not compared"])
    }

    func testLoadCommandIdentitySurvivesInsertedDependency() {
        let a = """
        /temporary/A/App:
        Load command 0
                  cmd LC_LOAD_DYLIB
              cmdsize 64
                 name @rpath/First.framework/First (offset 24)
        Load command 1
                  cmd LC_UUID
              cmdsize 24
                 uuid AAAA
        """
        let b = """
        /temporary/B/App:
        Load command 0
                  cmd LC_LOAD_DYLIB
              cmdsize 64
                 name @rpath/New.framework/New (offset 24)
        Load command 1
                  cmd LC_LOAD_DYLIB
              cmdsize 64
                 name @rpath/First.framework/First (offset 24)
        Load command 2
                  cmd LC_UUID
              cmdsize 24
                 uuid AAAA
        """
        let first = IPAComparison.parseLoadCommands(a), second = IPAComparison.parseLoadCommands(b)
        XCTAssertFalse(first.isEmpty)
        for (key, value) in first { XCTAssertEqual(second[key], value) }
        XCTAssertEqual(second["LC_UUID/uuid"], "AAAA")
        XCTAssertEqual(second.count - first.count, 2)
    }

    func testResourcesDeepInventoryAndRawFileHashRemainIndependent() throws {
        let a = try fixture("resourcesA") { app in
            try Data(#"{"host":"https://old.example.com/v1","enabled":false}"#.utf8).write(to: app.appendingPathComponent("config.json"))
            try Data("hello\nold\n".utf8).write(to: app.appendingPathComponent("notes.txt"))
        }
        let b = try fixture("resourcesB") { app in
            try Data(#"{"enabled":true,"host":"https://new.example.com/v2"}"#.utf8).write(to: app.appendingPathComponent("config.json"))
            try Data("hello\nnew\n".utf8).write(to: app.appendingPathComponent("notes.txt"))
        }
        let report = try IPAComparison.compare(left: a, right: b, deep: true, progress: { _ in })
        XCTAssertTrue(report.deepAnalysis)
        XCTAssertEqual(report.changes.first { $0.category == "Resources" && $0.path == "/enabled" }?.after, "true")
        XCTAssertTrue(report.changes.contains { $0.category == "Endpoints" && $0.kind == "Added" && $0.after == "https://new.example.com/v2" })
        XCTAssertTrue(report.changes.contains { $0.category == "Files" && $0.source == "config.json" })
        XCTAssertTrue(report.changes.contains { $0.category == "Resources" && $0.source == "notes.txt" && $0.valueType == "text" })
        let decoded = try JSONDecoder().decode(IPAComparisonReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.rows.count, report.rows.count)
        XCTAssertEqual(decoded.left.bundleID, "com.example.compare")
    }

    func testJSONFormattingDoesNotProduceStructuralChanges() throws {
        let a = try fixture("formatA") { try Data(#"{"a":1,"b":2}"#.utf8).write(to: $0.appendingPathComponent("config.json")) }
        let b = try fixture("formatB") { try Data("{\n  \"b\": 2,\n  \"a\": 1\n}".utf8).write(to: $0.appendingPathComponent("config.json")) }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        XCTAssertFalse(report.changes.contains { $0.category == "Resources" })
        XCTAssertTrue(report.changes.contains { $0.category == "Files" && $0.source == "config.json" })
        XCTAssertEqual(report.leftCoverage.first { $0.category == "Classes" }?.state, "Skipped")
    }

    func testMalformedResourceIsUnknownNotRemoved() throws {
        let a = try fixture("valid") { try Data(#"{"a":1}"#.utf8).write(to: $0.appendingPathComponent("config.json")) }
        let b = try fixture("invalid") { try Data("broken JSON".utf8).write(to: $0.appendingPathComponent("config.json")) }
        let report = try IPAComparison.compare(left: a, right: b, deep: true, progress: { _ in })
        XCTAssertEqual(report.rows.first { $0.category == "Resources" }?.kind, "Not compared")
        XCTAssertEqual(report.rightCoverage.first { $0.category == "Resources" }?.state, "Failed")
    }

    func testLineDiffPreservesContextAndDirection() {
        XCTAssertEqual(ComparisonTextDiff.render(before: "same\nold\nend", after: "same\nnew\nend"), "  same\n− old\n+ new\n  end")
        XCTAssertEqual(ComparisonTextDiff.render(before: nil, after: "added"), "+ added")
        XCTAssertEqual(ComparisonTextDiff.render(before: "removed", after: nil), "− removed")
    }

    func testPartialCoverageIsPreserved() throws {
        var snapshot = IPAComparison.Snapshot()
        try snapshot.capture("Security findings", "*") { result in
            result.status("Security findings", "*", "Partial", "tool failed")
        }
        XCTAssertEqual(snapshot.coverage["Security findings|*"]?.state, "Partial")
    }

    func testProvisioningProfileAndCertificateMetadata() throws {
        let key = directory.appendingPathComponent("key.pem")
        let certificate = directory.appendingPathComponent("certificate.pem")
        let der = directory.appendingPathComponent("certificate.der")
        _ = try ProcessRunner.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path,
            "-out", certificate.path, "-subj", "/CN=IPACompareFixture", "-days", "1"])
        _ = try ProcessRunner.run("/usr/bin/openssl", ["x509", "-in", certificate.path, "-outform", "DER", "-out", der.path])
        let data = try Data(contentsOf: der)
        let plist: [String: Any] = ["UUID": "fixture-profile", "Name": "Fixture", "TeamIdentifier": ["FIXTURE"],
            "ExpirationDate": Date(timeIntervalSince1970: 2_000_000_000), "ProvisionedDevices": ["device-b", "device-a"],
            "Entitlements": ["application-identifier": "FIXTURE.com.example.compare", "get-task-allow": true],
            "DeveloperCertificates": [data]]
        let content = directory.appendingPathComponent("profile.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: content)
        let profile = directory.appendingPathComponent("embedded.mobileprovision")
        _ = try ProcessRunner.run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-nodetach", "-in", content.path,
            "-signer", certificate.path, "-inkey", key.path, "-outform", "DER", "-out", profile.path])
        var snapshot = IPAComparison.Snapshot()
        try IPAComparison.profile(profile, source: "embedded.mobileprovision", into: &snapshot)
        let values = Array(snapshot.values.values)
        XCTAssertTrue(values.contains { $0.path == "Profile type (inferred)" && $0.text == "Development" })
        XCTAssertTrue(values.contains { $0.path == "/Entitlements/get-task-allow" && $0.text == "true" })
        XCTAssertTrue(values.contains { $0.path.hasSuffix("/SHA-256") && $0.text == IPAComparison.hash(data) })
        XCTAssertTrue(values.contains { $0.path.hasSuffix("/Not Before") })
        XCTAssertTrue(values.contains { $0.path.hasSuffix("/Not After") })
    }

    @MainActor
    func testSwapReversesValuesDirectionAndCoverage() {
        var a = IPAComparison.Snapshot(), b = IPAComparison.Snapshot()
        a.add("Resources", "config", "/old", "old")
        b.add("Resources", "config", "/new", "new")
        a.status("Resources", "config")
        b.status("Resources", "config")
        a.fileSizes["config"] = 10
        b.fileSizes["config"] = 30
        let model = IPAComparisonVM()
        model.report = IPAComparison.diff(a, b, leftName: "A", rightName: "B")
        model.swap()
        XCTAssertEqual(model.report?.leftName, "B")
        XCTAssertEqual(model.report?.changes.first { $0.path == "/new" }?.kind, "Removed")
        XCTAssertEqual(model.report?.changes.first { $0.path == "/old" }?.after, "old")
        XCTAssertEqual(model.report?.fileSizes.first?.delta, -20)
    }

    func testRealMachOEntitlementsSymbolsClassesAndStrings() throws {
        func binary(_ name: String, method: String, debug: Bool) throws -> URL {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("fixture.m")
            let code = """
            #import <Foundation/Foundation.h>
            @interface CompareFixture : NSObject
            - (const char *)\(method);
            @end
            @implementation CompareFixture
            - (const char *)\(method) { return "https://\(method).example.com/api"; }
            @end
            int \(method)(void) { return 42; }
            """
            try Data(code.utf8).write(to: source)
            let binary = folder.appendingPathComponent("Fixture")
            _ = try ProcessRunner.run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-dynamiclib", "-framework", "Foundation", source.path, "-o", binary.path, "-Wl,-install_name,@rpath/Fixture"], timeout: 60)
            let entitlements = folder.appendingPathComponent("entitlements.plist")
            try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": debug], format: .xml, options: 0).write(to: entitlements)
            _ = try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, binary.path])
            return binary
        }
        let first = try binary("binaryA", method: "oldMethod", debug: false)
        let second = try binary("binaryB", method: "newMethod", debug: true)
        let a = try fixture("machoA") { try FileManager.default.copyItem(at: first, to: $0.appendingPathComponent("Fixture")) }
        let b = try fixture("machoB") { try FileManager.default.copyItem(at: second, to: $0.appendingPathComponent("Fixture")) }
        let report = try IPAComparison.compare(left: a, right: b, deep: true, progress: { _ in })
        XCTAssertEqual(report.leftCoverage.first { $0.category == "Mach-O" }?.state, "Complete")
        XCTAssertEqual(report.leftCoverage.first { $0.category == "Signing" }?.state, "Complete")
        XCTAssertEqual(report.changes.first { $0.category == "Entitlements" && $0.path == "/get-task-allow" }?.after, "true")
        XCTAssertTrue(report.changes.contains { $0.category == "Symbols" && $0.after == "_newMethod" && $0.kind == "Added" })
        XCTAssertTrue(report.rows.contains { $0.category == "Classes" && $0.path == "Classes/CompareFixture" })
        XCTAssertTrue(report.changes.contains { $0.category == "Classes" && $0.path == "Selectors/newMethod" && $0.kind == "Added" })
        XCTAssertTrue(report.changes.contains { $0.category == "Endpoints" && $0.after == "https://newMethod.example.com/api" })
        XCTAssertTrue(report.rows.contains { $0.uuid })
        XCTAssertFalse(report.rows.contains { $0.category == "Mach-O" && ($0.before?.contains("ipaverse-compare-") == true || $0.after?.contains("ipaverse-compare-") == true) })
    }
}

extension IPAComparisonTests {
    func testSelectingInfoPlistExposesNestedValuesInsteadOfHash() throws {
        func edit(_ app: URL, next: Bool) throws {
            let file = app.appendingPathComponent("Info.plist")
            var plist = try XCTUnwrap(IPAComparison.readPlist(file) as? [String: Any])
            plist["CFBundleShortVersionString"] = next ? "2.0" : "1.0"
            plist["NSAppTransportSecurity"] = ["NSAllowsArbitraryLoads": next]
            plist["Custom"] = ["retries": next ? 5 : 2, "endpoint": next ? "https://new.example.com" : "https://old.example.com"] as [String: Any]
            plist["Blob"] = Data(next ? [0x10, 0x20] : [0x30, 0x40])
            try PropertyListSerialization.data(fromPropertyList: plist, format: next ? .binary : .xml, options: 0).write(to: file)
        }
        let a = try fixture("infoA") { try edit($0, next: false) }
        let b = try fixture("infoB") { try edit($0, next: true) }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        let content = try XCTUnwrap(IPAComparisonPresentation.contentIndex(report)["Info.plist"])
        XCTAssertEqual(content.first { $0.path == "/NSAppTransportSecurity/NSAllowsArbitraryLoads" }?.before, "false")
        XCTAssertEqual(content.first { $0.path == "/NSAppTransportSecurity/NSAllowsArbitraryLoads" }?.after, "true")
        XCTAssertEqual(content.first { $0.path == "/Custom/retries" }?.before, "2")
        XCTAssertEqual(content.first { $0.path == "/Custom/retries" }?.after, "5")
        XCTAssertEqual(content.first { $0.path == "/Blob" }?.after, Data([0x10, 0x20]).base64EncodedString())
        XCTAssertFalse(content.contains { $0.category == "Files" || $0.category == "Components" })
        let file = try XCTUnwrap(report.changes.first { $0.category == "Files" && $0.source == "Info.plist" })
        let summary = IPAComparisonPresentation.fileValue(file, content: content, before: false)
        XCTAssertFalse(summary.contains("SHA-256"))
        XCTAssertTrue(summary.contains("CFBundleShortVersionString: 2.0"))
        let exported = IPAComparisonPresentation.includingFileContent([file], index: IPAComparisonPresentation.contentIndex(report))
        XCTAssertTrue(exported.contains { $0.category == "Info.plist" && $0.path == "/Custom/retries" && $0.after == "5" })
    }

    func testContentDetectionHandlesExtensionlessJSONBinaryPlistAndUTF16Strings() throws {
        func resources(_ app: URL, next: Bool) throws {
            try Data("{\"feature\":\(next ? "true" : "false")}".utf8).write(to: app.appendingPathComponent("settings"))
            try PropertyListSerialization.data(fromPropertyList: ["endpoint": next ? "new" : "old"], format: .binary, options: 0)
                .write(to: app.appendingPathComponent("settings.dat"))
            try XCTUnwrap("\"welcome\" = \"\(next ? "Merhaba" : "Hello")\";".data(using: .utf16))
                .write(to: app.appendingPathComponent("Localizable.strings"))
            try Data("FEATURE=\(next ? "enabled" : "disabled")\n".utf8).write(to: app.appendingPathComponent(".env"))
        }
        let a = try fixture("detectionA") { try resources($0, next: false) }
        let b = try fixture("detectionB") { try resources($0, next: true) }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        let index = IPAComparisonPresentation.contentIndex(report)
        XCTAssertEqual(index["settings"]?.first { $0.path == "/feature" }?.after, "true")
        XCTAssertEqual(index["settings.dat"]?.first { $0.path == "/endpoint" }?.after, "new")
        XCTAssertEqual(index["Localizable.strings"]?.first { $0.path == "/welcome" }?.after, "Merhaba")
        XCTAssertEqual(index[".env"]?.first?.after, "FEATURE=enabled\n")
    }

    func testOpaqueFileShowsActualChangedBytesAtOffset() throws {
        let a = try fixture("opaqueA") { try Data(repeating: 0, count: 128).write(to: $0.appendingPathComponent("asset.bin")) }
        let b = try fixture("opaqueB") {
            var bytes = Data(repeating: 0, count: 128)
            bytes[72] = 0xfe
            try bytes.write(to: $0.appendingPathComponent("asset.bin"))
        }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        let content = try XCTUnwrap(IPAComparisonPresentation.contentIndex(report)["asset.bin"])
        let difference = try XCTUnwrap(content.first { $0.category == "Binary content" })
        XCTAssertEqual(difference.path, "Bytes @ 0x00000040")
        XCTAssertEqual(difference.kind, "Changed")
        XCTAssertTrue(difference.after?.contains("FE") == true)
        XCTAssertFalse(difference.before?.contains("FE") == true)
    }

    func testTextPreviewShowsChangedLineBeyondCommonHeader() {
        let common = (1...100).map { "common \($0)" }.joined(separator: "\n")
        let before = common + "\nFEATURE=old\nfooter"
        let after = common + "\nFEATURE=new\nfooter"
        XCTAssertEqual(ComparisonTextDiff.preview(before: before, after: after, beforeSide: true), "FEATURE=old")
        XCTAssertEqual(ComparisonTextDiff.preview(before: before, after: after, beforeSide: false), "FEATURE=new")
        let lines = ComparisonTextDiff.contextLines(before: before, after: after)
        XCTAssertTrue(lines.contains("− FEATURE=old"))
        XCTAssertTrue(lines.contains("+ FEATURE=new"))
        XCTAssertLessThan(lines.count, 15)
    }
}

extension IPAComparisonTests {
    func testLongTextDiffTrimsCommonRegionBeforeApplyingLimit() {
        let prefix = (0..<5000).map { "common \($0)" }.joined(separator: "\n")
        let before = prefix + "\nold\nend", after = prefix + "\nnew\nend"
        let lines = ComparisonTextDiff.contextLines(before: before, after: after)
        XCTAssertTrue(lines.contains("− old"))
        XCTAssertTrue(lines.contains("+ new"))
        XCTAssertLessThan(lines.count, 15)
        let oversized = String(repeating: "x", count: 300_000)
        XCTAssertEqual(ComparisonTextDiff.preview(before: oversized, after: "changed", beforeSide: false), "changed")
    }

    func testImagePixelChangeProducesBeforeAndAfterPreviews() throws {
        func writeImage(_ app: URL, red: CGFloat) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(app.appendingPathComponent("icon.png") as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let a = try fixture("imageA") { try writeImage($0, red: 0.2) }
        let b = try fixture("imageB") { try writeImage($0, red: 0.9) }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        let preview = try XCTUnwrap(report.previews.first { $0.source == "icon.png" })
        XCTAssertNotNil(preview.before)
        XCTAssertNotNil(preview.after)
        XCTAssertNotEqual(preview.before, preview.after)
        XCTAssertTrue(report.rows.contains { $0.source == "icon.png" && $0.path == "/Image/PixelWidth" && $0.after == "8" })
        let decoded = try JSONDecoder().decode(IPAComparisonReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.previews.first?.after, preview.after)
        XCTAssertEqual(decoded.fileSizes, report.fileSizes)
        XCTAssertEqual(report.fileSizes.reduce(0) { $0 + ($1.before ?? 0) }, report.left.extractedBytes)
        XCTAssertEqual(report.fileSizes.reduce(0) { $0 + ($1.after ?? 0) }, report.right.extractedBytes)
    }
}

extension IPAComparisonTests {
    private func assetRecord(_ name: String, scale: Int = 1, appearance: String? = nil, digest: String = "pixels-a", state: String = "Complete") -> [String: Any] {
        var variant: [String: Any] = ["Scale": scale]
        variant["Appearance"] = appearance
        return ["Name": name, "Variant": variant, "Digest": digest, "State": state, "Preview": Data([1, 2, 3]),
            "Metadata": ["Kind": "Image", "PixelWidth": 16 * scale, "PixelHeight": 16 * scale, "RenditionType": 0]]
    }

    private func assetSnapshot(_ records: [[String: Any]]) throws -> IPAComparison.Snapshot {
        var snapshot = IPAComparison.Snapshot()
        for entry in try IPAComparisonAssets.parse(records, source: "Assets.car") { snapshot.assetEntries[entry.id] = entry }
        snapshot.status("Asset catalogs", "Assets.car")
        return snapshot
    }

    func testCatalogMatchesNameScaleAndAppearanceWithoutCrossPairing() throws {
        let a = try assetSnapshot([assetRecord("icon"), assetRecord("icon", scale: 2), assetRecord("icon", appearance: "Dark"), assetRecord("old")])
        let b = try assetSnapshot([assetRecord("new"), assetRecord("icon", appearance: "Dark", digest: "dark-changed"),
            assetRecord("icon", scale: 2), assetRecord("icon", digest: "pixels-changed")])
        let assets = IPAComparisonAssets.compare(a, b)
        XCTAssertEqual(assets.count, 5)
        XCTAssertEqual(assets.filter { $0.kind == "Changed" }.count, 2)
        XCTAssertEqual(assets.first { $0.name == "icon" && $0.variant.contains("@2x") }?.kind, "Unchanged")
        XCTAssertEqual(assets.first { $0.name == "old" }?.kind, "Removed")
        XCTAssertEqual(assets.first { $0.name == "new" }?.kind, "Added")
        let report = IPAComparison.diff(a, b, leftName: "A", rightName: "B")
        XCTAssertEqual(report.assets.count, 5)
        XCTAssertEqual(report.rows.filter { $0.category == "Asset catalogs" }.count, 5)
        let decoded = try JSONDecoder().decode(IPAComparisonReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.assets.first?.before?.preview, report.assets.first?.before?.preview)
        XCTAssertFalse(report.rows.contains { $0.valueType == "hex bytes" })
    }

    func testCatalogIgnoresAtlasPackingAndRejectsAmbiguousVariants() throws {
        let records = [assetRecord("icon"), assetRecord("ZZZZPackedAsset-1.1.0"), assetRecord("icon")]
        XCTAssertEqual(try IPAComparisonAssets.parse(records, source: "Assets.car").count, 1)
        XCTAssertThrowsError(try IPAComparisonAssets.parse([assetRecord("icon"), assetRecord("icon", digest: "other")], source: "Assets.car"))
    }

    func testUnreadableCatalogDoesNotReportAssetsAsRemoved() throws {
        let a = try assetSnapshot([assetRecord("icon")])
        var b = IPAComparison.Snapshot()
        b.status("Asset catalogs", "Assets.car", "Failed", "Unsupported catalog")
        XCTAssertEqual(IPAComparisonAssets.compare(a, b).first?.kind, "Not compared")
        let unavailable = try assetSnapshot([assetRecord("icon", state: "Unavailable")])
        XCTAssertEqual(IPAComparisonAssets.compare(a, unavailable).first?.kind, "Not compared")
    }

    @MainActor
    func testAssetSwapReversesPreviewAndAddedRemovedStates() throws {
        let a = try assetSnapshot([assetRecord("old")]), b = try assetSnapshot([assetRecord("new")])
        let model = IPAComparisonVM()
        model.report = IPAComparison.diff(a, b, leftName: "A", rightName: "B")
        model.swap()
        let old = try XCTUnwrap(model.report?.assets.first { $0.name == "old" })
        XCTAssertEqual(old.kind, "Added")
        XCTAssertNil(old.before)
        XCTAssertNotNil(old.after?.preview)
        XCTAssertEqual(model.report?.rows.first { $0.id == old.rowID }?.kind, "Added")
    }

    func testCompiledCatalogProducesVisualChangesWithoutHexRows() throws {
        func catalog(_ name: String, color: String) throws -> URL {
            let root = directory.appendingPathComponent(name)
            let source = root.appendingPathComponent("Fixture.xcassets")
            let vector = source.appendingPathComponent("icon.imageset")
            let output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: vector, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let contents: [String: Any] = ["info": ["version": 1, "author": "xcode"],
                "images": [["idiom": "universal", "filename": "icon.svg"]], "properties": ["preserves-vector-representation": true]]
            try JSONSerialization.data(withJSONObject: contents).write(to: vector.appendingPathComponent("Contents.json"))
            try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\" fill=\"\(color)\"/></svg>".utf8)
                .write(to: vector.appendingPathComponent("icon.svg"))
            _ = try ProcessRunner.run("/usr/bin/xcrun", ["actool", source.path, "--compile", output.path, "--platform", "macosx",
                "--minimum-deployment-target", "14.0", "--target-device", "mac", "--output-format", "human-readable-text"], timeout: 60)
            return output.appendingPathComponent("Assets.car")
        }
        let first = try catalog("catalogA", color: "red"), second = try catalog("catalogB", color: "blue")
        let a = try fixture("catalogIPA-A") { try FileManager.default.copyItem(at: first, to: $0.appendingPathComponent("Assets.car")) }
        let b = try fixture("catalogIPA-B") { try FileManager.default.copyItem(at: second, to: $0.appendingPathComponent("Assets.car")) }
        let report = try IPAComparison.compare(left: a, right: b, progress: { _ in })
        let asset = try XCTUnwrap(report.assets.first { $0.name == "icon" && $0.kind == "Changed" })
        XCTAssertNotNil(asset.before?.preview)
        XCTAssertNotNil(asset.after?.preview)
        XCTAssertNotEqual(asset.before?.digest, asset.after?.digest)
        XCTAssertFalse(report.rows.contains { $0.source == "Assets.car" && $0.category == "Binary content" })
        XCTAssertTrue(IPAComparisonPresentation.contentIndex(report)["Assets.car"]?.contains { $0.id == asset.rowID } == true)
    }
}
