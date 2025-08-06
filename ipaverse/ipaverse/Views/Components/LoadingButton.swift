//
//  LoadingButton.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.08.2025.
//

import SwiftUI

struct LoadingButton: View {
    let title: String
    let isLoading: Bool
    let action: () async -> Void
    let isEnabled: Bool

    init(
        title: String,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                }

                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(LoadingButtonStyle())
        .disabled(isLoading || !isEnabled)
    }
}

struct LoadingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.blue.opacity(0.8) : Color.blue)
            )
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    VStack(spacing: 20) {
        LoadingButton(title: "Log in", isLoading: false) {
            // Action
        }

        LoadingButton(title: "Logging in...", isLoading: true) {
            // Action
        }

        LoadingButton(title: "Out of Service", isLoading: false, isEnabled: false) {
            // Action
        }
    }
    .padding()
}
