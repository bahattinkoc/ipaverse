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
        case email, password
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.showAuthCodeField {
                backButton(action: { viewModel.resetToLoginForm() })
            } else if !viewModel.showAccountPicker && !viewModel.savedProfiles.isEmpty {
                backButton(action: {
                    viewModel.resetForm_public()
                    viewModel.showAccountPicker = true
                })
            }

            ScrollView {
                VStack(spacing: 40) {
                    logoSection

                    if viewModel.showAuthCodeField {
                        twoFactorSection
                    } else if viewModel.showAccountPicker {
                        accountPickerSection
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

            if !viewModel.showAccountPicker {
                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.3)

                    loginButtonSection
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                        .background(.regularMaterial)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.showAccountPicker)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.showAuthCodeField)
        .toast(
            message: viewModel.toastMessage,
            isPresented: Binding(
                get: { !viewModel.toastMessage.isEmpty },
                set: { if !$0 { viewModel.toastMessage = "" } }
            )
        )
    }

    // MARK: - Back Button

    private func backButton(action: @escaping () -> Void) -> some View {
        HStack {
            Button(action: action) {
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

    // MARK: - Logo

    private var logoSection: some View {
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
        .padding(.top, 20)
    }

    // MARK: - Account Picker

    private var accountPickerSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Welcome Back")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Choose an account to continue")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ForEach(viewModel.savedProfiles) { profile in
                    AccountProfileCard(profile: profile) {
                        Task { await viewModel.quickLogin(profile: profile) }
                    } onEdit: {
                        viewModel.selectProfileForEditing(profile)
                    } onDelete: {
                        viewModel.deleteProfile(profile)
                    }
                }
            }

            Button {
                viewModel.showNewLoginForm()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                    Text("Add Another Account")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Login Form

    private var loginFormSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text(viewModel.editingProfile != nil ? "Edit Account" : "Sign In")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text(viewModel.editingProfile != nil
                     ? "Update your credentials for \(viewModel.editingProfile!.email)"
                     : "Sign in to your Apple ID to continue")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 8)

            ModernTextField(
                title: "Apple ID",
                placeholder: "Enter your Apple ID or email",
                text: $viewModel.email,
                icon: "person.circle.fill",
                isValid: !viewModel.hasEmailBeenEdited || viewModel.isEmailValid
            )
            .focused($focusedField, equals: .email)
            .disabled(viewModel.editingProfile != nil)
            .opacity(viewModel.editingProfile != nil ? 0.7 : 1)

            ModernSecureTextField(
                title: "Password",
                placeholder: "Enter your password",
                text: $viewModel.password,
                isValid: !viewModel.hasPasswordBeenEdited || viewModel.isPasswordValid
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
            if viewModel.editingProfile == nil && viewModel.savedProfiles.isEmpty {
                viewModel.loadUserEmail()
            }
        }
    }

    // MARK: - Two Factor

    private var twoFactorSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Two-Factor Authentication")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Apple sent a 6-digit verification code to your trusted devices.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                    Image(systemName: "ipad")
                    Image(systemName: "laptopcomputer")
                }
                .font(.system(size: 18))
                .foregroundColor(.secondary.opacity(0.6))

                Text("Check your iPhone, iPad, or Mac for a notification from Apple.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 4)

            VStack(spacing: 16) {
                Text("Verification Code")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                OTPVerificationView(otpText: $viewModel.authCode)

                Text("Didn't receive a code? Use the Resend button below.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Error

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

    // MARK: - Login Button

    private var loginButtonSection: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ModernLoadingButton(
                    title: viewModel.showAuthCodeField ? "Verify Code" : "Sign In",
                    isLoading: viewModel.isLoading,
                    isEnabled: Binding(
                        get: { viewModel.isLoginButtonEnabled },
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
                        title: "Resend",
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

// MARK: - Account Profile Card

struct AccountProfileCard: View {
    let profile: SavedProfile
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Text(profile.initials)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(profile.email)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Edit account")

                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Remove account")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit Account", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove Account", systemImage: "trash")
            }
        }
    }
}
