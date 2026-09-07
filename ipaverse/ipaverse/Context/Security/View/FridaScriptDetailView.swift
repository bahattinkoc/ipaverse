//
//  FridaScriptDetailView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Reverse Engineer's detail pane for whichever Frida script is selected in
//  `ReverseEngineerView`'s single combined sidebar (Static Analysis / Class
//  Browser / this catalog, grouped by `FridaScriptCategory`, all live
//  together there now — see that file's header for why the sidebar moved up
//  a level instead of staying local to this view). Attach to a running
//  process (jailbroken device over USB, or a Gadget-injected app) and watch
//  the picked script run live. Turns Static Analysis's passive findings
//  (pinning, anti-analysis, biometric usage) into one-click bypasses.

import SwiftUI

struct FridaScriptDetailView: View {
    /// Owned by `ReverseEngineerView` (not this view) — a script kept
    /// running (attached process, live log) must survive switching to
    /// another sidebar item and back, not get torn down with the view.
    @ObservedObject var viewModel: FridaToolkitVM
    /// Only meaningful for ui-hierarchy-dump — same shape as
    /// ClassBrowserView's `onTrace`, tapping a node's class name there jumps
    /// straight to the method tracer with that class pre-filled.
    var onTraceClass: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            scriptHeader
            Divider()
            configFields
            Divider()
            runBar
            Divider()
            if viewModel.selectedScriptID == FridaToolkitVM.networkLoggerScriptID {
                NetworkLoggerView(viewModel: viewModel)
            } else if viewModel.selectedScriptID == FridaToolkitVM.uiHierarchyScriptID {
                UIHierarchyView(viewModel: viewModel, onTraceClass: onTraceClass)
            } else if viewModel.selectedScript.category == .dump {
                DataDumpView(viewModel: viewModel)
            } else {
                log
            }
        }
    }

    private var scriptHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedScript.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedScript.title)
                    .font(.headline)
                Text(viewModel.selectedScript.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var configFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            configField("Process", placeholder: "Running app/process name", text: $viewModel.processName)
            if viewModel.selectedScript.requiresClassName {
                configField("Class", placeholder: "e.g. LAContext, YourAuthManager", text: $viewModel.className)
            }
            if viewModel.selectedScriptID == "class-method-tracer" {
                configField("Method", placeholder: "optional — substring match, e.g. \"login\" (blank = all, minus noisy defaults)", text: $viewModel.methodFilter)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func configField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isRunning)
        }
    }

    // MARK: - Run bar

    private var runBar: some View {
        HStack {
            if case .failed(let message) = viewModel.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if viewModel.isRunning {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Attached — live").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if viewModel.isRunning {
                Button("Stop") { viewModel.stop() }
                    .buttonStyle(.bordered)
            } else {
                Button("Run") { viewModel.run() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Log

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(logLineColor(line))
                            .textSelection(.enabled)
                            .id(index)
                    }
                    if viewModel.logLines.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "terminal")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text(viewModel.isRunning ? "Waiting for output…" : "Pick a script and hit Run.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.logLines.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    /// Cheap keyword-based coloring — these scripts have no structured log
    /// levels, just `send()` strings, so this reads the same conventions a
    /// human would (an "error:" prefix, a "· " progress marker, a success
    /// word like "hooked"/"bypass") rather than parsing anything.
    private func logLineColor(_ line: String) -> Color {
        if line.hasPrefix("· ") || line.hasPrefix("—") { return .secondary }
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") { return .red }
        if lower.contains("hooked") || lower.contains("bypass") || lower.contains(" -> ") { return .green }
        return .primary
    }
}
