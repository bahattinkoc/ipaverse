import Foundation

enum MZFinanceTests {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func run() async throws {
        let url = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=fixture")!
        let request = try MZFinanceAuthentication.makeRequest(url: url, email: "fixture@example.invalid",
                                                             pet: "fixture-pet", deviceID: "fixture", userAgent: "fixture")
        let success = try PropertyListSerialization.data(fromPropertyList: ["passwordToken": "fixture-token"], format: .xml, options: 0)
        func response(_ request: URLRequest, _ status: Int, _ headers: [String: String]? = nil) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        var sent: [URLRequest] = []
        var delays: [UInt64] = []
        var preparations = 0
        let (data, _) = try await MZFinanceAuthentication.exchange(request: request) { request in
            preparations += 1
            var prepared = request
            prepared.setValue("otp-\(preparations)", forHTTPHeaderField: "X-Apple-I-MD")
            prepared.setValue("signature-\(preparations)", forHTTPHeaderField: "X-Apple-ActionSignature")
            return prepared
        } send: { request in
            sent.append(request)
            switch sent.count {
            case 1: return (Data(), response(request, 204))
            case 2: return (Data(), response(request, 404))
            case 3: return (Data(), response(request, 302, ["Location": "https://p46-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=fixture"]))
            default: return (success, response(request, 200))
            }
        } sleep: { delays.append($0) }
        try check(data == success && sent.count == 4, "Retry/redirect flow failed")
        try check(delays == [1_000_000_000, 2_000_000_000], "Retry backoff changed")
        for (index, actual) in sent.enumerated() {
            try check(actual.httpBody == request.httpBody && actual.httpMethod == "POST", "Signed payload changed across retry/redirect")
            let body = try PropertyListSerialization.propertyList(from: actual.httpBody!, format: nil) as! [String: Any]
            try check(body["attempt"] as? String == "1" && body["password"] as? String == "fixture-pet", "Protocol attempt or PET changed")
            try check(actual.value(forHTTPHeaderField: "X-Apple-I-MD") == "otp-\(index + 1)", "OTP was not refreshed")
        }
        try check(sent[0].url == sent[1].url && sent[1].url == sent[2].url && sent[3].url?.host == "p46-buy.itunes.apple.com", "Unexpected host rotation")

        for (status, calls) in [(204, 3), (404, 3), (500, 3), (503, 3), (403, 1), (429, 1)] {
            var count = 0
            do {
                _ = try await MZFinanceAuthentication.exchange(request: request, prepare: { $0 }, send: { request in
                    count += 1
                    return (Data(), response(request, status))
                }, sleep: { _ in })
                throw Failure(message: "Accepted HTTP \(status)")
            } catch MZFinanceAuthenticationError.http(let actual) {
                try check(actual == status && count == calls, "Incorrect retry limit for \(status)")
            }
        }
        for target in ["https://evil.invalid/WebObjects/MZFinance.woa/wa/authenticate",
                       "http://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate",
                       "https://buy.itunes.apple.com.evil.invalid/WebObjects/MZFinance.woa/wa/authenticate"] as [String?] {
            var count = 0
            do {
                _ = try await MZFinanceAuthentication.exchange(request: request, prepare: { $0 }, send: { request in
                    count += 1
                    return (Data(), response(request, 301, target.map { ["Location": $0] }))
                })
                throw Failure(message: "Invalid redirect accepted")
            } catch MZFinanceAuthenticationError.invalidRedirect {
                try check(count == 1, "Credentials sent to invalid redirect")
            }
        }
        var count = 0
        do {
            _ = try await MZFinanceAuthentication.exchange(request: request, prepare: { $0 }, send: { request in
                count += 1
                return (Data(), response(request, 503))
            }, sleep: { _ in throw CancellationError() })
            throw Failure(message: "Cancellation swallowed")
        } catch is CancellationError {
            try check(count == 1, "Retried after cancellation")
        }
        // Exact reported flow: successful pod routing, then a destination-less 301.
        let podURL = "https://p46-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=fixture&Pod=46&PRH=46"
        var podRequests: [URLRequest] = []
        var podPreparations = 0
        var podDelays: [UInt64] = []
        let (podData, _) = try await MZFinanceAuthentication.exchange(request: request) { request in
            podPreparations += 1
            var prepared = request
            prepared.setValue("otp-\(podPreparations)", forHTTPHeaderField: "X-Apple-I-MD")
            return prepared
        } send: { request in
            podRequests.append(request)
            switch podRequests.count {
            case 1: return (Data(), response(request, 302, ["Location": podURL]))
            case 2: return (Data("<html>301 Moved Permanently</html>".utf8), response(request, 301))
            default: return (success, response(request, 200))
            }
        } sleep: { podDelays.append($0) }
        try check(podData == success && podRequests.count == 3 && podDelays == [1_000_000_000], "Missing-Location recovery failed")
        for (index, actual) in podRequests.dropFirst().enumerated() {
            try check(actual.url?.absoluteString == podURL && actual.httpBody == request.httpBody && actual.httpMethod == "POST",
                      "Pod retry lost its query, body or POST method")
            try check(actual.value(forHTTPHeaderField: "X-Apple-I-MD") == "otp-\(index + 2)", "Pod retry reused OTP headers")
        }
        // Missing/blank Location is bounded; mixed failures share the same budget.
        for headers in [nil, ["Location": ""], ["Location": "   "]] as [[String: String]?] {
            var requests = 0
            do {
                _ = try await MZFinanceAuthentication.exchange(request: request, prepare: { $0 }, send: { request in
                    requests += 1
                    return (Data(), response(request, requests == 1 ? 503 : 301, headers))
                }, sleep: { _ in })
                throw Failure(message: "Missing-Location retries were unbounded")
            } catch MZFinanceAuthenticationError.missingRedirectLocation(301) {
                try check(requests == 3, "Mixed failures did not share the retry budget")
            }
        }
        var cancelledRequests = 0
        do {
            _ = try await MZFinanceAuthentication.exchange(request: request, prepare: { $0 }, send: { request in
                cancelledRequests += 1
                return (Data(), response(request, 301))
            }, sleep: { _ in throw CancellationError() })
            throw Failure(message: "Missing-Location cancellation swallowed")
        } catch is CancellationError {
            try check(cancelledRequests == 1, "Retried missing Location after cancellation")
        }
        print("PASS: 302 -> pod 301 without Location -> 200, stable pod query/body, shared retry limit and cancellation")
        print("PASS: MZFinance stable payload, pod redirects, fresh preparation, bounded retries, 403/429 stop and cancellation")
    }
}
