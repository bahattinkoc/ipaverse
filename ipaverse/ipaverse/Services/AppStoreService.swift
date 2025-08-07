//
//  AppStoreService.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import Combine
import Network

// MARK: - App Store Constants
struct AppStoreConstants {
    static let failureTypeInvalidCredentials = "-5000"
    static let failureTypePasswordTokenExpired = "2034"
    static let failureTypeLicenseNotFound = "9610"
    static let failureTypeTemporarilyUnavailable = "2059"

    static let customerMessageBadLogin = "MZFinance.BadLogin.Configurator_message"
    static let customerMessageAccountDisabled = "Your account is disabled."
    static let customerMessageSubscriptionRequired = "Subscription Required"

    static let iTunesAPIDomain = "itunes.apple.com"
    static let iTunesAPIPathSearch = "/search"
    static let iTunesAPIPathLookup = "/lookup"

    static let privateAppStoreAPIDomainPrefixWithoutAuthCode = "p25"
    static let privateAppStoreAPIDomainPrefixWithAuthCode = "p71"
    static let privateAppStoreAPIDomain = "buy." + iTunesAPIDomain
    static let privateAppStoreAPIPathAuthenticate = "/WebObjects/MZFinance.woa/wa/authenticate"
    static let privateAppStoreAPIPathPurchase = "/WebObjects/MZFinance.woa/wa/buyProduct"
    static let privateAppStoreAPIPathDownload = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

    static let httpHeaderStoreFront = "X-Set-Apple-Store-Front"

    static let pricingParameterAppStore = "STDQ"
    static let pricingParameterAppleArcade = "GAME"
    static let defaultUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
}

protocol AppStoreServiceProtocol {
    func login(credentials: LoginCredentials) async throws -> Account
    func validateToken(_ token: String) async throws -> Bool
    func logout() async throws
    func search(term: String, account: Account, limit: Int) async throws -> SearchResult
    func purchase(app: AppStoreApp, account: Account) async throws
    func download(app: AppStoreApp, account: Account, outputPath: String?) async throws -> DownloadOutput
}

final class AppStoreService: AppStoreServiceProtocol {
    private let session: URLSession
    private let cookieJar: HTTPCookieStorage

    init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true

