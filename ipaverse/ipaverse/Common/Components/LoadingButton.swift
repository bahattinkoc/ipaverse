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
    @Binding var isEnabled: Bool

    init(
        title: String,
        isLoading: Bool = false,
        isEnabled: Binding<Bool>,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.isLoading = isLoading
        self._isEnabled = isEnabled
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
        .disabled(isLoading || !isEnabled)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? Color.blue : Color.gray.opacity(0.6))
        )
        .foregroundColor(.white)
        .scaleEffect(isLoading ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isLoading)
    }
}
