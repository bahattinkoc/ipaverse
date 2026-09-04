//
//  BinaryStringPatcher.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Some SDKs bake their own identity strings (an App Group name, a keychain
//  prefix, ...) directly into compiled code as a string literal, rather than
//  reading them from a plist/json config file — e.g. NetmeraCore calling
//  `Netmera.start(appGroupName: "group.com.turkcell.csi")` from the host
//  app's own AppDelegate. BundleIdentityMigrator only scans .plist/.json
//  entries, so it can never find or fix this class of reference; this patches
//  the compiled binaries directly instead.

import Foundation

enum BinaryStringPatcherError: LocalizedError {
    case replacementTooLong(old: String, new: String)

    var errorDescription: String? {
        switch self {
        case .replacementTooLong(let old, let new):
            "Can't patch \"\(old)\" → \"\(new)\" — the replacement (\(new.utf8.count) bytes) is longer than the original (\(old.utf8.count) bytes). Binary string patching can only shrink or keep the same length, never grow, without a full relink."
        }
    }
}

/// Overwrites a literal string embedded in a Mach-O binary's `__TEXT,__cstring`
/// section with a shorter-or-equal-length replacement, keeping every other
/// byte in the file at its original offset.
///
/// Deliberately restricted to that one section rather than searching the
/// whole file: a raw byte search over the entire binary also matches inside
/// embedded structured data that happens to contain the same ASCII text —
/// e.g. this app's own `__TEXT,__info_plist` copy and its DER-encoded
/// entitlements blob both contain "com.turkcell.csi" as plain text, but
/// aren't null-terminated C strings at that point. Treating a match there as
/// one (scanning forward to "the next zero byte") swallows hundreds–thousands
/// of unrelated bytes as a bogus "suffix" and corrupts that structure.
/// `__cstring` holds only genuine null-terminated string literals, so a match
/// found there is safe to widen out to its real terminator.
struct BinaryStringPatcher {

