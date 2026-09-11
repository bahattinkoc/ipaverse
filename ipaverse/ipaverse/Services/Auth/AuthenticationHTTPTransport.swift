import Foundation

/// GSA can reject the next handshake operation with HTTP 429 when it reuses an
/// idle connection (isideload f6a4d5d, September 2026). Scope a URLSession to each
/// exchange instead of sharing the App Store/download connection pool. Cookies,
/// configuration and delegate behavior are retained; SRP/anisette state lives in
/// GSAClient, independently of the transport connection.
struct AuthenticationHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let configuration = session.configuration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let exchange = URLSession(configuration: configuration,
                                  delegate: session.delegate, delegateQueue: session.delegateQueue)
        defer { exchange.invalidateAndCancel() }
        return try await exchange.data(for: request)
    }
}

