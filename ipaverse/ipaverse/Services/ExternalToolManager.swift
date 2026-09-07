//
//  ExternalToolManager.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Detects, installs, and removes the external reverse-engineering tools the
//  Reverse Engineer area hands off to (disassemblers, MITM proxies, Frida's
//  own CLI, libimobiledevice's extra utilities) — the "install it, don't
//  reimplement it" tools that don't make sense to bundle into ipaverse.app
//  itself (GUI apps, Python packages, multi-hundred-MB decompilers).
//
//  A GUI app launched from Finder/LaunchServices does NOT inherit the user's
//  shell PATH (no .zshrc sourced), so Homebrew's /opt/homebrew/bin — and a
//  pip --user install's ~/.local/bin — are invisible to a bare `which` call
//  here unless PATH is explicitly widened first. Every Process below does
//  that via `useExpandedPATH()`.

import Foundation

// MARK: - Catalog

enum ToolCategory: String, CaseIterable {
    case disassembly = "Disassembly & Decompile"
    case network = "Network / MITM"
    case dynamicInstrumentation = "Dynamic Instrumentation"
    case device = "Device Access"
}

enum ToolInstaller {
    case brewFormula(String)
    case brewCask(String)
    /// `pip3 install --user <package>` — for tools not packaged via Homebrew.
    case pipPackage(String)
    /// No supported auto-install (commercial license portal, shareware
    /// site) — the UI offers "Open Website" instead of "Install".
    case manualDownload(URL)
}

enum ToolStatus: Equatable {
    case unknown
    case checking
    case installed
    case notInstalled
}

struct ExternalTool: Identifiable {
    let id: String
    let name: String
    let summary: String
    let category: ToolCategory
    let installer: ToolInstaller
    /// Binary name (for `which`) or bundle name (for a /Applications app,
    /// without ".app") used to detect whether this is already installed.
    let detectionTarget: String
    let isApp: Bool
    let websiteURL: URL?

    init(id: String, name: String, summary: String, category: ToolCategory,
         installer: ToolInstaller, detectionTarget: String, isApp: Bool = false,
         websiteURL: URL? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.installer = installer
        self.detectionTarget = detectionTarget
        self.isApp = isApp
        self.websiteURL = websiteURL
    }
}

enum ExternalToolManager {

    static let catalog: [ExternalTool] = [
        ExternalTool(id: "radare2", name: "radare2", summary: "Free, scriptable disassembly framework (r2) — function disassembly, cross-references, and (with r2ghidra) decompiled pseudocode from the command line.",
                     category: .disassembly, installer: .brewFormula("radare2"), detectionTarget: "r2"),
        ExternalTool(id: "ghidra", name: "Ghidra", summary: "NSA's free decompiler/disassembler. Has a headless mode (`analyzeHeadless`) that can be scripted without opening the GUI.",
                     category: .disassembly, installer: .brewCask("ghidra"), detectionTarget: "Ghidra", isApp: true),
        ExternalTool(id: "hopper", name: "Hopper Disassembler", summary: "Commercial (free trial) macOS-native disassembler/decompiler with a polished GUI — good for manual, exploratory reverse engineering.",
                     category: .disassembly, installer: .brewCask("hopper-disassembler"), detectionTarget: "Hopper Disassembler", isApp: true),
        ExternalTool(id: "jtool2", name: "jtool2", summary: "Jonathan Levin's Mach-O Swiss-army knife — class-dump, entitlements, disassembly. Shareware, manual download only.",
                     category: .disassembly, installer: .manualDownload(URL(string: "http://newosxbook.com/tools/jtool.html")!),
                     detectionTarget: "jtool2"),

        ExternalTool(id: "mitmproxy", name: "mitmproxy", summary: "Free, scriptable HTTPS-capable intercepting proxy — pairs with Security Testing Mode's ATS bypass to inspect traffic.",
                     category: .network, installer: .brewFormula("mitmproxy"), detectionTarget: "mitmproxy"),
        ExternalTool(id: "proxyman", name: "Proxyman", summary: "Native macOS HTTPS traffic inspector with an easy device-certificate install flow.",
                     category: .network, installer: .brewCask("proxyman"), detectionTarget: "Proxyman", isApp: true),
        ExternalTool(id: "charles", name: "Charles Proxy", summary: "Long-standing commercial (free trial) HTTP/HTTPS traffic recorder and proxy.",
                     category: .network, installer: .brewCask("charles"), detectionTarget: "Charles", isApp: true),

        ExternalTool(id: "frida-tools", name: "frida-tools (CLI)", summary: "The `frida` / `frida-trace` / `frida-ps` command-line tools — for manual scripting and tracing against a Gadget ipaverse already injected.",
                     category: .dynamicInstrumentation, installer: .brewFormula("frida-tools"), detectionTarget: "frida"),
        ExternalTool(id: "objection", name: "objection", summary: "Frida-powered runtime mobile exploration toolkit — ready-made SSL-pinning bypass, jailbreak-detection bypass, and Keychain/NSUserDefaults dumping.",
                     category: .dynamicInstrumentation, installer: .pipPackage("objection"), detectionTarget: "objection"),

        ExternalTool(id: "ifuse", name: "ifuse", summary: "Mounts a device's AFC-accessible storage as a Finder volume — browse an app's sandbox without a jailbreak.",
                     category: .device, installer: .brewFormula("ifuse"), detectionTarget: "ifuse"),
        ExternalTool(id: "ideviceinstaller", name: "ideviceinstaller", summary: "CLI app install/list/uninstall over libimobiledevice — useful alongside ipaverse's own device install flow for scripting.",
                     category: .device, installer: .brewFormula("ideviceinstaller"), detectionTarget: "ideviceinstaller"),
    ]

