//
//  ModernCheckboxToggleStyle.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct ModernCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isOn.toggle()
                }
            }) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? .blue : .secondary)
                    .font(.title2)
            }
            .buttonStyle(.plain)

            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
        }
        .contentShape(Rectangle())
    }
}
