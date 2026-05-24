//
//  AppStoreService.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import Combine
import Network
import SwiftData
import IOKit

protocol AppStoreServiceProtocol {
    func login(credentials: LoginCredentials) async throws -> Account
    func validateToken(_ token: String) async throws -> Bool
    func logout() async throws
    func search(term: String, account: Account, limit: Int, platform: AppPlatform) async throws -> SearchResult
    func purchase(app: AppStoreApp, account: Account) async throws
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String?, progress: ((Double, Int64, Int64) -> Void)?, modelContext: ModelContext?) async throws -> DownloadOutput
    func listVersions(app: AppStoreApp, account: Account) async throws -> VersionsOutput
}

final class AppStoreService: AppStoreServiceProtocol {
    private let session: URLSession
    private let cookieJar: HTTPCookieStorage
    private let logger = NetworkLogger.shared

    let sessionDelegate: AppStoreURLSessionDelegate

    init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true

        let delegate = AppStoreURLSessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.cookieJar = HTTPCookieStorage.shared
    }

    // MARK: - Login
    func login(credentials: LoginCredentials) async throws -> Account {
        let deviceID = try await getDeviceIdentifier()
        let bag = try await fetchBag(deviceID: deviceID)
        var redirect = ""
        var attempt = 1
        let maxAttempts = 4

        while attempt <= maxAttempts {
            let urlString = redirect.isEmpty ? bag : redirect
            let loginRequest = try createLoginRequest(
                credentials: credentials,
                deviceID: deviceID,
                attempt: attempt,
                url: urlString
            )

            logger.logRequest(loginRequest)
            let (data, response) = try await session.data(for: loginRequest)
            logger.logResponse(response, data: data, error: nil)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LoginError.networkError
            }

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
                directoryServicesID: parseResult.directoryServicesID ?? "",
                pod: parseResult.pod
            )

            return account
        }

        throw LoginError.unknownError("Too many attempts were made.")
    }

    private func fetchBag(deviceID: String) async throws -> String {
        let urlString = "https://\(Constant.privateInitDomain)\(Constant.privateInitPath)?guid=\(deviceID)"
        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)
        logger.logResponse(response, data: data, error: nil)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LoginError.networkError
        }

        let normalizedData = normalizePlistData(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any] else {
            throw LoginError.unknownError("Failed to parse bag response")
        }

        guard let urlBag = plist["urlBag"] as? [String: Any],
              let authenticateAccount = urlBag["authenticateAccount"] as? String else {
            throw LoginError.unknownError("Bag response missing authentication endpoint")
        }

        return authenticateAccount
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

        } catch {
            throw LoginError.unknownError("Logout failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search
    func search(term: String, account: Account, limit: Int = 5, platform: AppPlatform) async throws -> SearchResult {
        let countryCode = getCountryCodeFromStoreFront(account.storeFront)

        let entity: String
        switch platform {
        case .ios:
            entity = "software,iPadSoftware"
        case .macos:
            entity = "macSoftware"
        }

        let urlString = "https://\(Constant.iTunesAPIDomain)\(Constant.iTunesAPIPathSearch)?entity=\(entity)&limit=\(limit)&media=software&term=\(term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.localizedLowercase ?? term)&country=\(countryCode)"

        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)
        logger.logResponse(response, data: data, error: nil)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LoginError.networkError
        }

        var searchResult = try JSONDecoder().decode(SearchResult.self, from: data)

        if let results = searchResult.results {
            let updatedResults = results.map { app in
                AppStoreApp(
                    id: app.id ?? 0,
                    bundleID: app.bundleID ?? "",
                    name: app.name ?? "",
                    version: app.version ?? "",
                    price: app.price ?? 0.0,
                    iconURL: app.iconURL,
                    platform: platform
                )
            }
            searchResult = SearchResult(count: searchResult.count, results: updatedResults)
        }

        return searchResult
    }

    // MARK: - Purchase
    func purchase(app: AppStoreApp, account: Account) async throws {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        if let price = app.price, price > 0 {
            throw LoginError.unknownError("Purchasing paid apps is not supported")
        }

        do {
            try await purchaseWithParams(account: account, app: app, guid: guid, pricingParameters: Constant.pricingParameterAppStore)
        } catch {
            if error.localizedDescription.contains("temporarily unavailable") {
                try await purchaseWithParams(account: account, app: app, guid: guid, pricingParameters: Constant.pricingParameterAppleArcade)
            } else {
                throw error
            }
        }
    }

    private func purchaseWithParams(account: Account, app: AppStoreApp, guid: String, pricingParameters: String) async throws {
        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let url = URL(string: "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathPurchase)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
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

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.logResponse(response, data: data, error: LoginError.networkError)
            throw LoginError.networkError
        }

        logger.logResponse(response, data: data, error: nil)

        if httpResponse.statusCode == 500 {
            throw LoginError.unknownError("License already exists")
        }

        let normalizedData = normalizePlistData(data)
        let plist = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String {
            let customerMessage = plist?["customerMessage"] as? String ?? ""
            if Constant.authFailureCodes.contains(failureType) ||
               customerMessage == Constant.customerMessagePasswordChanged {
                throw LoginError.tokenExpired
            }
            if failureType == Constant.failureTypeLicenseAlreadyExists {
                throw LoginError.unknownError("License already exists")
            }
            if failureType == Constant.failureTypeTemporarilyUnavailable {
                throw LoginError.unknownError("Item is temporarily unavailable")
            }
            if !failureType.isEmpty {
                let msg = customerMessage.isEmpty ? "Unknown error" : customerMessage
                throw LoginError.unknownError(msg)
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
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String? = nil, progress: ((Double, Int64, Int64) -> Void)? = nil, modelContext: ModelContext? = nil) async throws -> DownloadOutput {
        var purchased = false

        do {
            _ = try await checkLicense(app: app, account: account)
            purchased = true
        } catch {
            if error.localizedDescription.contains("license") || error.localizedDescription.contains("License") {
                do {
                    try await purchase(app: app, account: account)
                    purchased = true
                } catch {
                    if !error.localizedDescription.contains("already exists") {
                        throw error
                    }
                    purchased = true
                }
            } else {
                throw error
            }
        }

        if !purchased {
            throw LoginError.unknownError("Failed to verify app license")
        }

        let result = try await performDownload(app: app, account: account, outputPath: outputPath, externalVersionId: externalVersionId, progress: progress)

        if result.success, let modelContext {
            if await findExistingDownloadedApp(app: app, context: modelContext) != nil {
                await updateDownloadedApp(app: app, newFilePath: result.destinationPath, context: modelContext)
            } else {
                await saveDownloadedApp(app: app, filePath: result.destinationPath, context: modelContext)
            }
        }

        return result
    }

    private func checkLicense(app: AppStoreApp, account: Account) async throws {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let downloadURL = "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathDownload)?guid=\(guid)"

        guard let url = URL(string: downloadURL) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
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

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)

        guard let _ = response as? HTTPURLResponse else {
            logger.logResponse(response, data: data, error: LoginError.networkError)
            throw LoginError.networkError
        }

        logger.logResponse(response, data: data, error: nil)

        let normalizedData = normalizePlistData(data)
        let plist = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String {
            if Constant.authFailureCodes.contains(failureType) {
                throw LoginError.tokenExpired
            }
            if failureType == Constant.failureTypeLicenseNotFound {
                throw LoginError.unknownError("License required")
            }
            if !failureType.isEmpty {
                let customerMessage = plist?["customerMessage"] as? String ?? "Unknown error"
                throw LoginError.unknownError(customerMessage)
            }
        }
    }

    private func performDownload(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String? = nil, progress: ((Double, Int64, Int64) -> Void)? = nil) async throws -> DownloadOutput {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let downloadURL = "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathDownload)?guid=\(guid)"

        guard let url = URL(string: downloadURL) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        var payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id ?? 0
        ]
        if let versionId = externalVersionId {
            payload["externalVersionId"] = versionId
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .xml,
            options: 0
        )
        request.httpBody = plistData

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)

        guard let _ = response as? HTTPURLResponse else {
            logger.logResponse(response, data: data, error: LoginError.networkError)
            throw LoginError.networkError
        }

        logger.logResponse(response, data: data, error: nil)

        let normalizedData = normalizePlistData(data)
        let plist = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any]

        guard let items = plist?["songList"] as? [[String: Any]],
              let firstItem = items.first,
              let downloadURLString = firstItem["URL"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            throw LoginError.unknownError("Invalid download response")
        }

        let sinfsRaw = firstItem["sinfs"] as? [Any] ?? []
        print("🔐 [IPAPatcher] sinfs in API response: \(sinfsRaw.count)")
        let sinfs: [SinfData] = sinfsRaw.compactMap { item in
            guard let dict = item as? [String: Any],
                  let rawData = dict["sinf"] as? Data else {
                print("🔐 [IPAPatcher] sinf item skipped — unexpected format: \(item)")
                return nil
            }
            let id: Int64
            if let n = dict["id"] as? Int64 { id = n }
            else if let n = dict["id"] as? Int { id = Int64(n) }
            else { id = 0 }
            return SinfData(id: id, data: rawData)
        }
        print("🔐 [IPAPatcher] parsed sinfs: \(sinfs.count)")

        let destinationPath = outputPath ?? "\(app.bundleID ?? "")_\(app.id ?? 0)_\(app.version ?? "").ipa"
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let downloadResponse = try await streamDownloadFile(
            from: downloadURL,
            to: destinationURL,
            userAgent: Constant.defaultUserAgent,
            dsid: account.directoryServicesID,
            progress: progress
        )
        logger.logResponse(downloadResponse, data: nil, error: nil)

        do {
            try IPAPatcher().applyPatches(
                ipaPath: destinationPath,
                sinfs: sinfs,
                email: account.email
            )
        } catch {
            print("🔐 [IPAPatcher] patching error (download kept): \(error.localizedDescription)")
        }

        return DownloadOutput(
            destinationPath: destinationPath,
            success: true,
            error: nil
        )
    }

    private func streamDownloadFile(
        from sourceURL: URL,
        to destinationURL: URL,
        userAgent: String,
        dsid: String,
        progress: ((Double, Int64, Int64) -> Void)?
    ) async throws -> URLResponse {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).part")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempURL)

        defer {
            try? fileHandle.close()
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(dsid, forHTTPHeaderField: "X-Dsid")

        logger.logRequest(request)

        let (bytes, response) = try await session.bytes(for: request)

        let totalBytes = max(response.expectedContentLength, 0)
        var downloadedBytes: Int64 = 0

        // 64 KB buffer
        let bufferSize = 64 * 1024
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        // UI update throttle (her 100ms)
        var lastProgressUpdate = Date.distantPast
        let minUpdateInterval: TimeInterval = 0.1

        if totalBytes > 0 {
            progress?(0, 0, totalBytes)
        }

        for try await byte in bytes {
            buffer.append(byte)

            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let now = Date()
                if now.timeIntervalSince(lastProgressUpdate) >= minUpdateInterval {
                    if totalBytes > 0 {
                        let ratio = min(Double(downloadedBytes) / Double(totalBytes), 1.0)
                        progress?(ratio, downloadedBytes, totalBytes)
                    } else {
                        progress?(0, downloadedBytes, 0)
                    }
                    lastProgressUpdate = now
                }
            }
        }

        // Kalan buffer'ı yaz
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
            downloadedBytes += Int64(buffer.count)
        }

        // Final progress
        if totalBytes > 0 {
            progress?(1.0, downloadedBytes, totalBytes)
        } else {
            progress?(0, downloadedBytes, 0)
        }

        try fileHandle.close()
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        return response
    }

    // MARK: - List Versions
    func listVersions(app: AppStoreApp, account: Account) async throws -> VersionsOutput {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let urlString = "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathDownload)?guid=\(guid)"

        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id ?? 0
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        request.httpBody = plistData

        logger.logRequest(request)
        let (data, response) = try await session.data(for: request)
        logger.logResponse(response, data: data, error: nil)

        let normalizedData = normalizePlistData(data)
        let plist = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String, !failureType.isEmpty {
            if Constant.authFailureCodes.contains(failureType) {
                throw LoginError.tokenExpired
            }
            if failureType == Constant.failureTypeLicenseNotFound {
                throw LoginError.licenseRequired
            }
            let customerMessage = plist?["customerMessage"] as? String ?? "Unknown error"
            throw LoginError.unknownError(customerMessage)
        }

        guard let items = plist?["songList"] as? [[String: Any]],
              let firstItem = items.first else {
            throw LoginError.unknownError("Invalid response from App Store")
        }

        let metadata = firstItem["metadata"] as? [String: Any] ?? [:]

        guard let rawIds = metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
            throw LoginError.unknownError("No version information available for this app")
        }

        let versionIds = rawIds.map { "\($0)" }
        let latestVersionId = metadata["softwareVersionExternalIdentifier"].map { "\($0)" } ?? versionIds.last ?? ""

        return VersionsOutput(versionIds: versionIds, latestVersionId: latestVersionId)
    }

    // MARK: - Fetch Version Display Name
    func fetchVersionDisplayName(app: AppStoreApp, account: Account, versionId: String) async throws -> String {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()

        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let urlString = "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathDownload)?guid=\(guid)"

        guard let url = URL(string: urlString) else { throw LoginError.networkError }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let payload: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": app.id ?? 0,
            "externalVersionId": versionId
        ]
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        let (data, _) = try await session.data(for: request)
        let normalizedData = normalizePlistData(data)
        let plist = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any]

        if let failureType = plist?["failureType"] as? String, !failureType.isEmpty {
            if Constant.authFailureCodes.contains(failureType) {
                throw LoginError.tokenExpired
            }
            throw LoginError.unknownError(failureType)
        }

        guard let items = plist?["songList"] as? [[String: Any]],
              let firstItem = items.first,
              let metadata = firstItem["metadata"] as? [String: Any] else {
            throw LoginError.unknownError("No metadata in response")
        }

        for key in ["bundleShortVersionString", "CFBundleShortVersionString"] {
            if let v = metadata[key] as? String, !v.isEmpty { return v }
        }

        throw LoginError.unknownError("No version string in metadata")
    }

    // MARK: - Private Methods

    private func createLoginRequest(credentials: LoginCredentials, deviceID: String, attempt: Int, url urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

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
            request.httpBody = plistData
        } catch {
            throw LoginError.networkError
        }

        return request
    }

    private func parseLoginResponse(data: Data, statusCode: Int, attempt: Int, authCode: String?, httpResponse: HTTPURLResponse) throws -> LoginParseResult {
        var redirectURL: String? = nil

        if statusCode == 404 {
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

        let normalizedData = normalizePlistData(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any] else {
            throw LoginError.networkError
        }

        let failureType = plist["failureType"] as? String ?? ""
        let customerMessage = plist["customerMessage"] as? String ?? ""

        if failureType == Constant.failureTypeInvalidCredentials {
            throw LoginError.invalidCredentials
        }

        if customerMessage == Constant.customerMessageAccountDisabled {
            throw LoginError.accountLocked
        }

        if failureType.isEmpty && authCode == nil && customerMessage == Constant.customerMessageBadLogin {
            throw LoginError.twoFactorRequired
        }

        if failureType.isEmpty && authCode != nil && customerMessage == Constant.customerMessageBadLogin {
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
        let storeFront = httpResponse.value(forHTTPHeaderField: Constant.httpHeaderStoreFront) ?? "143441"
        let pod = httpResponse.value(forHTTPHeaderField: Constant.httpHeaderPod)

        return LoginParseResult(
            shouldRetry: false,
            accountName: accountName,
            storeFront: storeFront,
            passwordToken: passwordToken,
            directoryServicesID: directoryServicesID,
            pod: pod
        )
    }

    private func normalizePlistData(_ data: Data) -> Data {
        guard let string = String(data: data, encoding: .utf8) else { return data }

        // Try to extract <plist>...</plist>
        if let range = string.range(of: "<plist", options: .caseInsensitive),
           let endRange = string.range(of: "</plist>", options: .caseInsensitive) {
            let plistString = string[range.lowerBound..<endRange.upperBound]
            return plistString.data(using: .utf8) ?? data
        }

        // Try to extract <dict>...</dict> if it's not a full plist
        if let range = string.range(of: "<dict", options: .caseInsensitive),
           let endRange = string.range(of: "</dict>", options: .caseInsensitive) {
            let dictString = string[range.lowerBound..<endRange.upperBound]
            let fullPlist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n\(dictString)\n</plist>"
            return fullPlist.data(using: .utf8) ?? data
        }

        return data
    }

    private func getDeviceIdentifier() async throws -> String {
        let task = Process()
        task.launchPath = "/sbin/ifconfig"

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        let lines = output.components(separatedBy: .newlines)
        var currentInterface = ""
        let virtualPrefixes = ["lo", "utun", "bridge", "vmnet", "vlan", "gif", "stf", "awdl", "llw", "anpi"]

        for line in lines {
            if !line.hasPrefix("\t") && line.contains(":") {
                currentInterface = line.components(separatedBy: ":").first ?? ""
            }

            let isVirtual = virtualPrefixes.contains(where: { currentInterface.hasPrefix($0) })
            guard !isVirtual else { continue }

            if line.contains("ether") {
                let components = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                for component in components {
                    if component.contains(":") && component.count == 17 {
                        return component.replacingOccurrences(of: ":", with: "").uppercased()
                    }
                }
            }
        }

        // Fallback to a stable identifier if mac address is not found
        if let serialNumber = getSerialNumber() {
            return serialNumber.replacingOccurrences(of: "-", with: "").uppercased()
        }

        return UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private func getSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if platformExpert > 0 {
            if let serialNumber = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String {
                IOObjectRelease(platformExpert)
                return serialNumber
            }
            IOObjectRelease(platformExpert)
        }
        return nil
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

        return "tr"
    }

    @MainActor
    private func saveDownloadedApp(app: AppStoreApp, filePath: String, context: ModelContext) async {
        do {
            let downloadedApp = DownloadedApp(app: app, filePath: filePath)
            context.insert(downloadedApp)
            try context.save()
        } catch {
            print("❌ Failed to save downloaded app to SwiftData: \(error)")
        }
    }

    @MainActor
    private func findExistingDownloadedApp(app: AppStoreApp, context: ModelContext) async -> DownloadedApp? {
        do {
            let descriptor = FetchDescriptor<DownloadedApp>(
                predicate: #Predicate<DownloadedApp> { downloadedApp in
                    downloadedApp.appId == (app.id ?? 0)
                }
            )

            let existingApps = try context.fetch(descriptor)
            return existingApps.first
        } catch {
            print("❌ Failed to find existing downloaded app in SwiftData: \(error)")
            return nil
        }
    }

    @MainActor
    private func updateDownloadedApp(app: AppStoreApp, newFilePath: String, context: ModelContext) async {
        do {
            let descriptor = FetchDescriptor<DownloadedApp>(
                predicate: #Predicate<DownloadedApp> { downloadedApp in
                    downloadedApp.appId == (app.id ?? 0)
                }
            )

            let existingApps = try context.fetch(descriptor)
            if let existingApp = existingApps.first {
                existingApp.filePath = newFilePath
                try context.save()
            }
        } catch {
            print("❌ Failed to update downloaded app in SwiftData: \(error)")
        }
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
    let pod: String?

    init(
        shouldRetry: Bool,
        redirectURL: String? = nil,
        accountName: String? = nil,
        storeFront: String? = nil,
        passwordToken: String? = nil,
        directoryServicesID: String? = nil,
        pod: String? = nil
    ) {
        self.shouldRetry = shouldRetry
        self.redirectURL = redirectURL
        self.accountName = accountName
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
        self.pod = pod
    }
}

