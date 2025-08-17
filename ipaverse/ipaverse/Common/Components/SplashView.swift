//
//  SplashView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            LinearGradient(
                colors: [.blue, .purple, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 120, height: 120)
            .mask(
                Image("logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            
            ProgressView()
                .scaleEffect(0.8)
                .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    SplashView()
}
