//
//  ClassMethodResolver.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Reverse Engineer > Class Browser's real per-class method names — the one
//  thing `ClassDumper.swift` deliberately does NOT provide (see that file's
//  header: resolving a method's selector through relative-method-list
//  pointers on a chained-fixups binary isn't safely doable by hand). r2
//  already has a robust, correct Mach-O/ObjC analyzer that handles exactly
//  this, Swift name demangling included — `icj` (info-classes-json) reads
//  it straight from the binary's own metadata, no `aa` full-analysis pass
//  needed, and returns real method names.
//
//  Verified empirically against a real decrypted binary (Espressolab,
//  29MB): `r2 -q -c icj <path>` completed in ~4.4s covering 6569 class-ish
//  entries. r2 emits *multiple* entries for the same logical Swift class
//  under different demangling passes — e.g. both a bare `NotificationHelper`
//  (0 methods, wrong) and a dotted `Espressolab.NotificationHelper` (5
//  correctly-named methods) for the identical class. The dotted
//  `Module.ClassName` form is the one that lines up with `ClassDumper`'s own
//  `displayName` (from `xcrun swift-demangle`), so lookups key off that —
//  entries that don't resolve to a real method list just fall back to
//  ClassDumper's method *count*, same as when r2 isn't installed at all.
//
//  Only meaningful on a decrypted binary — same FairPlay caveat as
//  ClassDumper/IPASecurityScanner (r2 would be disassembling ciphertext).
//  Optional entirely: gated on r2 actually being installed (Settings/Tools
//  tab), never a hard requirement for the Class Browser to work.

import Foundation

/// A method r2 resolved a real name for. `address` is kept (rather than
/// just the name) so overloaded/duplicate-named methods still get distinct
/// `id`s in a `List`.
struct ResolvedMethod: Hashable, Identifiable {
    let name: String
    let address: UInt64

    var id: String { "\(address)-\(name)" }
}

enum ClassMethodResolver {

    private struct R2Method: Decodable {
        let name: String?
        let addr: UInt64?
    }

    private struct R2Class: Decodable {
        let classname: String?
        let methods: [R2Method]?
    }

    static var isAvailable: Bool {
        ExternalToolManager.locateBinary("r2") != nil
    }

    /// Returns a map from class display name (r2's `Module.ClassName`
    /// demangled form — matches `ObjCClassInfo.displayName`) to its real
    /// methods. Empty dictionary if r2 isn't installed, the binary is
    /// still encrypted, or analysis fails for any reason — always a
    /// graceful no-op, never throws, since this only ever *enriches* the
    /// Class Browser, it's never required for it to function.
    static func resolveMethods(binaryURL: URL, progress: @escaping (String) -> Void) -> [String: [ResolvedMethod]] {
        guard let r2Path = ExternalToolManager.locateBinary("r2") else { return [:] }
        if IPAResigner.isFairPlayEncrypted(binaryURL: binaryURL) { return [:] }

        progress("Running r2 icj…")
        let data = runR2(r2Path, ["-q", "-c", "icj", binaryURL.path])
        guard !data.isEmpty, let classes = try? JSONDecoder().decode([R2Class].self, from: data) else {
            return [:]
        }

        progress("Parsing r2 output…")
        var result: [String: [ResolvedMethod]] = [:]
        for cls in classes {
            guard let name = cls.classname, name.contains("."), let methods = cls.methods, !methods.isEmpty else {
                continue
            }
            let valid = methods.compactMap { m -> ResolvedMethod? in
                guard let mname = m.name, isRealMethodName(mname), let addr = m.addr else { return nil }
                return ResolvedMethod(name: mname, address: addr)
            }
            guard !valid.isEmpty else { continue }
            // A dotted classname can legitimately repeat (categories on the
            // same class, or duplicate demangling passes) — merge rather
            // than overwrite so nothing found gets silently dropped.
            result[name, default: []].append(contentsOf: valid)
        }
        for key in result.keys {
            result[key] = Array(Set(result[key]!)).sorted { $0.name < $1.name }
        }
        return result
    }

    /// r2 emits placeholder names (`func.100664dd8`, or bare numbers) for
    /// selectors it couldn't resolve on this particular demangling pass —
    /// filter those out rather than show fake-looking "method names".
    private static func isRealMethodName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.hasPrefix("func.") { return false }
        if Int(name) != nil { return false }
        return true
    }

    private static func runR2(_ path: String, _ args: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return Data() }
        // Concurrent drain — see IPASecurityScanner.drainConcurrently's doc
        // comment for why a sequential "read stdout fully, then stderr"
        // pattern can deadlock a tool that writes enough to both streams.
        let (out, _) = IPASecurityScanner.drainConcurrently(outPipe, errPipe)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return Data() }
        return out
    }
}
