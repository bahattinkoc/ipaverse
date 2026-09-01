//
//  Font+App.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 1.09.2026.
//

import SwiftUI

/// Small semantic type scale for the recurring literal `.system(size:weight:)`
/// values in the Login flow, so the same role (a screen title, a screen
/// subtitle, a section label) always renders identically instead of drifting
/// by a point or two between screens.
extension Font {
    /// 28pt bold rounded — top-level screen title ("Sign In", "Welcome Back").
    static let appScreenTitle = Font.system(size: 28, weight: .bold, design: .rounded)

    /// 16pt medium — descriptive line under a screen title.
    static let appScreenSubtitle = Font.system(size: 16, weight: .medium)

    /// 16pt semibold — a standalone section label (e.g. "Verification Code").
    static let appSectionTitle = Font.system(size: 16, weight: .semibold)

    /// 15pt semibold — emphasized label text (card titles, prominent button labels).
    static let appEmphasis = Font.system(size: 15, weight: .semibold)

    /// 15pt medium — secondary descriptive text at body scale.
    static let appBody = Font.system(size: 15, weight: .medium)

    /// 14pt medium — button/control label text.
    static let appControlLabel = Font.system(size: 14, weight: .medium)
}
