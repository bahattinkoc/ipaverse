//
//  LoginView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var viewModel: LoginViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerView

                ScrollView {
                    VStack(spacing: 32) {
                        logoSection

                        loginFormSection

                        if !viewModel.errorMessage.isEmpty {
                            errorMessageView
                        }

                        if viewModel.showAuthCodeField {
                            twoFactorSection
                        }

                        loginButtonSection
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 20)
                }

                Spacer()
            }
            .background(.background)
            .navigationTitle("")
        }
    }

    // MARK: - Header View
    private var headerView: some View {
        HStack {
            Text("ipaverse")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Spacer()

            Button("Settings") {
                // TODO: - Settings action
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.background)
    }

    // MARK: - Logo Section
    private var logoSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "apple.logo")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            Text("Sign in with Apple ID")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text("Sign in to discover and download App Store apps")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    // MARK: - Login Form Section
    private var loginFormSection: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple ID")
                    .font(.headline)
                    .foregroundColor(.primary)

                TextField("Apple ID or email address", text: $viewModel.email)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            SecureTextField(
                title: "Password",
                placeholder: "Enter your password",
                text: $viewModel.password,
                errorMessage: nil
            )

            HStack {
                Toggle("Remember Me", isOn: $viewModel.rememberMe)
                    .toggleStyle(CheckboxToggleStyle())

                Spacer()
            }
        }
    }

    // MARK: - Two Factor Section
    private var twoFactorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification Code")
                .font(.headline)
                .foregroundColor(.primary)

            TextField("Enter the 6-digit code", text: $viewModel.authCode)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Error Message View
    private var errorMessageView: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(viewModel.errorMessage)
                .font(.body)
                .foregroundColor(.red)

            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Login Button Section
    private var loginButtonSection: some View {
        VStack(spacing: 16) {
            LoadingButton(
                title: viewModel.showAuthCodeField ? "Verify" : "Log in",
                isLoading: viewModel.isLoading,
                isEnabled: viewModel.showAuthCodeField ? !viewModel.authCode.isEmpty : (!viewModel.email.isEmpty && !viewModel.password.isEmpty)
            ) {
                if viewModel.showAuthCodeField {
                    await viewModel.handle2FA(viewModel.authCode)
                } else {
                    await viewModel.login()
                }
            }

            if viewModel.showAuthCodeField {
                VStack(spacing: 12) {
                    Button("Resend verification code") {
                        Task {
                            await viewModel.resendAuthCode()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .disabled(viewModel.isLoading)

                    Button("Change Password") {
                        viewModel.resetToLoginForm()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Checkbox Toggle Style
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .foregroundColor(configuration.isOn ? .blue : .gray)
                .font(.title2)

            configuration.label
                .font(.body)
                .foregroundColor(.primary)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            configuration.isOn.toggle()
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(LoginViewModel())
}
