//
//  FridaToolkitVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One view node from the ui-hierarchy-dump script's structured tree —
/// class name, on-screen frame, and whatever type-specific detail the
/// script could pull off it (label/button text, a text field's real value
/// — including a *secure* field's, which is masked only visually — an
/// accessibility identifier/label, or a WKWebView's URL). Built recursively
/// from the script's `subviews()` walk; see that script's header comment
/// for what's actually been verified (the walking/struct-decoding
/// mechanics, empirically, against a real running process; the exact
/// UIKit-only class/selector names, from documented Apple API, not
/// locally testable since this Mac has no UIKit).
struct UIHierarchyNode: Identifiable {
    let id = UUID()
    /// The script's own id for the live view this node describes — kept
    /// alive server-side (`viewRegistry`) for the life of the run so
    /// `FridaToolkitVM.highlightView(_:)` can flash it on the real device
    /// later. Real risk if the screen has changed since the dump (the view
    /// may be deallocated) — see the script's own header comment.
    let viewId: String?
    let className: String
    let frame: CGRect?
    let hidden: Bool
    let accessibilityIdentifier: String?
    let accessibilityLabel: String?
    let text: String?
    let placeholder: String?
    let isSecure: Bool
    let url: String?
    let children: [UIHierarchyNode]

    init?(json: [String: Any]) {
        guard let cls = json["cls"] as? String else { return nil }
        className = cls
        viewId = json["id"] as? String
        if let f = json["frame"] as? [String: Any],
           let x = f["x"] as? Double, let y = f["y"] as? Double,
           let w = f["w"] as? Double, let h = f["h"] as? Double {
            frame = CGRect(x: x, y: y, width: w, height: h)
        } else {
            frame = nil
        }
        hidden = json["hidden"] as? Bool ?? false
        accessibilityIdentifier = json["accessibilityIdentifier"] as? String
        accessibilityLabel = json["accessibilityLabel"] as? String
        text = json["text"] as? String
        placeholder = json["placeholder"] as? String
        isSecure = json["secure"] as? Bool ?? false
        url = json["url"] as? String
        children = (json["children"] as? [[String: Any]])?.compactMap(UIHierarchyNode.init(json:)) ?? []
    }
}

/// One window ui-hierarchy-dump reported.
struct UIHierarchyWindow: Identifiable {
    let id = UUID()
    let index: Int
    let tree: UIHierarchyNode
}

/// One row from a Data Dump script (userdefaults-dump/keychain-dump/
/// sandbox-files) — a small ordered set of named fields (a single `key`/
/// `value` pair for userdefaults, `account`/`service`/`server`/`label` for
/// a Keychain item, `path`/`size` for a sandbox file), plus an optional
/// `category` the view groups by (e.g. "Generic Password (genp)" vs.
/// "Internet Password (inet)" — `nil` for userdefaults/sandbox-files,
/// which have nothing to group on).
struct DumpField: Identifiable {
    let id = UUID()
    let key: String
    var value: String
}

/// Plain `String` doesn't conform to `Error`, and `downloadSandboxFile`'s
/// failures are always just a human-readable reason — this is that reason,
/// wrapped enough to satisfy `Result<Data, some Error>`.
struct DumpFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DumpEntry: Identifiable {
    let id = UUID()
    let category: String?
    var fields: [DumpField]
    /// userdefaults-dump only — true when the script confirmed the value is
    /// a plain `NSString` or `NSNumber` (bool/int/double all report as
    /// "number" — NSUserDefaults's own convenience getters tolerate any
    /// NSNumber variant regardless of which one wrote it), so editing it
    /// back can't silently corrupt an `NSArray`/`NSDictionary`/`NSData`
    /// value into a plain string. `nil`/`false` for keychain-dump/
    /// sandbox-files, which never report this at all.
    let editable: Bool
    let valueType: String?

    init?(json: [String: Any]) {
        guard let fieldsJSON = json["fields"] as? [[String: Any]], !fieldsJSON.isEmpty else { return nil }
        category = json["category"] as? String
        fields = fieldsJSON.compactMap { f in
            guard let k = f["k"] as? String, let v = f["v"] as? String else { return nil }
            return DumpField(key: k, value: v)
        }
        editable = json["editable"] as? Bool ?? false
        valueType = json["valueType"] as? String
    }
}

