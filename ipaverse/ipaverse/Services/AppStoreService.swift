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
    func hasValidTokenFormat(_ token: String) async throws -> Bool
    func logout() async throws
    func search(term: String, account: Account, limit: Int, platform: AppPlatform) async throws -> SearchResult
    func lookup(bundleID: String, account: Account, platform: AppPlatform) async throws -> AppStoreApp
    func purchase(app: AppStoreApp, account: Account) async throws
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String?, downloadedVersion: String?, progress: ((Double, Int64, Int64) -> Void)?, modelContext: ModelContext?) async throws -> DownloadOutput
    func listVersions(app: AppStoreApp, account: Account) async throws -> VersionsOutput
}

final class AppStoreService: AppStoreServiceProtocol {
    private let session: URLSession
    private let ownsSession: Bool
    private let cookieJar: HTTPCookieStorage
    private let logger = NetworkLogger.shared

    let sessionDelegate: AppStoreURLSessionDelegate

    /// GrandSlam 2FA context from a verification-pending handshake, used to validate
    /// the code the user subsequently enters. `phoneId` is set when the code is
    /// delivered via SMS (no trusted device).
    private struct PendingGSATwoFactor {
        let identityToken: String
        let phoneId: Int?
        let email: String
        let configuration: AnisetteConfiguration
        let anisette: AnisetteSession
        var isVerified = false
    }
    private var pendingGSATwoFactor: PendingGSATwoFactor?

