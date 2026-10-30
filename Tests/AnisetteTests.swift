import Foundation

private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private struct Failure: Error { let message: String }
private let testServer = URL(string: "https://anisette.example.invalid:8443/service")!
private let serverClientInfo = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
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
        return AnisetteIdentity(version: AnisetteIdentity.currentVersion, server: server, localUserID: "remote-user",
                                deviceID: UUID().uuidString, clientInfo: "remote-client", provisioningData: "saved-adi")
    }
    func headers(for identity: AnisetteIdentity, sim: String?) async throws -> [String: String] {
        headerCount += 1
        if failHeaders { throw AnisetteError.http(503) }
        var result = fixtureHeaders("remote-\(headerCount)")
        result["X-Apple-I-MD-LU"] = identity.localUserID
        result["X-Mme-Device-Id"] = identity.deviceID
        result["X-Mme-Client-Info"] = identity.clientInfo
        return result
    }
}

private final class SIMRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func append(_ sim: String) { lock.withLock { recorded.append(sim) } }
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
    case "client_info":
        return try json(["client_info": serverClientInfo, "user_agent": "akd/1.0 CFNetwork/808.1.4"])
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
        let otp = (operation?["cpd"] as? [String: Any])?["X-Apple-I-MD"] as? String
        if operation?["u"] as? String == "resync-always@example.invalid" ||
            (operation?["u"] as? String == "resync@example.invalid" && otp != "resynced-otp") {
            data = try! plist(["Response": ["Status": ["ec": -22421, "em": "resync", "hsc": 434,
                                                       "X-Apple-I-MD-DATA": Data("apple-sim".utf8)]]])
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
        try expect(Locale.current.identifier == "en_US@currency=eur",
                   "Run scripts/test-anisette.sh to apply the authentication locale fixture")
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
        for (identifier, expected) in [("en_US@currency=eur", "en_US"),
                                       ("en_US@rg=inzzzz", "en_US"),
                                       ("zh_CN@calendar=chinese;currency=eur", "zh_CN"),
                                       ("zh_TW", "zh_TW"), ("en_US", "en_US")] {
            try expect(Locale(identifier: identifier).appleAuthenticationIdentifier == expected,
                       "Authentication locale must preserve language/region without ICU preferences")
        }
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
        for retired in ["https://ani.sidestore.zip", "https://ANI.sidestore.zip/"] {
            defaults.setVolatileDomain([AnisetteConfiguration.serverKey: retired], forName: UserDefaults.argumentDomain)
            try expect(AnisetteConfiguration.load(from: defaults).server == AnisetteConfiguration.defaultServer,
                       "A saved retired default must resolve to the current default server")
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
        try expect(AnisetteClientInfo.current.contains("com.apple.akd/1.0") && !AnisetteClientInfo.current.contains("com.apple.dt.Xcode"), "New identities still advertise Xcode")

        // A version 1 record holds this Mac's client info, which GSA rejects with -80045.
        // The store must report it as missing so that the provider provisions a new identity.
        func stored(_ version: Int, server: URL = testServer, clientInfo: String = serverClientInfo) throws -> Data {
            try JSONEncoder().encode(AnisetteIdentity(version: version, server: server, localUserID: "saved-local-id",
                                                      deviceID: UUID().uuidString, clientInfo: clientInfo,
                                                      provisioningData: "existing-personalization"))
        }
        try expect(try AnisetteIdentity.decodeStored(stored(1), server: testServer) == nil, "Outdated identity was reused")
        try expect(try AnisetteIdentity.decodeStored(stored(AnisetteIdentity.currentVersion), server: testServer)?.clientInfo == serverClientInfo,
                   "Current identity was not reused")
        do { _ = try AnisetteIdentity.decodeStored(stored(AnisetteIdentity.currentVersion + 1), server: testServer); throw Failure(message: "Future identity accepted") }
        catch AnisetteError.invalidIdentity {}
        do { _ = try AnisetteIdentity.decodeStored(stored(AnisetteIdentity.currentVersion, clientInfo: ""), server: testServer); throw Failure(message: "Empty client info accepted") }
        catch AnisetteError.invalidIdentity {}

        // The server's client info reaches GSA unchanged, even when it names another platform.
        let identity = AnisetteIdentity(version: AnisetteIdentity.currentVersion, server: testServer, localUserID: "saved-local-id",
                                        deviceID: UUID().uuidString, clientInfo: serverClientInfo,
                                        provisioningData: "existing-personalization")
        let client = AnisetteV3Client(transport: TransportMock(socket: try SocketMock([]), response: { try appleFixture($0) }))
        let headers = try await client.headers(for: identity)
        try expect(headers["X-Mme-Client-Info"] == serverClientInfo, "Server client info was rewritten")
        try expect(headers["X-Apple-Locale"] == "en_US",
                   "V3 authentication locale includes ICU preferences that break Apple 2FA")
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
        _ = try await client.headers(for: identity, sim: "apple-sim")
        let resyncBody = try JSONSerialization.jsonObject(with: transport.requests.last!.httpBody!) as! [String: String]
        try expect(resyncBody == ["identifier": identity.localUserID, "adi_pb": "personalization", "sim": "apple-sim",
                                  "device_id": identity.deviceID, "md_lu": identity.localUserID], "Wrong resync request")
        for request in transport.requests {
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "Credentials entered provisioning transport")
            if request.url?.host == "gsa.apple.com" {
                try expect(request.value(forHTTPHeaderField: "X-Apple-Locale") == "en_US",
                           "Provisioning locale includes ICU preferences that break Apple 2FA")
                try expect(request.value(forHTTPHeaderField: "X-Mme-Client-Info") == serverClientInfo,
                           "Provisioning request did not use the server's client info")
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

        let hostile = TransportMock(socket: try SocketMock([])) { request in
            if request.url!.lastPathComponent == "client_info" { return try appleFixture(request) }
            return try plist(["urls": ["midStartProvisioning": "https://apple.com.evil.invalid/start",
                                "midFinishProvisioning": "https://gsa.apple.com/finish"]])
        }
        do { _ = try await AnisetteV3Client(transport: hostile).provision(server: testServer); throw Failure(message: "Untrusted provisioning URL accepted") }
        catch AnisetteError.invalidResponse("Apple provisioning URL") {}
        try expect(hostile.requests.count == 2 && hostile.connectedURL == nil, "Contacted untrusted endpoint")
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
        try expect(cpd["loc"] as? String == "en_US",
                   "GSA locale includes ICU preferences that break Apple 2FA")
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

        // hsc 434: GSA asks for an anisette resync. The client resyncs once and retries once.
        let sims = SIMRecorder()
        let resyncing = AnisetteSession(initialHeaders: fixtureHeaders("first-otp"), refresh: { fixtureHeaders("second-otp") },
                                        resync: { sim in sims.append(sim); return fixtureHeaders("resynced-otp") })
        let resyncClient = GSAClient(session: urlSession, anisette: resyncing)
        var before = AppleURLProtocol.requests.count
        do { _ = try await resyncClient.authenticate(username: "resync@example.invalid", password: "fixture"); throw Failure(message: "Fixture login unexpectedly succeeded") }
        catch GSAError.serverError(-20101, _) {}
        let sent = Array(AppleURLProtocol.requests.dropFirst(before))
        try expect(sent.count == 2, "hsc 434 was not retried exactly once")
        let retried = try PropertyListSerialization.propertyList(from: sent[1].httpBody!, format: nil) as! [String: Any]
        let retriedCPD = (retried["Request"] as! [String: Any])["cpd"] as! [String: Any]
        try expect(retriedCPD["X-Apple-I-MD"] as? String == "resynced-otp", "Retry did not use the resynced headers")
        try expect(sims.values == [Data("apple-sim".utf8).base64EncodedString()], "Resync did not receive Apple's SIM")

        before = AppleURLProtocol.requests.count
        do { _ = try await resyncClient.authenticate(username: "resync-always@example.invalid", password: "fixture"); throw Failure(message: "Repeated hsc 434 accepted") }
        catch GSAError.serverError(-22421, _) {}
        try expect(AppleURLProtocol.requests.count == before + 2 && sims.values.count == 2, "Repeated hsc 434 caused a resync loop")

        before = AppleURLProtocol.requests.count
        do { _ = try await gsa.authenticate(username: "resync@example.invalid", password: "fixture"); throw Failure(message: "hsc 434 accepted without resync support") }
        catch GSAError.serverError(-22421, _) {}
        try expect(AppleURLProtocol.requests.count == before + 1, "A source without resync retried hsc 434")

        // hsc 409 without `au`: Apple already sent the code, so the client asks the user for it.
        try expect(GSAClient.secondaryAuth(in: ["ec": 0, "hsc": 409]) == .codeAlreadySent, "hsc 409 was not treated as 2FA")
        try expect(GSAClient.secondaryAuth(in: ["ec": 0, "hsc": 409, "au": "trustedDeviceSecondaryAuth"]) == .requestCode("trustedDeviceSecondaryAuth"),
                   "au no longer requests a code")
        try expect(GSAClient.secondaryAuth(in: ["ec": 0, "hsc": 200]) == GSAClient.SecondaryAuth.none, "hsc 200 required 2FA")

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
                _ = try await gsa.requestTwoFactorCode(identityToken: identity, sendSMS: true)
                throw Failure(message: "Claimed verification code was sent after HTTP 429")
            } catch GSAError.rateLimited {}
            try expect(AppleURLProtocol.requests.count == before + expectedRequests, "Retried rate-limited code request")
        }
        // The verification page lists a trusted number even when the account has trusted
        // devices; that must not text the user on top of the device prompt.
        before = AppleURLProtocol.requests.count
        let delivery = try await gsa.requestTwoFactorCode(identityToken: "sms-rate-limited-identity", sendSMS: false)
        try expect(delivery == TwoFactorDelivery(trustedPhoneId: 1), "Trusted-device code request lost the SMS alternative")
        try expect(AppleURLProtocol.requests.count == before + 1, "Trusted-device code request also sent an SMS")
        before = AppleURLProtocol.requests.count
        do {
            _ = try await gsa.sendSMSCode(phoneId: 1, identityToken: "sms-rate-limited-identity")
            throw Failure(message: "Claimed SMS was sent after HTTP 429")
        } catch GSAError.rateLimited {}
        try expect(AppleURLProtocol.requests.count == before + 1 && AppleURLProtocol.requests.last?.url?.path == "/auth/verify/phone/1/put",
                   "SMS on request did not go straight to the phone endpoint")
        do {
            _ = try await gsa.requestTwoFactorCode(identityToken: "failure-identity", sendSMS: false)
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

        let identity = AnisetteIdentity(version: AnisetteIdentity.currentVersion, server: testServer, localUserID: "user",
                                       deviceID: UUID().uuidString, clientInfo: "client", provisioningData: "saved")
        let partial = TransportMock(socket: try SocketMock([])) { _ in try json(["X-Apple-I-MD": "only-otp"]) }
        do { _ = try await AnisetteV3Client(transport: partial).headers(for: identity); throw Failure(message: "Partial remote headers accepted") }
        catch AnisetteError.invalidResponse("machine ID") {}
        let malformed = TransportMock(socket: try SocketMock([])) { _ in Data("<html>unavailable</html>".utf8) }
        do { _ = try await AnisetteV3Client(transport: malformed).headers(for: identity); throw Failure(message: "Malformed response accepted") }
        catch AnisetteError.invalidResponse("header generation") {}
    }
}