    /// Case-insensitive: an SDK's own hardcoded string may use different
    /// casing than the app's CFBundleIdentifier (e.g. this app's bundle ID is
    /// "com.turkcell.CSI" but the embedded group name is
    /// "group.com.turkcell.csi", all-lowercase).
    ///
    /// Scans the main executable, every embedded framework/dylib, and each
    /// PlugIns/*.appex's own executable + frameworks — the same set
    /// FrameworkStripper touches.
    static func patch(
        _ replacements: [(old: String, new: String)], in appURL: URL, progress: @escaping (String) -> Void
    ) throws {
        let pairs = replacements.filter { !$0.old.isEmpty && $0.old != $0.new }
        guard !pairs.isEmpty else { return }
        for (old, new) in pairs where new.utf8.count > old.utf8.count {
            throw BinaryStringPatcherError.replacementTooLong(old: old, new: new)
        }

        let fm = FileManager.default
        var bundleRoots = [appURL]
        if let appexes = try? fm.contentsOfDirectory(at: appURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil) {
            bundleRoots += appexes.filter { $0.pathExtension == "appex" }
        }

        for bundleRoot in bundleRoots {
            var binaries: [URL] = []
            let executableURL = bundleRoot.appendingPathComponent(bundleRoot.deletingPathExtension().lastPathComponent)
            if fm.fileExists(atPath: executableURL.path) { binaries.append(executableURL) }

            let frameworksDir = bundleRoot.appendingPathComponent("Frameworks")
            if let items = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
                for item in items {
                    if item.pathExtension == "framework" {
                        binaries.append(item.appendingPathComponent(item.deletingPathExtension().lastPathComponent))
                    } else if item.pathExtension == "dylib" {
                        binaries.append(item)
                    }
                }
            }

            for binaryURL in binaries {
                guard let count = try? patchOne(binaryURL: binaryURL, pairs: pairs), count > 0 else { continue }
                progress("Patched \(count) string(s) in \(binaryURL.lastPathComponent)")
            }
        }
    }

    /// Returns the number of occurrences replaced (0 if the file couldn't be
    /// read, has no `__TEXT,__cstring` section, or just had no match in it —
    /// none of those are errors, most binaries won't contain any of these).
    ///
    /// Matches `old` as a *substring* (not the whole string) so a single
    /// bundle-ID pair also fixes suffixed variants an SDK might use (e.g.
    /// "group.com.turkcell.csi.dev" alongside the bare
    /// "group.com.turkcell.csi"). That means the replaced span can end
    /// *before* the string's real terminator — padding the freed bytes in
    /// right after the match would insert a premature NUL and silently
    /// truncate that suffix. Instead each match is widened out to its
    /// enclosing string's actual terminator first, the untouched suffix is
    /// carried over unchanged, and the freed bytes are padded at the very
    /// end — so "group.com.turkcell.csi.dev" becomes
    /// "group.com.koc.pentest.dev\0" (one extra trailing NUL), not
    /// "group.com.koc.pentest\0dev" (truncated).
    @discardableResult
    private static func patchOne(binaryURL: URL, pairs: [(old: String, new: String)]) throws -> Int {
        guard var data = try? Data(contentsOf: binaryURL),
              let cstring = Self.cstringSectionRange(in: data)
        else { return 0 }
        var totalCount = 0

        for (old, new) in pairs {
            let needle = Data(old.lowercased().utf8)
            guard !needle.isEmpty else { continue }
            let newBytes = Data(new.utf8)
            let freed = needle.count - newBytes.count

            // Search on an ASCII-lowercased snapshot, restricted to the
            // __cstring section, so matching is case-insensitive without a
            // per-position folding comparison. Re-snapshotted per pair (not
            // incrementally patched) so a later pair searches the *current*
            // content, including any earlier pair's edits.
            //
            // `data[cstring].map { ... }` silently produces a 0-based `[UInt8]`
            // (`Data.map` returns an Array, which does NOT preserve `Data`'s
            // original — non-zero-based — slice indices) even though
            // `data[cstring]` itself is indexed starting at `cstring.lowerBound`.
            // Match positions found in `foldedRegion` are therefore relative to
            // the section start, not absolute file offsets — they must be
            // shifted by `cstring.lowerBound` before being used against `data`,
            // or every "match" ends up patching essentially random bytes near
            // the start of the file (Mach-O header/load commands) instead of
            // the actual string.
            let foldedRegion = Data(data[cstring].map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 })

            var matchStarts: [Int] = []
            var searchStart = foldedRegion.startIndex
            while let range = foldedRegion.range(of: needle, in: searchStart..<foldedRegion.endIndex) {
                matchStarts.append(cstring.lowerBound + range.lowerBound)
                searchStart = range.upperBound
            }
            guard !matchStarts.isEmpty else { continue }

            for start in matchStarts {
                let matchEnd = start + needle.count
                var stringEnd = matchEnd
                while stringEnd < cstring.upperBound, data[stringEnd] != 0 { stringEnd += 1 }
                // No terminator before the section's own end — not a real
                // string boundary (or we've hit the section's tail padding
                // some other way); skip rather than guess.
                guard stringEnd < cstring.upperBound else { continue }

                var replacement = newBytes
                replacement.append(data.subdata(in: matchEnd..<stringEnd)) // preserve any suffix (e.g. ".dev") verbatim
                replacement.append(Data(repeating: 0, count: freed))       // pad at the true end, not mid-string

                data.replaceSubrange(start..<stringEnd, with: replacement) // == stringEnd - start in length — file layout unchanged
                totalCount += 1
            }
        }

        if totalCount > 0 { try data.write(to: binaryURL) }
        return totalCount
    }

    // MARK: - Mach-O section lookup

    private static let machHeaderSize = 32
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let lcSegment64: UInt32 = 0x19

    /// File-offset range of the `__TEXT,__cstring` section in a thin 64-bit
    /// arm64 Mach-O, or nil if this isn't one / it has no such section (fat
    /// binaries, non-arm64 slices, and anything without a __cstring section
    /// are simply skipped by the caller — not every framework has one).
    private static func cstringSectionRange(in data: Data) -> Range<Data.Index>? {
        guard data.count >= machHeaderSize else { return nil }
        func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) } }
        guard u32(0) == machMagic64 else { return nil }

        let ncmds = Int(u32(16))
        var cmdOffset = machHeaderSize
        for _ in 0..<ncmds {
            guard cmdOffset + 8 <= data.count else { return nil }
            let cmd = u32(cmdOffset)
            let cmdsize = Int(u32(cmdOffset + 4))
            guard cmdsize >= 8, cmdOffset + cmdsize <= data.count else { return nil }

            if cmd == lcSegment64 {
                guard cmdOffset + 72 <= data.count else { return nil }
                let segname = data.subdata(in: (cmdOffset + 8)..<(cmdOffset + 24))
                if segnameString(segname) == "__TEXT" {
                    let nsects = Int(u32(cmdOffset + 64))
                    let sectionsBase = cmdOffset + 72
                    for i in 0..<nsects {
                        let sectionOffset = sectionsBase + i * 80
                        guard sectionOffset + 80 <= data.count else { break }
                        let sectname = data.subdata(in: sectionOffset..<(sectionOffset + 16))
                        if segnameString(sectname) == "__cstring" {
                            let size = Int(u32(sectionOffset + 40))
                            let fileOffset = Int(u32(sectionOffset + 48))
                            guard fileOffset >= 0, size >= 0, fileOffset + size <= data.count else { return nil }
                            return fileOffset..<(fileOffset + size)
                        }
                    }
                    return nil // found __TEXT but no __cstring in it
                }
            }
            cmdOffset += cmdsize
        }
        return nil
    }

    /// Mach-O seg/sect names are fixed 16-byte NUL-padded byte arrays.
    private static func segnameString(_ bytes: Data) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(data: trimmed, encoding: .ascii) ?? ""
    }
}
