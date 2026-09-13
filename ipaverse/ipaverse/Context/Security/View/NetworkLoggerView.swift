//
//  NetworkLoggerView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 7.09.2026.
//
//  Reverse Engineer's dedicated view for the network-request-logger script —
//  the generic free-text log (FridaScriptDetailView.log) can't show per-request
//  status, correlate a request with its response, pretty-print a JSON body,
//  or offer an editable pause-before-send like Burp's Proxy tab, so this
//  script gets its own structured view instead, deliberately styled close to
//  Burp's own Proxy tab: a prominent Intercept on/off control, a scope
//  filter so only requests you care about actually pause, and a separate
//  History tab holding everything (intercepted or not) so the live
//  Intercept tab only ever shows what's actually waiting on you right now.
//  See FridaToolkitVM's `NetworkExchange`/`handleNetworkMessage` for how
//  messages become rows here, and Resources/FridaScripts/README.md for
//  what's actually been verified end-to-end — both the request phase
//  (args[] rewrite) and the response phase (wrapping the completion-handler
//  block via `ObjC.Block`, so an edited status/headers/body genuinely
//  reaches the target app's own callback), and the filter (the hold/no-hold
//  decision is made once per request, at request time, and the response
//  phase reuses that same decision rather than re-checking live state) —
//  versus documented, accepted limitations (Drop redirects/fails rather
//  than truly suppressing the call; a request/response left held when Stop
//  is hit may leave one thread in the target app permanently blocked;
//  response holding only works for the completion-handler
//  `dataTaskWithRequest:` overload, since the other one has no block to
//  wrap).

import SwiftUI

struct NetworkLoggerView: View {
    @ObservedObject var viewModel: FridaToolkitVM

    private enum Tab: String, CaseIterable, Identifiable {
        case intercept = "Intercept"
        case history = "History"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .intercept

