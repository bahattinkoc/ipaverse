import Foundation
import CoreFoundation

enum AppStorePurchaseError: LocalizedError {
    case invalidApp
    case paidOrUnknownPrice
    case http(Int)
    case invalidResponse
    case failure(code: String, message: String)
    case licenseUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidApp: "The app has no valid App Store ID."
        case .paidOrUnknownPrice: "Only apps confirmed to be free can be purchased. Refresh the app details and try again."
        case .http(let status): "Apple's purchase service returned HTTP \(status). The license could not be confirmed."
        case .invalidResponse: "Apple did not confirm the app purchase. Please try again."
        case .licenseUnavailable: "Apple processed the purchase request but still reports that no license is available. Please try again later."
        case .failure(let code, let message):
            code == "2022"
                ? "Apple could not collect payment for a previous purchase on this account. This can also block free apps. Review your Purchase History and payment method in your Apple Account, resolve the unpaid balance, then try again. (Apple error 2022)"
                : "\(message.isEmpty ? "Apple could not purchase the app" : message) (Apple error \(code))"
        }
    }
}

/// Configurator free-license acquisition. A transport response is never proof
/// of ownership: require Apple's purchaseSuccess and an explicit zero status.
enum AppStorePurchase {
    static func acquire(
        request: URLRequest, appID: Int64?, price: Double?, guid: String,
        allowsArcade: Bool,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws {
        guard let appID, appID > 0 else { throw AppStorePurchaseError.invalidApp }
        guard price == 0 else { throw AppStorePurchaseError.paidOrUnknownPrice }
        var purchase = request
        purchase.httpMethod = "POST"
        purchase.httpBody = try body(appID: appID, guid: guid, pricing: "STDQ")
        try Task.checkCancellation()
        do {
            let (data, response) = try await send(purchase)
            try validate(data: data, response: response)
        } catch AppStorePurchaseError.failure(let code, _) where code == "2059" && allowsArcade {
            // IPAtool's Arcade fallback is only for Apple's item-unavailable code.
            // Billing, auth and transport failures must not switch purchase mode.
            try Task.checkCancellation()
            purchase.httpBody = try body(appID: appID, guid: guid, pricing: "GAME")
            let (data, response) = try await send(purchase)
            try validate(data: data, response: response)
        }
    }

    private static func body(appID: Int64, guid: String, pricing: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "appExtVrsId": "0", "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true", "hasDoneAgeCheck": "true",
            "guid": guid, "needDiv": "0", "origPage": "Software-\(appID)",
            "origPageLocation": "Buy", "price": "0", "pricingParameters": pricing,
            "productType": "C", "salableAdamId": appID
        ], format: .xml, options: 0)
    }

    static func validate(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AppStorePurchaseError.invalidResponse }
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        // Preserve explicit Apple errors even when delivered with HTTP 500.
        if let code = scalar(plist?["failureType"]), !code.isEmpty, code != "0" {
            throw AppStorePurchaseError.failure(code: code, message: plist?["customerMessage"] as? String ?? "")
        }
        guard response.statusCode == 200 else { throw AppStorePurchaseError.http(response.statusCode) }
        guard let plist,
              plist["jingleDocType"] as? String == "purchaseSuccess",
              scalar(plist["status"]) == "0",
              !isTrue(plist["cancel-purchase-batch"]),
              !isFalse(plist["m-allowed"]) else { throw AppStorePurchaseError.invalidResponse }
    }

    private static func scalar(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return nil
    }

    private static func isTrue(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue == true || (value as? String)?.lowercased() == "true"
    }

    private static func isFalse(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue == false || (value as? String)?.lowercased() == "false"
    }

    /// Used by both version loading and downloads. Retry the original operation
    /// once after acquisition; never repeat purchases when a license stays absent.
    static func withLicense<Value>(
        operation: () async throws -> Value,
        isLicenseRequired: (Error) -> Bool,
        purchase: () async throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        do { return try await operation() }
        catch { guard isLicenseRequired(error) else { throw error } }
        try Task.checkCancellation()
        do { try await purchase() }
        catch AppStorePurchaseError.failure(let code, _) where code == "5002" {
            // IPAtool interprets 5002 as already owned, but it can be ambiguous.
            // Only a successful follow-up download/version lookup confirms that.
        }
        try Task.checkCancellation()
        do { return try await operation() }
        catch {
            if isLicenseRequired(error) { throw AppStorePurchaseError.licenseUnavailable }
            throw error
        }
    }
}
