//
//  FridaScriptLibrary.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Canned Frida scripts for the Reverse Engineer area's Frida Toolkit —
//  turns the static findings Security Scan already surfaces (pinning,
//  anti-analysis, biometric usage) into one-click, live bypasses/traces
//  instead of just a "you should check this" note.
//
//  The actual JS lives in Resources/FridaScripts/*.js, not as Swift string
//  literals — see that folder's README for why (in short: Frida 17 requires
//  `import ObjC from 'frida-objc-bridge'` and our raw C-API script creation
//  parses plain, non-module source, so the ObjC-using scripts here are
//  pre-bundled with frida-compile into a single self-contained ~50KB blob;
//  embedding that as a Swift string literal risked transcription/escaping
//  errors for no benefit over just shipping it as a resource file).

import Foundation

/// Groups the catalog for the Frida Toolkit's sidebar — purely a UI
/// grouping, no behavioral difference between scripts in different
/// categories.
enum FridaScriptCategory: String, CaseIterable, Identifiable {
    case bypass = "Bypass"
    case dump = "Data Dump"
    case live = "Live Inspection"
    var id: String { rawValue }
}

struct FridaScript: Identifiable {
    let id: String
    let title: String
    let summary: String
    let category: FridaScriptCategory
    /// SF Symbol shown in the sidebar next to `title`.
    let icon: String
    /// When true, the UI must collect a class name and substitute it for
    /// `{{CLASS_NAME}}` in the loaded source before running.
    let requiresClassName: Bool
    /// Base filename (without extension) under Resources/FridaScripts/.
    fileprivate let resourceName: String

    var source: String {
        FridaScriptLibrary.loadSource(resourceName: resourceName)
    }
}

enum FridaScriptLibrary {

    static let scripts: [FridaScript] = [
        FridaScript(
            id: "ssl-pinning-bypass",
            title: "SSL Pinning Bypass",
            summary: "Forces SecTrustEvaluate / SecTrustEvaluateWithError to always succeed. Defeats naive pinning; a custom SecTrustSetAnchorCertificates/SecTrustSetPolicies implementation (see the Pinning findings) may need a targeted hook instead.",
            category: .bypass,
            icon: "lock.open.fill",
            requiresClassName: false,
            resourceName: "ssl-pinning-bypass"
        ),
        FridaScript(
            id: "jailbreak-detection-bypass",
            title: "Jailbreak Bypass",
            summary: "Hooks fopen/access/NSFileManager checks for common jailbreak file paths (Cydia, MobileSubstrate, apt) and makes them report \"not found\".",
            category: .bypass,
            icon: "ladybug.fill",
            requiresClassName: false,
            resourceName: "jailbreak-detection-bypass"
        ),
        FridaScript(
            id: "biometric-bypass",
            title: "Biometric Bypass",
            summary: "Forces LAContext.evaluatePolicy(...) to report success without a real Face ID/Touch ID/passcode prompt. Only defeats client-side trust — a server that re-verifies isn't affected.",
            category: .bypass,
            icon: "faceid",
            requiresClassName: false,
            resourceName: "biometric-bypass"
        ),
        FridaScript(
            id: "userdefaults-dump",
            title: "NSUserDefaults Dump",
            summary: "Lists every key/value in the app's standard NSUserDefaults — a common (insecure) place to find auth tokens, feature flags, and cached user data. With Evil Mode on, string/number values are editable in place, live on the device — try flipping a feature flag or a login state.",
            category: .dump,
            icon: "list.bullet.rectangle",
            requiresClassName: false,
            resourceName: "userdefaults-dump"
        ),
        FridaScript(
            id: "keychain-dump",
            title: "Keychain Dump",
            summary: "Lists account/service/label metadata for every Generic and Internet Password item in the Keychain — which accounts/services the app (and others on the same device) have stored credentials for. Doesn't fetch the secret values themselves (kSecReturnData reliably failed validation — see the script's own trailing note for why and how to pull one manually).",
            category: .dump,
            icon: "key.fill",
            requiresClassName: false,
            resourceName: "keychain-dump"
        ),
        FridaScript(
            id: "sandbox-files",
            title: "Sandbox Files",
            summary: "Walks the app's sandbox container (NSHomeDirectory) and lists every .sqlite/.sqlite3/.db/.realm/.plist file with its size — where an app is likely to cache tokens, user data, or config outside the Keychain/NSUserDefaults. Download any of them straight to your Mac while the script is still running.",
            category: .dump,
            icon: "folder.fill",
            requiresClassName: false,
            resourceName: "sandbox-files"
        ),
        FridaScript(
            id: "class-method-tracer",
            title: "Method Tracer",
            summary: "Hooks a class's methods and logs each call live with argument and return values (int/bool/pointer — float/double show as unreadable, a real ARM64 ABI limit for this hook style, not a bug). Optionally filter to methods whose name contains a substring; leave blank to trace everything except a built-in noisy-method list (dealloc/retain/release/etc).",
            category: .live,
            icon: "bolt.fill",
            requiresClassName: true,
            resourceName: "class-method-tracer"
        ),
        FridaScript(
            id: "network-request-logger",
            title: "Network Logger",
            summary: "Hooks NSURLSession data tasks at the API layer, before TLS and pinning checks. Supported requests pass through and are logged by default; flip on Intercept to pause their requests and completion-handler responses, edit method/URL/headers/body or status/headers/body, then Forward or Drop. Apps using other networking APIs or custom stacks need separate hooks.",
            category: .live,
            icon: "network",
            requiresClassName: false,
            resourceName: "network-request-logger"
        ),
        FridaScript(
            id: "ui-hierarchy-dump",
            title: "UI Hierarchy Dump",
            summary: "Walks every window's live view tree — class, frame, accessibility identifier/label, label/button text, a WKWebView's URL, and a text field's real value even if it's a secure field showing dots on screen. Tap the eye icon to flash that element red on the real device; tap a class name to send it to the Method Tracer.",
            category: .live,
            icon: "rectangle.stack",
            requiresClassName: false,
            resourceName: "ui-hierarchy-dump"
        ),
    ]

    static func resolvedSource(for script: FridaScript, className: String?, methodFilter: String = "") -> String {
        var source = script.source
        guard script.requiresClassName, let className, !className.isEmpty else { return source }
        source = source.replacingOccurrences(of: "{{CLASS_NAME}}", with: jsStringLiteralEscaped(className))
        // Only class-method-tracer.js has this placeholder — a no-op replace
        // on any other script.
        source = source.replacingOccurrences(of: "{{METHOD_FILTER}}", with: jsStringLiteralEscaped(methodFilter))
        return source
    }

    /// Both placeholders sit inside single-quoted JS string literals in the
    /// resource files (`var className = '{{CLASS_NAME}}';`) — escape `\`
    /// and `'` so a class/method name typed by the user can't break out of
    /// that literal.
    private static func jsStringLiteralEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    fileprivate static func loadSource(resourceName: String) -> String {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "js")
                ?? Bundle.main.url(forResource: resourceName, withExtension: "js", subdirectory: "FridaScripts"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Fails loudly at *run* time (a script that does nothing is far
            // more confusing than a script the user can see errored out) —
            // FridaScriptRunner will surface this as a normal script-load
            // failure via its own error path.
            return "send('error: missing bundled script resource \"\(resourceName).js\" — reinstall ipaverse.');"
        }
        return text
    }
}
