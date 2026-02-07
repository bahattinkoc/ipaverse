//
//  LoginVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import Foundation
import Combine

@MainActor
final class LoginVM: ObservableObject {

    // MARK: - PUBLISHED PROPERTIES

    @Published var loginState: LoginState = .loading
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var authCode: String = ""
    @Published var rememberMe: Bool = true
    @Published var showAuthCodeField: Bool = false
    @Published var errorMessage: String = ""
    @Published var toastMessage: String = ""
    @Published var isEmailValid: Bool = true
    @Published var isPasswordValid: Bool = true
    @Published var hasEmailBeenEdited: Bool = false
    @Published var hasPasswordBeenEdited: Bool = false

    // MARK: - SERVICES

    private let keychainService: KeychainServiceProtocol
    private let appStoreService: AppStoreServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - INIT

    init(
        keychainService: KeychainServiceProtocol = KeychainService(),
        appStoreService: AppStoreServiceProtocol = AppStoreService()
    ) {
        self.keychainService = keychainService
        self.appStoreService = appStoreService

        setupBindings()
        checkExistingLogin()
    }

    // MARK: - INTERNAL FUNCTIONS

    func loadUserEmail() {
        email = UserDefaults.standard.string(forKey: "lastEmail") ?? ""
    }

    func login() async {
        guard validateInputs() else { return }

        loginState = .loading
        errorMessage = ""

        do {
            let credentials = LoginCredentials(
                email: email,
                password: password,
                authCode: authCode.isEmpty ? nil : authCode,
                rememberMe: rememberMe
            )

            let account = try await appStoreService.login(credentials: credentials)

            if rememberMe {
                try keychainService.saveCredentials(credentials)
            }

            try keychainService.saveAccount(account)

            loginState = .success(account)
            saveUserEmail()
        } catch LoginError.twoFactorRequired {
            showAuthCodeField = true
            loginState = .requires2FA
            errorMessage = "Two-factor authentication code required"

        } catch LoginError.invalidCredentials {
            loginState = .error("Invalid Apple ID or password")
            errorMessage = "Invalid Apple ID or password"

        } catch {
            loginState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func handle2FA(_ code: String) async {
        authCode = code
        await login()
    }

    func resetToLoginForm() {
        authCode = ""
        resetForm()
        loginState = .idle
    }

    func resendAuthCode() async {
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

            if rememberMe {
                try keychainService.saveCredentials(credentials)
            }

            try keychainService.saveAccount(account)

            loginState = .success(account)
            saveUserEmail()
        } catch LoginError.twoFactorRequired {
            showAuthCodeField = true
            loginState = .requires2FA
            errorMessage = "New verification code sent. Please check your device."

        } catch LoginError.invalidCredentials {
            loginState = .error("Invalid Apple ID or password")
            errorMessage = "Invalid Apple ID or password"

        } catch {
            loginState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func logout(withMessage message: String? = nil) async {
        do {
            try await appStoreService.logout()

            loginState = .idle
            resetForm()

            if let message {
                toastMessage = message
            }
        } catch {
            errorMessage = "An error occurred while logging out.: \(error.localizedDescription)"
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - PRIVATE FUNCTIONS

    private func saveUserEmail() {
        UserDefaults.standard.set(email, forKey: "lastEmail")
    }

    private func setupBindings() {
        $email
            .dropFirst()
            .sink { [weak self] email in
                guard let self = self else { return }
                self.errorMessage = ""
                self.hasEmailBeenEdited = true
                let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                self.isEmailValid = trimmedEmail.isEmpty || self.isValidEmail(trimmedEmail)
            }
            .store(in: &cancellables)

        $password
            .dropFirst()
            .sink { [weak self] password in
                guard let self = self else { return }
                self.errorMessage = ""
                self.hasPasswordBeenEdited = true
                self.isPasswordValid = !password.isEmpty
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
                        saveUserEmail()
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
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty else {
            hasEmailBeenEdited = true
            isEmailValid = false
            errorMessage = "Apple ID required"
            return false
        }

        guard isValidEmail(trimmedEmail) else {
            hasEmailBeenEdited = true
            isEmailValid = false
            errorMessage = "Please enter a valid email address"
            return false
        }

        isEmailValid = true

        guard !password.isEmpty else {
            hasPasswordBeenEdited = true
            isPasswordValid = false
            errorMessage = "Password required"
            return false
        }

        isPasswordValid = true

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
        isEmailValid = true
        isPasswordValid = true
        hasEmailBeenEdited = false
        hasPasswordBeenEdited = false
    }
}

// MARK: - Computed Properties
extension LoginVM {
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

    var isLoginButtonEnabled: Bool {
        if showAuthCodeField {
            return !authCode.isEmpty
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidEmail(trimmedEmail) && !password.isEmpty
    }

    func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}
