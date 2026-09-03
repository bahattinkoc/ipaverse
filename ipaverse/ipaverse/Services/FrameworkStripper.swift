//
//  FrameworkStripper.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 3.09.2026.
//

import Foundation

enum FrameworkStripperError: LocalizedError {
    case unsupportedBinaryFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedBinaryFormat:
            "Framework removal only supports thin 64-bit arm64 Mach-O executables."
        }
    }
}

/// Removes a bundled framework/dylib an app doesn't strictly need to launch —
/// typically a 3rd-party SDK whose required capability (Push, App Groups, ...)
/// isn't available under the identity being used to resign, and which
/// hard-crashes instead of degrading gracefully when that capability is
/// missing (e.g. NetmeraCore fatalError-ing when its App Group container is
/// unavailable). Framework-agnostic — takes whatever names the caller found
/// responsible for a given crash, nothing here is specific to any one SDK.
///
/// Deletes the framework/dylib from the bundle *and* strips the
/// LC_LOAD_DYLIB/LC_LOAD_WEAK_DYLIB/LC_REEXPORT_DYLIB command referencing it
/// from every Mach-O that links it directly (main executable + each
/// PlugIns/*.appex's own executable) — leaving the file removed but the load
/// command in place just changes the crash from "could not register fairplay
/// decryption" to "no such file", same launch-time failure.
struct FrameworkStripper {

    private static let machHeaderSize = 32
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let lcLoadDylib: UInt32 = 0x0C
    private static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    private static let lcReexportDylib: UInt32 = 0x8000_001F

    /// `frameworkNames` are bare names without extension (e.g. "NetmeraCore",
    /// matching both NetmeraCore.framework and NetmeraCore.dylib).
    static func remove(frameworkNames: [String], from appURL: URL, progress: @escaping (String) -> Void) throws {
        guard !frameworkNames.isEmpty else { return }
        let fm = FileManager.default

        var bundleRoots = [appURL]
        if let appexes = try? fm.contentsOfDirectory(at: appURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil) {
            bundleRoots += appexes.filter { $0.pathExtension == "appex" }
        }

        for bundleRoot in bundleRoots {
            let executableURL = bundleRoot.appendingPathComponent(bundleRoot.deletingPathExtension().lastPathComponent)
            if fm.fileExists(atPath: executableURL.path) {
                for name in frameworkNames {
                    if (try? removeLoadCommand(binaryURL: executableURL, frameworkName: name)) == true {
                        progress("Unlinked \(name) from \(bundleRoot.lastPathComponent)")
                    }
                }
            }

            let frameworksDir = bundleRoot.appendingPathComponent("Frameworks")
            for name in frameworkNames {
                let fwURL = frameworksDir.appendingPathComponent("\(name).framework")
                let dylibURL = frameworksDir.appendingPathComponent("\(name).dylib")
                if fm.fileExists(atPath: fwURL.path) {
                    try? fm.removeItem(at: fwURL)
                    progress("Deleted \(name).framework from \(bundleRoot.lastPathComponent)")
                }
                if fm.fileExists(atPath: dylibURL.path) {
                    try? fm.removeItem(at: dylibURL)
                    progress("Deleted \(name).dylib from \(bundleRoot.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Mach-O patching

    /// Removes the load command referencing `frameworkName`, if present.
    /// Returns whether a command was actually removed (a binary simply not
    /// linking this framework isn't an error — most won't).
    @discardableResult
    private static func removeLoadCommand(binaryURL: URL, frameworkName: String) throws -> Bool {
        var data = try Data(contentsOf: binaryURL)
        guard data.count >= machHeaderSize else { throw FrameworkStripperError.unsupportedBinaryFormat }

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }
        func setU32(_ offset: Int, _ value: UInt32) {
            withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }

        guard u32(0) == machMagic64 else { throw FrameworkStripperError.unsupportedBinaryFormat }

        var ncmds = Int(u32(16))
        var sizeofcmds = Int(u32(20))

        // Frameworks/dylibs are referenced by their embedded install-name
        // path, e.g. "@rpath/NetmeraCore.framework/NetmeraCore" — match on
        // the trailing path so unrelated dylibs with a similar prefix aren't
        // touched.
        let needleFramework = "/\(frameworkName).framework/\(frameworkName)"
        let needleDylib = "/\(frameworkName).dylib"

        var removedAny = false
        var cmdOffset = machHeaderSize
        while cmdOffset < machHeaderSize + sizeofcmds {
            guard cmdOffset + 8 <= data.count else { break }
            let cmd = u32(cmdOffset)
            let cmdsize = Int(u32(cmdOffset + 4))
            guard cmdsize >= 8, cmdOffset + cmdsize <= data.count else { break }

            var matched = false
            if cmd == lcLoadDylib || cmd == lcLoadWeakDylib || cmd == lcReexportDylib {
                let nameOffset = Int(u32(cmdOffset + 8))
                let nameStart = cmdOffset + nameOffset
                if nameOffset >= 8, nameStart < cmdOffset + cmdsize, nameStart < data.count {
                    let searchEnd = min(cmdOffset + cmdsize, data.count)
                    let nameEnd = data[nameStart..<searchEnd].firstIndex(of: 0) ?? searchEnd
                    let pathString = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
                    matched = pathString.hasSuffix(needleFramework) || pathString.hasSuffix(needleDylib)
                }
            }

            if matched {
                // Shift every following command back by cmdsize (only within
                // the load-commands region — never touches segment data,
                // same slack-space guarantee DylibInjector relies on when
                // adding a command), then zero the freed tail.
                let tailStart = cmdOffset + cmdsize
                let tailLength = (machHeaderSize + sizeofcmds) - tailStart
                if tailLength > 0 {
                    let tail = data.subdata(in: tailStart..<tailStart + tailLength)
                    data.replaceSubrange(cmdOffset..<cmdOffset + tailLength, with: tail)
                }
                let zeroStart = cmdOffset + tailLength
                data.resetBytes(in: zeroStart..<zeroStart + cmdsize)

                ncmds -= 1
                sizeofcmds -= cmdsize
                removedAny = true
                continue // re-check the same offset — it now holds the next command
            }

            cmdOffset += cmdsize
        }

        guard removedAny else { return false }

        setU32(16, UInt32(ncmds))
        setU32(20, UInt32(sizeofcmds))
        try data.write(to: binaryURL)
        return true
    }
}
