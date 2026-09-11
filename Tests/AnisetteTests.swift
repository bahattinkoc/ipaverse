import Foundation

private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private struct Failure: Error { let message: String }
private let testServer = URL(string: "https://anisette.example.invalid:8443/service")!
private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func plist(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}
private func fixtureHeaders(_ otp: String = "otp") -> [String: String] {
    ["X-Apple-I-MD": otp, "X-Apple-I-MD-M": "machine", "X-Apple-I-MD-LU": "local-user",
     "X-Apple-I-MD-RINFO": "17106176", "X-Mme-Device-Id": "device", "X-Mme-Client-Info": AnisetteClientInfo.current]
}

private final class MemoryStore: AnisetteIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: AnisetteIdentity] = [:]
    var readError: AnisetteError?
    func load(server: URL) throws -> AnisetteIdentity? {
        try lock.withLock {
            if let readError { throw readError }
            return values[server]
        }
    }
    func save(_ identity: AnisetteIdentity) throws { lock.withLock { values[identity.server] = identity } }
}

private actor RemoteMock: AnisetteRemoteSource {
    private(set) var provisionCount = 0
    private(set) var headerCount = 0
    var failHeaders = false
    func setFailure() { failHeaders = true }
    func provision(server: URL) async throws -> AnisetteIdentity {
        provisionCount += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        return AnisetteIdentity(version: 1, server: server, localUserID: "remote-user",
                                deviceID: UUID().uuidString, clientInfo: "remote-client", provisioningData: "saved-adi")
    }
    func headers(for identity: AnisetteIdentity) async throws -> [String: String] {
        headerCount += 1
        if failHeaders { throw AnisetteError.http(503) }
        var result = fixtureHeaders("remote-\(headerCount)")
        result["X-Apple-I-MD-LU"] = identity.localUserID
        result["X-Mme-Device-Id"] = identity.deviceID
        result["X-Mme-Client-Info"] = identity.clientInfo
        return result
    }
}

private final class SocketMock: AnisetteSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data]
    private var outgoing: [Data] = []
    private var cancelled = false
    private var waiter: CheckedContinuation<Data, Error>?
    var sent: [Data] { lock.withLock { outgoing } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    init(_ messages: [[String: Any]]) throws { self.messages = try messages.map(json) }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if cancelled { continuation.resume(throwing: URLError(.cancelled)) }
                else if !messages.isEmpty { continuation.resume(returning: messages.removeFirst()) }
                else { waiter = continuation }
            }
        }
    }
    func send(_ data: Data) async throws { lock.withLock { outgoing.append(data) } }
    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.resume(throwing: URLError(.cancelled))
    }
}

private final class TransportMock: AnisetteTransport, @unchecked Sendable {
    let connection: SocketMock
    let response: @Sendable (URLRequest) throws -> Data
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var socketURL: URL?
    var requests: [URLRequest] { lock.withLock { captured } }
    var connectedURL: URL? { lock.withLock { socketURL } }

    init(socket: SocketMock, response: @escaping @Sendable (URLRequest) throws -> Data) {
        connection = socket
        self.response = response
    }
    func data(for request: URLRequest) async throws -> Data {
        lock.withLock { captured.append(request) }
        return try response(request)
    }
    func socket(at url: URL) -> any AnisetteSocket {
        lock.withLock { socketURL = url }
        return connection
    }
}

private func appleFixture(_ request: URLRequest) throws -> Data {
    switch request.url!.lastPathComponent {
    case "lookup":
        return try plist(["urls": ["midStartProvisioning": "https://gsa.apple.com/start",
                                   "midFinishProvisioning": "https://gsa.apple.com/finish"]])
    case "start": return try plist(["Response": ["spim": "start-data", "Status": ["ec": 0]]])
    case "finish": return try plist(["Response": ["ptm": "end-data", "tk": "ticket", "Status": ["ec": 0]]])
    case "get_headers":
        return try json(["X-Apple-I-MD": "fresh-otp", "X-Apple-I-MD-M": "remote-machine",
                         "X-Apple-I-MD-RINFO": "42", "Authorization": "must-not-be-forwarded"])
    default: throw Failure(message: "Unexpected URL")
    }
}

