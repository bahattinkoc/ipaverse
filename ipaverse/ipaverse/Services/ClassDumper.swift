//
//  ClassDumper.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Reverse Engineer > Class Browser: the Objective-C classes a Mach-O binary
//  declares (name + method counts), plus every selector string referenced
//  anywhere in it.
//
//  This deliberately does NOT attempt to resolve which selector belongs to
//  which class. First attempt did: `otool -ov`'s per-method `name` field
//  (in the modern "relative method list" format every current Xcode build
//  uses) is a relative offset that, once resolved to an absolute address,
//  points into a __DATA/__DATA_CONST pointer slot — and on a binary built
//  with chained fixups (`LC_DYLD_CHAINED_FIXUPS`, i.e. every current iOS
//  build), the raw bytes stored there on disk are NOT a plain pointer.
//  They're an encoded chain entry (rebase/bind info packed into the 64
//  bits) that only becomes a real address after dyld walks the chain at
//  load time. Reading it as a plain pointer and dereferencing again — the
//  first version of this file did exactly that — silently produces garbage
//  selector names most of the time. Verified empirically against a real
//  decrypted binary before landing this: direct interpretation resolved
//  ~29% of names to plausible-but-unverifiable text (and some outright
//  garbage), and adding a second dereference made it *worse* (4/12369).
//  Implementing chained-fixups decoding correctly is real, involved parsing
//  this session doesn't have the budget to get right and verify — so
//  instead of shipping a feature that's wrong some fraction of the time,
//  this only reports data through two paths verified to be always correct:
//
//   1. Class names: `otool -ov`'s class-level `name` field is NOT a
//      relative-method-list pointer — it resolves correctly (verified:
//      3526/3526 classes on the test binary got a real, sane name).
//   2. Method *counts* per class: the `count` field in a class's
//      `baseMethods` block is a plain integer `otool` prints directly, no
//      pointer involved.
//   3. The full selector inventory: `__TEXT,__objc_methname` is a flat,
//      NUL-separated block of plain C strings — no pointers to resolve at
//      all, so reading it directly (bypassing otool/relative-method-lists
//      entirely) is unconditionally safe and correct.
//
//  Only meaningful on a decrypted binary — see IPASecurityScanner.swift's
//  header for why FairPlay makes both otool's text output and __TEXT string
//  content unreadable while `cryptid == 1`.

import Foundation

struct ObjCClassInfo: Identifiable, Hashable {
    /// The exact runtime-registered name (what `ObjC.classes[name]` in a
    /// Frida script must use) — for a Swift class this is the mangled form
    /// (e.g. `_TtC8Multipay15SessionDelegate`), not the pretty one.
    let rawName: String
    var displayName: String
    var instanceMethodCount: Int
    var classMethodCount: Int

    var id: String { rawName }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawName == rhs.rawName }
    func hash(into hasher: inout Hasher) { hasher.combine(rawName) }
}

struct ClassDumpTarget: Identifiable, Hashable {
    let name: String
    let url: URL
    let isMainExecutable: Bool

    var id: String { url.path }
}

struct ClassDumpResult {
    let classes: [ObjCClassInfo]
    /// Every selector string found in `__TEXT,__objc_methname`, not
    /// attributed to a specific class — see file header for why.
    let allSelectors: [String]
}

enum ClassDumperError: LocalizedError {
    case extractionFailed(String)
    case appBundleNotFound
    case binaryEncrypted
    case binaryUnreadable

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let m): "Could not extract the IPA: \(m)"
        case .appBundleNotFound: "No .app bundle found inside the IPA."
        case .binaryEncrypted: "This binary is still FairPlay-encrypted — dump a decrypted copy first, then re-open the Class Browser."
        case .binaryUnreadable: "Couldn't read this binary (not a thin arm64 Mach-O, or the file is corrupt)."
        }
    }
}

enum ClassDumper {

    // MARK: - Bundle scanning

    /// Extracts the IPA into a caller-owned temp directory (the caller
    /// removes it once done) and lists every Mach-O binary inside, main
    /// executable first.
    static func availableTargets(ipaPath: String) throws -> (workDir: URL, targets: [ClassDumpTarget]) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("ipaverse-classdump-\(UUID().uuidString)", isDirectory: true)
        do {
            try IPASecurityScanner.extract(ipaPath: ipaPath, to: tmpDir)
        } catch {
            throw ClassDumperError.extractionFailed(error.localizedDescription)
        }

