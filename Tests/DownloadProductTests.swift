import Foundation

enum DownloadProductTests {
    static func run() async throws {
        let check = MZFinanceTests.check
        let endpoint = URL(string: "https://downloaddispatch.itunes.apple.com/r/redownload?fixture=1")!
        let empty: [String: Any] = ["authorized": false, "status": 0,
                                   "jingleDocType": "purchaseSuccess", "jingleAction": "purchaseProduct",
                                   "download-queue-item-count": 1, "songList": [[String: Any]]()]
        let metadata: [String: Any] = ["softwareVersionExternalIdentifiers": [123, 456], "bundleShortVersionString": "1.2"]
        let success: [String: Any] = ["songList": [["URL": "https://fixture.invalid/app.ipa",
                                                   "metadata": metadata,
                                                   "sinfs": [["id": 1, "sinf": Data([1, 2, 3])]]]]]
        func result(_ request: URLRequest, _ plist: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
            (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        func request(_ version: String?) throws -> URLRequest {
            var request = URLRequest(url: URL(string: "https://p46-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=fixture")!)
            request.httpMethod = "POST"
            request.setValue("fixture-dsid", forHTTPHeaderField: "X-Dsid")
            request.setValue("fixture-agent", forHTTPHeaderField: "User-Agent")
            request.httpBody = try AppStoreDownloadProduct.body(appID: 335162906, guid: "fixture", versionID: version)
            return request
        }
        // Exact reported empty success, for both latest and explicit older versions.
        for version in [nil, "123"] as [String?] {
            var sent: [URLRequest] = []
            var bagCalls = 0
            let item = try await AppStoreDownloadProduct.item(request: request(version), redownloadEndpoint: {
                bagCalls += 1
                return endpoint
            }, send: { request in
                sent.append(request)
                return try result(request, sent.count == 1 ? empty : success)
            })
            try check(sent.count == 2 && bagCalls == 1, "Empty volume-store success must fall back exactly once")
            let fallback = sent[1]
            let payload = try PropertyListSerialization.propertyList(from: fallback.httpBody!, format: nil) as! [String: Any]
            try check(fallback.httpMethod == "POST" && fallback.url?.host == endpoint.host, "Fallback must preserve POST")
            try check(fallback.value(forHTTPHeaderField: "X-Dsid") == "fixture-dsid", "Fallback lost account context")
            try check(payload["serialNumber"] as? String == "0" && payload["salableAdamId"] as? Int == 335162906, "Download payload changed")
            try check(payload["appExtVrsId"] as? String == version && payload["externalVersionId"] == nil, "Historical version was lost")
            let query = URLComponents(url: fallback.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try check(query.contains(URLQueryItem(name: "guid", value: "fixture")) && query.contains(URLQueryItem(name: "fixture", value: "1")), "Fallback query lost")
            try check((item["metadata"] as? [String: Any])?["bundleShortVersionString"] as? String == "1.2", "Version metadata lost")
            try check((item["sinfs"] as? [[String: Any]])?.first?["sinf"] as? Data == Data([1, 2, 3]), "SINF data lost")
        }
        var primaryCalls = 0
        _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: {
            throw MZFinanceTests.Failure(message: "Fetched bag for a working download")
        }, send: { request in
            primaryCalls += 1
            return try result(request, success)
        })
        try check(primaryCalls == 1, "Working downloads should use one metadata request")

        for code in ["9610", "2034", "1008", "5002"] {
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: {
                    throw MZFinanceTests.Failure(message: "Fell back on an explicit Apple error")
                }, send: { try result($0, ["failureType": code, "customerMessage": "fixture error"]) })
                throw MZFinanceTests.Failure(message: "Swallowed Apple failure")
            } catch AppStoreDownloadProductError.failure(let actual, _) {
                try check(actual == code, "Lost Apple error code")
            }
        }
        for status in [403, 429, 500, 503] {
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: {
                    throw MZFinanceTests.Failure(message: "Fell back on an HTTP failure")
                }, send: { try result($0, empty, status: status) })
                throw MZFinanceTests.Failure(message: "Swallowed HTTP failure")
            } catch AppStoreDownloadProductError.http(let actual) {
                try check(actual == status, "Lost HTTP status")
            }
        }
        var emptyCalls = 0
        do {
            _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: { endpoint }, send: {
                emptyCalls += 1
                return try result($0, empty)
            })
            throw MZFinanceTests.Failure(message: "Accepted empty fallback")
        } catch AppStoreDownloadProductError.noItems {
            try check(emptyCalls == 2, "Repeated empty fallback")
        }
        for plist in [["status": 0], ["songList": "invalid"]] as [[String: Any]] {
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: {
                    throw MZFinanceTests.Failure(message: "Fell back on malformed response")
                }, send: { try result($0, plist) })
                throw MZFinanceTests.Failure(message: "Accepted malformed response")
            } catch AppStoreDownloadProductError.invalidResponse {}
        }
        for url in ["http://downloaddispatch.itunes.apple.com/r/redownload",
                    "https://downloaddispatch.itunes.apple.com.evil.invalid/r/redownload",
                    "https://user:pass@downloaddispatch.itunes.apple.com/r/redownload",
                    "https://downloaddispatch.itunes.apple.com:444/r/redownload",
                    "https://downloaddispatch.itunes.apple.com/other"] {
            var calls = 0
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: { URL(string: url)! }, send: {
                    calls += 1
                    return try result($0, empty)
                })
                throw MZFinanceTests.Failure(message: "Accepted unsupported endpoint")
            } catch AppStoreDownloadProductError.invalidEndpoint {
                try check(calls == 1, "Sent account context to unsupported endpoint")
            }
        }
        func emptyHTTP(_ request: URLRequest, status: Int = 500, data: Data = Data()) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        // Reported chain: empty purchase success -> empty redownload 500 -> pinned success.
        for retrySucceeds in [true, false] {
            var sent: [URLRequest] = []
            var lookups = 0
            do {
                let item = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: { endpoint }, latestVersionID: {
                    lookups += 1
                    return "891009506"
                }, send: { request in
                    sent.append(request)
                    if sent.count == 1 { return try result(request, empty) }
                    if sent.count == 2 || !retrySucceeds { return emptyHTTP(request) }
                    return try result(request, success)
                })
                try check(retrySucceeds && item["URL"] as? String == "https://fixture.invalid/app.ipa", "Pinned retry lost download item")
            } catch AppStoreDownloadProductError.http(let status) {
                try check(!retrySucceeds && status == 500, "Unexpected pinned retry failure")
            }
            try check(sent.count == 3 && lookups == 1, "Catalog retry must be bounded")
            let pinned = sent[2]
            let payload = try PropertyListSerialization.propertyList(from: pinned.httpBody!, format: nil) as! [String: Any]
            try check(payload["appExtVrsId"] as? String == "891009506", "Missing catalog version")
            try check(payload["externalVersionId"] == nil && payload["salableAdamId"] as? Int == 335162906, "Pinned retry changed app")
            try check(pinned.url == sent[1].url && pinned.allHTTPHeaderFields == sent[1].allHTTPHeaderFields && pinned.httpMethod == "POST", "Pinned retry lost session context")
        }
        // No substitution for historical versions, nonempty errors, other statuses or primary 500.
        for (version, status, body, primary) in [
            ("123", 500, Data(), false), (nil, 500, Data("server error".utf8), false),
            (nil, 503, Data(), false), (nil, 429, Data(), false), (nil, 500, Data(), true)
        ] as [(String?, Int, Data, Bool)] {
            var calls = 0
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(version), redownloadEndpoint: { endpoint }, latestVersionID: {
                    throw MZFinanceTests.Failure(message: "Looked up a version for an ineligible response")
                }, send: { request in
                    calls += 1
                    if calls == 1 && !primary { return try result(request, empty) }
                    return emptyHTTP(request, status: status, data: body)
                })
                throw MZFinanceTests.Failure(message: "Swallowed ineligible HTTP error")
            } catch AppStoreDownloadProductError.http(let actual) {
                try check(actual == status && calls == (primary ? 1 : 2), "Retried ineligible HTTP error")
            }
        }
        for lookupFails in [true, false] {
            var calls = 0
            do {
                _ = try await AppStoreDownloadProduct.item(request: request(nil), redownloadEndpoint: { endpoint }, latestVersionID: {
                    if lookupFails { throw AppStoreDownloadProductError.missingCatalogVersion }
                    return "invalid"
                }, send: { request in
                    calls += 1
                    return calls == 1 ? try result(request, empty) : emptyHTTP(request)
                })
                throw MZFinanceTests.Failure(message: "Retried without a valid catalog version")
            } catch AppStoreDownloadProductError.missingCatalogVersion {
                try check(calls == 2, "Sent an unvalidated pinned retry")
            }
        }
        let catalogRequest = try AppStoreDownloadProduct.catalogRequest(appID: 335162906, countryCode: "TR")
        let catalogQuery = URLComponents(url: catalogRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        try check(catalogQuery.contains(URLQueryItem(name: "cc", value: "tr")) && catalogQuery.contains(URLQueryItem(name: "platform", value: "enterprisestore")), "Catalog request lost region/platform")
        for offer in [["version": ["externalId": 891009506]], ["version": ["externalId": "891009506"]],
                      ["buyParams": "salableAdamId=335162906&appExtVrsId=891009506"]] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: ["results": ["335162906": ["offers": [offer]]]])
            try check(try AppStoreDownloadProduct.catalogVersionID(data: data, appID: 335162906) == "891009506", "Catalog version parsing failed")
            do {
                _ = try AppStoreDownloadProduct.catalogVersionID(data: data, appID: 123)
                throw MZFinanceTests.Failure(message: "Used another app's catalog version")
            } catch AppStoreDownloadProductError.missingCatalogVersion {}
        }
        for value in [true, 0, -1, 1.5, "", "19.32.0", "unknown"] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["results": ["335162906": ["offers": [["version": ["externalId": value]]]]]])
            do {
                _ = try AppStoreDownloadProduct.catalogVersionID(data: data, appID: 335162906)
                throw MZFinanceTests.Failure(message: "Accepted invalid catalog version")
            } catch AppStoreDownloadProductError.missingCatalogVersion {}
        }
        let updateEndpoint = URL(string: "https://downloaddispatch.itunes.apple.com/up/updateProduct")!
        // Exact new report: primary empty -> unpinned 500 -> pinned 500 -> update.
        // Historical selections skip catalog resolution and retain their version.
        for version in [nil, "123"] as [String?] {
            let selected = version ?? "891009506"
            let validMetadata: [String: Any] = ["itemId": 335162906,
                "softwareVersionExternalIdentifier": selected, "softwareVersionBundleId": "com.turkcell.CSI"]
            for outcome in ["success", "http", "license", "empty", "multiple", "app", "version", "bundle", "missing"] {
                var calls = 0
                var lookups = 0
                var updates = 0
                do {
                    let item = try await AppStoreDownloadProduct.item(request: request(version), redownloadEndpoint: { endpoint }, latestVersionID: {
                        lookups += 1
                        return selected
                    }, updateEndpoint: {
                        updates += 1
                        return updateEndpoint
                    }, bundleID: "com.turkcell.CSI", send: { req in
                        calls += 1
                        if calls == 1 { return try result(req, empty) }
                        guard req.url?.path == "/up/updateProduct" else { return emptyHTTP(req) }
                        let payload = try PropertyListSerialization.propertyList(from: req.httpBody!, format: nil) as! [String: Any]
                        try check(payload["appExtVrsId"] as? String == selected && payload["externalVersionId"] == nil, "Update changed selected version")
                        try check(payload["salableAdamId"] as? Int == 335162906 && payload["guid"] as? String == "fixture", "Update changed app/GUID")
                        try check(req.httpMethod == "POST" && req.value(forHTTPHeaderField: "X-Dsid") == "fixture-dsid", "Update lost session context")
                        try check(req.url?.query == "guid=fixture", "Update inherited redownload query")
                        if outcome == "http" { return emptyHTTP(req) }
                        if outcome == "license" { return try result(req, ["failureType": "9610"]) }
                        var metadata = validMetadata
                        if outcome == "app" { metadata["itemId"] = 42 }
                        if outcome == "version" { metadata["softwareVersionExternalIdentifier"] = "999" }
                        if outcome == "bundle" { metadata["softwareVersionBundleId"] = "com.other" }
                        if outcome == "missing" { metadata.removeValue(forKey: "itemId") }
                        var item = (success["songList"] as! [[String: Any]])[0]
                        item["metadata"] = metadata
                        let count = outcome == "empty" ? 0 : outcome == "multiple" ? 2 : 1
                        return try result(req, ["songList": Array(repeating: item, count: count)])
                    })
                    try check(outcome == "success", "Accepted invalid update response")
                    try check((item["sinfs"] as? [[String: Any]])?.first?["sinf"] as? Data == Data([1, 2, 3]), "Update lost SINF")
                } catch AppStoreDownloadProductError.http(let status) {
                    try check(outcome == "http" && status == 500, "Lost update HTTP error")
                } catch AppStoreDownloadProductError.failure(let code, _) {
                    try check(outcome == "license" && code == "9610", "Lost update license error")
                } catch AppStoreDownloadProductError.mismatchedUpdate {
                    try check(["empty", "multiple", "app", "version", "bundle", "missing"].contains(outcome), "Rejected matching update")
                }
                try check(calls == (version == nil ? 4 : 3) && lookups == (version == nil ? 1 : 0) && updates == 1, "Update fallback is not bounded")
            }
        }
        // Update is optional and cannot widen the failure/platform conditions.
        for (status, body) in [(403, Data()), (429, Data()), (503, Data()), (500, Data("maintenance".utf8))] {
            do {
                var calls = 0
                _ = try await AppStoreDownloadProduct.item(request: request("123"), redownloadEndpoint: { endpoint }, updateEndpoint: {
                    throw MZFinanceTests.Failure(message: "Updated after an ineligible error")
                }, send: { req in
                    calls += 1
                    return calls == 1 ? try result(req, empty) : emptyHTTP(req, status: status, data: body)
                })
                throw MZFinanceTests.Failure(message: "Swallowed original error")
            } catch AppStoreDownloadProductError.http(let actual) { try check(actual == status, "Changed error status") }
        }
        for url in [nil, "https://evil.invalid/up/updateProduct", "http://downloaddispatch.itunes.apple.com/up/updateProduct",
                    "https://downloaddispatch.itunes.apple.com/up/%75pdateProduct", updateEndpoint.absoluteString + "?guid=other",
                    updateEndpoint.absoluteString + "#fragment", "https://user@downloaddispatch.itunes.apple.com/up/updateProduct",
                    "https://downloaddispatch.itunes.apple.com:443/up/updateProduct", endpoint.absoluteString] as [String?] {
            var calls = 0
            do {
                _ = try await AppStoreDownloadProduct.item(request: request("123"), redownloadEndpoint: { endpoint }, updateEndpoint: {
                    url.flatMap(URL.init(string:))
                }, send: { req in
                    calls += 1
                    return calls == 1 ? try result(req, empty) : emptyHTTP(req)
                })
                throw MZFinanceTests.Failure(message: "Accepted missing/unsafe update endpoint")
            } catch AppStoreDownloadProductError.http(let status) {
                try check(url == nil && status == 500, "Missing endpoint lost original error")
            } catch AppStoreDownloadProductError.invalidEndpoint { try check(url != nil, "Unexpected missing endpoint error") }
            try check(calls == 2, "Sent update to unsupported endpoint")
        }
        print("PASS: empty volume-store fallback, bounded catalog/update fallbacks, selected version and app validation, metadata/SINF and endpoint validation")
    }
}
