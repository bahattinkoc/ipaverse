//
//  OTPVerificationView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct OTPVerificationView: View {
    @Binding var otpText: String
    @FocusState private var isKeyboardShowing: Bool

    var body: some View {
        let chars = Array(otpText)
        HStack(spacing: 12) {
            ForEach(0..<6, id: \.self) { index in
                OTPTextBox(index, chars: chars)
            }
        }
        .background {
            TextField("", text: $otpText)
                .textContentType(.oneTimeCode)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .blendMode(.screen)
                .focused($isKeyboardShowing)
                .onChange(of: otpText) { _, newValue in
                    if newValue.count > 6 {
                        otpText = String(newValue.prefix(6))
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isKeyboardShowing.toggle()
        }
    }

    @ViewBuilder
    func OTPTextBox(_ index: Int, chars: [Character]) -> some View {
        ZStack {
            if chars.count > index {
                Text(String(chars[index]))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            } else {
                Text(" ")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
            }
        }
        .frame(width: 50, height: 50)
        .background {
            let status = (isKeyboardShowing && otpText.count == index)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(status ? Color.blue : Color.secondary.opacity(0.3), lineWidth: status ? 2 : 1)
                )
                .animation(.easeInOut(duration: 0.2), value: isKeyboardShowing)
        }
        .frame(maxWidth: .infinity)
    }
}
