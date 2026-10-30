//
//  GSAClient.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.15.2025.
//
//  Apple GrandSlam (GSA) authentication client.
//
//  Apple migrated Apple ID / App Store auth to GSA: a two-phase SRP-6a handshake
//  against gsa.apple.com, with device-bound anisette headers. This replaces the
//  dead legacy MZFinance username/password POST.
//
//  Flow:  init  -> server returns salt/iterations/protocol/B/cookie
//         complete -> server returns M2 + encrypted `spd` (account data)
//
//  Structure follows the JJTech gsa.py reference. The SRP math and the spd key
//  derivation are verified against pysrp vectors; the live round-trip and the
//  2FA sub-flow still require validation against real server responses.
//

import Foundation

struct GSAAccountData {
    let dsid: String          // adsid
    let idmsToken: String     // GsIdmsToken
    let raw: [String: Any]    // full decrypted spd, for the App Store token bridge
}

/// Where a 2FA code was sent, and which number can receive one by SMS on request.
struct TwoFactorDelivery: Equatable, Sendable {
    /// Set once a code went out by SMS; the code is then validated through the phone endpoint.
    var smsPhoneId: Int?
    var maskedPhone: String?
    /// The trusted number Apple's verification page offers as the SMS alternative.
    var trustedPhoneId: Int?
}

enum GSAError: LocalizedError {
    case networkError
    case rateLimited
    case serverError(code: Int, message: String)
    case needsTwoFactor(identityToken: String, delivery: TwoFactorDelivery)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .networkError: "Network connection error"
        case .rateLimited: "Apple is temporarily limiting sign-in requests (HTTP 429). Please wait before trying again."
        case .serverError(let code, let message): "GSA error \(code): \(message)"
        case .needsTwoFactor: "Two-factor authentication required"
        case .invalidResponse(let detail): "Unexpected GSA response: \(detail)"
        }
    }
}

final class GSAClient {
    private let endpoint = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    private let transport: AuthenticationHTTPTransport
    private let anisette: AnisetteSession

    init(session: URLSession = .shared, anisette: AnisetteSession) {
        self.transport = AuthenticationHTTPTransport(session: session)
        self.anisette = anisette
    }

    // MARK: - Public

    /// Performs the full GSA SRP handshake. Returns decrypted account data on success,
    /// or throws `.needsTwoFactor` when the account requires a verification code.
    func authenticate(username: String, password: String) async throws -> GSAAccountData {
        let srp = SRPClient()

        // --- init ---
        let initResponse = try await send(request: [
            "A2k": srp.publicKey,
            "ps": ["s2k", "s2k_fo"],
            "u": username,
            "o": "init"
        ])

        guard let saltData = initResponse["s"] as? Data,
              let iterations = (initResponse["i"] as? NSNumber)?.intValue,
              let protocolString = initResponse["sp"] as? String,
              let bData = initResponse["B"] as? Data,
              let cookie = initResponse["c"] as? String else {
            throw GSAError.invalidResponse("init missing fields: \(initResponse.keys.sorted())")
        }
        let proto = SRPProtocol(rawValue: protocolString) ?? .s2k

        // --- complete ---
        let encrypted = SRPClient.encryptPassword(password, salt: saltData, iterations: iterations, protocol: proto)
        let m1 = srp.processChallenge(username: username, salt: saltData, serverPublicKey: bData, encryptedPassword: encrypted)

        let completeResponse = try await send(request: [
            "c": cookie,
            "M1": m1,
            "u": username,
            "o": "complete"
        ])

        // Decrypt spd (account payload) using the SRP-derived session sub-keys.
        guard let spd = completeResponse["spd"] as? Data,
              let key = srp.deriveKey(named: "extra data key:"),
              let ivFull = srp.deriveKey(named: "extra data iv:"),
              let decrypted = CryptoHelpers.aesCBCDecrypt(data: spd, key: key, iv: ivFull.prefix(16)) else {
            throw GSAError.invalidResponse("could not decrypt spd; keys: \(completeResponse.keys.sorted())")
        }

        let account = (try? PropertyListSerialization.propertyList(from: decrypted, options: [], format: nil)) as? [String: Any] ?? [:]
        print("🔐 [GSA] spd account keys: \(account.keys.sorted())")

        let dsid = (account["adsid"] as? String) ?? ""
        let idmsToken = (account["GsIdmsToken"] as? String) ?? ""

        // Detect 2FA requirement from the complete Status.
        let status = completeResponse["Status"] as? [String: Any] ?? [:]
        switch Self.secondaryAuth(in: status) {
        case .requestCode(let au):
            print("🔐 [GSA] secondary auth required: \(au)")
            let identity = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
            // `trustedDeviceSecondaryAuth` means the account has trusted devices: ask only
            // for their prompt, as Apple's own sign-in does. SMS is sent when the account
            // has none (`secondaryAuth`) or when the user asks for it.
            let delivery = try await requestTwoFactorCode(identityToken: identity,
                                                          sendSMS: au != Self.trustedDeviceSecondaryAuth)
            throw GSAError.needsTwoFactor(identityToken: identity, delivery: delivery)
        case .codeAlreadySent:
            print("🔐 [GSA] secondary auth required: code already sent to trusted devices (hsc 409)")
            let identity = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
            throw GSAError.needsTwoFactor(identityToken: identity, delivery: TwoFactorDelivery())
        case .none:
            break
        }

        guard !dsid.isEmpty, !idmsToken.isEmpty else {
            throw GSAError.invalidResponse("spd decrypted but missing adsid/GsIdmsToken: \(account.keys.sorted())")
        }

        return GSAAccountData(dsid: dsid, idmsToken: idmsToken, raw: account)
    }

