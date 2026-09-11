import CryptoKit
import Foundation

protocol AnisetteSocket: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func cancel()
}

protocol AnisetteTransport: Sendable {
    func data(for request: URLRequest) async throws -> Data
    func socket(at url: URL) -> any AnisetteSocket
}

/// Dedicated transport: no Apple account cookies, credentials, redirects, or body logging.
final class AnisetteURLTransport: AnisetteTransport, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnisetteError.invalidResponse("HTTP")
            }
            guard (200..<300).contains(http.statusCode) else { throw AnisetteError.http(http.statusCode) }
            guard data.count <= 1_048_576 else { throw AnisetteError.invalidResponse("response size") }
            return data
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? AnisetteError.timeout : AnisetteError.network
        }
    }

    func socket(at url: URL) -> any AnisetteSocket {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1_048_576
        task.resume()
        return AnisetteURLSocket(task: task)
    }
}

private struct AnisetteURLSocket: AnisetteSocket {
    let task: URLSessionWebSocketTask
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw AnisetteError.invalidResponse("provisioning message")
        }
    }
    func send(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

protocol AnisetteRemoteSource: Sendable {
    func provision(server: URL) async throws -> AnisetteIdentity
    func headers(for identity: AnisetteIdentity) async throws -> [String: String]
}

/// Implements the V3 provisioning exchange, independently of Apple account authentication.
/// Protocol references and validation notes: docs/anisette.md.
struct AnisetteV3Client: AnisetteRemoteSource {
    let transport: any AnisetteTransport
    let provisioningTimeout: UInt64

    init(transport: any AnisetteTransport = AnisetteURLTransport(),
         provisioningTimeout: UInt64 = 45_000_000_000) {
        self.transport = transport
        self.provisioningTimeout = provisioningTimeout
    }

    static func webSocketURL(server: URL) throws -> URL {
        var components = URLComponents(url: server.appendingPathComponent("v3/provisioning_session"),
                                       resolvingAgainstBaseURL: false)
        components?.scheme = server.scheme == "http" ? "ws" : "wss"
        guard let url = components?.url else { throw AnisetteError.invalidServerURL }
        return url
    }

    func provision(server: URL) async throws -> AnisetteIdentity {
        let random = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let localID = SHA256.hash(data: random).map { String(format: "%02X", $0) }.joined()
        let clientInfo = AnisetteClientInfo.current
        let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
        let lookupData = try await transport.data(for: appleRequest(url: lookupURL, localID: localID, clientInfo: clientInfo))
        let lookup = try plist(lookupData, stage: "provisioning lookup")
        guard let urls = lookup["urls"] as? [String: String],
              let start = urls["midStartProvisioning"], let finish = urls["midFinishProvisioning"] else {
            throw AnisetteError.invalidResponse("provisioning lookup")
        }
        let startURL = try Self.appleURL(start)
        let finishURL = try Self.appleURL(finish)
        let socket = transport.socket(at: try Self.webSocketURL(server: server))
        // Cancelling the socket unblocks receive(), including a silent or stalled peer.
        let deadline = Task {
            try await Task.sleep(nanoseconds: provisioningTimeout)
            socket.cancel()
        }
        defer { deadline.cancel(); socket.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let expected = ["GiveIdentifier", "GiveStartProvisioningData", "GiveEndProvisioningData", "ProvisioningSuccess"]
                for step in expected {
                    try Task.checkCancellation()
                    let message = try await socket.receive()
                    let reply = try json(message, stage: "provisioning message")
                    if reply["result"] as? String == "Timeout" { throw AnisetteError.timeout }
                    guard reply["result"] as? String == step else {
                        throw AnisetteError.invalidResponse("provisioning sequence")
                    }
                    var outgoing: [String: String] = [:]
                    switch step {
                    case "GiveIdentifier":
                        outgoing["identifier"] = localID
                    case "GiveStartProvisioningData":
                        let response = try await provisioningRequest(url: startURL, localID: localID,
                                                                     clientInfo: clientInfo, values: [:])
                        outgoing["spim"] = try field("spim", in: response, stage: "start provisioning")
                    case "GiveEndProvisioningData":
                        let cpim = try field("cpim", in: reply, stage: "finish provisioning")
                        let response = try await provisioningRequest(url: finishURL, localID: localID,
                                                                     clientInfo: clientInfo, values: ["cpim": cpim])
                        outgoing["ptm"] = try field("ptm", in: response, stage: "finish provisioning")
                        outgoing["tk"] = try field("tk", in: response, stage: "finish provisioning")
                    default:
                        return AnisetteIdentity(version: 1, server: server, localUserID: localID,
                                                deviceID: UUID().uuidString.uppercased(), clientInfo: clientInfo,
                                                provisioningData: try field("adi_pb", in: reply, stage: "personalization"))
                    }
                    try await socket.send(JSONSerialization.data(withJSONObject: outgoing))
                }
                throw AnisetteError.invalidResponse("provisioning sequence")
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let error = error as? AnisetteError { throw error }
                if let error = error as? URLError {
                    // A closed socket after our deadline can surface as cancelled or timedOut.
                    throw [.cancelled, .timedOut].contains(error.code) ? AnisetteError.timeout : AnisetteError.network
                }
                throw AnisetteError.invalidResponse("provisioning")
            }
        } onCancel: {
            socket.cancel()
        }
    }

    func headers(for identity: AnisetteIdentity) async throws -> [String: String] {
        var request = URLRequest(url: identity.server.appendingPathComponent("v3/get_headers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identity.localUserID, "adi_pb": identity.provisioningData
        ])
        let data = try await transport.data(for: request)
        let response = try json(data, stage: "header generation")
        // Only known fields are accepted. The server cannot inject authentication headers.
        return [
            "X-Apple-I-MD": try field("X-Apple-I-MD", in: response, stage: "OTP"),
            "X-Apple-I-MD-M": try field("X-Apple-I-MD-M", in: response, stage: "machine ID"),
            "X-Apple-I-MD-RINFO": try field("X-Apple-I-MD-RINFO", in: response, stage: "routing info"),
            "X-Apple-I-MD-LU": identity.localUserID,
            "X-Mme-Device-Id": identity.deviceID,
            "X-Apple-I-SRL-NO": "0",
            "X-Mme-Client-Info": AnisetteClientInfo.replacingLegacyIdentifier(in: identity.clientInfo),
            "X-Apple-I-Client-Time": ISO8601DateFormatter().string(from: Date()),
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "UTC",
            "X-Apple-Locale": Locale.current.identifier
        ]
    }

    private static func appleURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), host == "apple.com" || host.hasSuffix(".apple.com"),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else {
            throw AnisetteError.invalidResponse("Apple provisioning URL")
        }
        return url
    }

    private func appleRequest(url: URL, localID: String, clientInfo: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue("akd/1.0 CFNetwork/808.1.4", forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(localID, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation() ?? "UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }

    private func provisioningRequest(url: URL, localID: String, clientInfo: String,
                                     values: [String: String]) async throws -> [String: Any] {
        var request = appleRequest(url: url, localID: localID, clientInfo: clientInfo)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: ["Header": [:], "Request": values],
                                                              format: .xml, options: 0)
        let data = try await transport.data(for: request)
        let object = try plist(data, stage: "Apple provisioning")
        guard let response = object["Response"] as? [String: Any] else {
            throw AnisetteError.invalidResponse("Apple provisioning")
        }
        if let status = response["Status"] as? [String: Any], let code = status["ec"] as? Int, code != 0 {
            throw AnisetteError.invalidResponse("Apple provisioning status")
        }
        return response
    }

    private func plist(_ data: Data, stage: String) throws -> [String: Any] {
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AnisetteError.invalidResponse(stage)
        }
        return value
    }

    private func json(_ data: Data, stage: String) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.invalidResponse(stage)
        }
        return value
    }

    private func field(_ key: String, in object: [String: Any], stage: String) throws -> String {
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains("\r"), !value.contains("\n") else { throw AnisetteError.invalidResponse(stage) }
        return value
    }
}

enum AnisetteClientInfo {
    // Apple's GSA edge rejects the Xcode client identifier with HTTP 503 as of
    // September 2026. Keep the hardware/OS tuple and use the AuthKit daemon identity.
    private static let clientIdentifier = "com.apple.akd/1.0"

    static var current: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return "<\(systemString("hw.model"))> <macOS;\(version);\(systemString("kern.osversion"))> <com.apple.AuthKit/1 (\(clientIdentifier))>"
    }

    /// Older Keychain records retain their provisioned identity and host tuple.
    /// Only the obsolete client token changes; no re-provisioning is necessary.
    static func replacingLegacyIdentifier(in clientInfo: String) -> String {
        clientInfo.replacingOccurrences(of: #"com\.apple\.dt\.Xcode/[^\s)>]+"#,
                                         with: clientIdentifier, options: .regularExpression)
    }

    private static func systemString(_ name: String) -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }
}
