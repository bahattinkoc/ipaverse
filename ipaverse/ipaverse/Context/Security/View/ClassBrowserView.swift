//
//  ClassBrowserView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Reverse Engineer > Class Browser. See ClassDumper.swift's header for why
//  this only shows class names + method counts and a flat selector
//  inventory, not a full per-class method list — resolving selector names
//  through relative-method-list pointers on a chained-fixups binary turned
//  out to be unsafe to do by hand (verified against a real binary before
//  landing this; see that file for the details).

import SwiftUI

struct ClassBrowserView: View {
    /// Owned by `ReverseEngineerView` — see `SecurityScanView`/
    /// `FridaScriptDetailView` for why (survive sidebar switches).
    @ObservedObject var viewModel: ClassBrowserVM
    /// Sends a class's raw runtime name — and, when tracing a single real
    /// method resolved by r2, that method's selector as a filter — to the
    /// method tracer script and switches the sidebar to it.
    let onTrace: (String, String?) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case classes = "Classes"
        case selectors = "All Selectors"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .classes
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .onAppear { viewModel.loadIfNeeded() }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if viewModel.targets.count > 1 {
                HStack {
                    Text("Binary").frame(width: 60, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { viewModel.selectedTargetID ?? "" },
                        set: { viewModel.selectTarget($0) }
                    )) {
                        ForEach(viewModel.targets) { target in
                            Text(target.name).tag(target.id)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    if case .done = viewModel.state {
                        Button {
                            viewModel.dump()
                        } label: {
                            Label("Re-dump", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            modeBar
        }
    }

    /// Keep the mode tabs aligned with Network Logger's tab bar: explicitly
    /// inset from the leading edge instead of relying on the parent stack's padding.
    private var modeBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
                TextField("Filter…", text: $searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loadingTargets:
            statusView(message: "Extracting…")
        case .dumping:
            statusView(message: viewModel.dumpStep ?? "Dumping…")
        case .failed(let message):
            failedView(message)
        case .done(let result):
            switch mode {
            case .classes: classList(result)
            case .selectors: selectorList(result)
            }
        }
    }

    private func statusView(message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).font(.callout).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") { viewModel.dump() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func classList(_ result: ClassDumpResult) -> some View {
        let filtered = searchText.isEmpty
            ? result.classes
            : result.classes.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.rawName.localizedCaseInsensitiveContains(searchText)
            }

        return Group {
            if result.classes.isEmpty {
                EmptyStateView(icon: "square.stack.3d.up.slash", title: "No Objective-C Classes",
                                message: "This binary has no Objective-C runtime metadata to read — likely a pure-Swift binary with nothing exposed to @objc.")
            } else if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No Matches")
            } else {
                List(filtered) { cls in
                    ClassRow(cls: cls, realMethods: viewModel.methodsByClass[cls.displayName], onTrace: onTrace)
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(filtered.count) of \(result.classes.count) classes")
                Spacer()
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private func selectorList(_ result: ClassDumpResult) -> some View {
        let filtered = searchText.isEmpty
            ? result.allSelectors
            : result.allSelectors.filter { $0.localizedCaseInsensitiveContains(searchText) }

        return Group {
            if filtered.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No Matches",
                                message: searchText.isEmpty ? "This binary has no readable selector strings." : nil)
            } else {
                List(filtered, id: \.self) { selector in
                    Text(selector)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(filtered.count) of \(result.allSelectors.count) selectors — not attributed to a specific class")
                Spacer()
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - ClassRow

/// A plain row when no real methods were resolved for this class (r2 not
/// installed, or this particular class's selectors didn't resolve) —
/// becomes a `DisclosureGroup` showing each real method name, with its own
/// per-method trace shortcut, when `realMethods` is non-nil.
private struct ClassRow: View {
    let cls: ObjCClassInfo
    let realMethods: [ResolvedMethod]?
    let onTrace: (String, String?) -> Void

    @State private var isExpanded = false

    var body: some View {
        if let realMethods, !realMethods.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(realMethods) { method in
                        methodRow(method)
                    }
                }
                .padding(.leading, 12)
                .padding(.top, 2)
            } label: {
                header
            }
        } else {
            header
                .padding(.vertical, 2)
        }
    }

    private func methodRow(_ method: ResolvedMethod) -> some View {
        HStack(spacing: 8) {
            Text(method.name)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                onTrace(cls.rawName, method.name)
            } label: {
                Image(systemName: "bolt.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Trace just this method")
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cls.displayName)
                    .font(.system(.callout, design: .monospaced))
                if cls.displayName != cls.rawName {
                    Text(cls.rawName)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let realMethods {
                Text("\(realMethods.count) resolved")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.accentColor)
            }
            Text("-\(cls.instanceMethodCount) +\(cls.classMethodCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .help("\(cls.instanceMethodCount) instance / \(cls.classMethodCount) class methods")
            Button {
                onTrace(cls.rawName, nil)
            } label: {
                Label("Trace", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Send to Frida Toolkit's method tracer")
        }
    }
}
