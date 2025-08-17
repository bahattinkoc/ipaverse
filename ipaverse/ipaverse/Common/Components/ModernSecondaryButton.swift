//
//  ModernSecondaryButton.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct ModernSecondaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))

                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
