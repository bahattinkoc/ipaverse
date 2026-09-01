//
//  EmptyStateView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 1.09.2026.
//

import SwiftUI

/// Semantic tone for an empty/error state, driving its default icon color so
/// call sites don't each pick their own ad hoc color.
enum EmptyStateTone {
    case neutral
    case accent
    case warning

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .warning: return .orange
        }
    }
}

/// Full-bleed placeholder for empty lists and error screens (icon + title +
/// optional message/action), replacing the icon/title/message block that was
/// duplicated across Search, Downloaded, and AppDetail.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var tone: EmptyStateTone = .neutral
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(tone.color)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            if let message {
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
