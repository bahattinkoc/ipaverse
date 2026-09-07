//
//  Data+SafeRead.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//

import Foundation

extension Data {
    /// Reads a little-endian-in-memory `UInt32` at `offset` via `copyBytes`
    /// rather than `UnsafeRawBufferPointer.load(fromByteOffset:as:)`.
    ///
    /// `.load(fromByteOffset:)` traps with "Fatal error: load from
    /// misaligned raw pointer" whenever `baseAddress + offset` isn't a
    /// multiple of 4 — a real risk here, since every offset comes from
    /// parsing a Mach-O binary we don't control (fat-header slice offsets,
    /// section tables, accumulated load-command sizes), not from a Swift
    /// type layout the compiler can guarantee is aligned. `copyBytes` does a
    /// plain memcpy into a properly-aligned local, so it has identical
    /// result semantics with no alignment requirement on the source.
    ///
    /// Implemented via `subdata` rather than `copyBytes(to:from:)` into a
    /// stack local — the latter trips a Swift 6 frontend crash
    /// ("failed to produce diagnostic for expression") on some toolchains
    /// when used inside `withUnsafeMutableBytes(of:)`. `subdata` allocates a
    /// fresh, independently-owned 4-byte buffer, so reading at its own
    /// offset 0 is always aligned regardless of the original offset.
    func safeUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let slice = subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    /// Same rationale as `safeUInt32(at:)`, for 8-byte fields (segment
    /// `vmaddr`/`vmsize`/`fileoff`/`filesize`, section `addr`/`size`).
    func safeUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let slice = subdata(in: offset..<(offset + 8))
        return slice.withUnsafeBytes { $0.load(as: UInt64.self) }
    }

    /// Reads a fixed-length ASCII field (e.g. Mach-O `segname`/`sectname`,
    /// 16 bytes, NUL-padded) and trims the trailing NULs.
    func safeFixedString(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        let slice = subdata(in: offset..<(offset + length))
        guard let raw = String(data: slice, encoding: .ascii) else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
