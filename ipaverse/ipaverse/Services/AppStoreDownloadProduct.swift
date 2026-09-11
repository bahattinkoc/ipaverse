import Foundation

enum AppStoreDownloadProductError: LocalizedError {
    case http(Int)
    case failure(code: String, message: String)
    case invalidResponse
    case noItems
    case invalidEndpoint
    case missingCatalogVersion
    case mismatchedUpdate

    var errorDescription: String? {
        switch self {
        case .http(let status): "App Store download request failed (HTTP \(status))."
        case .failure(let code, let message): message.isEmpty ? "App Store download failed (\(code))." : message
        case .invalidResponse: "App Store returned an invalid download response."
        case .noItems: "Apple returned no downloadable file for this app or version. Please try again later."
        case .invalidEndpoint: "Apple's service list did not provide a supported download endpoint."
        case .missingCatalogVersion: "Apple's catalog did not provide a current version for this app in your account's region."
        case .mismatchedUpdate: "Apple returned a different app or version than requested."
        }
    }
}

/// Shared by downloading, version listing and version metadata. Empty volume-store
/// success responses are not evidence of a missing license or an expired session.
enum AppStoreDownloadProduct {
    static func body(appID: Int64, guid: String, versionID: String?) throws -> Data {
        var payload: [String: Any] = [
            "creditDisplay": "", "guid": guid, "salableAdamId": appID,
            "serialNumber": "0"
        ]
        if let versionID, !versionID.isEmpty { payload["externalVersionId"] = versionID }
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    static func item(
        request: URLRequest,
        redownloadEndpoint: () async throws -> URL,
        latestVersionID: (() async throws -> String)? = nil,
        updateEndpoint: (() async throws -> URL?)? = nil,
        bundleID: String? = nil,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> [String: Any] {
        try Task.checkCancellation()
        let primary = try await response(to: request, send: send)
        if let item = primary.first { return item }

        // Only a well-formed HTTP 200 with an explicitly empty songList reaches here.
        // Resolve the consumer endpoint from Apple's bag, keeping volumeStore primary.
        let endpoint = try await redownloadEndpoint()
        guard isSupportedRedownloadEndpoint(endpoint),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let data = request.httpBody,
              var payload = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let guid = payload["guid"] as? String else {
            throw AppStoreDownloadProductError.invalidEndpoint
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "guid" }
        query.append(URLQueryItem(name: "guid", value: guid))
        components.queryItems = query
        // The two endpoints use different keys; otherwise redownload silently
        // ignores an explicitly selected historical version and serves the latest.
        payload["appExtVrsId"] = payload.removeValue(forKey: "externalVersionId")
        var fallback = request
        fallback.url = components.url
        fallback.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try Task.checkCancellation()
        var (fallbackData, fallbackResponse) = try await send(fallback)
        if (fallbackResponse as? HTTPURLResponse)?.statusCode == 500,
           fallbackData.isEmpty, payload["appExtVrsId"] == nil,
           let latestVersionID {
            // Some consumer downloads fail only when no version is specified.
            // Resolve the current catalog version once; never replace a selected version.
            try Task.checkCancellation()
            let version = try await latestVersionID()
            guard isValidVersionID(version) else { throw AppStoreDownloadProductError.missingCatalogVersion }
            payload["appExtVrsId"] = version
            fallback.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            try Task.checkCancellation()
            (fallbackData, fallbackResponse) = try await send(fallback)
        }
        // A pinned redownload can also return an empty 500. The bag's update
        // endpoint can serve the same iOS build (ipatool 741049d). Callers only
        // provide this fallback for iOS/iPadOS; do not infer a missing license.
        if (fallbackResponse as? HTTPURLResponse)?.statusCode == 500,
           fallbackData.isEmpty, let version = payload["appExtVrsId"] as? String,
           isValidVersionID(version), let updateEndpoint {
            try Task.checkCancellation()
            if let endpoint = try await updateEndpoint() {
                guard isSupportedUpdateEndpoint(endpoint),
                      var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                    throw AppStoreDownloadProductError.invalidEndpoint
                }
                components.queryItems = [URLQueryItem(name: "guid", value: guid)]
                var update = fallback
                update.url = components.url
                try Task.checkCancellation()
                let items = try await response(to: update, send: send)
                guard items.count == 1, let item = items.first,
                      let metadata = item["metadata"] as? [String: Any],
                      let requestedAppID = identifier(payload["salableAdamId"]),
                      identifier(metadata["itemId"]) == requestedAppID,
                      identifier(metadata["softwareVersionExternalIdentifier"]) == version,
                      let returnedBundle = metadata["softwareVersionBundleId"] as? String,
                      !returnedBundle.isEmpty,
                      bundleID == nil || bundleID == "" || returnedBundle == bundleID else {
                    throw AppStoreDownloadProductError.mismatchedUpdate
                }
                return item
            }
        }
        let items = try decode(data: fallbackData, response: fallbackResponse)
        guard let item = items.first else { throw AppStoreDownloadProductError.noItems }
        return item
    }

    static func isSupportedRedownloadEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "downloaddispatch.itunes.apple.com" &&
        url.path == "/r/redownload" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && url.fragment == nil
    }

