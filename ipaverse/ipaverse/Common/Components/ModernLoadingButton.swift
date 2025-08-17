//
//  ModernLoadingButton.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct ModernLoadingButton: View {
    let title: String
    let isLoading: Bool
    let isEnabled: Binding<Bool>
    let action: () async -> Void

    var body: some View {
        Button(action: {
            Task {
                await action()
            }
        }) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: isEnabled.wrappedValue ? [.blue, .indigo] : [.gray, .gray],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.primary)
            .cornerRadius(16)
            .shadow(color: isEnabled.wrappedValue ? .blue.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
        }
        .disabled(!isEnabled.wrappedValue || isLoading)
        .buttonStyle(.plain)
    }
}