    init(session: URLSession? = nil, isolatedCookies: Bool = false) {
        let config = isolatedCookies ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        if isolatedCookies {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix("apple.com") || cookie.domain.hasSuffix("itunes.apple.com") {
                config.httpCookieStorage?.setCookie(cookie)
            }
        } else {
            config.httpCookieStorage = HTTPCookieStorage.shared
        }
        config.httpShouldSetCookies = true

        let delegate = AppStoreURLSessionDelegate()
        self.sessionDelegate = delegate
        self.ownsSession = session == nil
        self.session = session ?? URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.cookieJar = config.httpCookieStorage ?? HTTPCookieStorage.shared
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    // MARK: - Login
    //
    // Apple deprecated the legacy MZFinance username/password authenticate endpoint
    // (now returns 403). Auth now goes through GrandSlam (GSA) — an SRP-6a handshake
    // against gsa.apple.com with local or explicitly configured V3 anisette headers. See GSAClient.
    func login(credentials: LoginCredentials) async throws -> Account {
        let configuration = AnisetteConfiguration.load()
        let email = credentials.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let submittingCode = credentials.authCode != nil
        if let pending = pendingGSATwoFactor,
           pending.email != email || pending.configuration != configuration {
            pendingGSATwoFactor = nil
            if submittingCode {
                throw LoginError.unknownError("Sign-in options or account changed. Go back and start sign-in again.")
            }
        }
        if submittingCode && pendingGSATwoFactor == nil { throw LoginError.invalidAuthCode }
        let anisette: AnisetteSession
        if let pending = pendingGSATwoFactor {
            anisette = pending.anisette
        } else {
            anisette = try await AnisetteProvider.shared.makeSession(configuration: configuration)
        }
        let gsa = GSAClient(session: session, anisette: anisette)
        do {
            // If the user just entered a 2FA code, validate it against the pending
            // GrandSlam identity before re-running the handshake (now trusted).
            if let code = credentials.authCode, let pending = pendingGSATwoFactor, !pending.isVerified {
                do {
                    try await gsa.submitTwoFactorCode(code, identityToken: pending.identityToken, phoneId: pending.phoneId)
                } catch GSAError.serverError(let code, _) where !(500...599).contains(code) {
                    throw LoginError.invalidAuthCode
                }
                pendingGSATwoFactor?.isVerified = true
            }

            let gsaAccount = try await gsa.authenticate(
                username: credentials.email,
                password: credentials.password
            )
            print("🔐 [GSA] handshake OK — dsid set: \(!gsaAccount.dsid.isEmpty), idmsToken set: \(!gsaAccount.idmsToken.isEmpty)")
            pendingGSATwoFactor = nil
            return try await bridgeToAppStore(gsa: gsaAccount, credentials: credentials, anisette: anisette)
        } catch let GSAError.needsTwoFactor(identity, phoneId, maskedPhone) {
            pendingGSATwoFactor = PendingGSATwoFactor(identityToken: identity, phoneId: phoneId,
                                                     email: email, configuration: configuration, anisette: anisette)
            // If we already submitted a code and 2FA is still required, the code
            // was wrong/expired — prompt again rather than claiming success.
            throw submittingCode ? LoginError.invalidAuthCode : LoginError.twoFactorRequired(maskedPhone: maskedPhone)
        } catch let GSAError.serverError(code, message) {
            // Apple GSA error codes for bad credentials.
            if code == -20101 || code == -22406 || code == -36607 {
                throw LoginError.invalidCredentials
            }
            throw LoginError.unknownError("GSA \(code): \(message)")
        } catch GSAError.invalidResponse {
            // gsa.apple.com returned something unparseable even after
            // GSAClient's own retry — a raw "unparseable GsService2 body"
            // message means nothing to the user; this is the exact same
            // "Apple's edge is having a bad moment" situation the MZFinance
            // host-rotation exhaustion below already reports, so reuse that
            // message for a consistent, actionable result either way.
            throw LoginError.serviceTemporarilyUnavailable
        }
    }

    /// Exchanges a successful GrandSlam identity for the App Store credentials
    /// (passwordToken / DSID / storeFront) that the download endpoints require.
    ///
    private func bridgeToAppStore(gsa: GSAAccountData, credentials: LoginCredentials, anisette: AnisetteSession) async throws -> Account {
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
        let parsed = try await authenticateMZFinance(email: credentials.email, password: pet, deviceID: deviceID, anisette: anisette)

        let fallbackName = [gsa.raw["fn"] as? String, gsa.raw["ln"] as? String]
            .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let dsid = parsed.directoryServicesID
            ?? (gsa.raw["DsPrsId"] as? NSNumber).map { "\($0)" }
            ?? ""

        return Account(
            email: credentials.email,
            name: parsed.accountName ?? fallbackName,
            storeFront: parsed.storeFront ?? "143441",
            passwordToken: parsed.passwordToken ?? "",
            directoryServicesID: dsid,
            pod: parsed.pod
        )
    }

    /// Builds the legacy MZFinance authentication endpoint URL.
    ///
    /// The PET bridge uses the plist endpoint, with pod routing supplied by
    /// validated Apple redirects. Transport retries keep the same endpoint/body.
    private func authenticateURL(host: String, deviceID: String) -> String {
        return "https://\(host)\(Constant.privateAppStoreAPIPathAuthenticate)?guid=\(deviceID)"
    }

    // MARK: - Token Validation

    /// Checks whether `token` merely *looks like* a token (non-empty, long enough, expected
    /// character set). This is a local, offline format check only — it does NOT verify with
    /// Apple's servers that the token is still valid/unexpired/unrevoked. A token that passes
    /// this check can still be rejected on the next real API call.
    func hasValidTokenFormat(_ token: String) async throws -> Bool {
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

    // MARK: - Header Helpers

    /// Sets the account's DSID under both header names Apple's private API endpoints expect.
    private func setDSIDHeaders(_ dsid: String, on request: inout URLRequest) {
        request.setValue(dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(dsid, forHTTPHeaderField: "X-Dsid")
    }

    /// Applies the standard headers required by Apple's private App Store plist API: content
    /// type, user agent, and the account's DSID. Pass `includeStoreFrontAndToken: true` for
    /// endpoints that also require the storefront and password token (e.g. purchase).
    private func applyAppStoreHeaders(to request: inout URLRequest, account: Account, includeStoreFrontAndToken: Bool = false) {
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        setDSIDHeaders(account.directoryServicesID, on: &request)
        if includeStoreFrontAndToken {
            request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
            request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        }
    }

    // MARK: - Logout
    func logout() async throws {
        pendingGSATwoFactor = nil
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
    func search(term: String, account: Account, limit: Int = 50, platform: AppPlatform) async throws -> SearchResult {
        let countryCode = getCountryCodeFromStoreFront(account.storeFront)

        let entity: String
        switch platform {
        case .ios:
            entity = "software"
        case .ipados:
            entity = "iPadSoftware"
        case .macos:
            entity = "macSoftware"
        case .tvos:
            entity = "software,tvSoftware"
        case .visionos:
            entity = "xrosSoftware"
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
        case .ios: entity = "software"
        case .ipados: entity = "iPadSoftware"
        case .macos: entity = "macSoftware"
        case .tvos: entity = "tvSoftware"
        case .visionos: entity = "xrosSoftware"
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

        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        let url = URL(string: "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathPurchase)")!
        var request = URLRequest(url: url)
        applyAppStoreHeaders(to: &request, account: account, includeStoreFrontAndToken: true)
        do {
            try await AppStorePurchase.acquire(
                request: request, appID: app.id, price: app.price, guid: guid,
                allowsArcade: app.platform != .macos,
                send: { request in
                    self.logger.logRequest(request)
                    let (data, response) = try await self.session.data(for: request)
                    self.logger.logResponse(response, data: data, error: nil)
                    return (self.normalizePlistData(data), response)
                }
            )
        } catch AppStorePurchaseError.failure(let code, let message) {
            if Constant.authFailureCodes.contains(code) || message == Constant.customerMessagePasswordChanged {
                throw LoginError.tokenExpired
            }
            throw AppStorePurchaseError.failure(code: code, message: message)
        }
    }

    // MARK: - Download
    func download(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String? = nil, downloadedVersion: String? = nil, progress: ((Double, Int64, Int64) -> Void)? = nil, modelContext: ModelContext? = nil) async throws -> DownloadOutput {
        var result = try await AppStorePurchase.withLicense(operation: {
            try await self.performDownload(app: app, account: account, outputPath: outputPath, externalVersionId: externalVersionId, progress: progress)
        }, isLicenseRequired: { ($0 as? LoginError) == .licenseRequired }, purchase: {
            try await self.purchase(app: app, account: account)
        })

        if result.success, let modelContext {
            result.version = try await LibraryRepository.recordDownload(app: app, filePath: result.destinationPath,
                version: downloadedVersion, externalVersionID: externalVersionId, context: modelContext)
        }

        return result
    }

    private func downloadItem(app: AppStoreApp, account: Account, versionID: String? = nil) async throws -> [String: Any] {
        let deviceID = try await getDeviceIdentifier()
        let guid = deviceID.replacingOccurrences(of: ":", with: "").uppercased()
        let podPrefix = account.pod.map { "p\($0)-" } ?? ""
        guard let url = URL(string: "https://\(podPrefix)\(Constant.privateAppStoreAPIDomain)\(Constant.privateAppStoreAPIPathDownload)?guid=\(guid)") else {
            throw LoginError.networkError
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAppStoreHeaders(to: &request, account: account)
        request.httpBody = try AppStoreDownloadProduct.body(appID: app.id ?? 0, guid: guid, versionID: versionID)
        var bagUpdateEndpoint: URL?
        let latestVersionID: (() async throws -> String)?
        if app.platform == nil || app.platform == .ios || app.platform == .ipados {
            latestVersionID = {
                guard let country = StoreFrontCatalog.countryCode(for: account.storeFront) else {
                    throw AppStoreDownloadProductError.missingCatalogVersion
                }
                var lookup = try AppStoreDownloadProduct.catalogRequest(appID: app.id ?? 0, countryCode: country)
                lookup.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
                self.logger.logRequest(lookup)
                let (data, response) = try await self.session.data(for: lookup)
                self.logger.logResponse(response, data: data, error: nil)
                guard let http = response as? HTTPURLResponse else { throw LoginError.networkError }
                guard http.statusCode == 200 else { throw AppStoreDownloadProductError.http(http.statusCode) }
                return try AppStoreDownloadProduct.catalogVersionID(data: data, appID: app.id ?? 0)
            }
        } else {
            latestVersionID = nil
        }
        do {
            return try await AppStoreDownloadProduct.item(request: request, redownloadEndpoint: {
                var bagRequest = URLRequest(url: URL(string: "https://\(Constant.privateInitDomain)\(Constant.privateInitPath)")!)
                bagRequest.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
                self.logger.logRequest(bagRequest)
                let (data, response) = try await self.session.data(for: bagRequest)
                self.logger.logResponse(response, data: data, error: nil)
                guard let http = response as? HTTPURLResponse else { throw LoginError.networkError }
                guard http.statusCode == 200 else { throw AppStoreDownloadProductError.http(http.statusCode) }
                guard let plist = try? PropertyListSerialization.propertyList(from: self.normalizePlistData(data), format: nil) as? [String: Any],
                      let bag = plist["urlBag"] as? [String: Any],
                      let endpoint = bag["redownloadProduct"] as? String,
                      let url = URL(string: endpoint) else {
                    throw AppStoreDownloadProductError.invalidEndpoint
                }
                if let update = bag["updateProduct"] as? String {
                    guard let url = URL(string: update) else { throw AppStoreDownloadProductError.invalidEndpoint }
                    bagUpdateEndpoint = url
                }
                return url
            }, latestVersionID: latestVersionID,
               updateEndpoint: latestVersionID == nil ? nil : { bagUpdateEndpoint },
               bundleID: app.bundleID, send: { request in
                self.logger.logRequest(request)
                let (data, response) = try await self.session.data(for: request)
                self.logger.logResponse(response, data: data, error: nil)
                return (self.normalizePlistData(data), response)
            })
        } catch AppStoreDownloadProductError.failure(let code, let message) {
            if Constant.authFailureCodes.contains(code) || message == Constant.customerMessagePasswordChanged {
                throw LoginError.tokenExpired
            }
            if code == Constant.failureTypeLicenseNotFound { throw LoginError.licenseRequired }
            throw AppStoreDownloadProductError.failure(code: code, message: message)
        }
    }

    private func performDownload(app: AppStoreApp, account: Account, outputPath: String?, externalVersionId: String? = nil, progress: ((Double, Int64, Int64) -> Void)? = nil) async throws -> DownloadOutput {
        let firstItem = try await downloadItem(app: app, account: account, versionID: externalVersionId)
        guard let downloadURLString = firstItem["URL"] as? String,
              let downloadURL = URL(string: downloadURLString),
              ["https", "http"].contains(downloadURL.scheme ?? ""), downloadURL.host != nil else {
            throw AppStoreDownloadProductError.invalidResponse
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

        let packageExtension = app.platform == .macos ? "pkg" : "ipa"
        let destinationPath = outputPath ?? "\(app.bundleID ?? "")_\(app.id ?? 0)_\(app.version ?? "").\(packageExtension)"
        let destinationURL = URL(fileURLWithPath: destinationPath)
        var request = URLRequest(url: downloadURL)
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        setDSIDHeaders(account.directoryServicesID, on: &request)
        try await PackageDownload.fetch(request: request, session: session, destination: destinationURL, progress: progress) { staged in
            try PackageDownload.validate(staged, isMacPackage: app.platform == .macos)
            if app.platform != .macos {
                do {
                    try IPAPatcher().applyPatches(ipaPath: staged.path, sinfs: sinfs, email: account.email)
                    try PackageDownload.validate(staged, isMacPackage: false)
                } catch {
                    throw PackageDownloadError.preparation(error.localizedDescription)
                }
            }
        }
        return DownloadOutput(destinationPath: destinationPath, success: true, error: nil)
    }

    // MARK: - List Versions
    func listVersions(app: AppStoreApp, account: Account) async throws -> VersionsOutput {
        let firstItem = try await downloadItem(app: app, account: account)
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
        let firstItem = try await downloadItem(app: app, account: account, versionID: versionId)
        guard let metadata = firstItem["metadata"] as? [String: Any] else {
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
    /// Fetches the live `sign-sap-setup` / `sign-sap-setup-cert` /
    /// `sign-sap-version` URLs from bag.xml. These are the URLs
    /// ``SAPSigner`` needs to run the SAP setup handshake — the same bag
    /// that already supplies `authenticateAccount` conceptually, fetched
    /// separately here since AppStoreService doesn't otherwise need bag.xml.
    private func fetchSAPBagInfo() async throws -> (setupURL: URL, certificateURL: URL, version: UInt32) {
        let bagURLString = "https://\(Constant.privateInitDomain)\(Constant.privateInitPath)"
        guard let bagURL = URL(string: bagURLString) else { throw LoginError.networkError }

        var request = URLRequest(url: bagURL)
        request.setValue(Constant.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LoginError.networkError
        }

        let normalized = normalizePlistData(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: normalized, options: [], format: nil) as? [String: Any],
              let urlBag = plist["urlBag"] as? [String: Any],
              let setupURLString = urlBag["sign-sap-setup"] as? String,
              let certURLString = urlBag["sign-sap-setup-cert"] as? String,
              let versionString = urlBag["sign-sap-version"] as? String,
              let version = UInt32(versionString),
              let setupURL = URL(string: setupURLString),
              let certificateURL = URL(string: certURLString) else {
            throw LoginError.unknownError("Apple's bag.xml is missing the sign-sap-* keys the App Store signing handshake needs")
        }

        return (setupURL, certificateURL, version)
    }

    /// Builds a signer that produces `X-Apple-ActionSignature` values for
    /// MZFinance authenticate requests — see ``SAPSigner`` for what this
    /// actually does (emulating Apple's real 2013 FairPlay/CommerceKit code
    /// to run the same challenge-response a genuine Mac client performs).
    /// The hardware ID reuses the device's MAC address (the same value
    /// already used as `guid`), matching how ipatool derives its
    /// equivalent `machineID` from the same source.
    private func createSAPSigner(deviceID: String) async throws -> SAPSigner {
        let bagInfo = try await fetchSAPBagInfo()
        let bundle = try await SAPAssets.load()

        var hardwareID: [UInt8] = []
        var hexChars = Array(deviceID)
        var index = 0
        while index + 1 < hexChars.count, hardwareID.count < 20 {
            guard let byte = UInt8(String(hexChars[index...index+1]), radix: 16) else { break }
            hardwareID.append(byte)
            index += 2
        }
        if hardwareID.isEmpty {
            hardwareID = Array(deviceID.utf8.prefix(20))
        }
        hexChars.removeAll()

        return try await SAPSigner.create(
            setupURL: bagInfo.setupURL,
            certificateURL: bagInfo.certificateURL,
            version: bagInfo.version,
            hardwareID: hardwareID,
            bundle: bundle
        )
    }

    private func authenticateMZFinance(email: String, password: String, deviceID: String, anisette: AnisetteSession) async throws -> LoginParseResult {
        // MZFinance now requires a signed X-Apple-ActionSignature header on
        // every authenticate request (confirmed empirically: live nodes
        // were rejecting even well-formed, PET-authenticated requests with
        // an empty 403 until this was added) — see SAPSigner for what
        // actually produces it. One signer/handshake per login attempt;
        // its `sign()` is called fresh for each retry's request body.
        let sapSigner: SAPSigner
        do {
            sapSigner = try await createSAPSigner(deviceID: deviceID)
        } catch {
            throw LoginError.unknownError("Could not establish Apple's App Store signing session: \(error.localizedDescription)")
        }
        defer { sapSigner.close() }

        let urlString = authenticateURL(host: Constant.privateAppStoreAPIDomain, deviceID: deviceID)
        guard let url = URL(string: urlString) else { throw LoginError.networkError }
        let request = try MZFinanceAuthentication.makeRequest(url: url, email: email, pet: password,
                                                             deviceID: deviceID, userAgent: Constant.defaultUserAgent)
        let transport = AuthenticationHTTPTransport(session: session)
        let (data, response) = try await MZFinanceAuthentication.exchange(request: request) { request in
            var prepared = request
            let headers = try await anisette.headers()
            for (key, value) in headers { prepared.setValue(value, forHTTPHeaderField: key) }
            guard let body = prepared.httpBody else { throw LoginError.networkError }
            let signature = try sapSigner.sign(body)
            prepared.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
            return prepared
        } send: { request in
            self.logger.logRequest(request)
            let (data, response) = try await transport.data(for: request)
            self.logger.logResponse(response, data: data, error: nil)
            return (data, response)
        }
        let result = try parseLoginResponse(data: data, statusCode: response.statusCode,
                                            authCode: nil, httpResponse: response)
        guard !result.shouldRetry else { throw LoginError.serviceTemporarilyUnavailable }
        return result
    }

    private func parseLoginResponse(data: Data, statusCode: Int, authCode: String?, httpResponse: HTTPURLResponse) throws -> LoginParseResult {
        // Transport failures and pod redirects are handled before parsing.
        let normalizedData = normalizePlistData(data)
        guard let plist = try? PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any] else {
            throw MZFinanceAuthenticationError.invalidResponse
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
            return LoginParseResult(shouldRetry: true, retryReason: "failureType 5005 (transient)")
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


}

// MARK: - Login Parse Result
struct LoginParseResult {
    let shouldRetry: Bool
    let redirectURL: String?
    /// Human-readable reason a retry was requested (e.g. "404 Not Found",
    /// "403 Forbidden", "301 without Location"). Used to build a diagnosable
    /// error if every fallback host is exhausted.
    let retryReason: String?
    let accountName: String?
    let storeFront: String?
    let passwordToken: String?
    let directoryServicesID: String?
    let pod: String?

    init(
        shouldRetry: Bool,
        redirectURL: String? = nil,
        retryReason: String? = nil,
        accountName: String? = nil,
        storeFront: String? = nil,
        passwordToken: String? = nil,
        directoryServicesID: String? = nil,
        pod: String? = nil
    ) {
        self.shouldRetry = shouldRetry
        self.redirectURL = redirectURL
        self.retryReason = retryReason
        self.accountName = accountName
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
        self.pod = pod
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
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
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

        static let privateAppStoreAPIDomain = "buy." + iTunesAPIDomain
        static let privateAppStoreAPIPathAuthenticate = "/WebObjects/MZFinance.woa/wa/authenticate"
        static let privateAppStoreAPIPathPurchase = "/WebObjects/MZFinance.woa/wa/buyProduct"
        static let privateAppStoreAPIPathDownload = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

        static let httpHeaderStoreFront = "X-Set-Apple-Store-Front"
        static let httpHeaderPod = "pod"

        static let privateInitDomain = "init." + iTunesAPIDomain
        static let privateInitPath = "/bag.xml"

        static let defaultUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    }
}
