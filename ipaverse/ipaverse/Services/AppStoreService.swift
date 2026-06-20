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
    func lookup(bundleID: String, account: Account, platform: AppPlatform) async throws -> AppStoreApp
    func purchase(app: AppStoreApp, account: Account) async throws
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String?, downloadedVersion: String?, progress: ((Double, Int64, Int64) -> Void)?, modelContext: ModelContext?) async throws -> DownloadOutput
    func listVersions(app: AppStoreApp, account: Account) async throws -> VersionsOutput
}

final class AppStoreService: AppStoreServiceProtocol {
    private let session: URLSession
    private let cookieJar: HTTPCookieStorage
    private let logger = NetworkLogger.shared

    let sessionDelegate: AppStoreURLSessionDelegate

    /// GrandSlam 2FA context from a verification-pending handshake, used to validate
    /// the code the user subsequently enters. `phoneId` is set when the code is
    /// delivered via SMS (no trusted device).
    private var pendingGSATwoFactor: (identityToken: String, phoneId: Int?)?

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
    //
    // Apple deprecated the legacy MZFinance username/password authenticate endpoint
    // (now returns 403). Auth now goes through GrandSlam (GSA) — an SRP-6a handshake
    // against gsa.apple.com with native anisette headers. See GSAClient.
    func login(credentials: LoginCredentials) async throws -> Account {
        let gsa = GSAClient(session: session)
        let submittingCode = credentials.authCode != nil
        do {
            // If the user just entered a 2FA code, validate it against the pending
            // GrandSlam identity before re-running the handshake (now trusted).
            if let code = credentials.authCode, let pending = pendingGSATwoFactor {
                do {
                    try await gsa.submitTwoFactorCode(code, identityToken: pending.identityToken, phoneId: pending.phoneId)
                } catch {
                    throw LoginError.invalidAuthCode
                }
                pendingGSATwoFactor = nil
            }

            let gsaAccount = try await gsa.authenticate(
                username: credentials.email,
                password: credentials.password
            )
            print("🔐 [GSA] handshake OK — dsid set: \(!gsaAccount.dsid.isEmpty), idmsToken set: \(!gsaAccount.idmsToken.isEmpty)")
            return try await bridgeToAppStore(gsa: gsaAccount, credentials: credentials)
        } catch let GSAError.needsTwoFactor(identity, phoneId, maskedPhone) {
            pendingGSATwoFactor = (identity, phoneId)
            // If we already submitted a code and 2FA is still required, the code
            // was wrong/expired — prompt again rather than claiming success.
            throw submittingCode ? LoginError.invalidAuthCode : LoginError.twoFactorRequired(maskedPhone: maskedPhone)
        } catch GSAError.anisetteUnavailable {
            throw LoginError.unknownError("Could not generate anisette data on this Mac.")
        } catch let GSAError.serverError(code, message) {
            // Apple GSA error codes for bad credentials.
            if code == -20101 || code == -22406 || code == -36607 {
                throw LoginError.invalidCredentials
            }
            throw LoginError.unknownError("GSA \(code): \(message)")
        }
    }

    /// Exchanges a successful GrandSlam identity for the App Store credentials
    /// (passwordToken / DSID / storeFront) that the download endpoints require.
    ///
    /// NOTE: this bridge is the remaining unsolved step. For now it surfaces the
    /// decrypted `spd` keys so the real exchange can be implemented from live data.
    private func bridgeToAppStore(gsa: GSAAccountData, credentials: LoginCredentials) async throws -> Account {
        // Diagnostic dump of the decrypted spd structure (types/lengths only — no
        // token bytes or personal data) to drive the App Store token bridge design.
        print("🔐 [GSA] ----- spd structure -----")
        for key in gsa.raw.keys.sorted() {
            let value = gsa.raw[key]!
            switch value {
            case let s as String:
                print("   \(key): String(len \(s.count))")
            case let d as Data:
                print("   \(key): Data(len \(d.count))")
            case let dict as [String: Any]:
                print("   \(key): Dict keys=\(dict.keys.sorted())")
            case let arr as [Any]:
                print("   \(key): Array(count \(arr.count))")
            case let n as NSNumber:
                print("   \(key): Number(\(n))")
            default:
                print("   \(key): \(type(of: value))")
            }
        }
        print("🔐 [GSA] dsid(adsid)=\(gsa.dsid)  DsPrsId present=\(gsa.raw["DsPrsId"] != nil)")
        print("🔐 [GSA] ---------------------------")

        // Bridge: use the password-equivalent token (PET) from the GrandSlam token
        // table as the "password" for the MZFinance authenticate endpoint. The PET
        // already encodes the GSA (2FA) authentication, so the store returns a
        // passwordToken / DSID / storeFront without rejecting it like a raw password.
        guard let tokens = gsa.raw["t"] as? [String: Any],
              let petEntry = tokens["com.apple.gs.idms.pet"] as? [String: Any],
              let pet = petEntry["token"] as? String, !pet.isEmpty else {
            throw LoginError.unknownError("GSA OK but PET token (com.apple.gs.idms.pet) not found in spd")
        }
        print("🔐 [GSA] PET token len=\(pet.count) — authenticating to MZFinance with PET")

        let deviceID = try await getDeviceIdentifier()
        let parsed = try await authenticateMZFinance(email: credentials.email, password: pet, deviceID: deviceID)

        let fallbackName = [gsa.raw["fn"] as? String, gsa.raw["ln"] as? String]
            .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let dsid = parsed.directoryServicesID
            ?? (gsa.raw["DsPrsId"] as? NSNumber).map { "\($0)" }
            ?? ""

        return Account(
            email: credentials.email,
            password: credentials.password,
            name: parsed.accountName ?? fallbackName,
            storeFront: parsed.storeFront ?? "143441",
            passwordToken: parsed.passwordToken ?? "",
            directoryServicesID: dsid,
            pod: parsed.pod
        )
    }

