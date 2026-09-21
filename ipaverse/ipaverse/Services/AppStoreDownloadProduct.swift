import Foundation

enum AppStoreDownloadProductError: LocalizedError {
    case http(Int)
    case failure(code: String, message: String)
    case invalidResponse
    case noItems
    case invalidEndpoint
    case missingCatalogVersion
    case mismatchedUpdate
    case platformMismatch(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): "App Store download request failed (HTTP \(status))."
        case .failure(let code, let message): message.isEmpty ? "App Store download failed (\(code))." : message
        case .invalidResponse: "App Store returned an invalid download response."
        case .noItems: "Apple returned no downloadable file for this app or version. Please try again later."
        case .invalidEndpoint: "Apple's service list did not provide a supported download endpoint."
        case .missingCatalogVersion: "Apple's catalog did not provide a current version for this app in your account's region."
        case .platformMismatch(let expected): "Apple returned a package that does not support \(expected)."
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
        var request = request
        try Task.checkCancellation()
        let primary = try await response(to: request, send: send)
        if let item = primary.first { return item }

        // The /r/redownload consumer dispatch path is unreliable when no version
        // is pinned — it can fail unrelated apps with spurious errors (empty 500s,
        // stale "Terms and Conditions changed" dialogs) that have nothing to do
        // with the account. Other App Store tooling avoids it by pinning a real
        // externalVersionId and retrying the primary (volumeStore) endpoint first.
        if let latestVersionID,
           let data = request.httpBody,
           var pinnedPayload = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           pinnedPayload["externalVersionId"] == nil {
            try Task.checkCancellation()
            if let version = try? await latestVersionID(), isValidVersionID(version) {
                pinnedPayload["externalVersionId"] = version
                var pinned = request
                pinned.httpBody = try PropertyListSerialization.data(fromPropertyList: pinnedPayload, format: .xml, options: 0)
                // Keep the selected platform/version when moving to redownload.
                request = pinned
                try Task.checkCancellation()
                if let item = try? await response(to: pinned, send: send).first { return item }
            }
        }

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
        // endpoint can serve the same iOS or macOS build (ipatool 741049d).
        // Callers exclude tvOS/visionOS; do not infer a missing license.
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

    static func catalogRequest(appID: Int64, countryCode: String, platform: String = "enterprisestore") throws -> URLRequest {
        guard appID > 0, countryCode.count == 2 else { throw AppStoreDownloadProductError.missingCatalogVersion }
        var url = URLComponents(string: "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup")!
        url.queryItems = ["version": "2", "id": String(appID), "p": "mdm-lockup",
                          "caller": "MDM", "platform": platform,
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

    /// The product page carries separate offers for universal Mac/vision apps.
    /// Never take an unrelated recommendation or the iOS offer from that page.
    static func storefrontVersionID(data: Data, appID: Int64, platform: String, bundleID: String?) throws -> String {
        guard let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']serialized-server-data["'][^>]*>(.*?)</script>"#,
                                                    options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let json = String(html[range]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) else {
            throw AppStoreDownloadProductError.missingCatalogVersion
        }
        var versions = Set<String>()
        func visit(_ value: Any) {
            if let list = value as? [Any] { list.forEach(visit) }
            guard let object = value as? [String: Any] else { return }
            if let config = object["purchaseConfiguration"] as? [String: Any],
               (config["appPlatforms"] as? [String])?.contains(platform) == true,
               platform != "vision" || config["metricsPlatformDisplayStyle"] as? String == "vision",
               bundleID == nil || bundleID == "" || config["bundleId"] as? String == bundleID,
               let buyParams = config["buyParams"] as? String {
                var params = URLComponents()
                params.query = buyParams
                let items = params.queryItems ?? []
                if items.first(where: { $0.name == "salableAdamId" })?.value == String(appID),
                   let version = items.first(where: { $0.name == "appExtVrsId" })?.value,
                   isValidVersionID(version) { versions.insert(version) }
            }
            object.values.forEach(visit)
        }
        visit(root)
        guard versions.count == 1, let version = versions.first else {
            throw AppStoreDownloadProductError.missingCatalogVersion
        }
        return version
    }

    static func catalogSupports(platform: String, devices: [String], kind: String?) -> Bool {
        let prefixes: [String]
        switch platform {
        case "tvOS": prefixes = ["AppleTV"]
        case "visionOS": prefixes = ["AppleVisionPro", "RealityDevice", "Vision"]
        case "iPadOS": prefixes = ["iPad"]
        case "iOS": prefixes = ["iPhone", "iPod"]
        case "macOS": return kind == "mac-software" || devices.contains { $0.hasPrefix("Mac") }
        default: return false
        }
        return devices.contains { device in prefixes.contains { device.hasPrefix($0) } }
    }

    static func validatePlatform(plist: [String: Any], platform: String) throws {
        let supported = plist["CFBundleSupportedPlatforms"] as? [String] ?? []
        let families = plist["UIDeviceFamily"] as? [Int] ?? []
        let valid: Bool
        switch platform {
        case "tvOS": valid = supported.contains("AppleTVOS")
        case "visionOS": valid = supported.contains("XROS")
        case "iOS": valid = supported.contains("iPhoneOS") && families.contains(1)
        case "iPadOS": valid = supported.contains("iPhoneOS") && families.contains(2)
        case "macOS": valid = supported.contains("MacOSX")
        default: valid = false
        }
        guard valid else { throw AppStoreDownloadProductError.platformMismatch(platform) }
    }

    private static func isValidVersionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (Int64(value) ?? 0) > 0
    }
}
