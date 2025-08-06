//
//  KeychainService.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import Security

protocol KeychainServiceProtocol {
    func saveCredentials(_ credentials: LoginCredentials) throws
    func getCredentials() -> LoginCredentials?
    func clearCredentials() throws
    func saveAccount(_ account: Account) throws
    func getAccount() -> Account?
}

final class KeychainService: KeychainServiceProtocol {
    private let credentialsKey = "ipaverse.credentials"
    private let accountKey = "ipaverse.account"

    // MARK: - Credentials Management
    func saveCredentials(_ credentials: LoginCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func getCredentials() -> LoginCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(LoginCredentials.self, from: data) else {
            return nil
        }

        return credentials
    }

    func clearCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: credentialsKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Account Management
    func saveAccount(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func getAccount() -> Account? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let account = try? JSONDecoder().decode(Account.self, from: data) else {
            return nil
        }

        return account
    }
}

// MARK: - Keychain Error
enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case readFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Error saving to keychain: \(status)"
        case .deleteFailed(let status):
            return "Error deleting from Keychain: \(status)"
        case .readFailed(let status):
            return "Reading error from keychain: \(status)"
        }
    }
}
