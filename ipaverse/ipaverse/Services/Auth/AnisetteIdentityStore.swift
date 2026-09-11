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

    func updatingClientIdentifier() -> Self {
        Self(version: version, server: server, localUserID: localUserID, deviceID: deviceID,
             clientInfo: AnisetteClientInfo.replacingLegacyIdentifier(in: clientInfo),
             provisioningData: provisioningData)
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
        guard let data = result as? Data,
              let identity = try? JSONDecoder().decode(AnisetteIdentity.self, from: data),
              identity.version == 1, identity.server == server,
              !identity.localUserID.isEmpty, UUID(uuidString: identity.deviceID) != nil,
              !identity.clientInfo.isEmpty, !identity.provisioningData.isEmpty else {
            throw AnisetteError.invalidIdentity
        }
        return identity
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
