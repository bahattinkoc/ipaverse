//
//  LoginView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var viewModel: LoginVM
    @FocusState private var focusedField: Field?

    enum Field {
        case email, password, authCode
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showAuthCodeField {
                HStack {
                    Button(action: {
                        viewModel.resetToLoginForm()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.secondary.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
            }
            
            ScrollView {
                VStack(spacing: 40) {
                    logoSection

                    if viewModel.showAuthCodeField {
                        twoFactorSection
                    } else {
                        loginFormSection
                    }

                    if !viewModel.errorMessage.isEmpty {
                        errorMessageView
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            
            VStack(spacing: 0) {
                Divider()
                    .opacity(0.3)
                
                loginButtonSection
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .background(.regularMaterial)
            }
        }
        .toast(
            message: viewModel.toastMessage,
            isPresented: Binding(
                get: { !viewModel.toastMessage.isEmpty },
                set: { if !$0 { viewModel.toastMessage = "" } }
            )
        )
    }

    private var logoSection: some View {
        VStack(spacing: 20) {
            LinearGradient(
                colors: [.blue, .purple, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 100, height: 100)
            .mask(
                Image("logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            .shadow(color: .blue.opacity(0.3), radius: 20, x: 0, y: 10)
        }
        .padding(.top, 20)
    }

    private var loginFormSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text("Welcome Back")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Sign in to your Apple ID to continue")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 8)

            ModernTextField(
                title: "Apple ID",
                placeholder: "Enter your Apple ID or email",
                text: $viewModel.email,
                icon: "person.circle.fill"
            )
            .focused($focusedField, equals: .email)

            ModernSecureTextField(
                title: "Password",
                placeholder: "Enter your password",
                text: $viewModel.password
            )
            .focused($focusedField, equals: .password)

            HStack {
                Toggle("Remember me", isOn: $viewModel.rememberMe)
                    .toggleStyle(ModernCheckboxToggleStyle())

                Spacer()
            }
            .padding(.top, 8)
        }
        .task {
            viewModel.loadUserEmail()
        }
    }

    private var twoFactorSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text("Two-Factor Authentication")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Enter the 6-digit verification code sent to your trusted device")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 8)

            VStack(spacing: 16) {
                Text("Verification Code")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { index in
                        ModernAuthCodeField(
                            text: Binding(
                                get: { String(viewModel.authCode.dropFirst(index).prefix(1)) },
                                set: { newValue in
                                    if newValue.count <= 1 {
                                        if newValue.isEmpty {
                                            viewModel.authCode = String(viewModel.authCode.prefix(index))
                                        } else {
                                            let currentCode = viewModel.authCode
                                            if index < currentCode.count {
                                                viewModel.authCode = String(currentCode.prefix(index)) + newValue + String(currentCode.dropFirst(index + 1))
                                            } else {
                                                viewModel.authCode = currentCode + newValue
                                            }
                                        }

                                        if newValue.count == 1 && index < 5 {
                                            focusedField = .authCode
                                        }
                                    }
                                }
                            ),
                            isFocused: focusedField == .authCode
                        )
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var errorMessageView: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title3)

            Text(viewModel.errorMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.red)

            Spacer()
        }
        .padding(16)
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    private var loginButtonSection: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ModernLoadingButton(
                    title: viewModel.showAuthCodeField ? "Verify Code" : "Sign In",
                    isLoading: viewModel.isLoading,
                    isEnabled: Binding(
                        get: { viewModel.showAuthCodeField ? !viewModel.authCode.isEmpty : (!viewModel.email.isEmpty && !viewModel.password.isEmpty) },
                        set: { _ in }
                    )
                ) {
                    if viewModel.showAuthCodeField {
                        await viewModel.handle2FA(viewModel.authCode)
                    } else {
                        await viewModel.login()
                    }
                }

                if viewModel.showAuthCodeField {
                    ModernSecondaryButton(
                        title: "",
                        icon: "arrow.clockwise",
                        action: {
                            Task {
                                await viewModel.resendAuthCode()
                            }
                        }
                    )
                }
            }
            .frame(height: 56)
        }
        .padding(.top, 8)
    }
}
