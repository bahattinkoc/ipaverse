import CryptoKit
import Foundation
import Security

/// The entire provisioned identity travels together; OTPs are never persisted.
struct AnisetteIdentity: Codable, Sendable {
    let version: Int
    let server: URL
    let localUserID: String
    let deviceID: String
    let clientInfo: String
    let provisioningData: String

    /// Version 1 records stored this Mac's client info, not the server's, so GSA rejects them
    /// with ec=-80045. The store treats them as missing, and the provider provisions a new one.
    static let currentVersion = 2

    /// Returns nil for an outdated record, so that the caller provisions a new identity.
    static func decodeStored(_ data: Data, server: URL) throws -> AnisetteIdentity? {
        guard let identity = try? JSONDecoder().decode(AnisetteIdentity.self, from: data) else {
            throw AnisetteError.invalidIdentity
        }
        if identity.version < currentVersion { return nil }
        guard identity.version == currentVersion, identity.server == server,
              !identity.localUserID.isEmpty, UUID(uuidString: identity.deviceID) != nil,
              !identity.clientInfo.isEmpty, !identity.provisioningData.isEmpty else {
            throw AnisetteError.invalidIdentity
        }
        return identity
    }
}

protocol AnisetteIdentityStoring: Sendable {
    func load(server: URL) throws -> AnisetteIdentity?
    func save(_ identity: AnisetteIdentity) throws
}

struct AnisetteKeychainStore: AnisetteIdentityStoring {
    private func query(server: URL) -> [String: Any] {
        let key = SHA256.hash(data: Data(server.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.ipaverse.anisette.v3",
                kSecAttrAccount as String: key]
    }

    func load(server: URL) throws -> AnisetteIdentity? {
        var query = query(server: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AnisetteError.keychain(status) }
        guard let data = result as? Data else { throw AnisetteError.invalidIdentity }
        return try AnisetteIdentity.decodeStored(data, server: server)
    }

    func save(_ identity: AnisetteIdentity) throws {
        let query = query(server: identity.server)
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(identity),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AnisetteError.keychain(status) }
    }
}
