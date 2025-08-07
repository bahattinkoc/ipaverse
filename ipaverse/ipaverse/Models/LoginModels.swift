//
//  LoginModels.swift
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
    
    init(email: String = "", password: String = "", authCode: String? = nil, rememberMe: Bool = true) {
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
    
    init(
        email: String,
        password: String = "",
        name: String,
        storeFront: String,
        passwordToken: String,
        directoryServicesID: String
    ) {
        self.email = email
        self.password = password
        self.name = name
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
    }
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
        case (.idle, .idle):
            return true
        case (.loading, .loading):
            return true
        case (.requires2FA, .requires2FA):
            return true
        case (.success(let lhsAccount), .success(let rhsAccount)):
            return lhsAccount.email == rhsAccount.email
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

// MARK: - Login Error
enum LoginError: LocalizedError {
    case invalidCredentials
    case networkError
    case twoFactorRequired
    case accountLocked
    case unknownError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Apple ID or password"
        case .networkError:
            return "Network connection error"
        case .twoFactorRequired:
            return "Two-factor authentication required"
        case .accountLocked:
            return "Account locked"
        case .unknownError(let message):
            return message
        }
    }
} 
