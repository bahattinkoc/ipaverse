import Foundation

enum MZFinanceAuthenticationError: LocalizedError {
    case http(Int)
    case invalidRedirect
    case missingRedirectLocation(Int)
    case tooManyRedirects
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(429):
            "Apple is temporarily limiting App Store sign-in requests. Please wait before trying again."
        case .http(let status):
            "Apple Account verification succeeded, but the App Store could not start a session (HTTP \(status)). Please try again later."
        case .missingRedirectLocation(let status):
            "Apple Account verification succeeded, but the App Store repeatedly returned a redirect without a destination (HTTP \(status)). Please try again later."
        case .invalidRedirect, .tooManyRedirects, .invalidResponse:
            "Apple Account verification succeeded, but the App Store returned an unexpected sign-in response. Please try again later."
        }
    }
}

/// Keep the protocol attempt and signed payload stable across transport retries
/// and pod redirects. See majd/ipatool#533; a transport retry is not a new login.
enum MZFinanceAuthentication {
    static func makeRequest(url: URL, email: String, pet: String, deviceID: String, userAgent: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: [
            "appleId": email, "password": pet, "guid": deviceID,
            "attempt": "1", "rmp": "0", "why": "signIn"
        ], format: .xml, options: 0)
        return request
    }

    static func exchange(
        request: URLRequest,
        prepare: (URLRequest) async throws -> URLRequest,
        send: (URLRequest) async throws -> (Data, URLResponse),
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        var transientResponses = 0
        var redirects = 0
        while true {
            try Task.checkCancellation()
            let prepared = try await prepare(request)
            let (data, response) = try await send(prepared)
            guard let http = response as? HTTPURLResponse else { throw MZFinanceAuthenticationError.invalidResponse }
            let status = http.statusCode
            let isRedirect = [301, 302, 307, 308].contains(status)
            let location = http.value(forHTTPHeaderField: "Location")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let missingLocation = isRedirect && (location == nil || location?.isEmpty == true)
            if isRedirect, !missingLocation, let location {
                guard let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
                      isAuthenticationURL(target) else { throw MZFinanceAuthenticationError.invalidRedirect }
                redirects += 1
                guard redirects <= 3 else { throw MZFinanceAuthenticationError.tooManyRedirects }
                request.url = target
                continue
            }
            // Observed: buy -> valid p46 redirect -> HTML 301 without Location.
            // Retry the current pod and exact query/body, never guess a destination.
            // Share the transient budget so alternating failures cannot loop forever.
            if missingLocation || status == 204 || status == 404 || (500...599).contains(status) {
                transientResponses += 1
                guard transientResponses < 3 else {
                    if missingLocation { throw MZFinanceAuthenticationError.missingRedirectLocation(status) }
                    throw MZFinanceAuthenticationError.http(status)
                }
                print("🔐 [MZFinance] HTTP \(status)\(missingLocation ? " without Location" : "") — retry \(transientResponses)/2 on current endpoint")
                try await sleep(UInt64(transientResponses) * 1_000_000_000)
                continue
            }
            guard status == 200 else { throw MZFinanceAuthenticationError.http(status) }
            guard !data.isEmpty else { throw MZFinanceAuthenticationError.invalidResponse }
            return (data, http)
        }
    }

    private static func isAuthenticationURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil,
              url.path == "/WebObjects/MZFinance.woa/wa/authenticate",
              let host = url.host?.lowercased() else { return false }
        return host == "buy.itunes.apple.com" ||
            host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
    }
}