    // MARK: - Detection

    static func status(for tool: ExternalTool) -> ToolStatus {
        if tool.isApp {
            return applicationExists(named: tool.detectionTarget) ? .installed : .notInstalled
        }
        return locateBinary(tool.detectionTarget) != nil ? .installed : .notInstalled
    }

    private static func applicationExists(named name: String) -> Bool {
        let candidates = [
            "/Applications/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Widened search path covering Apple Silicon/Intel Homebrew prefixes and
    /// common pip `--user` install locations — see file header for why this
    /// can't just rely on the process's inherited PATH.
    private static var expandedSearchPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "\(home)/.local/bin",
            "\(home)/Library/Python/3.13/bin", "\(home)/Library/Python/3.12/bin",
            "\(home)/Library/Python/3.11/bin", "\(home)/Library/Python/3.10/bin",
            "\(home)/Library/Python/3.9/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }

    /// Not private: reused by ClassMethodResolver to find `r2` the same way
    /// the Tools tab does, without duplicating the PATH-widening logic.
    static func locateBinary(_ name: String) -> String? {
        for dir in expandedSearchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func homebrewPath() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Install / Uninstall

    enum ManagerError: LocalizedError {
        case homebrewNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .homebrewNotFound: "Homebrew isn't installed. Install it from brew.sh, then try again."
            case .commandFailed(let msg): msg.isEmpty ? "The command failed." : msg
            }
        }
    }

    static func install(_ tool: ExternalTool, progress: @escaping (String) -> Void) async throws -> Void {
        switch tool.installer {
        case .brewFormula(let formula):
            try await runBrew(["install", formula], progress: progress)
        case .brewCask(let cask):
            try await runBrew(["install", "--cask", cask], progress: progress)
        case .pipPackage(let package):
            try await runStreaming("/usr/bin/python3", ["-m", "pip", "install", "--user", package], progress: progress)
        case .manualDownload:
            break // UI offers "Open Website" instead of calling this.
        }
    }

    static func uninstall(_ tool: ExternalTool, progress: @escaping (String) -> Void) async throws -> Void {
        switch tool.installer {
        case .brewFormula(let formula):
            try await runBrew(["uninstall", formula], progress: progress)
        case .brewCask(let cask):
            try await runBrew(["uninstall", "--cask", cask], progress: progress)
        case .pipPackage(let package):
            try await runStreaming("/usr/bin/python3", ["-m", "pip", "uninstall", "-y", package], progress: progress)
        case .manualDownload:
            break
        }
    }

    private static func runBrew(_ args: [String], progress: @escaping (String) -> Void) async throws {
        guard let brew = homebrewPath() else { throw ManagerError.homebrewNotFound }
        try await runStreaming(brew, args, progress: progress)
    }

    /// Runs a CLI tool with a widened PATH, forwarding each output line to
    /// `progress` as it arrives (installs can take minutes; a silent
    /// spinner with no feedback reads as hung).
    private static func runStreaming(_ launchPath: String, _ args: [String], progress: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            let extra = expandedSearchPaths.joined(separator: ":")
            env["PATH"] = extra + ":" + (env["PATH"] ?? "")
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { progress(trimmed) }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ManagerError.commandFailed("Exited with status \(proc.terminationStatus)."))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