        self.session = URLSession(configuration: config, delegate: AppStoreURLSessionDelegate(), delegateQueue: nil)
        self.cookieJar = HTTPCookieStorage.shared
    }

    // MARK: - Login
    func login(credentials: LoginCredentials) async throws -> Account {
        let deviceID = try await getDeviceIdentifier()
        print("Device ID: \(deviceID)")

        var redirect = ""
        var attempt = 1
        let maxAttempts = 4

        while attempt <= maxAttempts {
            let loginRequest = try createLoginRequest(
                credentials: credentials,
                deviceID: deviceID,
                attempt: attempt,
                redirectURL: redirect
            )

            let (data, response) = try await session.data(for: loginRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LoginError.networkError
            }

            print("Attempt \(attempt) - Status Code: \(httpResponse.statusCode)")

            let parseResult = try parseLoginResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                attempt: attempt,
                authCode: credentials.authCode,
                httpResponse: httpResponse
            )

            if parseResult.shouldRetry {
                redirect = parseResult.redirectURL ?? ""
                attempt += 1
                continue
            }

            let account = Account(
                email: credentials.email,
                password: credentials.password,
                name: parseResult.accountName ?? "",
                storeFront: parseResult.storeFront ?? "",
                passwordToken: parseResult.passwordToken ?? "",
                directoryServicesID: parseResult.directoryServicesID ?? ""
            )

            print("Login successful: \(account.name)")
            return account
        }

        throw LoginError.unknownError("Too many attempts were made.")
    }

    // MARK: - Token Validation
    func validateToken(_ token: String) async throws -> Bool {
        guard !token.isEmpty else {
            return false
        }

        if token.count < 20 {
            return false
        }

        let validCharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        if token.rangeOfCharacter(from: validCharacterSet.inverted) != nil {
            return false
        }

        return true
    }

    // MARK: - Logout
    func logout() async throws {
        print("🔓 Logout is starting...")

        do {
            let keychain = KeychainService()
            try keychain.clearCredentials()

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: "ipaverse.account"
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("⚠️ Account keychain deletion error: \(status)")
            }

            if let cookies = HTTPCookieStorage.shared.cookies {
                for cookie in cookies {
                    if cookie.domain.contains("apple.com") || cookie.domain.contains("itunes.com") {
                        HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                }
            }

            print("✅ Logout successful - all data cleared")

        } catch {
            print("❌ Logout error: \(error)")
            throw LoginError.unknownError("Logout failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search
    func search(term: String, account: Account, limit: Int = 5) async throws -> SearchResult {
        print("🔍 Searching for: \(term) (limit: \(limit))")

        let countryCode = getCountryCodeFromStoreFront(account.storeFront)
        let urlString = "https://\(AppStoreConstants.iTunesAPIDomain)\(AppStoreConstants.iTunesAPIPathSearch)?entity=software,iPadSoftware&limit=\(limit)&media=software&term=\(term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.localizedLowercase ?? term)&country=\(countryCode)"

        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppStoreConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LoginError.networkError
        }

        let searchResult = try JSONDecoder().decode(SearchResult.self, from: data)
        print("✅ Search completed: \(searchResult.count ?? 0) results found")
        return searchResult
    }

    // MARK: - Purchase
    func purchase(app: AppStoreApp, account: Account) async throws {
        print("🛒 Purchasing app: \(app.name ?? "")")

        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        if let price = app.price, price > 0 {
            throw LoginError.unknownError("Purchasing paid apps is not supported")
        }

        do {
            try await purchaseWithParams(account: account, app: app, guid: guid, pricingParameters: AppStoreConstants.pricingParameterAppStore)
        } catch {
            if error.localizedDescription.contains("temporarily unavailable") {
                try await purchaseWithParams(account: account, app: app, guid: guid, pricingParameters: AppStoreConstants.pricingParameterAppleArcade)
            } else {
                throw error
            }
        }

        print("✅ Purchase completed successfully")
    }

    private func purchaseWithParams(account: Account, app: AppStoreApp, guid: String, pricingParameters: String) async throws {
        let url = URL(string: "https://\(AppStoreConstants.privateAppStoreAPIDomain)\(AppStoreConstants.privateAppStoreAPIPathPurchase)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(AppStoreConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")

        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.id ?? 0)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameters,
            "productType": "C",
            "salableAdamId": app.id ?? 0
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LoginError.networkError
        }

        if httpResponse.statusCode == 500 {
            throw LoginError.unknownError("License already exists")
        }

        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String {
            if failureType == AppStoreConstants.failureTypePasswordTokenExpired {
                throw LoginError.unknownError("Password token expired")
            }
            if failureType == AppStoreConstants.failureTypeTemporarilyUnavailable {
                throw LoginError.unknownError("Item is temporarily unavailable")
            }
            if !failureType.isEmpty {
                let customerMessage = plist?["customerMessage"] as? String ?? "Unknown error"
                throw LoginError.unknownError(customerMessage)
            }
        }

        if let jingleDocType = plist?["jingleDocType"] as? String,
           let status = plist?["status"] as? Int {
            if jingleDocType != "purchaseSuccess" || status != 0 {
                throw LoginError.unknownError("Failed to purchase app")
            }
        }
    }

    // MARK: - Download
    func download(app: AppStoreApp, account: Account, outputPath: String?) async throws -> DownloadOutput {
        print("📥 Starting download for: \(app.name ?? "")")

        var lastError: Error?
        var purchased = false // TODO: - bunu kullan

        for _ in 1...2 {
            do {
                let result = try await performDownload(app: app, account: account, outputPath: outputPath)
                print("✅ Download completed: \(result.destinationPath)")
                return result

            } catch {
                lastError = error

                if error.localizedDescription.contains("license") || error.localizedDescription.contains("License") {
                    print("🛒 License required, attempting purchase...")
                    try await purchase(app: app, account: account)
                    purchased = true
                    continue
                }

                if error.localizedDescription.contains("token expired") {
                    print("🔄 Token expired, need to re-login")
                    throw error
                }

                throw error
            }
        }

        throw lastError ?? LoginError.networkError
    }

    private func performDownload(app: AppStoreApp, account: Account, outputPath: String?) async throws -> DownloadOutput {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        let downloadURL = "https://\(AppStoreConstants.privateAppStoreAPIDomainPrefixWithoutAuthCode)-\(AppStoreConstants.privateAppStoreAPIDomain)\(AppStoreConstants.privateAppStoreAPIPathDownload)?guid=\(guid)"

        guard let url = URL(string: downloadURL) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(AppStoreConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id ?? 0
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData

        let (data, response) = try await session.data(for: request)

        guard let _ = response as? HTTPURLResponse else {
            throw LoginError.networkError
        }

        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String {
            if failureType == AppStoreConstants.failureTypePasswordTokenExpired {
                throw LoginError.unknownError("Password token expired")
            }
            if failureType == AppStoreConstants.failureTypeLicenseNotFound {
                throw LoginError.unknownError("License required")
            }
            if !failureType.isEmpty {
                let customerMessage = plist?["customerMessage"] as? String ?? "Unknown error"
                throw LoginError.unknownError(customerMessage)
            }
        }

        guard let items = plist?["songList"] as? [[String: Any]],
              let firstItem = items.first,
              let downloadURL = firstItem["URL"] as? String else {
            throw LoginError.unknownError("Invalid download response")
        }

        let destinationPath = outputPath ?? "\(app.bundleID ?? "")_\(app.id ?? 0)_\(app.version ?? "").ipa"

        print("📥 Download URL obtained: \(downloadURL)")

        return DownloadOutput(
            destinationPath: destinationPath,
            success: true,
            error: nil
        )
    }

    // MARK: - Private Methods

    private func createLoginRequest(credentials: LoginCredentials, deviceID: String, attempt: Int, redirectURL: String) throws -> URLRequest {
        print("Creating login request for: \(credentials.email) (Attempt: \(attempt))")
        print("Device ID: \(deviceID)")

        var baseURL: String

        switch attempt {
        case 1:
            baseURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        case 2:
            baseURL = "https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        case 3:
            baseURL = "https://p71-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        case 4:
            baseURL = "https://idmsa.apple.com/appleauth/auth/signin"
        default:
            baseURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        }

        let urlString = redirectURL.isEmpty ? baseURL : redirectURL

        print("🌐 Request URL: \(urlString)")
        print("🏗️ Domain: \(AppStoreConstants.privateAppStoreAPIDomain)")
        print("🛤️ Path: \(AppStoreConstants.privateAppStoreAPIPathAuthenticate)")

        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL: \(urlString)")
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(AppStoreConstants.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let payload: Data
        switch attempt {
        case 1, 2:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            payload = try createPlistPayload(credentials: credentials, deviceID: deviceID, attempt: attempt)
            print("📦 Using XML Plist payload")
        case 3:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            payload = createURLEncodedPayload(credentials: credentials, deviceID: deviceID, attempt: attempt)
            print("📦 Using URL Encoded payload")
        case 4:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            payload = try createJSONPayload(credentials: credentials, deviceID: deviceID, attempt: attempt)
            print("📦 Using JSON payload")
        default:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            payload = try createPlistPayload(credentials: credentials, deviceID: deviceID, attempt: attempt)
            print("📦 Using XML Plist payload (default)")
        }

        request.httpBody = payload

        print("📦 Payload size: \(payload.count) bytes")
        print("📄 Payload preview: \(String(data: payload.prefix(200), encoding: .utf8) ?? "Unable to decode")")

        return request
    }

    private func createPlistPayload(credentials: LoginCredentials, deviceID: String, attempt: Int) throws -> Data {
        let payloadDict: [String: Any] = [
            "appleId": credentials.email,
            "attempt": String(attempt),
            "guid": deviceID,
            "password": credentials.password + (credentials.authCode ?? "").replacingOccurrences(of: " ", with: ""),
            "rmp": "0",
            "why": "signIn"
        ]

        do {
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: payloadDict,
                format: .xml,
                options: 0
            )
            return plistData
        } catch {
            throw LoginError.networkError
        }
    }

    private func createURLEncodedPayload(credentials: LoginCredentials, deviceID: String, attempt: Int) -> Data {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "appleId", value: credentials.email),
            URLQueryItem(name: "attempt", value: String(attempt)),
            URLQueryItem(name: "guid", value: deviceID),
            URLQueryItem(name: "password", value: credentials.password + (credentials.authCode ?? "").replacingOccurrences(of: " ", with: "")),
            URLQueryItem(name: "rmp", value: "0"),
            URLQueryItem(name: "why", value: "signIn")
        ]

        return components.query?.data(using: .utf8) ?? Data()
    }

    private func createJSONPayload(credentials: LoginCredentials, deviceID: String, attempt: Int) throws -> Data {
        let payloadDict: [String: Any] = [
            "accountName": credentials.email,
            "password": credentials.password + (credentials.authCode ?? "").replacingOccurrences(of: " ", with: ""),
            "rememberMe": credentials.rememberMe,
            "trustTokens": []
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payloadDict, options: [])
            return jsonData
        } catch {
            throw LoginError.networkError
        }
    }

    private func parseLoginResponse(data: Data, statusCode: Int, attempt: Int, authCode: String?, httpResponse: HTTPURLResponse) throws -> LoginParseResult {
        print("Response Status Code: \(statusCode)")
        if let responseString = String(data: data, encoding: .utf8) {
            print("Response Data: \(responseString.prefix(500))...")
        }

        var redirectURL: String? = nil

        if statusCode == 404 {
            print("⚠️ 404 error received - URL or format may be incorrect")
            return LoginParseResult(shouldRetry: true)
        }

        if statusCode == 302 {
            if let location = httpResponse.value(forHTTPHeaderField: "Location") {
                redirectURL = location
                return LoginParseResult(shouldRetry: true, redirectURL: redirectURL)
            } else {
                throw LoginError.networkError
            }
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw LoginError.networkError
        }

        let failureType = plist["failureType"] as? String ?? ""
        let customerMessage = plist["customerMessage"] as? String ?? ""

        if failureType == AppStoreConstants.failureTypeInvalidCredentials {
            throw LoginError.invalidCredentials
        }

        if customerMessage == AppStoreConstants.customerMessageAccountDisabled {
            throw LoginError.accountLocked
        }

        if failureType.isEmpty && authCode == nil && customerMessage == AppStoreConstants.customerMessageBadLogin {
            throw LoginError.twoFactorRequired
        }

        if failureType.isEmpty && authCode != nil && customerMessage == AppStoreConstants.customerMessageBadLogin {
            throw LoginError.twoFactorRequired
        }

        if !failureType.isEmpty {
            let message = customerMessage.isEmpty ? "Unknown error" : customerMessage
            throw LoginError.unknownError(message)
        }

        if statusCode != 200 || plist["passwordToken"] as? String == nil || plist["dsPersonId"] as? String == nil {
            throw LoginError.networkError
        }

        guard let accountInfo = plist["accountInfo"] as? [String: Any],
              let address = accountInfo["address"] as? [String: Any],
              let firstName = address["firstName"] as? String,
              let lastName = address["lastName"] as? String,
              let passwordToken = plist["passwordToken"] as? String,
              let directoryServicesID = plist["dsPersonId"] as? String else {
            throw LoginError.networkError
        }

        let accountName = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let storeFront = httpResponse.value(forHTTPHeaderField: AppStoreConstants.httpHeaderStoreFront) ?? "143441"

        return LoginParseResult(
            shouldRetry: false,
            accountName: accountName,
            storeFront: storeFront,
            passwordToken: passwordToken,
            directoryServicesID: directoryServicesID
        )
    }

    private func getDeviceIdentifier() async throws -> String {
        let task = Process()
        task.launchPath = "/sbin/ifconfig"
        task.arguments = ["en0", "ether"]

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("ether") {
                let components = line.components(separatedBy: " ")
                for component in components {
                    if component.contains(":") && component.count == 17 {
                        return component.replacingOccurrences(of: ":", with: "").uppercased()
                    }
                }
            }
        }

        return UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private func getCountryCodeFromStoreFront(_ storeFront: String) -> String {
        let storeFronts: [String: String] = [
            "AE": "143481", "AG": "143540", "AI": "143538", "AL": "143575", "AM": "143524",
            "AO": "143564", "AR": "143505", "AT": "143445", "AU": "143460", "AZ": "143568",
            "BB": "143541", "BD": "143490", "BE": "143446", "BG": "143526", "BH": "143559",
            "BM": "143542", "BN": "143560", "BO": "143556", "BR": "143503", "BS": "143539",
            "BW": "143525", "BY": "143565", "BZ": "143555", "CA": "143455", "CH": "143459",
            "CI": "143527", "CL": "143483", "CN": "143465", "CO": "143501", "CR": "143495",
            "CY": "143557", "CZ": "143489", "DE": "143443", "DK": "143458", "DM": "143545",
            "DO": "143508", "DZ": "143563", "EC": "143509", "EE": "143518", "EG": "143516",
            "ES": "143454", "FI": "143447", "FR": "143442", "GB": "143444", "GD": "143546",
            "GE": "143615", "GH": "143573", "GR": "143448", "GT": "143504", "GY": "143553",
            "HK": "143463", "HN": "143510", "HR": "143494", "HU": "143482", "ID": "143476",
            "IE": "143449", "IL": "143491", "IN": "143467", "IS": "143558", "IT": "143450",
            "IQ": "143617", "JM": "143511", "JO": "143528", "JP": "143462", "KE": "143529",
            "KN": "143548", "KR": "143466", "KW": "143493", "KY": "143544", "KZ": "143517",
            "LB": "143497", "LC": "143549", "LI": "143522", "LK": "143486", "LT": "143520",
            "LU": "143451", "LV": "143519", "MD": "143523", "MG": "143531", "MK": "143530",
            "ML": "143532", "MN": "143592", "MO": "143515", "MS": "143547", "MT": "143521",
            "MU": "143533", "MV": "143488", "MX": "143468", "MY": "143473", "NE": "143534",
            "NG": "143561", "NI": "143512", "NL": "143452", "NO": "143457", "NP": "143484",
            "NZ": "143461", "OM": "143562", "PA": "143485", "PE": "143507", "PH": "143474",
            "PK": "143477", "PL": "143478", "PT": "143453", "PY": "143513", "QA": "143498",
            "RO": "143487", "RS": "143500", "RU": "143469", "SA": "143479", "SE": "143456",
            "SG": "143464", "SI": "143499", "SK": "143496", "SN": "143535", "SR": "143554",
            "SV": "143506", "TC": "143552", "TH": "143475", "TN": "143536", "TR": "143480",
            "TT": "143551", "TW": "143470", "TZ": "143572", "UA": "143492", "UG": "143537",
            "US": "143441", "UY": "143514", "UZ": "143566", "VC": "143550", "VE": "143502",
            "VG": "143543", "VN": "143471", "YE": "143571", "ZA": "143472"
        ]

        let parts = storeFront.components(separatedBy: "-")
        let storeFrontValue = parts.first ?? storeFront

        for (countryCode, sf) in storeFronts {
            if sf == storeFrontValue {
                return countryCode.lowercased()
            }
        }

        print("⚠️ StoreFront mapping not found for: \(storeFront) (parsed as: \(storeFrontValue))")
        return "tr"
    }
}

// MARK: - Login Parse Result
struct LoginParseResult {
    let shouldRetry: Bool
    let redirectURL: String?
    let accountName: String?
    let storeFront: String?
    let passwordToken: String?
    let directoryServicesID: String?

    init(
        shouldRetry: Bool,
        redirectURL: String? = nil,
        accountName: String? = nil,
        storeFront: String? = nil,
        passwordToken: String? = nil,
        directoryServicesID: String? = nil
    ) {
        self.shouldRetry = shouldRetry
        self.redirectURL = redirectURL
        self.accountName = accountName
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
    }
}

// MARK: - URLSession Delegate for Redirect Handling
final class AppStoreURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let referer = response.url?.absoluteString,
           referer.contains("buy.itunes.apple.com") && referer.contains("authenticate") {
            print("🔄 Redirect stopped: \(referer) -> \(request.url?.absoluteString ?? "")")
            completionHandler(nil)
        } else {
            print("🔄 Redirect allowed: \(request.url?.absoluteString ?? "")")
            completionHandler(request)
        }
    }
}