private final class AppleURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var saved = request
        if let stream = saved.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            saved.httpBody = body
        }
        Self.lock.withLock { Self.captured.append(saved) }
        if request.url!.lastPathComponent == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var httpStatus = request.url!.lastPathComponent == "unavailable" ||
            request.value(forHTTPHeaderField: "X-Apple-Identity-Token") == "failure-identity" ? 503 : 200
        let status = request.url!.lastPathComponent == "GsService2" ? -20101 : 0
        var data = try! plist(["Response": ["Status": ["ec": status, "em": "test"]], "Status": ["ec": 0]])
        let body = saved.httpBody.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        let operation = body?["Request"] as? [String: Any]
        if operation?["u"] as? String == "rate-limited-complete@example.invalid",
           operation?["o"] as? String == "init" {
            data = try! plist(["Response": ["Status": ["ec": 0], "s": Data(repeating: 1, count: 16),
                                            "B": Data(repeating: 3, count: 256), "i": 2,
                                            "sp": "s2k", "c": "fixture-session-cookie"]])
        }
        let identity = request.value(forHTTPHeaderField: "X-Apple-Identity-Token")
        if identity == "sms-rate-limited-identity", request.url!.lastPathComponent == "trusteddevice" {
            data = Data("phoneNumber.id=\"1\"".utf8)
        }
        if operation?["u"] as? String == "rate-limited-init@example.invalid" ||
            (operation?["u"] as? String == "rate-limited-complete@example.invalid" && operation?["o"] as? String == "complete") ||
            identity == "rate-limited-identity" ||
            (identity == "sms-rate-limited-identity" && request.url!.lastPathComponent == "put") {
            httpStatus = 429
            data = Data("<html><h1>429 Too Many Requests</h1></html>".utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: httpStatus,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private enum AnisetteTests {
    static func main() async throws {
        try loggerRedactionTests()
        try configurationTests()
        try await providerTests()
        try await clientIdentifierTests()
        try await protocolTests()
        try await failureTests()
        try await transportTests()
        try await gsaTests()
        try await MZFinanceTests.run()
        try await DownloadProductTests.run()
        try await PurchaseTests.run()
        try await gsaConnectionTests()
        print("PASS: configuration, provider pinning, identity persistence, concurrent provisioning, V3 exchange, failures, cancellation, GSA and 2FA headers")
    }

    static func loggerRedactionTests() throws {
        guard let capture = tmpfile() else { throw Failure(message: "Cannot capture logger output") }
        fflush(stdout)
        let savedOutput = dup(STDOUT_FILENO)
        guard savedOutput >= 0 else {
            fclose(capture)
            throw Failure(message: "Cannot duplicate stdout")
        }
        defer {
            fflush(stdout)
            dup2(savedOutput, STDOUT_FILENO)
            close(savedOutput)
            fclose(capture)
        }
        try expect(dup2(fileno(capture), STDOUT_FILENO) >= 0, "Cannot redirect stdout")
        let endpoint = URL(string: "https://store.example.invalid/buyProduct")!
        let action = "https://store.example.invalid/editAddress?xToken=fixture-url-secret&unknownKey=fixture-query-secret#fixture-fragment-secret"
        let body: [String: Any] = [
            "failureType": "2022", "customerMessage": "There is a billing problem with a previous purchase.",
            "dsPersonId": "fixture-person-secret",
            "dialog": ["okButtonAction": ["url": action]], "links": [action]
        ]
        let xml = try plist(body)
        for (type, data) in [("text/xml", xml), ("application/x-apple-plist", xml), ("application/json", try json(body))] {
            let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": type, "Location": action])!
            NetworkLogger.shared.logResponse(response, data: data, error: nil)
        }
        fflush(stdout)
        let handle = FileHandle(fileDescriptor: fileno(capture), closeOnDealloc: false)
        handle.seek(toFileOffset: 0)
        let output = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for secret in ["fixture-url-secret", "fixture-query-secret", "fixture-fragment-secret", "fixture-person-secret"] {
            try expect(!output.contains(secret), "Logger exposed a synthetic credential")
        }
        try expect(output.contains("2022") && output.contains("billing problem") && output.contains("editAddress"),
                   "Logger discarded useful billing diagnostics")
    }

    static func configurationTests() throws {
        // Volatile preferences exercise defaults and existing choices without writing to disk.
        let defaults = UserDefaults(suiteName: "AnisetteTests.\(UUID().uuidString)")!
        try expect(AnisetteConfiguration.load(from: defaults).mode == .automatic, "New installs must select automatic fallback")
        for mode in AnisetteConfiguration.Mode.allCases {
            defaults.setVolatileDomain([AnisetteConfiguration.modeKey: mode.rawValue,
                                        AnisetteConfiguration.serverKey: testServer.absoluteString],
                                       forName: UserDefaults.argumentDomain)
            let saved = AnisetteConfiguration.load(from: defaults)
            try expect(saved.mode == mode && saved.server == testServer.absoluteString, "Existing sign-in preferences overwritten")
        }
        defaults.setVolatileDomain([AnisetteConfiguration.modeKey: "unknown"], forName: UserDefaults.argumentDomain)
        try expect(AnisetteConfiguration.load(from: defaults).mode == .automatic, "Invalid mode must use automatic default")
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)

        let https = try AnisetteConfiguration.serverURL(" https://EXAMPLE.com:8443/prefix/ ")
        try expect(https.absoluteString == "https://example.com:8443/prefix", "Server normalization")
        try expect(try AnisetteV3Client.webSocketURL(server: https).absoluteString == "wss://example.com:8443/prefix/v3/provisioning_session", "HTTPS port and path")
        let http = try AnisetteConfiguration.serverURL("http://127.0.0.1:6969")
        try expect(try AnisetteV3Client.webSocketURL(server: http).absoluteString == "ws://127.0.0.1:6969/v3/provisioning_session", "Loopback port and scheme")
        for invalid in ["http://example.com", "https://user:password@example.com", "https://example.com?q=x", "https://example.com#x", "file:///tmp/data", "https://", "https://example.com:99999"] {
            do { _ = try AnisetteConfiguration.serverURL(invalid); throw Failure(message: "Accepted invalid URL: \(invalid)") }
            catch AnisetteError.invalidServerURL {}
        }
        var partial = fixtureHeaders()
        partial.removeValue(forKey: "X-Apple-I-MD-M")
        do { _ = try AnisetteSession.validate(partial); throw Failure(message: "Accepted partial OTP") }
        catch AnisetteError.incompleteHeaders {}
        partial = fixtureHeaders("\n")
        do { _ = try AnisetteSession.validate(partial); throw Failure(message: "Accepted invalid OTP") }
        catch AnisetteError.incompleteHeaders {}
    }

    static func clientIdentifierTests() async throws {
        let host = "<Mac17,8> <macOS;26.6.2;25G83>"
        let compatible = "\(host) <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
        for version in ["25183.54.10", "3594.4.19"] {
            let legacy = "\(host) <com.apple.AuthKit/1 (com.apple.dt.Xcode/\(version))>"
            try expect(AnisetteClientInfo.replacingLegacyIdentifier(in: legacy) == compatible, "Legacy client token not updated")
        }
        try expect(AnisetteClientInfo.replacingLegacyIdentifier(in: compatible) == compatible, "Client migration is not idempotent")
        let other = "\(host) <com.apple.AOSKit/282 (com.apple.accountsd/113)>"
        try expect(AnisetteClientInfo.replacingLegacyIdentifier(in: other) == other, "Unrelated client identifier changed")
        try expect(AnisetteClientInfo.current.contains("com.apple.akd/1.0") && !AnisetteClientInfo.current.contains("com.apple.dt.Xcode"), "New identities still advertise Xcode")

        let old = AnisetteIdentity(version: 1, server: testServer, localUserID: "saved-local-id",
                                   deviceID: UUID().uuidString,
                                   clientInfo: "\(host) <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>",
                                   provisioningData: "existing-personalization")
        let store = MemoryStore()
        try store.save(old)
        let remote = RemoteMock()
        let provider = AnisetteProvider(local: { throw Failure(message: "Remote migration used local provider") }, remote: remote, store: store)
        let session = try await provider.makeSession(configuration: .init(mode: .remote, server: testServer.absoluteString))
        let result = try await session.headers()
        try expect(result["X-Mme-Client-Info"] == compatible, "Saved Xcode identifier reached the session")
        try expect(await remote.provisionCount == 0, "Client metadata update reprovisioned the device")
        let saved = try store.load(server: testServer)!
        try expect(saved.clientInfo == compatible && saved.deviceID == old.deviceID &&
                   saved.localUserID == old.localUserID && saved.provisioningData == old.provisioningData &&
                   saved.server == old.server && saved.version == old.version, "Migration changed provisioned identity data")

        // Direct V3 consumers also get a compatible header from an older record.
        let client = AnisetteV3Client(transport: TransportMock(socket: try SocketMock([]), response: { try appleFixture($0) }))
        try expect(try await client.headers(for: old)["X-Mme-Client-Info"] == compatible, "Direct V3 header retained Xcode")
    }

    static func providerTests() async throws {
        let remote = RemoteMock()
        let store = MemoryStore()
        let local = AnisetteProvider(local: { fixtureHeaders() }, remote: remote, store: store)
        let config = AnisetteConfiguration(mode: .automatic, server: testServer.absoluteString)
        let session = try await local.makeSession(configuration: config)
        try expect(try await session.headers()["X-Apple-I-MD"] == "otp", "Local source preferred")
        try expect(await remote.provisionCount == 0, "Local path contacted remote")

        let fallback = AnisetteProvider(local: { ["X-Apple-I-MD": "partial"] }, remote: remote, store: store)
        async let first = fallback.makeSession(configuration: config)
        async let second = fallback.makeSession(configuration: config)
        let (one, two) = try await (first, second)
        let a = try await one.headers()
        let b = try await two.headers()
        try expect(await remote.provisionCount == 1, "Concurrent callers provisioned multiple identities")
        try expect(a["X-Mme-Device-Id"] == b["X-Mme-Device-Id"], "Concurrent identity mismatch")
        try expect(a["X-Apple-I-MD-LU"] == "remote-user" && a["X-Mme-Client-Info"] == "remote-client", "Mixed local and remote identity")
        let fresh = try await one.headers()
        try expect(fresh["X-Apple-I-MD"] != a["X-Apple-I-MD"], "OTP reused indefinitely")
        let restarted = AnisetteProvider(local: { throw AnisetteError.localUnavailable }, remote: remote, store: store)
        let resumed = try await restarted.makeSession(configuration: config)
        try expect(try await resumed.headers()["X-Mme-Device-Id"] == a["X-Mme-Device-Id"], "Identity did not survive provider restart")
        try expect(await remote.provisionCount == 1, "Saved identity reprovisioned")
        await remote.setFailure()
        do { _ = try await one.headers(); throw Failure(message: "Remote failure silently changed source") }
        catch AnisetteError.http(503) {}
        try expect(await remote.provisionCount == 1, "Network failure reprovisioned identity")

        let unused = RemoteMock()
        let disabled = AnisetteProvider(local: { throw AnisetteError.localUnavailable }, remote: unused, store: MemoryStore())
        do { _ = try await disabled.makeSession(configuration: .init(mode: .local, server: testServer.absoluteString)); throw Failure(message: "Local failure ignored") }
        catch AnisetteError.localUnavailable {}
        try expect(await unused.provisionCount == 0, "Remote used without configuration")
        let badStore = MemoryStore()
        badStore.readError = .keychain(-25308)
        let locked = AnisetteProvider(local: { fixtureHeaders() }, remote: unused, store: badStore)
        do { _ = try await locked.makeSession(configuration: .init(mode: .remote, server: testServer.absoluteString)); throw Failure(message: "Keychain failure ignored") }
        catch AnisetteError.keychain(-25308) {}
        try expect(await unused.provisionCount == 0, "Keychain error silently replaced identity")
    }

    static func protocolTests() async throws {
        let socket = try SocketMock([["result": "GiveIdentifier"], ["result": "GiveStartProvisioningData"],
                                     ["result": "GiveEndProvisioningData", "cpim": "cpim-data"],
                                     ["result": "ProvisioningSuccess", "adi_pb": "personalization"]])
        let transport = TransportMock(socket: socket, response: { try appleFixture($0) })
        let client = AnisetteV3Client(transport: transport)
        let identity = try await client.provision(server: testServer)
        let result = try await client.headers(for: identity)
        try expect(identity.provisioningData == "personalization", "Personalization missing")
        try expect(transport.connectedURL?.absoluteString == "wss://anisette.example.invalid:8443/service/v3/provisioning_session", "Wrong socket URL")
        let sent = try socket.sent.map { try JSONSerialization.jsonObject(with: $0) as! [String: String] }
        try expect(sent == [["identifier": identity.localUserID], ["spim": "start-data"], ["ptm": "end-data", "tk": "ticket"]], "Wrong provisioning exchange")
        try expect(socket.isCancelled, "Socket not closed")
        try expect(result["Authorization"] == nil && result["X-Apple-I-MD-RINFO"] == "42", "Server header allowlist/routing")
        try expect(result["X-Mme-Device-Id"] == identity.deviceID && result["X-Apple-I-MD-LU"] == identity.localUserID, "Identity changed")
        let last = transport.requests.last!
        let body = try JSONSerialization.jsonObject(with: last.httpBody!) as! [String: String]
        try expect(body == ["identifier": identity.localUserID, "adi_pb": "personalization"], "Unexpected data sent to server")
        for request in transport.requests {
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "Credentials entered provisioning transport")
            if request.url?.host == "gsa.apple.com" {
                try expect(request.value(forHTTPHeaderField: "X-Mme-Client-Info")?.contains("com.apple.akd/1.0") == true,
                           "Provisioning request advertised the old client identifier")
            }
        }
    }

    static func failureTests() async throws {
        let broken = try SocketMock([["result": "GiveEndProvisioningData", "cpim": "unexpected"]])
        do {
            _ = try await AnisetteV3Client(transport: TransportMock(socket: broken, response: { try appleFixture($0) })).provision(server: testServer)
            throw Failure(message: "Out-of-order message accepted")
        } catch AnisetteError.invalidResponse("provisioning sequence") {}
        try expect(broken.sent.isEmpty && broken.isCancelled, "Invalid sequence sent data or leaked socket")

        let stalled = try SocketMock([])
        do {
            _ = try await AnisetteV3Client(transport: TransportMock(socket: stalled, response: { try appleFixture($0) }), provisioningTimeout: 20_000_000).provision(server: testServer)
            throw Failure(message: "Stalled provisioning succeeded")
        } catch AnisetteError.timeout {}
        try expect(stalled.isCancelled, "Timeout did not cancel socket")

        let cancelled = try SocketMock([])
        let task = Task { try await AnisetteV3Client(transport: TransportMock(socket: cancelled, response: { try appleFixture($0) })).provision(server: testServer) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "Cancellation ignored") }
        catch is CancellationError {}
        try expect(cancelled.isCancelled, "Cancellation did not close socket")

        let hostile = TransportMock(socket: try SocketMock([])) { _ in
            try plist(["urls": ["midStartProvisioning": "https://apple.com.evil.invalid/start",
                                "midFinishProvisioning": "https://gsa.apple.com/finish"]])
        }
        do { _ = try await AnisetteV3Client(transport: hostile).provision(server: testServer); throw Failure(message: "Untrusted provisioning URL accepted") }
        catch AnisetteError.invalidResponse("Apple provisioning URL") {}
        try expect(hostile.requests.count == 1 && hostile.connectedURL == nil, "Contacted untrusted endpoint")
    }

    static func gsaTests() async throws {
        let initialRequestCount = AppleURLProtocol.requests.count
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppleURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }
        let anisette = AnisetteSession(initialHeaders: fixtureHeaders("first-otp")) { fixtureHeaders("second-otp") }
        let gsa = GSAClient(session: urlSession, anisette: anisette)
        do { _ = try await gsa.authenticate(username: "fixture@example.invalid", password: "fixture"); throw Failure(message: "Fixture login unexpectedly succeeded") }
        catch GSAError.serverError(-20101, _) {}
        let request = AppleURLProtocol.requests[initialRequestCount]
        let body = try PropertyListSerialization.propertyList(from: request.httpBody!, format: nil) as! [String: Any]
        let cpd = (body["Request"] as! [String: Any])["cpd"] as! [String: Any]
        try expect(cpd["X-Apple-I-MD"] as? String == "first-otp", "GSA consumed extra OTP")
        try expect(cpd["X-Mme-Client-Info"] as? String == request.value(forHTTPHeaderField: "X-Mme-Client-Info"), "GSA body/header mismatch")
        try expect(request.value(forHTTPHeaderField: "X-Mme-Client-Info")?.contains("com.apple.akd/1.0") == true, "GSA request advertised Xcode")
        try await gsa.submitTwoFactorCode("123456", identityToken: "fixture-identity", phoneId: nil)
        let verification = AppleURLProtocol.requests.last!
        try expect(verification.value(forHTTPHeaderField: "X-Apple-I-MD") == "second-otp", "2FA did not refresh OTP")
        try expect(verification.value(forHTTPHeaderField: "X-Mme-Device-Id") == cpd["X-Mme-Device-Id"] as? String, "2FA changed device")
        try expect(verification.value(forHTTPHeaderField: "X-Mme-Client-Info") == request.value(forHTTPHeaderField: "X-Mme-Client-Info"), "2FA changed client identifier")
        for phoneID in [nil, 1] as [Int?] {
            do {
                try await gsa.submitTwoFactorCode("123456", identityToken: "failure-identity", phoneId: phoneID)
                throw Failure(message: "2FA accepted HTTP 503")
            } catch GSAError.serverError(503, _) {}
        }

        // Reproduce both an init rejection and the reported init=200/complete=429.
        for (phase, expectedRequests) in [("init", 1), ("complete", 2)] {
            let before = AppleURLProtocol.requests.count
            do {
                _ = try await gsa.authenticate(username: "rate-limited-\(phase)@example.invalid", password: "fixture")
                throw Failure(message: "GSA accepted HTTP 429")
            } catch GSAError.rateLimited {}
            let requests = Array(AppleURLProtocol.requests.dropFirst(before))
            try expect(requests.count == expectedRequests, "GSA retried a rate-limited operation")
            if phase == "complete" {
                let body = try PropertyListSerialization.propertyList(from: requests.last!.httpBody!, format: nil) as! [String: Any]
                let operation = body["Request"] as! [String: Any]
                try expect(operation["c"] as? String == "fixture-session-cookie", "SRP cookie lost between exchanges")
                try expect((operation["M1"] as? Data)?.count == 32, "Complete request missing SRP proof")
            }
        }
        for phoneID in [nil, 1] as [Int?] {
            let before = AppleURLProtocol.requests.count
            do {
                try await gsa.submitTwoFactorCode("123456", identityToken: "rate-limited-identity", phoneId: phoneID)
                throw Failure(message: "2FA accepted HTTP 429")
            } catch GSAError.rateLimited {}
            try expect(AppleURLProtocol.requests.count == before + 1, "Retried rate-limited 2FA validation")
        }
        for (identity, expectedRequests) in [("rate-limited-identity", 1), ("sms-rate-limited-identity", 2)] {
            let before = AppleURLProtocol.requests.count
            do {
                _ = try await gsa.requestTwoFactorCode(identityToken: identity)
                throw Failure(message: "Claimed verification code was sent after HTTP 429")
            } catch GSAError.rateLimited {}
            try expect(AppleURLProtocol.requests.count == before + expectedRequests, "Retried rate-limited code request")
        }
        do {
            _ = try await gsa.requestTwoFactorCode(identityToken: "failure-identity")
            throw Failure(message: "Claimed verification code was sent after HTTP 503")
        } catch GSAError.serverError(503, _) {}
        print("PASS: GSA init/complete and all 2FA paths reject HTTP 429 without retrying")
    }

    /// Run with Tests/GSAKeepAliveServer.py to exercise real HTTP/1.1 connections.
    static func gsaConnectionTests() async throws {
        guard let address = ProcessInfo.processInfo.environment["IPAVERSE_GSA_TEST_URL"],
              let url = URL(string: address), url.host == "127.0.0.1" else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.httpAdditionalHeaders = ["X-Fixture": "preserved"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("fixture".utf8)
        let (first, _) = try await session.data(for: request)
        let (second, _) = try await session.data(for: request)
        let firstJSON = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        let secondJSON = try JSONSerialization.jsonObject(with: second) as! [String: Any]
        try expect(firstJSON["connection"] as? Int == secondJSON["connection"] as? Int,
                   "Control session did not reuse the keep-alive connection; regression test inconclusive")

        let transport = AuthenticationHTTPTransport(session: session)
        let (third, _) = try await transport.data(for: request)
        let (fourth, _) = try await transport.data(for: request)
        let thirdJSON = try JSONSerialization.jsonObject(with: third) as! [String: Any]
        let fourthJSON = try JSONSerialization.jsonObject(with: fourth) as! [String: Any]
        try expect(thirdJSON["connection"] as? Int != secondJSON["connection"] as? Int &&
                   thirdJSON["connection"] as? Int != fourthJSON["connection"] as? Int,
                   "GSA transport reused a connection")
        for payload in [thirdJSON, fourthJSON] {
            try expect(payload["fixture"] as? String == "preserved", "Session configuration lost")
            try expect((payload["cookie"] as? String)?.contains("gsa-fixture=retained") == true, "Cookies lost across GSA connections")
            try expect(payload["body"] as? String == "fixture", "Request body changed")
        }
        var previousConnection = fourthJSON["connection"] as? Int
        // Logout clears cookies but the service's template URLSession survives.
        // Repeated sign-ins must still open fresh connections and accept new cookies.
        for _ in 0..<2 {
            let storage = session.configuration.httpCookieStorage!
            for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
            for exchangeIndex in 0..<2 {
                let (data, _) = try await transport.data(for: request)
                let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let connection = payload["connection"] as? Int
                try expect(connection != previousConnection, "Re-login reused the previous connection")
                let cookie = payload["cookie"] as? String ?? ""
                try expect(exchangeIndex == 0 ? cookie.isEmpty : cookie.contains("gsa-fixture=retained"),
                           "Logout/re-login cookie lifecycle failed")
                previousConnection = connection
            }
        }
        print("PASS: real HTTP connections are isolated across authentication and repeated logout/re-login; cookies/configuration retained correctly")
    }

    static func transportTests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppleURLProtocol.self]
        let transport = AnisetteURLTransport(configuration: config)
        for (path, expected) in [("unavailable", 503), ("timeout", 0)] {
            do {
                _ = try await transport.data(for: URLRequest(url: testServer.appendingPathComponent(path)))
                throw Failure(message: "HTTP failure ignored")
            } catch AnisetteError.http(let code) {
                try expect(code == expected, "Wrong HTTP status")
            } catch AnisetteError.timeout {
                try expect(expected == 0, "Wrong timeout classification")
            }
        }
        try expect(config.httpCookieStorage == nil && config.urlCredentialStorage == nil && !config.httpShouldSetCookies,
                   "Provisioning transport inherited credentials/cookies")

        let identity = AnisetteIdentity(version: 1, server: testServer, localUserID: "user",
                                       deviceID: UUID().uuidString, clientInfo: "client", provisioningData: "saved")
        let partial = TransportMock(socket: try SocketMock([])) { _ in try json(["X-Apple-I-MD": "only-otp"]) }
        do { _ = try await AnisetteV3Client(transport: partial).headers(for: identity); throw Failure(message: "Partial remote headers accepted") }
        catch AnisetteError.invalidResponse("machine ID") {}
        let malformed = TransportMock(socket: try SocketMock([])) { _ in Data("<html>unavailable</html>".utf8) }
        do { _ = try await AnisetteV3Client(transport: malformed).headers(for: identity); throw Failure(message: "Malformed response accepted") }
        catch AnisetteError.invalidResponse("header generation") {}
    }
}