        guard let appURL = (try? fm.contentsOfDirectory(
            at: tmpDir.appendingPathComponent("Payload", isDirectory: true), includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            throw ClassDumperError.appBundleNotFound
        }

        let targets = IPASecurityScanner.machOBinaries(in: appURL).map { url -> ClassDumpTarget in
            let isMain = url.deletingLastPathComponent().standardizedFileURL == appURL.standardizedFileURL
            let name = isMain ? appURL.deletingPathExtension().lastPathComponent : url.lastPathComponent
            return ClassDumpTarget(name: name, url: url, isMainExecutable: isMain)
        }.sorted { $0.isMainExecutable && !$1.isMainExecutable }

        return (tmpDir, targets)
    }

    // MARK: - Dump

    static func dump(target: ClassDumpTarget, progress: @escaping (String) -> Void) throws -> ClassDumpResult {
        if IPAResigner.isFairPlayEncrypted(binaryURL: target.url) {
            throw ClassDumperError.binaryEncrypted
        }
        guard let data = try? Data(contentsOf: target.url) else {
            throw ClassDumperError.binaryUnreadable
        }

        progress("Reading selector strings…")
        let allSelectors = extractMethNameStrings(from: data)

        progress("Running otool -ov…")
        let otoolData = IPASecurityScanner.runProcess("/usr/bin/otool", ["-ov", target.url.path])
        guard let text = String(data: otoolData, encoding: .utf8) ?? String(data: otoolData, encoding: .isoLatin1) else {
            return ClassDumpResult(classes: [], allSelectors: allSelectors)
        }

        progress("Parsing classes…")
        let (order, counts) = parseClassList(text)

        progress("Resolving Swift names…")
        let displayNames = demangle(order)

        let classes = order.map { raw -> ObjCClassInfo in
            let c = counts[raw] ?? (instance: 0, classM: 0)
            return ObjCClassInfo(rawName: raw, displayName: displayNames[raw] ?? raw,
                                  instanceMethodCount: c.instance, classMethodCount: c.classM)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return ClassDumpResult(classes: classes, allSelectors: allSelectors)
    }

    // MARK: - __objc_methname raw string extraction (no pointer chasing)

    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let lcSegment64: UInt32 = 0x19

    private static func extractMethNameStrings(from data: Data) -> [String] {
        guard data.safeUInt32(at: 0) == machMagic64, let ncmds = data.safeUInt32(at: 16) else { return [] }
        var cmdOffset = 32
        for _ in 0..<Int(ncmds) {
            guard cmdOffset + 8 <= data.count,
                  let cmd = data.safeUInt32(at: cmdOffset),
                  let cmdsizeRaw = data.safeUInt32(at: cmdOffset + 4) else { break }
            let cmdsize = Int(cmdsizeRaw)
            guard cmdsize >= 8, cmdOffset + cmdsize <= data.count else { break }

            if cmd == lcSegment64, let nsects = data.safeUInt32(at: cmdOffset + 64) {
                let segname = data.safeFixedString(at: cmdOffset + 8, length: 16) ?? ""
                var sectionOffset = cmdOffset + 72
                for _ in 0..<Int(nsects) {
                    guard sectionOffset + 80 <= data.count else { break }
                    let sectname = data.safeFixedString(at: sectionOffset, length: 16) ?? ""
                    if segname == "__TEXT", sectname == "__objc_methname",
                       let size = data.safeUInt64(at: sectionOffset + 40),
                       let fileoff = data.safeUInt32(at: sectionOffset + 48),
                       let length = Int(exactly: size) {
                        return splitNulSeparatedStrings(in: data, start: Int(fileoff), length: length)
                    }
                    sectionOffset += 80
                }
            }
            cmdOffset += cmdsize
        }
        return []
    }

    private static func splitNulSeparatedStrings(in data: Data, start: Int, length: Int) -> [String] {
        guard start >= 0, length > 0, start <= data.count, length <= data.count - start else { return [] }
        let blob = data.subdata(in: start..<(start + length))
        var names = Set<String>()
        var current: [UInt8] = []
        for byte in blob {
            if byte == 0 {
                if !current.isEmpty { names.insert(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        return names.sorted()
    }

    // MARK: - Class list + method counts (text-based, from otool -ov)

    /// Parses just the `__objc_classlist` section of `otool -ov`'s output.
    /// Deliberately bounded to that one section (stops at the next
    /// "Contents of (...)" header) — categories (`__objc_catlist`) use a
    /// different, unrelated layout with no `ivarLayout` anchor, and mixing
    /// them in here risks misattributing methods to a stale class name.
    private static func parseClassList(_ text: String) -> (order: [String], counts: [String: (instance: Int, classM: Int)]) {
        guard let startRange = text.range(of: "__objc_classlist) section"),
              let lineBreak = text[startRange.upperBound...].firstIndex(of: "\n") else {
            return ([], [:])
        }
        let sectionStart = text.index(after: lineBreak)
        var sectionEnd = text.endIndex
        if let nextRange = text.range(of: "\nContents of (", range: sectionStart..<text.endIndex) {
            sectionEnd = nextRange.lowerBound
        }
        let section = text[sectionStart..<sectionEnd]

        var currentClassName: String?
        var inMetaClass = false
        var order: [String] = []
        var counts: [String: (instance: Int, classM: Int)] = [:]
        // True right after a line starting with "ivarLayout" — the very
        // next "name" line is class_ro_t's own `name` field (a fixed,
        // otool-resolved struct field, not a relative-method-list pointer).
        var prevWasIvarLayout = false

        let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
        let n = lines.count
        var i = 0
        while i < n {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }

            if trimmed == "Meta Class" {
                inMetaClass = true
                prevWasIvarLayout = false
                continue
            }
            if isClasslistHeader(trimmed) {
                // A fresh class entry starts here — nothing parsed so far
                // about the *next* class should leak into it.
                currentClassName = nil
                inMetaClass = false
                prevWasIvarLayout = false
                continue
            }
            if trimmed.hasPrefix("ivarLayout") {
                prevWasIvarLayout = true
                continue
            }

            if trimmed.hasPrefix("name "), prevWasIvarLayout {
                let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    let className = String(parts[2])
                    currentClassName = className
                    if counts[className] == nil {
                        counts[className] = (0, 0)
                        order.append(className)
                    }
                }
                prevWasIvarLayout = false
                continue
            }

            // A null baseMethods (no own methods) resolves to the mach
            // header's own address — see file header rationale — so there's
            // no entsize/count pair to read for it.
            if trimmed.hasPrefix("baseMethods"), let className = currentClassName,
               !trimmed.contains("__mh_execute_header"), i + 2 < n {
                let entsizeLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let countLine = lines[i + 2].trimmingCharacters(in: .whitespaces)
                if entsizeLine.hasPrefix("entsize"), countLine.hasPrefix("count") {
                    let countParts = countLine.split(separator: " ")
                    if countParts.count >= 2, let methodCount = Int(countParts[1]) {
                        var existing = counts[className] ?? (0, 0)
                        if inMetaClass { existing.classM += methodCount } else { existing.instance += methodCount }
                        counts[className] = existing
                    }
                }
            }
            prevWasIvarLayout = false
        }

        return (order, counts)
    }

    /// A classlist-slot header line: exactly two tokens, `<16 hex digits>
    /// 0x<hex>` — distinctive enough that nothing else in the dump matches.
    private static func isClasslistHeader(_ trimmed: String) -> Bool {
        let parts = trimmed.split(separator: " ")
        guard parts.count == 2 else { return false }
        guard parts[0].count == 16, parts[0].allSatisfy(\.isHexDigit) else { return false }
        guard parts[1].hasPrefix("0x") else { return false }
        let tail = parts[1].dropFirst(2)
        return !tail.isEmpty && tail.allSatisfy(\.isHexDigit)
    }

    // MARK: - Best-effort Swift demangling

    /// A Swift class visible to the ObjC runtime carries its mangled name
    /// (`_TtC...` or `$s...`) as the actual `class_ro_t` name — that's what
    /// `otool` prints and what Frida's `ObjC.classes` is keyed by, so the
    /// raw name is never discarded. This only prettifies the label shown in
    /// the list; if `swift-demangle` isn't available, or a name isn't
    /// mangled at all, the raw name is kept as-is.
    private static func demangle(_ names: [String]) -> [String: String] {
        let mangled = names.filter { $0.hasPrefix("_Tt") || $0.hasPrefix("$s") || $0.hasPrefix("_$s") }
        guard !mangled.isEmpty else { return [:] }

        let input = mangled.joined(separator: "\n")
        guard let inputData = input.data(using: .utf8) else { return [:] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift-demangle"]
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [:] }
        // Writing all of stdin before reading any of stdout is the classic
        // bidirectional-pipe deadlock: with ~1000+ class names piped in,
        // swift-demangle's stdout can fill its 64KB kernel buffer while
        // it's still consuming stdin, and once it blocks on ITS write, our
        // write(inputData) below blocks right back — forever, since
        // nothing reads stdout until after that write returns. Doing the
        // write on a background queue lets both directions drain at once.
        DispatchQueue.global(qos: .userInitiated).async {
            inPipe.fileHandleForWriting.write(inputData)
            try? inPipe.fileHandleForWriting.close()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: outData, encoding: .utf8) else { return [:] }

        let outLines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard outLines.count >= mangled.count else { return [:] }

        var result: [String: String] = [:]
        for (i, raw) in mangled.enumerated() {
            let demangled = outLines[i].trimmingCharacters(in: .whitespaces)
            if !demangled.isEmpty, demangled != raw {
                result[raw] = demangled
            }
        }
        return result
    }
}