/// One HTTP request/response the network-request-logger script has reported.
/// Headers are kept as raw "Key: Value" lines rather than a dictionary so a
/// pending exchange's edit UI can bind a `TextEditor` straight to
/// `headersText`/`responseHeadersText` — parsed back into a dictionary only
/// when forwarding. The request and response phases pause independently
/// (Intercept holds both, one after the other, if it's on for the whole
/// round trip) — `state` tracks which phase, if any, is currently held.
struct NetworkExchange: Identifiable {
    enum State: Equatable { case pendingRequest, sent, pendingResponse, completed, dropped }

    let id: String
    var method: String
    var url: String
    var headersText: String
    var body: String?
    var state: State
    var taskIdentifier: String?
    var status: Int?
    var responseHeadersText: String = ""
    var responseBody: String?
    var error: String?
    let receivedAt = Date()

    init(id: String, method: String, url: String, headers: [String: String], body: String?, state: State) {
        self.id = id
        self.method = method
        self.url = url
        self.headersText = Self.text(from: headers)
        self.body = body
        self.state = state
    }

    var headers: [String: String] { Self.dict(from: headersText) }
    var responseHeaders: [String: String] { Self.dict(from: responseHeadersText) }

    static func text(from headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    static func dict(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

@MainActor
final class FridaToolkitVM: ObservableObject {
    enum State: Equatable {
        case idle
        case attaching
        case running
        case failed(String)
    }

    static let networkLoggerScriptID = "network-request-logger"
    static let uiHierarchyScriptID = "ui-hierarchy-dump"

    @Published var state: State = .idle
    @Published private(set) var logLines: [String] = []
    @Published var selectedScriptID: String = FridaScriptLibrary.scripts.first!.id
    @Published var className: String = ""
    /// Optional, only meaningful for the class-method-tracer script: a
    /// substring match against method names. Empty means "trace everything
    /// except the built-in noisy-method default skip list" (see that
    /// script's own `defaultSkip`).
    @Published var methodFilter: String = ""
    @Published var processName: String

    /// network-request-logger only. Off by default (passive pass-through
    /// logging, zero added latency); flipping it on makes every subsequent
    /// request that matches `interceptFilter` (or every request, if that's
    /// empty) pause in the target app until forwarded/dropped from here —
    /// see that script's README entry for what's actually been verified.
    @Published var interceptEnabled = false {
        didSet {
            guard oldValue != interceptEnabled else { return }
            postInterceptState()
        }
    }
    /// Case-insensitive substring match against the request URL — a
    /// non-matching request (and its response) is logged normally but never
    /// paused, same idea as Burp's intercept scope rules, just simplified
    /// to one substring instead of a rule list. Empty means "match
    /// everything" (the old, pre-filter behavior).
    @Published var interceptFilter: String = "" {
        didSet {
            guard oldValue != interceptFilter else { return }
            postInterceptState()
        }
    }
    @Published private(set) var networkExchanges: [NetworkExchange] = []
    /// ui-hierarchy-dump only — one entry per window the script reported.
    @Published private(set) var uiHierarchyWindows: [UIHierarchyWindow] = []
    /// The Data Dump scripts (userdefaults-dump/keychain-dump/sandbox-files)
    /// — a flat, arrival-ordered list; `DataDumpView` groups by `category`.
    @Published private(set) var dumpEntries: [DumpEntry] = []

    private var handle: FridaScriptHandle?
    private var attachTask: Task<Void, Never>?
    /// Invalidates callbacks/results from an attach that was stopped while its
    /// synchronous Frida setup was still executing on a background thread.
    private var sessionGeneration = 0
    /// sandbox-files only — keyed by the request's own UUID so a `file-
    /// content` reply (handled in `handleDumpMessage`) reaches the right
    /// caller. Requires the script to still be attached — reading a file
    /// is a live, on-demand request to the running script, not something
    /// captured up front during the dump.
    private var pendingFileRequests: [String: (Result<Data, DumpFileError>) -> Void] = [:]
    /// userdefaults-dump only — same request/reply pattern as
    /// `pendingFileRequests`, for `updateUserDefault`.
    private var pendingValueUpdateRequests: [String: (Result<Void, DumpFileError>) -> Void] = [:]

    init(appName: String) {
        self.processName = appName
    }

    /// True while attaching too, so the UI exposes Stop and prevents a second attach.
    var isRunning: Bool { state == .attaching || state == .running }
    var isAttached: Bool { state == .running }

    private var evilModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "evilModeEnabled")
    }

    var selectedScript: FridaScript {
        FridaScriptLibrary.scripts.first { $0.id == selectedScriptID } ?? FridaScriptLibrary.scripts[0]
    }

    func run() {
        guard !isRunning else { return }
        guard evilModeEnabled else {
            state = .failed("Enable Evil Mode before starting a live Frida session.")
            return
        }
        let script = selectedScript
        let trimmedClass = className.trimmingCharacters(in: .whitespaces)
        if script.requiresClassName && trimmedClass.isEmpty {
            state = .failed("Enter a class name first.")
            return
        }
        let trimmedProcess = processName.trimmingCharacters(in: .whitespaces)
        guard !trimmedProcess.isEmpty else {
            state = .failed("Enter the running process/app name to attach to.")
            return
        }

        logLines.removeAll()
        networkExchanges.removeAll()
        uiHierarchyWindows.removeAll()
        dumpEntries.removeAll()
        sessionGeneration += 1
        let generation = sessionGeneration
        state = .attaching
        let isNetworkLogger = script.id == Self.networkLoggerScriptID
        let isUIHierarchy = script.id == Self.uiHierarchyScriptID
        let isDataDump = script.category == .dump
        let source = FridaScriptLibrary.resolvedSource(
            for: script, className: trimmedClass,
            methodFilter: methodFilter.trimmingCharacters(in: .whitespaces)
        )

        attachTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let handle = try FridaScriptRunner.attachAndRun(
                    processName: trimmedProcess,
                    scriptSource: source,
                    onMessage: { raw in
                        Task { @MainActor in
                            guard self?.sessionGeneration == generation,
                                  self?.evilModeEnabled == true else { return }
                            if isNetworkLogger {
                                self?.handleNetworkMessage(raw)
                            } else if isUIHierarchy {
                                self?.handleUIHierarchyMessage(raw)
                            } else if isDataDump {
                                self?.handleDumpMessage(raw)
                            } else {
                                self?.append(Self.displayText(fromFridaMessage: raw))
                            }
                        }
                    },
                    progress: { line in
                        Task { @MainActor in
                            guard self?.sessionGeneration == generation else { return }
                            self?.append("· " + line)
                        }
                    }
                )
                let accepted = await MainActor.run { [weak self] in
                    guard let self,
                          self.sessionGeneration == generation,
                          self.evilModeEnabled,
                          self.state == .attaching else { return false }
                    self.handle = handle
                    self.state = .running
                    self.attachTask = nil
                    if isNetworkLogger { self.postInterceptState() }
                    return true
                }
                if !accepted { handle.stop() }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.attachTask = nil
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// `clearingData` is for `ReverseEngineerView.prepareToSwitchScript` —
    /// navigating to a *different* script auto-stops whatever was running
    /// and wipes its log/network/UI-hierarchy history too, so coming back
    /// to it later starts clean instead of showing a stale capture from a
    /// session that's already over. The manual Stop button in the UI
    /// doesn't pass this — someone who just hit Stop almost always wants to
    /// review what they captured, not have it vanish immediately.
    func stop(clearingData: Bool = false) {
        let wasActive = isRunning
        sessionGeneration += 1
        attachTask?.cancel()
        attachTask = nil
        forwardPendingNetworkExchanges()
        handle?.stop()
        handle = nil
        if wasActive {
            append("— stopped —")
        }
        state = .idle
        // Any in-flight downloadSandboxFile(_:) calls will never get their
        // reply now — fail them explicitly rather than leaving the caller
        // waiting forever.
        for completion in pendingFileRequests.values {
            completion(.failure(DumpFileError(message: "Script stopped before the file finished transferring.")))
        }
        pendingFileRequests.removeAll()
        for completion in pendingValueUpdateRequests.values {
            completion(.failure(DumpFileError(message: "Script stopped before the value finished updating.")))
        }
        pendingValueUpdateRequests.removeAll()
        if clearingData {
            logLines.removeAll()
            networkExchanges.removeAll()
            uiHierarchyWindows.removeAll()
            dumpEntries.removeAll()
        }
    }

    private func append(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    // MARK: - Network logger

    private func postInterceptState() {
        guard evilModeEnabled else { return }
        post(["type": "set-intercept", "enabled": interceptEnabled, "filter": interceptFilter])
    }

    /// Forward (with whatever edits are in `exchange` right now) or drop a
    /// held request — posts `resume-req-<id>`. Updates local state
    /// optimistically; the script doesn't ack this beyond the
    /// `request-sent`/`dropped` message `handleNetworkMessage` also applies.
    func resolvePendingRequest(_ exchange: NetworkExchange, drop: Bool) {
        guard evilModeEnabled else { return }
        guard networkExchanges.contains(where: { $0.id == exchange.id }) else { return }
        var payload: [String: Any] = ["type": "resume-req-\(exchange.id)", "action": drop ? "drop" : "forward"]
        if !drop {
            payload["method"] = exchange.method
            payload["url"] = exchange.url
            payload["headers"] = exchange.headers
            if let body = exchange.body { payload["body"] = body }
        }
        post(payload)
        if let idx = networkExchanges.firstIndex(where: { $0.id == exchange.id }) {
            networkExchanges[idx].state = drop ? .dropped : .sent
        }
    }

    /// Forward (with whatever edits are in `exchange` right now) or drop a
    /// held response — posts `resume-resp-<id>`. Only reachable for a
    /// request made via the completion-handler `dataTaskWithRequest:`
    /// overload — see the script's README entry for why the other overload
    /// can't offer this.
    func resolvePendingResponse(_ exchange: NetworkExchange, drop: Bool) {
        guard evilModeEnabled else { return }
        guard let idx = networkExchanges.firstIndex(where: { $0.id == exchange.id }) else { return }
        var payload: [String: Any] = ["type": "resume-resp-\(exchange.id)", "action": drop ? "drop" : "forward"]
        if !drop {
            if let status = exchange.status { payload["status"] = String(status) }
            payload["headers"] = exchange.responseHeaders
            if let body = exchange.responseBody { payload["body"] = body }
        }
        post(payload)
        networkExchanges[idx].state = drop ? .dropped : .completed
    }

    private func post(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        handle?.post(json)
    }

    /// A stopped intercept must not leave target-app threads blocked in Frida's
    /// `recv().wait()`. Resume held exchanges with their current values before unload.
    private func forwardPendingNetworkExchanges() {
        for index in networkExchanges.indices {
            let exchange = networkExchanges[index]
            switch exchange.state {
            case .pendingRequest:
                var payload: [String: Any] = [
                    "type": "resume-req-\(exchange.id)", "action": "forward",
                    "method": exchange.method, "url": exchange.url, "headers": exchange.headers
                ]
                if let body = exchange.body { payload["body"] = body }
                post(payload)
                networkExchanges[index].state = .sent
            case .pendingResponse:
                var payload: [String: Any] = [
                    "type": "resume-resp-\(exchange.id)", "action": "forward",
                    "headers": exchange.responseHeaders
                ]
                if let status = exchange.status { payload["status"] = String(status) }
                if let body = exchange.responseBody { payload["body"] = body }
                post(payload)
                networkExchanges[index].state = .completed
            default:
                break
            }
        }
    }

    private func handleNetworkMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            append(Self.displayText(fromFridaMessage: raw))
            return
        }
        switch type {
        case "log":
            if let text = payload["text"] as? String { append("· " + text) }
        case "request-log", "request-pending":
            guard let id = payload["id"] as? String else { return }
            let exchange = NetworkExchange(
                id: id,
                method: payload["method"] as? String ?? "GET",
                url: payload["url"] as? String ?? "",
                headers: (payload["headers"] as? [String: String]) ?? [:],
                body: payload["body"] as? String,
                state: type == "request-pending" ? .pendingRequest : .sent
            )
            networkExchanges.append(exchange)
        case "request-sent":
            guard let id = payload["id"] as? String,
                  let idx = networkExchanges.firstIndex(where: { $0.id == id }) else { return }
            networkExchanges[idx].state = .sent
            networkExchanges[idx].taskIdentifier = payload["taskIdentifier"] as? String
        case "dropped":
            guard let id = payload["id"] as? String,
                  let idx = networkExchanges.firstIndex(where: { $0.id == id }) else { return }
            networkExchanges[idx].state = .dropped
        case "response-log", "response-pending":
            guard let id = payload["id"] as? String,
                  let idx = networkExchanges.firstIndex(where: { $0.id == id }) else { return }
            networkExchanges[idx].state = type == "response-pending" ? .pendingResponse : .completed
            networkExchanges[idx].status = (payload["status"] as? String).flatMap(Int.init)
            networkExchanges[idx].error = payload["error"] as? String
            networkExchanges[idx].responseBody = payload["body"] as? String
            if let headers = payload["headers"] as? [String: String] {
                networkExchanges[idx].responseHeadersText = NetworkExchange.text(from: headers)
            }
        case "response":
            // Fallback for the non-completion-handler overload only — the
            // script skips this for any task it's already reporting via
            // response-log/response-pending above.
            guard let tid = payload["taskIdentifier"] as? String,
                  let idx = networkExchanges.firstIndex(where: { $0.taskIdentifier == tid }) else { return }
            networkExchanges[idx].state = .completed
            networkExchanges[idx].status = (payload["status"] as? String).flatMap(Int.init)
            networkExchanges[idx].error = payload["error"] as? String
        default:
            break
        }
    }

    // MARK: - UI hierarchy dump

    private func handleUIHierarchyMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            append(Self.displayText(fromFridaMessage: raw))
            return
        }
        switch type {
        case "log":
            if let text = payload["text"] as? String { append("· " + text) }
        case "ui-window":
            if let treeJSON = payload["tree"] as? [String: Any], let node = UIHierarchyNode(json: treeJSON) {
                let index = payload["index"] as? Int ?? uiHierarchyWindows.count
                uiHierarchyWindows.append(UIHierarchyWindow(index: index, tree: node))
            }
        default:
            break
        }
    }

    // MARK: - Data Dump (userdefaults-dump / keychain-dump / sandbox-files)

    private func handleDumpMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            append(Self.displayText(fromFridaMessage: raw))
            return
        }
        switch type {
        case "log":
            if let text = payload["text"] as? String { append("· " + text) }
        case "dump-entry":
            if let entry = DumpEntry(json: payload) {
                dumpEntries.append(entry)
            }
        case "file-content":
            guard let requestId = payload["requestId"] as? String,
                  let completion = pendingFileRequests.removeValue(forKey: requestId) else { return }
            if let errorMessage = payload["error"] as? String {
                completion(.failure(DumpFileError(message: errorMessage)))
            } else if let base64 = payload["base64"] as? String, let fileData = Data(base64Encoded: base64) {
                completion(.success(fileData))
            } else {
                completion(.failure(DumpFileError(message: "Malformed response from the script.")))
            }
        case "value-updated":
            guard let requestId = payload["requestId"] as? String,
                  let completion = pendingValueUpdateRequests.removeValue(forKey: requestId) else { return }
            if payload["success"] as? Bool == true {
                if let key = payload["key"] as? String, let newValue = payload["value"] as? String,
                   let idx = dumpEntries.firstIndex(where: { $0.fields.first?.key == key }) {
                    dumpEntries[idx].fields = [DumpField(key: key, value: newValue)]
                }
                completion(.success(()))
            } else {
                completion(.failure(DumpFileError(message: payload["error"] as? String ?? "Update failed")))
            }
        default:
            break
        }
    }

    /// sandbox-files only — asks the still-attached script to read a file
    /// (path relative to the sandbox container, exactly as reported in that
    /// entry's "path" field) and hand back its raw bytes. Requires the
    /// script to still be running; verified end-to-end (a real local file,
    /// including non-ASCII content, round-tripped byte-for-byte through
    /// this exact request/response shape) before shipping — see the
    /// script's own README entry.
    func downloadSandboxFile(path: String, completion: @escaping (Result<Data, DumpFileError>) -> Void) {
        guard evilModeEnabled, isAttached else {
            completion(.failure(DumpFileError(message: "The script isn't running anymore — re-run the dump first.")))
            return
        }
        let requestId = UUID().uuidString
        pendingFileRequests[requestId] = completion
        post(["type": "read-file", "path": path, "requestId": requestId])
    }

    /// userdefaults-dump only — writes `newValue` back to the device's real
    /// NSUserDefaults for `key`, actually changing the running app's state
    /// (this is why the app-modifying features in ipaverse are gated behind
    /// Evil Mode; wire this one the same way at the call site). `valueType`
    /// ("string"/"number", from that entry's `DumpEntry.valueType`) tells
    /// the script which `NSString`/`NSNumber` constructor to use — verified
    /// end-to-end before shipping that both directions round-trip correctly
    /// *and* keep their original Objective-C class (a number stays
    /// `__NSCFNumber`, not degraded to a string) — see the script's own
    /// README entry. Only reachable while the script is still attached.
    func updateUserDefault(key: String, valueType: String, newValue: String, completion: @escaping (Result<Void, DumpFileError>) -> Void) {
        guard evilModeEnabled, isAttached else {
            completion(.failure(DumpFileError(message: "The script isn't running anymore — re-run the dump first.")))
            return
        }
        let requestId = UUID().uuidString
        pendingValueUpdateRequests[requestId] = completion
        post(["type": "write-userdefault", "key": key, "value": newValue, "valueType": valueType, "requestId": requestId])
    }

    /// Plain-text export ("Key: Value" per line, grouped under a `##
    /// Category` heading whenever entries carry one) — readable on its own,
    /// pastable into a report.
    func exportDumpText() {
        guard !dumpEntries.isEmpty else { return }
        var lines: [String] = ["# \(selectedScript.title) — \(processName)", ""]
        var lastCategory = ""
        var sawCategory = false
        for entry in dumpEntries {
            let category = entry.category ?? ""
            if !sawCategory || category != lastCategory {
                if let realCategory = entry.category { lines.append("\n## \(realCategory)\n") }
                lastCategory = category
                sawCategory = true
            }
            lines.append(entry.fields.map { "\($0.key): \($0.value)" }.joined(separator: "  "))
        }
        save(data: Data(lines.joined(separator: "\n").utf8),
             suggestedName: "\(safeName)-\(selectedScriptID).txt",
             contentType: .plainText)
    }

    /// Structured export — an array of `{category?, fields: {key: value}}`
    /// objects, full content included (not just what's visible on screen).
    func exportDumpJSON() {
        guard !dumpEntries.isEmpty else { return }
        let payload: [[String: Any]] = dumpEntries.map { entry in
            var fieldsDict: [String: String] = [:]
            for field in entry.fields { fieldsDict[field.key] = field.value }
            var dict: [String: Any] = ["fields": fieldsDict]
            if let category = entry.category { dict["category"] = category }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        save(data: data,
             suggestedName: "\(safeName)-\(selectedScriptID).json",
             contentType: .json)
    }

    private var safeName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = processName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).isEmpty ? "app" : String(cleaned)
    }

    private func save(data: Data, suggestedName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Flashes the real view (identified by `viewId`, from a node's
    /// `UIHierarchyNode.viewId`) red on the device for ~1.2s, then restores
    /// its original background color — posts `highlight-view`, handled by
    /// the script's persistent `viewRegistry`. Only meaningful shortly
    /// after a dump; the script logs (doesn't crash) if the view's since
    /// been deallocated, but there's no way to guarantee that in general —
    /// see the script's own header comment.
    func highlightView(_ viewId: String) {
        guard evilModeEnabled, isAttached else { return }
        post(["type": "highlight-view", "viewId": viewId])
    }

    /// Frida's "message" signal delivers a JSON envelope
    /// (`{"type":"send","payload":"..."}`) rather than plain text — pull the
    /// human-readable payload out, falling back to the raw string for
    /// anything that isn't the expected shape.
    private static func displayText(fromFridaMessage raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        if let payload = obj["payload"] as? String { return payload }
        if let type = obj["type"] as? String, type == "error" {
            let desc = (obj["description"] as? String) ?? raw
            return "error: \(desc)"
        }
        return raw
    }
}
