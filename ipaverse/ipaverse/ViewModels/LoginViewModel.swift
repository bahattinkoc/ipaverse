//
//  LoginViewModel.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import Combine

@MainActor
final class LoginViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var loginState: LoginState = .idle
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var authCode: String = ""
    @Published var rememberMe: Bool = true
    @Published var showAuthCodeField: Bool = false
    @Published var errorMessage: String = ""
    @Published var toastMessage: String = ""

    // MARK: - Services
    private let keychainService: KeychainServiceProtocol
    private let appStoreService: AppStoreServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(keychainService: KeychainServiceProtocol = KeychainService(),
         appStoreService: AppStoreServiceProtocol = AppStoreService()) {
        self.keychainService = keychainService
        self.appStoreService = appStoreService

        setupBindings()
        checkExistingLogin()
    }

    // MARK: - Public Methods
    func login() async {
        guard validateInputs() else { return }

        loginState = .loading
        errorMessage = ""

        print("🔐 Login starting...")
        print("📧 Email: \(email)")
        print("🔑 Password length: \(password.count)")
        print("📱 2FA Code: \(authCode.isEmpty ? "Doesn't have" : "Have (\(authCode.count) characters)")")

        do {
            let credentials = LoginCredentials(
                email: email,
                password: password,
                authCode: authCode.isEmpty ? nil : authCode,
                rememberMe: rememberMe
            )

            let account = try await appStoreService.login(credentials: credentials)

            print("✅ Login succeeded!")
            print("👤 User: \(account.name)")
            print("🏪 Store Front: \(account.storeFront)")
            print("🎫 Token length: \(account.passwordToken.count)")

            if rememberMe {
                try keychainService.saveCredentials(credentials)
                print("💾 Credentials saved to keychain")
            }

            try keychainService.saveAccount(account)
            print("💾 Account saved to keychain")

            loginState = .success(account)

        } catch LoginError.twoFactorRequired {
            print("🔐 2FA required")
            showAuthCodeField = true
            loginState = .requires2FA
            errorMessage = "Two-factor authentication code required"

        } catch LoginError.invalidCredentials {
            print("❌ Invalid credentials")
            loginState = .error("Invalid Apple ID or password")
            errorMessage = "Invalid Apple ID or password"

        } catch {
            print("❌ Login error: \(error)")
            loginState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func handle2FA(_ code: String) async {
        print("2FA code received: \(code)")
        authCode = code
        await login()
    }

    func resetToLoginForm() {
        print("🔄 Resetting to login form")
        showAuthCodeField = false
        authCode = ""
        errorMessage = ""
        loginState = .idle
    }
    
    func resendAuthCode() async {
        print("🔄 Resending auth code...")
        errorMessage = ""
        authCode = ""

        let credentials = LoginCredentials(
            email: email,
            password: password,
            authCode: nil,
            rememberMe: rememberMe
        )
        
        do {
            let account = try await appStoreService.login(credentials: credentials)
            
            print("✅ Resend successful!")
            print("👤 User: \(account.name)")
            
            if rememberMe {
                try keychainService.saveCredentials(credentials)
                print("💾 Credentials saved to keychain")
            }
            
            try keychainService.saveAccount(account)
            print("💾 Account saved to keychain")
            
            loginState = .success(account)
            
        } catch LoginError.twoFactorRequired {
            print("🔐 2FA required after resend")
            showAuthCodeField = true
            loginState = .requires2FA
            errorMessage = "New verification code sent. Please check your device."
            
        } catch LoginError.invalidCredentials {
            print("❌ Invalid credentials during resend")
            loginState = .error("Invalid Apple ID or password")
            errorMessage = "Invalid Apple ID or password"
            
        } catch {
            print("❌ Resend error: \(error)")
            loginState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func logout(withMessage message: String? = nil) async {
        print("🔓 ViewModel logout is starting...")

        do {
            try await appStoreService.logout()

            loginState = .idle
            resetForm()
            
            if let message {
                toastMessage = message
            }

            print("✅ ViewModel logout completed")

        } catch {
            print("❌ ViewModel logout error: \(error)")
            errorMessage = "An error occurred while logging out.: \(error.localizedDescription)"
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - Private Methods
    private func setupBindings() {
        $email
            .dropFirst()
            .sink { [weak self] _ in
                self?.errorMessage = ""
            }
            .store(in: &cancellables)

        $password
            .dropFirst()
            .sink { [weak self] _ in
                self?.errorMessage = ""
            }
            .store(in: &cancellables)

        $authCode
            .dropFirst()
            .sink { [weak self] _ in
                self?.errorMessage = ""
            }
            .store(in: &cancellables)
    }

    private func checkExistingLogin() {
        if let account = keychainService.getAccount() {
            Task {
                do {
                    let isValid = try await appStoreService.validateToken(account.passwordToken)
                    if isValid {
                        loginState = .success(account)
                    } else {
                        loginState = .idle
                    }
                } catch {
                    loginState = .idle
                }
            }
        } else {
            loginState = .idle
        }
    }

    private func validateInputs() -> Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Apple ID required"
            return false
        }

        guard !password.isEmpty else {
            errorMessage = "Password required"
            return false
        }

        if showAuthCodeField && authCode.isEmpty {
            errorMessage = "Verification code required"
            return false
        }

        return true
    }

    private func resetForm() {
        email = ""
        password = ""
        authCode = ""
        rememberMe = true
        showAuthCodeField = false
        errorMessage = ""
    }
}

// MARK: - Computed Properties
extension LoginViewModel {
    var isLoading: Bool {
        if case .loading = loginState {
            return true
        }
        return false
    }

    var isLoggedIn: Bool {
        if case .success = loginState {
            return true
        }
        return false
    }

    var currentAccount: Account? {
        if case .success(let account) = loginState {
            return account
        }
        return nil
    }
}
