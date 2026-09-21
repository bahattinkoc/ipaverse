import XCTest
@testable import ipaverse

final class MacPackageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-package-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func package() throws -> Data {
        _ = try file("Payload", Data("fixture package payload for checksum verification".utf8))
        let url = directory.appendingPathComponent("fixture.pkg")
        _ = try ProcessRunner.run("/usr/bin/xar", ["--compression=none", "-cf", url.path, "Payload"], directory: directory)
        return try Data(contentsOf: url)
    }

    func testDPInfoAndUniversalMacMetadata() throws {
        let dp = Data([1, 2, 3])
        for sinfs in [[["dpInfo": dp]], [["dpInfo": Data()], ["dpInfo": dp], ["dpInfo": dp]],
                      [["dpInfo": dp, "sinf": Data([9])]]] {
            let item: [String: Any] = ["sinfs": sinfs, "metadata": ["software-platform": "macOS", "product-type": "ios-app"]]
            XCTAssertEqual(try MacPackage.dpInfo(from: item), dp)
        }
        for item in [[:], ["sinfs": [["dpInfo": Data()]]]] as [[String: Any]] {
            XCTAssertThrowsError(try MacPackage.dpInfo(from: item)) { error in
                guard case MacPackageError.missingDPInfo = error else { return XCTFail("\(error)") }
            }
        }
        for item in [
            ["sinfs": [["dpInfo": dp], ["dpInfo": Data([9])]]],
            ["sinfs": [["dpInfo": dp], ["sinf": Data([8])]]],
            ["sinfs": [["dpInfo": dp]], "metadata": ["software-platform": "ios"]],
            ["sinfs": [["dpInfo": dp]], "metadata": ["product-type": "ios-app"]]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try MacPackage.dpInfo(from: item)) { error in
                guard case MacPackageError.conflictingMetadata = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testHardwareIdentityUsesRequestGUID() throws {
        XCTAssertEqual(try MacPackage.hardwareID(guid: "001a2B3c4Dff"), [0, 26, 43, 60, 77, 255])
        for guid in ["", "0", "00:11:22:33:44:55", "123xyz", "001122ZZ", String(repeating: "0", count: 42)] {
            XCTAssertThrowsError(try MacPackage.hardwareID(guid: guid))
        }
    }

    func testStoreAgentRejectsUnverifiedImageBeforeEmulation() throws {
        let empty = SAPAssetBundle(commerceKit: Data(), commerceCore: Data(), coreFP: Data(), coreFPICXS: Data())
        for data in [Data(), Data(repeating: 0, count: 2580176)] {
            XCTAssertThrowsError(try SAPStoreAgent(bundle: empty, image: data, hardwareID: [1], dpInfo: Data([1]))) { error in
                guard case SAPAssetsError.integrityCheckFailed("storeagent") = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testStreamFillsShortReadsAndPreservesFinalPartialBlock() throws {
        for size in [0, 17, MacPackage.chunkSize, MacPackage.chunkSize * 2 + 17] {
            var remaining = size
            var sizes: [Int] = []
            var output = Data()
            try MacPackage.decryptStream(read: { limit in
                let count = min(remaining, min(limit, 137))
                remaining -= count
                return Data(repeating: 0x3c, count: count)
            }, write: { output.append($0) }, decrypt: { block in
                sizes.append(block.count)
                return Data(block.map { $0 ^ 0xff })
            })
            let full = Array(repeating: MacPackage.chunkSize, count: size / MacPackage.chunkSize)
            XCTAssertEqual(sizes, full + (size % MacPackage.chunkSize == 0 ? [] : [size % MacPackage.chunkSize]))
            XCTAssertEqual(output, Data(repeating: 0xc3, count: size))
        }
    }

    func testStreamErrorsDoNotWriteFailedBlock() throws {
        for outcome in ["read", "decrypt", "length", "write"] {
            var writes = 0
            XCTAssertThrowsError(try MacPackage.decryptStream(read: { limit in
                if outcome == "read" { throw CocoaError(.fileReadUnknown) }
                return Data(repeating: 1, count: limit)
            }, write: { _ in
                writes += 1
                throw CocoaError(.fileWriteUnknown)
            }, decrypt: { block in
                if outcome == "decrypt" { throw CocoaError(.fileReadCorruptFile) }
                return outcome == "length" ? Data() : block
            }))
            XCTAssertEqual(writes, outcome == "write" ? 1 : 0)
        }
    }

    func testCancellationStopsDecryptionBeforeWriting() async throws {
        let task = Task {
            try MacPackage.decryptStream(read: { Data(repeating: 1, count: $0) }, write: { _ in
                XCTFail("Cancelled block must not be written")
            }, decrypt: { block in
                withUnsafeCurrentTask { $0?.cancel() }
                return block
            })
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    func testXARValidationChecksPayloadIntegrity() throws {
        let data = try package()
        try MacPackage.validate(file("valid.pkg", data))
        var corrupt = data
        let range = try XCTUnwrap(corrupt.range(of: Data("fixture package payload".utf8)))
        corrupt[range.lowerBound] ^= 0xff
        for invalid in [corrupt, Data(data.dropLast(5)), Data("xar!invalid".utf8), Data("<html>error</html>".utf8)] {
            XCTAssertThrowsError(try MacPackage.validate(file("invalid.pkg", invalid)))
        }
    }

    func testDecryptedPackageCommitsOnlyAfterCloseAndValidation() throws {
        let expected = try package()
        let incoming = try file("encrypted", Data(expected.map { $0 ^ 0xff }))
        let original = Data("previous package".utf8)
        let destination = try file("app.pkg", original)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/app.pkg")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": "\(expected.count)"])!
        var closed = false
        try PackageDownload.finish(temporary: incoming, response: response, destination: destination) { staged in
            try MacPackage.decryptStaged(staged, decrypt: { Data($0.map { $0 ^ 0xff }) }, close: {
                XCTAssertEqual(try Data(contentsOf: destination), original)
                closed = true
            })
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".ipaverse-") })
    }

    func testPreparationFailuresPreserveOriginalAndCleanStaging() throws {
        let expected = try package()
        let incoming = try file("encrypted", Data(expected.map { $0 ^ 0xff }))
        let original = Data("previous package".utf8)
        let destination = try file("app.pkg", original)
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/app.pkg")!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Length": "\(expected.count)"])!
        for failure in ["decrypt", "close", "integrity"] {
            XCTAssertThrowsError(try PackageDownload.finish(temporary: incoming, response: response, destination: destination) { staged in
                try MacPackage.decryptStaged(staged, decrypt: {
                    if failure == "decrypt" { throw CocoaError(.fileReadCorruptFile) }
                    return failure == "integrity" ? $0 : Data($0.map { $0 ^ 0xff })
                }, close: {
                    if failure == "close" { throw CocoaError(.fileWriteUnknown) }
                })
            })
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".ipaverse-") })
        }
    }
}
