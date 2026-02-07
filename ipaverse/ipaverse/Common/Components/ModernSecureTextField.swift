//
//  ModernSecureTextField.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct ModernSecureTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @State private var isSecure: Bool = true
    var isValid: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
                    .frame(width: 20)

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .textContentType(.password)
                .textFieldStyle(.plain)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSecure.toggle()
                    }
                }) {
                    Image(systemName: isSecure ? "eye.slash.fill" : "eye.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isValid ? Color.secondary.opacity(0.3) : Color.red, lineWidth: isValid ? 1 : 2)
            )
        }
    }
}
