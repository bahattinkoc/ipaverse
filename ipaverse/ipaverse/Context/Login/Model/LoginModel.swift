//
//  LoginModel.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation

// MARK: - Login Models
struct LoginCredentials: Codable {
    let email: String
    let password: String
    let authCode: String?
    let rememberMe: Bool
    
    init(
        email: String = "",
        password: String = "",
        authCode: String? = nil,
        rememberMe: Bool = true
    ) {
        self.email = email
        self.password = password
        self.authCode = authCode
        self.rememberMe = rememberMe
    }
}

struct Account: Codable, Equatable {
    let email: String
    let name: String
    let storeFront: String
    let passwordToken: String
    let directoryServicesID: String
    let password: String
    let pod: String?
    
    init(
        email: String,
        password: String = "",
        name: String,
        storeFront: String,
        passwordToken: String,
        directoryServicesID: String,
        pod: String? = nil
    ) {
        self.email = email
        self.password = password
        self.name = name
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
        self.pod = pod
    }
}

// MARK: - Saved Profile

struct SavedProfile: Codable, Identifiable, Equatable {
    let email: String
    let name: String
    let storeFront: String

    var id: String { email }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? String(email.prefix(2)).uppercased() : String(letters).uppercased()
    }

    var countryCode: String? { StoreFrontCatalog.countryCode(for: storeFront) }
    var flagEmoji: String? { StoreFrontCatalog.region(for: storeFront)?.flagEmoji }
    var countryName: String? { StoreFrontCatalog.region(for: storeFront)?.name }
}

// MARK: - Login State
enum LoginState: Equatable {
    case idle
    case loading
    case success(Account)
    case error(String)
    case requires2FA
    
    static func == (lhs: LoginState, rhs: LoginState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.loading, .loading): true
        case (.requires2FA, .requires2FA): true
        case (.success(let lhsAccount), .success(let rhsAccount)): lhsAccount.email == rhsAccount.email
        case (.error(let lhsMessage), .error(let rhsMessage)): lhsMessage == rhsMessage
        default: false
        }
    }
}

// MARK: - Login Error
enum LoginError: LocalizedError, Equatable {
    case invalidCredentials
    case networkError
    case twoFactorRequired
    case invalidAuthCode
    case accountLocked
    case tokenExpired
    case licenseRequired
    case unknownError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid Apple ID or password"
        case .networkError: "Network connection error"
        case .twoFactorRequired: "Two-factor authentication required"
        case .invalidAuthCode: "Invalid verification code. Please try again."
        case .accountLocked: "Account locked"
        case .tokenExpired: "Session expired. Please login again."
        case .licenseRequired: "License required"
        case .unknownError(let message): message
        }
    }
} 