    /// Only what's actually waiting on the user right now — resolved items
    /// (forwarded/dropped) drop out of this list, they're only in History.
    private var interceptItems: [NetworkExchange] {
        viewModel.networkExchanges.filter { $0.state == .pendingRequest || $0.state == .pendingResponse }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            tabBar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .intercept:
            if interceptItems.isEmpty {
                interceptEmptyState
            } else {
                List {
                    ForEach(interceptItems) { exchange in
                        NetworkExchangeRow(exchange: exchange, viewModel: viewModel)
                    }
                }
                .listStyle(.inset)
            }
        case .history:
            if viewModel.networkExchanges.isEmpty {
                historyEmptyState
            } else {
                List {
                    ForEach(viewModel.networkExchanges.reversed()) { exchange in
                        NetworkExchangeRow(exchange: exchange, viewModel: viewModel)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Control bar (Intercept toggle + filter)

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.interceptEnabled.toggle()
            } label: {
                Label(
                    viewModel.interceptEnabled ? "Intercept is ON" : "Intercept is OFF",
                    systemImage: viewModel.interceptEnabled ? "pause.circle.fill" : "play.circle.fill"
                )
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.interceptEnabled ? .orange : Color(NSColor.controlColor))
            .foregroundColor(viewModel.interceptEnabled ? .white : .primary)
            .disabled(!viewModel.isRunning)
            .help("When on, requests matching the filter (or every request, if it's blank) pause in the target app until you Forward or Drop them here — like Burp's Proxy intercept.")

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.secondary)
                TextField("Filter — URL contains… (blank = everything)", text: $viewModel.interceptFilter)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !viewModel.interceptFilter.isEmpty {
                    Button { viewModel.interceptFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Tab bar (Intercept vs History)

    @ViewBuilder private var tabBar: some View {
        HStack {
            Picker("", selection: $tab) {
                Text("Intercept (\(interceptItems.count))").tag(Tab.intercept)
                Text("History (\(viewModel.networkExchanges.count))").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button("Clear Completed") { viewModel.clearCompletedNetworkHistory() }
                .help("Held and in-flight exchanges stay in the history.")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        Text("Up to 500 exchanges; body capture limited to 32 KB. \(viewModel.discardedNetworkExchanges) older or excess exchanges omitted. Oversized captures continue unchanged.")
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
    }

    // MARK: - Empty states

    private var interceptEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.interceptEnabled ? "pause.circle" : "play.circle")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(viewModel.interceptEnabled
                 ? "Waiting for a matching request…"
                 : "Intercept is off — turn it on to hold requests here.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(viewModel.isRunning ? "Waiting for the app to make a request…" : "Pick a process and hit Run.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - NetworkExchangeRow

private struct NetworkExchangeRow: View {
    let exchange: NetworkExchange
    @ObservedObject var viewModel: FridaToolkitVM

    @State private var isExpanded = false
    @State private var editedMethod: String
    @State private var editedURL: String
    @State private var editedHeaders: String
    @State private var editedBody: String
    @State private var editedStatus: String
    @State private var editedResponseHeaders: String
    @State private var editedResponseBody: String

    init(exchange: NetworkExchange, viewModel: FridaToolkitVM) {
        self.exchange = exchange
        self.viewModel = viewModel
        _editedMethod = State(initialValue: exchange.method)
        _editedURL = State(initialValue: exchange.url)
        _editedHeaders = State(initialValue: exchange.headersText)
        _editedBody = State(initialValue: exchange.body.map(Self.prettyPrinted) ?? "")
        _editedStatus = State(initialValue: exchange.status.map(String.init) ?? "")
        _editedResponseHeaders = State(initialValue: exchange.responseHeadersText)
        _editedResponseBody = State(initialValue: exchange.responseBody.map(Self.prettyPrinted) ?? "")
    }

    private var isPendingRequest: Bool { exchange.state == .pendingRequest }
    private var isPendingResponse: Bool { exchange.state == .pendingResponse }
    private var isPending: Bool { isPendingRequest || isPendingResponse }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isExpanded || isPending },
            set: { isExpanded = $0 }
        )) {
            if isPendingRequest {
                requestEditForm
            } else if isPendingResponse {
                responseEditForm
            } else {
                readOnlyDetail
            }
        } label: {
            summaryLine
        }
        // `init`'s `State(initialValue:)` only ever runs the first time this
        // row's identity (exchange.id) is created — back when the request
        // first appeared, before any response data existed. Re-sync the
        // edit fields from the now-current `exchange` right as each phase
        // actually starts holding, or they show what was there at creation
        // time (empty, for the response side) instead of the real data.
        .onChange(of: exchange.state) { _, newState in
            switch newState {
            case .pendingRequest:
                editedMethod = exchange.method
                editedURL = exchange.url
                editedHeaders = exchange.headersText
                editedBody = exchange.body.map(Self.prettyPrinted) ?? ""
            case .pendingResponse:
                editedStatus = exchange.status.map(String.init) ?? ""
                editedResponseHeaders = exchange.responseHeadersText
                editedResponseBody = exchange.responseBody.map(Self.prettyPrinted) ?? ""
            default:
                break
            }
        }
    }

    private var summaryLine: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            Text(exchange.method)
                .font(.system(.callout, design: .monospaced)).fontWeight(.semibold)
                .frame(width: 52, alignment: .leading)
            Text(exchange.url)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            statusBadge
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch exchange.state {
        case .pendingRequest:
            Text("HOLDING REQUEST").font(.caption).fontWeight(.bold).foregroundColor(.orange)
        case .pendingResponse:
            Text("HOLDING RESPONSE").font(.caption).fontWeight(.bold).foregroundColor(.orange)
        case .dropped:
            Text("DROPPED").font(.caption).fontWeight(.bold).foregroundColor(.secondary)
        case .sent:
            Text("…").font(.callout).foregroundColor(.secondary)
        case .completed:
            if let status = exchange.status {
                Text("\(status)").font(.system(.callout, design: .monospaced)).fontWeight(.bold).foregroundColor(statusColor)
            } else if exchange.error != nil {
                Text("ERROR").font(.caption).fontWeight(.bold).foregroundColor(.red)
            }
        }
    }

    private var statusColor: Color {
        if exchange.error != nil { return .red }
        switch exchange.state {
        case .pendingRequest, .pendingResponse: return .orange
        case .dropped: return .secondary
        case .sent: return .secondary
        case .completed:
            guard let status = exchange.status else { return .secondary }
            switch status {
            case 200..<300: return .green
            case 300..<400: return .blue
            case 400..<500: return .orange
            default: return .red
            }
        }
    }

    // MARK: - Read-only detail (sent/completed/dropped)

    private var readOnlyDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Request")
            if !exchange.headers.isEmpty {
                detailBlock(title: "Headers", text: exchange.headersText)
            }
            if let body = exchange.body {
                detailBlock(title: "Body", text: Self.prettyPrinted(body))
            }
            if exchange.state == .completed {
                sectionLabel("Response")
                if !exchange.responseHeaders.isEmpty {
                    detailBlock(title: "Headers", text: exchange.responseHeadersText)
                }
                if let body = exchange.responseBody {
                    detailBlock(title: "Body", text: Self.prettyPrinted(body))
                }
            }
            if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.red)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 17)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption).fontWeight(.bold)
            .foregroundColor(.secondary)
    }

    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(NSColor.separatorColor)))
        }
    }

    /// Best-effort JSON pretty-print — anything that doesn't parse as JSON
    /// (form-encoded bodies, plain text) is left as-is. Applied both to the
    /// read-only detail view AND to the edit forms' body fields — a minified
    /// single-line JSON body is exactly the case `autoSizingEditor` below
    /// can't size correctly (no `\n` to count), and re-formatting it into
    /// real lines is the fix, not just a display nicety. Whitespace outside
    /// string literals is insignificant JSON, so forwarding the
    /// pretty-printed (possibly user-edited) text back as the body parses
    /// identically on the receiving end.
    private static func prettyPrinted(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else { return raw }
        return s
    }

    /// A `TextEditor` that grows with its content (clamped to a sane range)
    /// instead of a fixed box the text has to scroll inside. Sums, per
    /// logical (`\n`-separated) line, how many visual rows it likely wraps
    /// into at this font/width — a plain `\n`-count under-sizes anything
    /// that's still a long single line (a token, a non-JSON body before any
    /// pretty-printing applies) since it wraps within the box without ever
    /// producing a real newline to count.
    private func autoSizingEditor(_ text: Binding<String>) -> some View {
        let charsPerVisualLine = 46
        let content = text.wrappedValue
        let wrappedRows = content.components(separatedBy: "\n").reduce(0) { total, line in
            total + max(1, (line.count + charsPerVisualLine - 1) / charsPerVisualLine)
        }
        let lines = max(3, min(30, wrappedRows))
        return TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .frame(height: CGFloat(lines) * 19 + 12)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(NSColor.separatorColor)))
    }

    private func editorField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            autoSizingEditor(text)
        }
    }

    // MARK: - Edit forms (pending only)

    private var requestEditForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Method", text: $editedMethod)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(width: 90)
                TextField("URL", text: $editedURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
            editorField("Headers", text: $editedHeaders)
            if !editedBody.isEmpty || exchange.body != nil {
                editorField("Body", text: $editedBody)
            }
            HStack {
                Spacer()
                Button("Drop") {
                    viewModel.resolvePendingRequest(exchange, drop: true)
                }
                .buttonStyle(.bordered)
                Button("Forward") {
                    var edited = exchange
                    edited.method = editedMethod
                    edited.url = editedURL
                    edited.headersText = editedHeaders
                    edited.body = editedBody.isEmpty ? nil : editedBody
                    viewModel.resolvePendingRequest(edited, drop: false)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 17)
    }

    private var responseEditForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Status").font(.callout).foregroundColor(.secondary)
                TextField("Status", text: $editedStatus)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .frame(width: 80)
            }
            editorField("Headers", text: $editedResponseHeaders)
            editorField("Body", text: $editedResponseBody)
            HStack {
                Spacer()
                Button("Drop") {
                    viewModel.resolvePendingResponse(exchange, drop: true)
                }
                .buttonStyle(.bordered)
                .help("Delivers a failed/cancelled response to the app — see the script's README for why this can't be a silent no-op.")
                Button("Forward") {
                    var edited = exchange
                    edited.status = Int(editedStatus)
                    edited.responseHeadersText = editedResponseHeaders
                    edited.responseBody = editedResponseBody.isEmpty ? nil : editedResponseBody
                    viewModel.resolvePendingResponse(edited, drop: false)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 6)
        .padding(.leading, 17)
    }
}
