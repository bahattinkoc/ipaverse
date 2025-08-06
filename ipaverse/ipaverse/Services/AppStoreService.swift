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
}

protocol AppStoreServiceProtocol {
    func login(credentials: LoginCredentials) async throws -> Account
    func validateToken(_ token: String) async throws -> Bool
    func logout() async throws
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
                name: parseResult.accountName ?? "",
                storeFront: parseResult.storeFront ?? "143441",
                passwordToken: parseResult.passwordToken ?? "",
                directoryServicesID: parseResult.directoryServicesID ?? "",
                password: credentials.password
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

        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")

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
