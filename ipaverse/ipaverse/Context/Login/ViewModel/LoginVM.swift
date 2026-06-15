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
    @Published var twoFactorPhoneHint: String? = nil
    @Published var errorMessage: String = ""
    @Published var toastMessage: String = ""
    @Published var isEmailValid: Bool = true
    @Published var isPasswordValid: Bool = true
    @Published var hasEmailBeenEdited: Bool = false
    @Published var hasPasswordBeenEdited: Bool = false

    @Published var savedProfiles: [SavedProfile] = []
    @Published var showAccountPicker: Bool = false
    @Published var editingProfile: SavedProfile? = nil

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
        loadSavedProfiles()
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
                keychainService.saveProfilePassword(password, for: email)
            }

            try keychainService.saveAccount(account)
            saveProfile(from: account)

            loginState = .success(account)
            showAccountPicker = false
            saveUserEmail()
        } catch LoginError.twoFactorRequired(let maskedPhone) {
            showAuthCodeField = true
            loginState = .requires2FA
            twoFactorPhoneHint = maskedPhone
            errorMessage = ""

        } catch LoginError.invalidAuthCode {
            authCode = ""
            loginState = .requires2FA
            errorMessage = "Invalid verification code. Please try again."

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
        showAccountPicker = !savedProfiles.isEmpty
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
        } catch LoginError.twoFactorRequired(let maskedPhone) {
            showAuthCodeField = true
            loginState = .requires2FA
            twoFactorPhoneHint = maskedPhone
            errorMessage = ""
            toastMessage = maskedPhone.map { "A new verification code was sent to \($0)." }
                ?? "A new verification code was sent to your trusted devices."

        } catch LoginError.invalidCredentials {
            loginState = .error("Invalid Apple ID or password")
            errorMessage = "Invalid Apple ID or password"

        } catch {
            loginState = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func signOutCompletely() async {
        for profile in savedProfiles {
            keychainService.deleteProfilePassword(for: profile.email)
        }
        savedProfiles = []
        UserDefaults.standard.removeObject(forKey: "savedProfiles")
        try? keychainService.clearCredentials()
        await logout()
    }

    func logout(withMessage message: String? = nil) async {
        do {
            try await appStoreService.logout()
            UserDefaults.standard.removeObject(forKey: "originalStoreFront")

            loginState = .idle
            resetForm()

            showAccountPicker = !savedProfiles.isEmpty

            if let message {
                toastMessage = message
            }
        } catch {
            errorMessage = "An error occurred while logging out: \(error.localizedDescription)"
            loginState = .error(error.localizedDescription)
        }
    }

    // MARK: - Saved Profiles

    func loadSavedProfiles() {
        guard let data = UserDefaults.standard.data(forKey: "savedProfiles"),
              let profiles = try? JSONDecoder().decode([SavedProfile].self, from: data) else {
            savedProfiles = []
            return
        }
        savedProfiles = profiles
    }

    func quickLogin(profile: SavedProfile) async {
        guard let savedPassword = keychainService.getProfilePassword(for: profile.email) else {
            selectProfileForEditing(profile)
            return
        }

        email = profile.email
        password = savedPassword
        await login()
    }

    func selectProfileForEditing(_ profile: SavedProfile) {
        email = profile.email
        password = keychainService.getProfilePassword(for: profile.email) ?? ""
        editingProfile = profile
        showAccountPicker = false
        loginState = .idle
    }

    func deleteProfile(_ profile: SavedProfile) {
        keychainService.deleteProfilePassword(for: profile.email)
        savedProfiles.removeAll { $0.email == profile.email }
        persistProfiles()
        if savedProfiles.isEmpty {
            showAccountPicker = false
        }
    }

    func showNewLoginForm() {
        resetForm()
        showAccountPicker = false
        loginState = .idle
    }

    func resetForm_public() {
        resetForm()
    }

    // MARK: - PRIVATE FUNCTIONS

    private func saveProfile(from account: Account) {
        let profile = SavedProfile(
            email: account.email,
            name: account.name,
            storeFront: account.storeFront
        )
        if let index = savedProfiles.firstIndex(where: { $0.email == profile.email }) {
            savedProfiles[index] = profile
        } else {
            savedProfiles.append(profile)
        }
        persistProfiles()
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(savedProfiles) else { return }
        UserDefaults.standard.set(data, forKey: "savedProfiles")
    }

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
                        showAccountPicker = !savedProfiles.isEmpty
                    }
                } catch {
                    loginState = .idle
                    showAccountPicker = !savedProfiles.isEmpty
                }
            }
        } else {
            loginState = .idle
            showAccountPicker = !savedProfiles.isEmpty
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
        twoFactorPhoneHint = nil
        errorMessage = ""
        isEmailValid = true
        isPasswordValid = true
        hasEmailBeenEdited = false
        hasPasswordBeenEdited = false
        editingProfile = nil
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

    func changeStoreFront(_ storeFront: String) {
        guard let account = currentAccount else { return }
        if UserDefaults.standard.string(forKey: "originalStoreFront") == nil {
            UserDefaults.standard.set(account.storeFront, forKey: "originalStoreFront")
        }
        applyStoreFront(storeFront, to: account)
    }

    func resetToDefaultStoreFront() {
        guard let original = UserDefaults.standard.string(forKey: "originalStoreFront"),
              let account = currentAccount else { return }
        UserDefaults.standard.removeObject(forKey: "originalStoreFront")
        applyStoreFront(original, to: account)
    }

    var isUsingCustomRegion: Bool {
        guard let original = UserDefaults.standard.string(forKey: "originalStoreFront"),
              let current = currentAccount?.storeFront else { return false }
        return (original.components(separatedBy: "-").first ?? original) !=
               (current.components(separatedBy: "-").first ?? current)
    }

    var originalStoreFrontCode: String? {
        guard let sf = UserDefaults.standard.string(forKey: "originalStoreFront") else { return nil }
        return sf.components(separatedBy: "-").first ?? sf
    }

    private func applyStoreFront(_ storeFront: String, to account: Account) {
        let updated = Account(
            email: account.email,
            password: account.password,
            name: account.name,
            storeFront: storeFront,
            passwordToken: account.passwordToken,
            directoryServicesID: account.directoryServicesID,
            pod: account.pod
        )
        try? keychainService.saveAccount(updated)
        loginState = .success(updated)
    }

    var isLoginButtonEnabled: Bool {
        if showAuthCodeField {
            return !authCode.isEmpty
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidEmail(trimmedEmail) && !password.isEmpty
    }

    func isValidEmail(_ email: String) -> Bool {
        Self.emailPredicate.evaluate(with: email)
    }

    private static let emailPredicate = NSPredicate(
        format: "SELF MATCHES %@",
        "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
    )
}