    /// Builds the legacy MZFinance authentication endpoint URL.
    ///
    /// We deliberately construct this ourselves instead of reading `authenticateAccount`
    /// from `bag.xml`: Apple's bag now points that key at the newer SRP endpoint
    /// (`auth.itunes.apple.com/auth/v1/native`), which silently rejects the legacy
    /// plist credential body with an empty `200` response. The classic
    /// `pXX-buy.itunes.apple.com/.../authenticate` endpoint still accepts it.
    private func authenticateURL(authCode: String?, deviceID: String) -> String {
        let prefix = authCode != nil
            ? Constant.privateAppStoreAPIDomainPrefixWithAuthCode
            : Constant.privateAppStoreAPIDomainPrefixWithoutAuthCode
        return "https://\(prefix)-\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathAuthenticate)?guid=\(deviceID)"
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

            // deleteCookie synchronously dispatches to HTTPCookieStorage's internal
            // (default-QoS) queue. Run it on a detached utility task so the waiting
            // thread isn't higher priority than that queue — otherwise the login/
            // logout call chain (user-initiated QoS) triggers a priority inversion.
            await Task.detached(priority: .utility) {
                let storage = HTTPCookieStorage.shared
                if let cookies = storage.cookies {
                    for cookie in cookies where cookie.domain.contains("apple.com") || cookie.domain.contains("itunes.com") {
                        storage.deleteCookie(cookie)
                    }
                }
            }.value

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

    func lookup(bundleID: String, account: Account, platform: AppPlatform) async throws -> AppStoreApp {
        let countryCode = getCountryCodeFromStoreFront(account.storeFront)

        let entity: String
        switch platform {
        case .ios: entity = "software,iPadSoftware"
        case .macos: entity = "macSoftware"
        }

        let encodedID = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        let urlString = "https://\(Constant.iTunesAPIDomain)\(Constant.iTunesAPIPathLookup)?bundleId=\(encodedID)&entity=\(entity)&limit=1&media=software&country=\(countryCode)"

        guard let url = URL(string: urlString) else { throw LoginError.networkError }

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

        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        guard let raw = result.results?.first else {
            throw LoginError.unknownError("App not found")
        }

        return AppStoreApp(
            id: raw.id ?? 0,
            bundleID: raw.bundleID ?? "",
            name: raw.name ?? "",
            version: raw.version ?? "",
            price: raw.price ?? 0.0,
            iconURL: raw.iconURL,
            platform: platform
        )
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
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String? = nil, downloadedVersion: String? = nil, progress: ((Double, Int64, Int64) -> Void)? = nil, modelContext: ModelContext? = nil) async throws -> DownloadOutput {
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
                await updateDownloadedApp(app: app, newFilePath: result.destinationPath, downloadedVersion: downloadedVersion, context: modelContext)
            } else {
                await saveDownloadedApp(app: app, filePath: result.destinationPath, downloadedVersion: downloadedVersion, context: modelContext)
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

        // Write remaining buffer
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
    func fetchVersionDisplayName(app: AppStoreApp, account: Account, versionId: String) async throws -> VersionDisplayInfo {
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

        // Try to get accurate metadata from the actual IPA via partial ZIP range requests.
        // API metadata can be stale (ipatool comment: "Do not fall back to item.Metadata here").
        if let cdnURLString = firstItem["URL"] as? String,
           let cdnURL = URL(string: cdnURLString) {
            if let info = try? await PartialZIPReader(url: cdnURL).readVersionMetadata() {
                return info
            }
        }

        // Fallback: use metadata from API response (may be stale for older versions)
        let apiMinimumOS = (metadata["minimumOSVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        for key in ["bundleShortVersionString", "CFBundleShortVersionString"] {
            if let v = metadata[key] as? String, !v.isEmpty {
                return VersionDisplayInfo(versionString: v, releaseDate: nil, minimumOSVersion: apiMinimumOS)
            }
        }

        throw LoginError.unknownError("No version string in metadata")
    }

    // MARK: - Private Methods

    /// Posts the MZFinance authenticate request (with PET as password) and follows
    /// the pod redirect (e.g. p25 -> p46) manually, re-POSTing the body each hop.
    /// URLSession can't auto-follow because the session delegate cancels these
    /// redirects (to preserve the POST method/body). Returns the final parsed
    /// result containing passwordToken / DSID / storeFront / pod.
    private func authenticateMZFinance(email: String, password: String, deviceID: String) async throws -> LoginParseResult {
        var redirect = ""
        var attempt = 1
        let maxAttempts = 5

        while attempt <= maxAttempts {
            let urlString = redirect.isEmpty
                ? authenticateURL(authCode: nil, deviceID: deviceID)
                : redirect
            let credentials = LoginCredentials(email: email, password: password, authCode: nil)
            let request = try createLoginRequest(credentials: credentials, deviceID: deviceID, attempt: attempt, url: urlString)

            logger.logRequest(request)
            let (data, response) = try await session.data(for: request)
            logger.logResponse(response, data: data, error: nil)

            guard let httpResponse = response as? HTTPURLResponse else { throw LoginError.networkError }

            let result = try parseLoginResponse(
                data: data, statusCode: httpResponse.statusCode,
                attempt: attempt, authCode: nil, httpResponse: httpResponse
            )

            if result.shouldRetry {
                if let redirectURL = result.redirectURL {
                    redirect = redirectURL
                } else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    redirect = ""
                }
                attempt += 1
                continue
            }
            return result
        }

        throw LoginError.unknownError("MZFinance authentication exceeded redirect attempts")
    }

    private func createLoginRequest(credentials: LoginCredentials, deviceID: String, attempt: Int, url urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw LoginError.networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Apple now enforces device-bound anisette headers on the auth endpoint.
        // On macOS these are generated natively via AOSKit (no external server).
        let anisette = AnisetteProvider.shared.headers()
        for (key, value) in anisette {
            request.setValue(value, forHTTPHeaderField: key)
        }
        print("🔑 [Anisette] attached \(anisette.count) header(s); OTP available: \(AnisetteProvider.shared.isOTPAvailable)")

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

        // An empty 200 from the auth endpoint means the request was silently rejected
        // (e.g. the legacy plist body sent to the new SRP endpoint). Surface this
        // explicitly instead of a generic network error so it stays diagnosable.
        if data.isEmpty {
            throw LoginError.unknownError("The authentication endpoint returned an empty response (status \(statusCode)). The request was likely rejected.")
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

        if failureType.isEmpty && customerMessage == Constant.customerMessageBadLogin {
            // If authCode was provided, the code itself was wrong; otherwise 2FA is needed
            if authCode != nil {
                throw LoginError.invalidAuthCode
            } else {
                throw LoginError.twoFactorRequired(maskedPhone: nil)
            }
        }

        // Transient Apple server error — signal a retry with a fresh bag session
        if failureType == Constant.failureTypeTransientError {
            return LoginParseResult(shouldRetry: true)
        }

        if !failureType.isEmpty {
            let message = customerMessage.isEmpty ? "Unknown error" : customerMessage
            throw LoginError.unknownError(message)
        }

        // failureType is empty but Apple returned an account restriction message
        // (e.g. "iTunes account creation not allowed.", "m-allowed: false", etc.)
        if !customerMessage.isEmpty {
            let dialog = plist["dialog"] as? [String: Any]
            let explanation = dialog?["explanation"] as? String ?? ""
            throw LoginError.unknownError(explanation.isEmpty ? customerMessage : explanation)
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
        StoreFrontCatalog.searchCountryCode(for: storeFront)
    }

    @MainActor
    private func saveDownloadedApp(app: AppStoreApp, filePath: String, downloadedVersion: String? = nil, context: ModelContext) async {
        do {
            let downloadedApp = DownloadedApp(app: app, filePath: filePath, versionOverride: downloadedVersion)
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
    private func updateDownloadedApp(app: AppStoreApp, newFilePath: String, downloadedVersion: String? = nil, context: ModelContext) async {
        do {
            let descriptor = FetchDescriptor<DownloadedApp>(
                predicate: #Predicate<DownloadedApp> { downloadedApp in
                    downloadedApp.appId == (app.id ?? 0)
                }
            )

            let existingApps = try context.fetch(descriptor)
            if let existingApp = existingApps.first {
                existingApp.filePath = newFilePath
                if let version = downloadedVersion {
                    existingApp.version = version
                    existingApp.downloadDate = Date()
                }
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
        // Apple transient server error during auth — safe to retry with a fresh session
        static let failureTypeTransientError = "5005"

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
