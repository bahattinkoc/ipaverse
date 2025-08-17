//
//  WindowFeatures.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 17.08.2025.
//

import SwiftUI

// MARK: - Public API

extension View {
    func fixedWindow(
        width: CGFloat,
        height: CGFloat,
        allowFullScreen: Bool = false,
        isResizable: Bool = false,
        disableZoomButton: Bool = true
    ) -> some View {
        modifier(WindowFeatures(
            size: NSSize(width: width, height: height),
            allowFullScreen: allowFullScreen,
            isResizable: isResizable,
            disableZoomButton: disableZoomButton
        ))
    }
}

// MARK: - Implementation

private struct WindowFeatures: ViewModifier {
    let size: NSSize
    let allowFullScreen: Bool
    let isResizable: Bool
    let disableZoomButton: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .fixedSize()
            .background(WindowTuner { window in
                window.setContentSize(size)
                window.minSize = size
                window.maxSize = size
                window.aspectRatio = size

                if isResizable {
                    window.styleMask.insert(.resizable)
                } else {
                    window.styleMask.remove(.resizable)
                }

                if allowFullScreen {
                    window.collectionBehavior.insert(.fullScreenPrimary)
                } else {
                    window.collectionBehavior.remove(.fullScreenPrimary)
                    window.collectionBehavior.remove(.fullScreenAuxiliary)
                }

                if disableZoomButton,
                   let zoomBtn = window.standardWindowButton(.zoomButton) {
                    zoomBtn.isEnabled = false
                }
            })
    }
}

private struct WindowTuner: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            if let w = v?.window { configure(w) }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            if let w = nsView?.window { configure(w) }
        }
    }
}