    // MARK: - Request plumbing

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        NetworkLogger.shared.logRequest(request)
        let (data, response) = try await transport.data(for: request)
        NetworkLogger.shared.logResponse(response, data: data, error: nil)
        // Check before parsing: Apple's edge returns HTML, including during 2FA.
        // Do not replay a rate-limited handshake or verification-code request.
        if (response as? HTTPURLResponse)?.statusCode == 429 {
            throw GSAError.rateLimited
        }
        return (data, response)
    }

    /// Sends one GsService2 operation and returns the inner `Response` dict.
    /// Retry one potentially transient 5xx response. A 503 alone does not prove
    /// an outage: GSA also returns it for unsupported client identifiers (see
    /// AnisetteClientInfo). Other unparseable responses are not retried.
    private func send(request inner: [String: Any]) async throws -> [String: Any] {
        let maxAttempts = 2
        var attempt = 1
        var resynced: [String: String]?
        var didResync = false
        while attempt <= maxAttempts {
            let headers: [String: String]
            if let fresh = resynced {
                headers = fresh
                resynced = nil
            } else {
                headers = try await anisette.headers()
            }
            var requestBody = inner
            requestBody["cpd"] = clientProvidedData(headers: headers)
            let body: [String: Any] = ["Header": ["Version": "1.0.1"], "Request": requestBody]
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
            req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            req.setValue("akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0", forHTTPHeaderField: "User-Agent")
            req.setValue(headers["X-Mme-Client-Info"], forHTTPHeaderField: "X-MMe-Client-Info")

            let (data, response) = try await perform(req)

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let parsed = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  let responseDict = parsed["Response"] as? [String: Any] else {
                let isTransient = (500...599).contains(statusCode)
                if isTransient, attempt < maxAttempts {
                    print("🔐 [GSA] transient response (HTTP \(statusCode)) on attempt \(attempt) — retrying")
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    attempt += 1
                    continue
                }
                throw GSAError.invalidResponse("unparseable GsService2 body (HTTP \(statusCode))")
            }

            // hsc 434: GSA does not trust the anisette data yet and sends resync data (the SIM).
            // The anisette server turns the SIM into corrected headers, and the request is sent
            // once more. The resync does not count as a transient retry.
            if !didResync, let sim = Self.resyncSIM(in: responseDict),
               let fresh = try await anisette.resyncedHeaders(sim: sim) {
                print("🔐 [GSA] anisette resync required (hsc 434) — retrying with resynced headers")
                didResync = true
                resynced = fresh
                continue
            }

            if let status = responseDict["Status"] as? [String: Any],
               let ec = (status["ec"] as? NSNumber)?.intValue, ec != 0 {
                // ec != 0 but secondary-auth markers are handled by the caller; only
                // throw here for hard failures (bad credentials, etc.).
                if status["au"] == nil {
                    let em = (status["em"] as? String) ?? "Unknown error"
                    throw GSAError.serverError(code: ec, message: em)
                }
            }

            return responseDict
        }

        throw GSAError.invalidResponse("unparseable GsService2 body")
    }

    enum SecondaryAuth: Equatable {
        case none
        /// `au` names a second factor, and the client must ask Apple to send a code.
        case requestCode(String)
        /// hsc 409 without `au`: Apple already pushed a code to the trusted devices
        /// ("sign in to a new device"). Requesting another code is not needed.
        case codeAlreadySent
    }

    static let trustedDeviceSecondaryAuth = "trustedDeviceSecondaryAuth"

    static func secondaryAuth(in status: [String: Any]) -> SecondaryAuth {
        if let au = status["au"] as? String, !au.isEmpty { return .requestCode(au) }
        if (status["hsc"] as? NSNumber)?.intValue == 409 { return .codeAlreadySent }
        return .none
    }

    /// The base64 SIM (`X-Apple-I-MD-DATA`) from a response whose Status has hsc 434, or nil.
    static func resyncSIM(in response: [String: Any]) -> String? {
        guard let status = response["Status"] as? [String: Any],
              (status["hsc"] as? NSNumber)?.intValue == 434 else { return nil }
        switch status["X-Apple-I-MD-DATA"] {
        case let data as Data: return data.isEmpty ? nil : data.base64EncodedString()
        case let text as String: return text.isEmpty ? nil : text
        default: return nil
        }
    }

    // MARK: - Two-factor verification

    /// Requests a verification code. The trusted-device endpoint prompts every trusted
    /// device. Its page always lists the trusted phone number as the "text me instead"
    /// option, so that number does not mean the account lacks trusted devices. An SMS is
    /// sent only when `sendSMS` is set.
    func requestTwoFactorCode(identityToken: String, sendSMS: Bool) async throws -> TwoFactorDelivery {
        var req = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!)
        req.httpMethod = "GET"
        try await applyTwoFactorHeaders(&req, identityToken: identityToken)
        let (data, response) = try await perform(req)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GSAError.networkError }
        guard (200..<300).contains(status) else {
            throw GSAError.serverError(code: status, message: "Could not request a verification code")
        }

        let phoneId = parsePhoneId(from: String(decoding: data, as: UTF8.self))
        guard sendSMS, let phoneId else {
            print("🔐 [GSA] code requested from trusted devices")
            return TwoFactorDelivery(trustedPhoneId: phoneId)
        }
        return try await sendSMSCode(phoneId: phoneId, identityToken: identityToken)
    }

    /// Sends a code by SMS to the trusted phone number `phoneId`.
    func sendSMSCode(phoneId: Int, identityToken: String) async throws -> TwoFactorDelivery {
        print("🔐 [GSA] requesting SMS to phone id \(phoneId)")
        let maskedPhone = try await requestSMSCode(phoneId: phoneId, identityToken: identityToken)
        return TwoFactorDelivery(smsPhoneId: phoneId, maskedPhone: maskedPhone, trustedPhoneId: phoneId)
    }

    /// Submits the user-entered verification code via the SMS path (if `phoneId`
    /// is set) or the trusted-device path. Throws if the code is rejected.
    func submitTwoFactorCode(_ code: String, identityToken: String, phoneId: Int?) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespaces)

        if let phoneId {
            var req = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode")!)
            req.httpMethod = "POST"
            try await applyTwoFactorHeaders(&req, identityToken: identityToken)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "phoneNumber": ["id": phoneId],
                "securityCode": ["code": trimmed],
                "mode": "sms"
            ])
            let (data, response) = try await perform(req)

            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GSAError.networkError }
            if !(200..<300).contains(status) {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = ((json?["serviceErrors"] as? [[String: Any]])?.first?["message"] as? String)
                    ?? "Invalid verification code"
                print("🔐 [GSA] SMS code rejected (\(status)): \(message)")
                throw GSAError.serverError(code: status, message: message)
            }
        } else {
            var req = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!)
            req.httpMethod = "GET"
            try await applyTwoFactorHeaders(&req, identityToken: identityToken)
            req.setValue(trimmed, forHTTPHeaderField: "security-code")
            let (data, response) = try await perform(req)

            guard let statusCode = (response as? HTTPURLResponse)?.statusCode else { throw GSAError.networkError }
            guard (200..<300).contains(statusCode) else {
                throw GSAError.serverError(code: statusCode, message: "Could not validate the verification code")
            }
            if let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
                let status = (plist["Status"] as? [String: Any]) ?? plist
                if let ec = (status["ec"] as? NSNumber)?.intValue, ec != 0 {
                    let em = (status["em"] as? String) ?? "Invalid verification code"
                    print("🔐 [GSA] trusted-device code rejected ec=\(ec): \(em)")
                    throw GSAError.serverError(code: ec, message: em)
                }
            }
        }
        print("🔐 [GSA] 2FA code accepted")
    }

    /// Triggers an SMS to the trusted phone number. The trusted-device buddyML page
    /// specifies the "Send Code" action as POST /auth/verify/phone/{id}/put
    /// (POST /auth/verify/phone/ only returns phone info, it does not send).
    /// Returns the masked trusted phone number (e.g. "+90 •••• ••• •• 96") for the UI.
    private func requestSMSCode(phoneId: Int, identityToken: String) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://gsa.apple.com/auth/verify/phone/\(phoneId)/put")!)
        req.httpMethod = "POST"
        try await applyTwoFactorHeaders(&req, identityToken: identityToken)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "phoneNumber": ["id": phoneId],
            "mode": "sms"
        ])
        let (data, response) = try await perform(req)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GSAError.networkError }
        guard (200..<300).contains(status) else {
            throw GSAError.serverError(code: status, message: "Could not request an SMS verification code")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let phone = (json?["trustedPhoneNumber"] as? [String: Any]) ?? (json?["phoneNumber"] as? [String: Any])
        return (phone?["numberWithDialCode"] as? String) ?? (phone?["obfuscatedNumber"] as? String)
    }

    /// Extracts the trusted phone number id from the trusted-device buddyML page.
    private func parsePhoneId(from body: String) -> Int? {
        guard let range = body.range(of: #"phoneNumber\.id=\""#, options: .regularExpression) else {
            return nil
        }
        let rest = body[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    private func applyTwoFactorHeaders(_ req: inout URLRequest, identityToken: String) async throws {
        let headers = try await anisette.headers()
        req.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
        req.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue("akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
    }

    /// Client-provided data (cpd): static GSA flags + anisette device headers.
    private func clientProvidedData(headers: [String: String]) -> [String: Any] {
        var cpd: [String: Any] = [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "loc": Locale.current.appleAuthenticationIdentifier
        ]
        for (key, value) in headers {
            cpd[key] = value
        }
        return cpd
    }
}
