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
    /// When set, renders a dashed drop-zone box below the message advertising
    /// that this screen also accepts a file drag-and-drop — otherwise that
    /// affordance is invisible until a drag is already in progress.
    var dropHint: String? = nil

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

            if let dropHint {
                DropHintBox(text: dropHint)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dashed-border "this accepts a file drag-and-drop" hint — a static
/// affordance, since the only other indication (a highlighted border) only
/// appears once a drag is already in progress, by which point the user has
/// already had to guess drop support exists.
struct DropHintBox: View {
    let text: String
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
            Text(text)
        }
        .font(compact ? .caption : .callout)
        .foregroundColor(.secondary)
        .padding(.horizontal, compact ? 12 : 20)
        .padding(.vertical, compact ? 8 : 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        )
    }
}