// MARK: - URLSession Delegate for Redirect Handling
final class AppStoreURLSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    var progressHandler: ((Double, Int64, Int64) -> Void)?
    private var hasStartedProgress = false

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let referer = response.url?.absoluteString,
           referer.contains("buy.itunes.apple.com") && referer.contains("authenticate") {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if !hasStartedProgress {
            progressHandler?(0.0, 0, totalBytesExpectedToWrite)
            hasStartedProgress = true
        }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        progressHandler?(1.0, 0, 0)
        hasStartedProgress = false
    }
}

// MARK: - CONSTANT

private extension AppStoreService {
    enum Constant {
        static let failureTypeInvalidCredentials = "-5000"
        static let failureTypePasswordTokenExpired = "2034"
        static let failureTypeSignInRequired = "2042"
        static let failureTypeDeviceVerificationFailed = "1008"
        static let failureTypeLicenseNotFound = "9610"
        static let failureTypeLicenseAlreadyExists = "5002"
        static let failureTypeTemporarilyUnavailable = "2059"

        // Auth failure codes that all indicate session expiry / re-auth required
        static let authFailureCodes: Set<String> = ["-5000", "1008", "2002", "2034", "2042"]

        static let customerMessageBadLogin = "MZFinance.BadLogin.Configurator_message"
        static let customerMessageAccountDisabled = "Your account is disabled."
        static let customerMessageSubscriptionRequired = "Subscription Required"
        static let customerMessagePasswordChanged = "Your password has changed."

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
        static let httpHeaderPod = "pod"

        static let privateInitDomain = "init." + iTunesAPIDomain
        static let privateInitPath = "/bag.xml"

        static let pricingParameterAppStore = "STDQ"
        static let pricingParameterAppleArcade = "GAME"
        static let defaultUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    }
}
