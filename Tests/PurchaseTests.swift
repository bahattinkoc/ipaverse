import Foundation

enum PurchaseTests {
    private static let check = MZFinanceTests.check
    private static let appID: Int64 = 1215185098
    private static let success: [String: Any] = ["jingleDocType": "purchaseSuccess", "status": 0]

    private static func response(_ plist: Any, status: Int = 200) throws -> (Data, URLResponse) {
        (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), http(status))
    }

    private static func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://p46-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!,
                        statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func request() -> URLRequest {
        var request = URLRequest(url: http(200).url!)
        request.setValue("fixture-token", forHTTPHeaderField: "X-Token")
        request.setValue("fixture-dsid", forHTTPHeaderField: "X-Dsid")
        request.setValue("143480-2,34", forHTTPHeaderField: "X-Apple-Store-Front")
        return request
    }

    static func run() async throws {
        // First-time acquisition followed by the same latest/historical download.
        // Use the real download parser and purchase transport with synthetic replies.
        for version in [nil, "123456"] as [String?] {
            for purchaseCode in [nil, "5002", "2022"] as [String?] {
                var events: [String] = []
                var downloads = 0
                do {
                    let item = try await AppStorePurchase.withLicense(operation: {
                        downloads += 1
                        var download = URLRequest(url: URL(string: "https://p46-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct")!)
                        download.httpBody = try AppStoreDownloadProduct.body(appID: appID, guid: "fixture", versionID: version)
                        return try await AppStoreDownloadProduct.item(request: download, redownloadEndpoint: {
                            throw MZFinanceTests.Failure(message: "License recovery incorrectly fetched a bag")
                        }, send: { request in
                            events.append("download")
                            let body = try PropertyListSerialization.propertyList(from: request.httpBody!, format: nil) as! [String: Any]
                            try check(body["externalVersionId"] as? String == version, "License recovery changed selected version")
                            if downloads == 1 {
                                return try response(["failureType": "9610", "customerMessage": "License not found"])
                            }
                            return try response(["songList": [["URL": "https://fixture.invalid/app.ipa"]]])
                        })
                    }, isLicenseRequired: {
                        if case AppStoreDownloadProductError.failure(let code, _) = $0 { return code == "9610" }
                        return false
                    }, purchase: {
                        try await AppStorePurchase.acquire(request: request(), appID: appID, price: 0, guid: "fixture", allowsArcade: true, send: { request in
                            events.append("purchase")
                            let body = try PropertyListSerialization.propertyList(from: request.httpBody!, format: nil) as! [String: Any]
                            try check(request.httpMethod == "POST" && body["salableAdamId"] as? Int64 == appID, "Wrong purchase target")
                            try check(body["pricingParameters"] as? String == "STDQ" && body["price"] as? String == "0", "Wrong free-purchase mode")
                            try check(body["appExtVrsId"] as? String == "0", "Historical download must acquire the current license")
                            try check(request.value(forHTTPHeaderField: "X-Token") == "fixture-token" && request.value(forHTTPHeaderField: "X-Apple-Store-Front") == "143480-2,34", "Purchase lost account context")
                            if let purchaseCode {
                                return try response(["failureType": purchaseCode, "customerMessage": "There is a billing problem with a previous purchase."])
                            }
                            return try response(success)
                        })
                    })
                    try check(purchaseCode != "2022" && item["URL"] != nil, "Billing failure was swallowed")
                    try check(events == ["download", "purchase", "download"], "First-time license flow did not resume exactly once")
                } catch AppStorePurchaseError.failure(let code, _) {
                    try check(code == "2022" && purchaseCode == code, "Lost billing error")
                    try check(events == ["download", "purchase"], "Retried or switched pricing after billing rejection")
                }
            }
        }

        // Repeated missing-license errors cannot create a purchase loop.
        var purchases = 0
        var operations = 0
        do {
            let _: Int = try await AppStorePurchase.withLicense(operation: {
                operations += 1
                throw AppStoreDownloadProductError.failure(code: "9610", message: "License not found")
            }, isLicenseRequired: { _ in true }, purchase: { purchases += 1 })
            throw MZFinanceTests.Failure(message: "Missing license accepted")
        } catch AppStorePurchaseError.licenseUnavailable {
            try check(purchases == 1 && operations == 2, "License acquisition is not bounded")
        }
        // Already-owned apps and unrelated failures must never purchase.
        let value = try await AppStorePurchase.withLicense(operation: { 42 }, isLicenseRequired: { _ in true }, purchase: {
            throw MZFinanceTests.Failure(message: "Purchased an owned app")
        })
        try check(value == 42, "Changed a successful result")
        do {
            let _: Int = try await AppStorePurchase.withLicense(operation: { throw URLError(.timedOut) }, isLicenseRequired: { _ in false }, purchase: {
                throw MZFinanceTests.Failure(message: "Purchased after a network error")
            })
            throw MZFinanceTests.Failure(message: "Swallowed network error")
        } catch let error as URLError { try check(error.code == .timedOut, "Changed network error") }

        for price in [nil, -1, 1, Double.nan] as [Double?] {
            do {
                try await AppStorePurchase.acquire(request: request(), appID: appID, price: price, guid: "fixture", allowsArcade: true, send: { _ in
                    throw MZFinanceTests.Failure(message: "Sent purchase for an app not confirmed free")
                })
                throw MZFinanceTests.Failure(message: "Accepted unknown or paid price")
            } catch AppStorePurchaseError.paidOrUnknownPrice {}
        }
        for id in [nil, 0, -1] as [Int64?] {
            do {
                try await AppStorePurchase.acquire(request: request(), appID: id, price: 0, guid: "fixture", allowsArcade: true, send: { _ in
                    throw MZFinanceTests.Failure(message: "Sent purchase without a valid app ID")
                })
                throw MZFinanceTests.Failure(message: "Accepted invalid app ID")
            } catch AppStorePurchaseError.invalidApp {}
        }
        for allowsArcade in [true, false] {
            var modes: [String] = []
            do {
                try await AppStorePurchase.acquire(request: request(), appID: appID, price: 0, guid: "fixture", allowsArcade: allowsArcade, send: { request in
                    let body = try PropertyListSerialization.propertyList(from: request.httpBody!, format: nil) as! [String: Any]
                    modes.append(body["pricingParameters"] as! String)
                    return try response(["failureType": "2059", "customerMessage": "Unavailable"])
                })
                throw MZFinanceTests.Failure(message: "Accepted failed Arcade purchase")
            } catch AppStorePurchaseError.failure(let code, _) {
                try check(code == "2059" && modes == (allowsArcade ? ["STDQ", "GAME"] : ["STDQ"]), "Incorrect Arcade retry policy")
            }
        }
        for code in ["2022", "2034", "1008", "5002"] {
            for status in [200, 500] {
                var calls = 0
                do {
                    try await AppStorePurchase.acquire(request: request(), appID: appID, price: 0, guid: "fixture", allowsArcade: true, send: { _ in
                        calls += 1
                        return try response(["failureType": Int(code)!, "customerMessage": "fixture"], status: status)
                    })
                    throw MZFinanceTests.Failure(message: "Swallowed Apple failure")
                } catch AppStorePurchaseError.failure(let actual, _) {
                    try check(actual == code && calls == 1, "Lost Apple error or retried purchase")
                }
            }
        }
        for status in [204, 403, 429, 500, 503] {
            do {
                try AppStorePurchase.validate(data: Data(), response: http(status))
                throw MZFinanceTests.Failure(message: "HTTP failure treated as owned")
            } catch AppStorePurchaseError.http(let actual) { try check(actual == status, "Lost HTTP status") }
        }
        for plist in [[:], ["status": 0], ["jingleDocType": "purchaseSuccess"],
                      ["jingleDocType": "purchaseSuccess", "status": false],
                      ["jingleDocType": "purchaseSuccess", "status": 1],
                      ["jingleDocType": "purchaseSuccess", "status": 0, "cancel-purchase-batch": true],
                      ["jingleDocType": "purchaseSuccess", "status": 0, "m-allowed": false]] as [[String: Any]] {
            do {
                let (data, response) = try response(plist)
                try AppStorePurchase.validate(data: data, response: response)
                throw MZFinanceTests.Failure(message: "Invalid purchase response accepted")
            } catch AppStorePurchaseError.invalidResponse {}
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await AppStorePurchase.acquire(request: request(), appID: appID, price: 0, guid: "fixture", allowsArcade: true, send: { _ in
                throw MZFinanceTests.Failure(message: "Sent cancelled purchase")
            })
        }
        do { try await cancelled.value; throw MZFinanceTests.Failure(message: "Ignored cancellation") }
        catch is CancellationError {}
        print("PASS: first-time free purchase, resumed downloads, bounded recovery, billing/auth failures, malformed responses and cancellation")
    }
}