    static func isSupportedUpdateEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == "downloaddispatch.itunes.apple.com" &&
            components.percentEncodedPath == "/up/updateProduct" && components.user == nil &&
            components.password == nil && components.port == nil && components.query == nil && components.fragment == nil
    }

    private static func identifier(_ value: Any?) -> String? {
        if let string = value as? String, isValidVersionID(string) { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           isValidVersionID(number.stringValue) { return number.stringValue }
        return nil
    }

    private static func response(
        to request: URLRequest,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> [[String: Any]] {
        let (data, response) = try await send(request)
        return try decode(data: data, response: response)
    }

    private static func decode(data: Data, response: URLResponse) throws -> [[String: Any]] {
        guard let http = response as? HTTPURLResponse else { throw AppStoreDownloadProductError.invalidResponse }
        guard http.statusCode == 200 else { throw AppStoreDownloadProductError.http(http.statusCode) }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppStoreDownloadProductError.invalidResponse
        }
        let code = (plist["failureType"] as? String) ?? (plist["failureType"] as? NSNumber)?.stringValue ?? ""
        let message = plist["customerMessage"] as? String ?? ""
        if !code.isEmpty || !message.isEmpty {
            throw AppStoreDownloadProductError.failure(code: code, message: message)
        }
        if let status = plist["status"] as? Int, status != 0 {
            throw AppStoreDownloadProductError.failure(code: String(status), message: "")
        }
        guard let items = plist["songList"] as? [[String: Any]] else {
            throw AppStoreDownloadProductError.invalidResponse
        }
        return items
    }

    static func catalogRequest(appID: Int64, countryCode: String) throws -> URLRequest {
        guard appID > 0, countryCode.count == 2 else { throw AppStoreDownloadProductError.missingCatalogVersion }
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = ["version": "2", "id": String(appID), "p": "mdm-lockup",
                          "caller": "MDM", "platform": "enterprisestore",
                          "cc": countryCode.lowercased(), "l": "en"].map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func catalogVersionID(data: Data, appID: Int64) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let item = results[String(appID)] as? [String: Any],
              let offers = item["offers"] as? [[String: Any]], let offer = offers.first else {
            throw AppStoreDownloadProductError.missingCatalogVersion
        }
        let version = offer["version"] as? [String: Any]
        var externalID = version?["externalId"] as? String
        if let number = version?["externalId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            externalID = number.stringValue
        }
        if externalID == nil || externalID == "" {
            var params = URLComponents()
            params.query = offer["buyParams"] as? String
            externalID = params.queryItems?.first(where: { $0.name == "appExtVrsId" })?.value
        }
        guard let externalID, isValidVersionID(externalID) else { throw AppStoreDownloadProductError.missingCatalogVersion }
        return externalID
    }

    private static func isValidVersionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (Int64(value) ?? 0) > 0
    }
}
