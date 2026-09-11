import Foundation

struct AnisetteConfiguration: Equatable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case automatic, local, remote
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatic (Recommended)"
            case .local: return "This Mac Only"
            case .remote: return "Server Only"
            }
        }
    }

    static let modeKey = "anisette.mode"
    static let serverKey = "anisette.serverURL"
    static let defaultServer = "https://ani.sidestore.zip"
    let mode: Mode
    let server: String

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(mode: Mode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .automatic,
             server: defaults.string(forKey: serverKey) ?? defaultServer)
    }

    static func serverURL(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AnisetteError.invalidServerURL
        }
        let scheme = parts.scheme?.lowercased()
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw AnisetteError.invalidServerURL
        }
        parts.scheme = scheme
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw AnisetteError.invalidServerURL }
        return url
    }
}

enum AnisetteError: LocalizedError {
    case localUnavailable
    case invalidServerURL
    case incompleteHeaders
    case invalidResponse(String)
    case http(Int)
    case network
    case timeout
    case keychain(Int32)
    case invalidIdentity

    var errorDescription: String? {
        switch self {
        case .localUnavailable:
            return "This Mac could not prepare sign-in data. To allow automatic server fallback, open Settings → Account → Advanced Sign-in Settings."
        case .invalidServerURL:
            return "Enter an HTTPS server address without credentials, a query, or a fragment. HTTP is allowed only for a server on this Mac."
        case .incompleteHeaders:
            return "The sign-in data is incomplete. Please try again."
        case .invalidResponse(let stage):
            return "Could not prepare sign-in data (\(stage)). Please try again or check your server settings."
        case .http(let status):
            return "The sign-in data service returned HTTP \(status). Please try again later."
        case .network:
            return "Could not reach the sign-in data service. Check your connection and server address."
        case .timeout:
            return "Preparing sign-in data timed out. Please try again."
        case .keychain(let status):
            return "Could not access the saved sign-in device in Keychain (\(status)). Unlock your Keychain and try again."
        case .invalidIdentity:
            return "The saved sign-in device could not be read. Its Keychain data has been preserved."
        }
    }
}
