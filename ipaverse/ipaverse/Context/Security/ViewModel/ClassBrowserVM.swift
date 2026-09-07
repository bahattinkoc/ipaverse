//
//  ClassBrowserVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//

import SwiftUI

@MainActor
final class ClassBrowserVM: ObservableObject {
    enum State {
        case idle
        case loadingTargets
        case dumping
        case done(ClassDumpResult)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var targets: [ClassDumpTarget] = []
    @Published var selectedTargetID: String?
    @Published var dumpStep: String?
    /// Real per-class method names from r2 (`ClassMethodResolver`), keyed by
    /// `ObjCClassInfo.displayName`. Empty until (if) that finishes — always
    /// optional enrichment on top of `ClassDumper`'s method *counts*, never
    /// required, so its absence never blocks or fails the base dump.
    @Published private(set) var methodsByClass: [String: [ResolvedMethod]] = [:]

    private let ipaPath: String
    private var workDir: URL?

    init(ipaPath: String) {
        self.ipaPath = ipaPath
    }

    deinit {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    var isBusy: Bool {
        switch state {
        case .loadingTargets, .dumping: return true
        default: return false
        }
    }

    var selectedTarget: ClassDumpTarget? {
        targets.first { $0.id == selectedTargetID }
    }

    /// Bumped on every load/dump kick-off; a completion (or timeout) whose
    /// generation no longer matches the current one is stale and ignored —
    /// guards against a slow background op finishing after the user already
    /// switched targets or retried, and clobbering the newer state.
    private var generation = 0
    private static let watchdogSeconds: UInt64 = 45

    func loadIfNeeded() {
        guard case .idle = state else { return }
        generation += 1
        let myGeneration = generation
        state = .loadingTargets
        let path = ipaPath

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let (dir, list) = try ClassDumper.availableTargets(ipaPath: path)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == myGeneration else { return }
                    self.workDir = dir
                    self.targets = list
                    self.selectedTargetID = list.first?.id
                    if list.isEmpty {
                        self.state = .failed("No Mach-O binaries found in this bundle.")
                    } else {
                        // NOT `dump()` — that function's own `isBusy` guard
                        // would see `state` still sitting at `.loadingTargets`
                        // (nothing has transitioned it away yet at this exact
                        // point) and silently no-op, leaving the UI stuck on
                        // "Extracting…" forever. This *directly* starts the
                        // dump instead of routing back through that guard.
                        self.startDump(for: list[0])
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == myGeneration else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        armWatchdog(generation: myGeneration, phase: "Extracting/scanning the bundle")
    }

    func selectTarget(_ id: String) {
        guard id != selectedTargetID, !isBusy, let target = targets.first(where: { $0.id == id }) else { return }
        selectedTargetID = id
        startDump(for: target)
    }

    /// Explicit re-dump / retry entry point for the UI — safe to call
    /// whenever nothing else is in flight.
    func dump() {
        guard !isBusy, let target = selectedTarget else { return }
        startDump(for: target)
    }

    private func startDump(for target: ClassDumpTarget) {
        generation += 1
        let myGeneration = generation
        state = .dumping
        dumpStep = nil
        methodsByClass = [:]
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try ClassDumper.dump(target: target) { step in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == myGeneration else { return }
                        self.dumpStep = step
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == myGeneration else { return }
                    self.state = .done(result)
                }

                // Best-effort follow-up, still on this same background task —
                // never blocks or fails the base dump above; a no-op in well
                // under a millisecond if r2 isn't installed.
                if ClassMethodResolver.isAvailable {
                    let methods = ClassMethodResolver.resolveMethods(binaryURL: target.url) { _ in }
                    if !methods.isEmpty {
                        await MainActor.run { [weak self] in
                            guard let self, self.generation == myGeneration else { return }
                            self.methodsByClass = methods
                        }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == myGeneration else { return }
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
        armWatchdog(generation: myGeneration, phase: "Dumping \(target.name)")
    }

    /// Backstop so a hang anywhere in this chain — known or not-yet-found —
    /// surfaces as a retryable error instead of an infinite spinner. Doesn't
    /// kill the underlying blocked background thread (Process calls here are
    /// synchronous, not cooperatively cancellable), just stops the UI from
    /// waiting on it forever; the leaked thread exits on its own once
    /// whatever it's blocked on resolves.
    private func armWatchdog(generation myGeneration: Int, phase: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.watchdogSeconds * 1_000_000_000)
            guard let self, self.generation == myGeneration, self.isBusy else { return }
            self.state = .failed("\(phase) is taking far longer than expected (>\(Self.watchdogSeconds)s) and was given up on. Try again, or pick a different binary if this bundle has unusually many/large frameworks.")
        }
    }
}
