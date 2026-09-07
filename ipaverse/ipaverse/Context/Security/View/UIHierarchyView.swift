//
//  UIHierarchyView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 7.09.2026.
//
//  Reverse Engineer's dedicated view for the ui-hierarchy-dump script — a
//  real collapsible tree instead of a raw recursiveDescription() text blob,
//  built from the script's structured `ui-window` messages
//  (`FridaToolkitVM.UIHierarchyNode`). Confirmed working against a real
//  device (the free-text v1 of this script was only ever verified via its
//  graceful no-UIKit fallback — this is the first real confirmation, which
//  is what prompted rebuilding it properly instead of just prettifying the
//  same text dump).
//
//  Surfaces exactly what a pentester actually wants out of "what's on
//  screen right now": accessibility identifiers/labels (often leak internal
//  naming — hidden debug affordances, real field purposes), and — the
//  sharpest one — a text field's *real* value even when it's a secure
//  field showing dots on screen, since `UITextField.text` holds the
//  plaintext regardless of `isSecureTextEntry` (that's purely a rendering
//  flag). Verified empirically that this technique works exactly as
//  expected — reading a secure field's real value straight through the
//  bridge — against a real (AppKit, not UIKit — see the script's own header
//  for why that's still a faithful proxy for the mechanism) secure text
//  field before shipping.
//
//  The eye icon flashes the tapped node's real view red on the device for
//  ~1.2s (`FridaToolkitVM.highlightView`) — only meaningful shortly after
//  the dump, see that method's doc comment for the honest risk if the
//  screen's changed since. A screenshot-preview mode (a captured image with
//  a box over the element) was tried and shipped alongside this, but the
//  user reported it didn't actually work and asked for it to be removed —
//  live highlight was confirmed working, so that's all this offers now.

import SwiftUI

struct UIHierarchyView: View {
    @ObservedObject var viewModel: FridaToolkitVM
    /// Sends a tapped node's class name to the method tracer and switches
    /// the sidebar there — same shape as ClassBrowserView's `onTrace`.
    let onTraceClass: (String) -> Void

    var body: some View {
        if viewModel.uiHierarchyWindows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(viewModel.uiHierarchyWindows) { window in
                    Section("Window \(window.index)") {
                        UIHierarchyNodeRow(node: window.tree, viewModel: viewModel, onTraceClass: onTraceClass)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(viewModel.isRunning ? "Waiting for the dump…" : "Pick a process and hit Run.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - UIHierarchyNodeRow

private struct UIHierarchyNodeRow: View {
    let node: UIHierarchyNode
    @ObservedObject var viewModel: FridaToolkitVM
    let onTraceClass: (String) -> Void

    @State private var isExpanded = true

    var body: some View {
        if node.children.isEmpty {
            summary.padding(.vertical, 2)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    UIHierarchyNodeRow(node: child, viewModel: viewModel, onTraceClass: onTraceClass)
                }
                .padding(.leading, 14)
            } label: {
                summary
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            if let viewId = node.viewId {
                Button {
                    viewModel.highlightView(viewId)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("Flash this element red on the device for ~1.2s")
            }

            Text(node.className)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(node.isSecure ? .bold : .regular)
                .foregroundColor(node.hidden ? .secondary : .primary)
                .onTapGesture { onTraceClass(node.className) }
                .help("Send to Method Tracer")

            if let frame = node.frame {
                Text("\(Int(frame.width))×\(Int(frame.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if node.hidden {
                Image(systemName: "eye.slash").font(.caption).foregroundColor(.secondary)
            }

            if node.isSecure {
                Label(node.text?.isEmpty == false ? node.text! : "(empty)", systemImage: "key.fill")
                    .font(.caption).fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .textSelection(.enabled)
                    .help("Real value behind the masked secure field")
            } else if let text = node.text, !text.isEmpty {
                Text("\u{201C}\(text)\u{201D}")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            if let accId = node.accessibilityIdentifier {
                Text("#\(accId)")
                    .font(.caption)
                    .foregroundColor(.purple)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            if let accLabel = node.accessibilityLabel, node.accessibilityIdentifier == nil {
                Text(accLabel)
                    .font(.caption)
                    .foregroundColor(.purple)
                    .lineLimit(1)
            }
            if let url = node.url {
                Text(url)
                    .font(.caption)
                    .foregroundColor(.teal)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }
}
