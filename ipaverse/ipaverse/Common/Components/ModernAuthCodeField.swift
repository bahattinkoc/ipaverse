//
//  ModernAuthCodeField.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct ModernAuthCodeField: View {
    @Binding var text: String
    let isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.system(size: 20, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .textContentType(.oneTimeCode)
            .frame(width: 50, height: 50)
            .textFieldStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.blue : Color.secondary.opacity(0.3), lineWidth: isFocused ? 2 : 1)
            )
            .onChange(of: text) { _, newValue in
                if newValue.count > 1 {
                    text = String(newValue.prefix(1))
                }
            }
    }
}
