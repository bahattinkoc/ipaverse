//
//  DylibInjector.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//

import Foundation

enum DylibInjectorError: LocalizedError {
    case unsupportedBinaryFormat
    case insufficientHeaderPadding(available: Int, needed: Int)
    case resourceNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedBinaryFormat:
            "Frida Gadget injection only supports thin 64-bit arm64 Mach-O executables."
        case .insufficientHeaderPadding(let available, let needed):
            "Not enough free space in the Mach-O header to add a new load command (\(available) bytes available, \(needed) needed). This binary can't be patched without a full relink."
        case .resourceNotFound:
            "Frida Gadget is still missing after downloading — the download may be corrupted."
        }
    }
}

/// Injects the Frida Gadget into an app bundle by patching its main
/// executable's Mach-O load commands — no jailbreak/frida-server required,
/// since the agent runs in-process. The gadget itself (~40MB) isn't bundled
/// into ipaverse.app; it's downloaded on first use and cached (FridaRuntime),
/// so users who never touch this feature don't pay for its size.
/// See Vendor/frida/README.md for context.
struct DylibInjector {

    private static let machHeaderSize = 32
    private static let lcLoadWeakDylib: UInt32 = 0x8000_0018 // LC_REQ_DYLD | LC_LOAD_WEAK_DYLIB
    private static let lcSegment64: UInt32 = 0x19
    private static let machMagic64: UInt32 = 0xFEED_FACF

    static func injectFridaGadget(appURL: URL, mainBinaryURL: URL, progress: @escaping (String) -> Void) throws {
        let gadgetURL = try FridaRuntime.ensureGadget(progress: progress)
        guard FileManager.default.fileExists(atPath: gadgetURL.path) else {
            throw DylibInjectorError.resourceNotFound
        }

        let frameworksURL = appURL.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: frameworksURL, withIntermediateDirectories: true)
        let destURL = frameworksURL.appendingPathComponent("FridaGadget.dylib")
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.copyItem(at: gadgetURL, to: destURL)

        try insertLoadCommand(binaryURL: mainBinaryURL, dylibPath: "@executable_path/Frameworks/FridaGadget.dylib")
    }

    // MARK: - Mach-O patching

    /// Adds a new LC_LOAD_WEAK_DYLIB command referencing `dylibPath` to a thin
    /// arm64 Mach-O executable. Only writes into the zero-padded gap that
    /// already exists between the load commands and the first section's file
    /// data (present in virtually every Xcode-linked binary due to page
    /// alignment) — no bytes are shifted, so every other offset in the file
    /// stays valid and only the trailing code signature (already discarded and
    /// rebuilt by the caller) is invalidated.
    private static func insertLoadCommand(binaryURL: URL, dylibPath: String) throws {
        var data = try Data(contentsOf: binaryURL)
        guard data.count >= machHeaderSize else { throw DylibInjectorError.unsupportedBinaryFormat }

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }
        func setU32(_ offset: Int, _ value: UInt32) {
            withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }

        guard u32(0) == machMagic64 else { throw DylibInjectorError.unsupportedBinaryFormat }

        let ncmds = Int(u32(16))
        let sizeofcmds = Int(u32(20))

        // Walk existing load commands to find the earliest on-disk section
        // offset — everything between the end of the load commands and that
        // point is free (zero) padding we can safely write into.
        var minSectionOffset = Int.max
        var cmdOffset = machHeaderSize
        for _ in 0..<ncmds {
            guard cmdOffset + 8 <= data.count else { throw DylibInjectorError.unsupportedBinaryFormat }
            let cmd = u32(cmdOffset)
            let cmdsize = Int(u32(cmdOffset + 4))
            guard cmdsize >= 8, cmdOffset + cmdsize <= data.count else { throw DylibInjectorError.unsupportedBinaryFormat }

            if cmd == lcSegment64 {
                let nsects = Int(u32(cmdOffset + 64))
                let sectionsBase = cmdOffset + 72
                for i in 0..<nsects {
                    let sectionOffset = sectionsBase + i * 80
                    guard sectionOffset + 52 <= data.count else { break }
                    let fileOffset = Int(u32(sectionOffset + 48))
                    if fileOffset > 0 { minSectionOffset = min(minSectionOffset, fileOffset) }
                }
            }
            cmdOffset += cmdsize
        }
        guard minSectionOffset != Int.max else { throw DylibInjectorError.unsupportedBinaryFormat }

        // Build the new dylib_command: cmd, cmdsize, dylib{name_offset, timestamp,
        // current_version, compatibility_version}, then the NUL-terminated path,
        // padded to an 8-byte boundary (required alignment for load commands).
        var pathBytes = Array(dylibPath.utf8)
        pathBytes.append(0)
        let unpaddedSize = 24 + pathBytes.count
        let newCmdSize = (unpaddedSize + 7) / 8 * 8
        pathBytes.append(contentsOf: repeatElement(0, count: newCmdSize - unpaddedSize))

        var newCommand = Data(capacity: newCmdSize)
        for field: UInt32 in [lcLoadWeakDylib, UInt32(newCmdSize), 24, 0, 0, 0] {
            withUnsafeBytes(of: field) { newCommand.append(contentsOf: $0) }
        }
        newCommand.append(contentsOf: pathBytes)

        let insertOffset = machHeaderSize + sizeofcmds
        let available = minSectionOffset - insertOffset
        guard available >= newCommand.count else {
            throw DylibInjectorError.insufficientHeaderPadding(available: available, needed: newCommand.count)
        }

        data.replaceSubrange(insertOffset..<insertOffset + newCommand.count, with: newCommand)
        setU32(16, UInt32(ncmds + 1))
        setU32(20, UInt32(sizeofcmds + newCommand.count))

        try data.write(to: binaryURL)
    }
}
