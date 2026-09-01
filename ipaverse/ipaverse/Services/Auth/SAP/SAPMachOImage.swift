//
//  SAPMachOImage.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Minimal x86-64 Mach-O loader: just enough to parse segments, resolve
//  exported symbols, apply dyld rebase/bind fixups against a caller-chosen
//  load address, and write the relocated bytes into emulator memory.
//
//  Structure-for-structure port of ipatool's internal/sap/machimage
//  (MIT licensed, github.com/majd/ipatool), itself built on
//  github.com/blacktop/go-macho — this only reimplements the subset that
//  reference actually needs: LC_SEGMENT_64, LC_SYMTAB, and the classic
//  LC_DYLD_INFO(_ONLY) rebase/bind opcode streams (the format these 2013
//  binaries use — not the newer LC_DYLD_CHAINED_FIXUPS format). Confirmed
//  empirically against the real downloaded files (see SAPAssets):
//  CommerceKit is a thin MH_MAGIC_64 x86-64 dylib; CommerceCore and CoreFP
//  are FAT_MAGIC universal binaries containing an x86-64 slice; CoreFP.icxs
//  is not a Mach-O at all and is handed to the shim layer as opaque bytes.
//

import Foundation

struct SAPMachOSegment {
    let name: String
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let fileSize: UInt64
}

/// What ``SAPMachOImage/load(into:)`` writes relocated segment bytes into.
/// Implemented by the Unicorn engine wrapper (Phase 3).
protocol SAPMachineMemory {
    func map(address: UInt64, size: UInt64) throws
    func write(address: UInt64, data: [UInt8]) throws
}

enum SAPMachOError: LocalizedError {
    case notMachO
    case unsupportedArchitecture
    case noX86_64Slice
    case truncated(String)
    case unsupportedRebaseType(UInt8)
    case unsupportedBindType(UInt8)
    case symbolNotFound(String)
    case alreadyRelocated
    case notRelocated
    case segmentNotFound(String)
    case fixupOutOfRange(String)
    case malformedOpcode(String)

    var errorDescription: String? {
        switch self {
        case .notMachO: "Not a Mach-O file"
        case .unsupportedArchitecture: "Expected an x86-64 Mach-O image"
        case .noX86_64Slice: "Universal binary has no x86-64 slice"
        case .truncated(let what): "Mach-O file is truncated (\(what))"
        case .unsupportedRebaseType(let type): "Unsupported Mach-O rebase type \(type)"
        case .unsupportedBindType(let type): "Unsupported Mach-O bind type \(type)"
        case .symbolNotFound(let name): "Symbol \(name) not found"
        case .alreadyRelocated: "Image is already relocated"
        case .notRelocated: "Image must be relocated before loading"
        case .segmentNotFound(let what): "Segment \(what) not found"
        case .fixupOutOfRange(let what): "Fixup out of range (\(what))"
        case .malformedOpcode(let what): "Malformed dyld opcode stream (\(what))"
        }
    }
}

final class SAPMachOImage {
    private struct Bind {
        let segmentIndex: Int
        let segmentOffset: UInt64
        let symbolName: String
        let addend: Int64
    }

    private struct Rebase {
        let segmentIndex: Int
        let segmentOffset: UInt64
    }

    private static let pointerSize = 8
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let machMagic64: UInt32 = 0xfeed_facf
    // FAT_MAGIC (0xcafebabe) is stored big-endian on disk; reading the
    // first 4 bytes little-endian yields this value.
    private static let fatMagicAsLittleEndian: UInt32 = 0xbeba_feca

    let name: String
    private var data: [UInt8]
    private let base: UInt64
    private(set) var segments: [SAPMachOSegment] = []
    private var symbols: [String: UInt64] = [:]
    private var rebases: [Rebase] = []
    private var binds: [Bind] = []
    private var relocated = false
    private var loadedBase: UInt64 = 0

    init(name: String, data inputData: Data) throws {
        self.name = name
        self.data = Array(try Self.extractX86_64Slice(inputData))

        guard data.count >= 32 else { throw SAPMachOError.truncated("header") }
        guard Self.u32(data, 0) == Self.machMagic64 else { throw SAPMachOError.notMachO }
        guard Self.u32(data, 4) == Self.cpuTypeX86_64 else { throw SAPMachOError.unsupportedArchitecture }

        let ncmds = Int(Self.u32(data, 16))
        let sizeofcmds = Int(Self.u32(data, 20))
        guard data.count >= 32 + sizeofcmds else { throw SAPMachOError.truncated("load commands") }

        var cursor = 32
        var symtabOffset = 0, nsyms = 0, strtabOffset = 0, strtabSize = 0
        var rebaseOff = 0, rebaseSize = 0, bindOff = 0, bindSize = 0
        var lazyBindOff = 0, lazyBindSize = 0

        for _ in 0..<ncmds {
            guard cursor + 8 <= data.count else { throw SAPMachOError.truncated("load command header") }
            let cmd = Self.u32(data, cursor)
            let cmdsize = Int(Self.u32(data, cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= data.count else {
                throw SAPMachOError.truncated("load command body")
            }

            switch cmd {
            case 0x19: // LC_SEGMENT_64
                let segname = Self.fixedString(data, cursor + 8, length: 16)
                segments.append(SAPMachOSegment(
                    name: segname,
                    address: Self.u64(data, cursor + 24),
                    size: Self.u64(data, cursor + 32),
                    fileOffset: Self.u64(data, cursor + 40),
                    fileSize: Self.u64(data, cursor + 48)
                ))

            case 0x2: // LC_SYMTAB
                symtabOffset = Int(Self.u32(data, cursor + 8))
                nsyms = Int(Self.u32(data, cursor + 12))
                strtabOffset = Int(Self.u32(data, cursor + 16))
                strtabSize = Int(Self.u32(data, cursor + 20))

            case 0x22, 0x8000_0022: // LC_DYLD_INFO / LC_DYLD_INFO_ONLY
                rebaseOff = Int(Self.u32(data, cursor + 8))
                rebaseSize = Int(Self.u32(data, cursor + 12))
                bindOff = Int(Self.u32(data, cursor + 16))
                bindSize = Int(Self.u32(data, cursor + 20))
                lazyBindOff = Int(Self.u32(data, cursor + 32))
                lazyBindSize = Int(Self.u32(data, cursor + 36))

            default:
                break
            }

            cursor += cmdsize
        }

        base = segments
            .filter { $0.name != "__PAGEZERO" && $0.size > 0 }
            .map(\.address)
            .min() ?? 0

        if nsyms > 0 {
            symbols = try Self.parseSymbols(data, symtabOffset: symtabOffset, nsyms: nsyms, strtabOffset: strtabOffset, strtabSize: strtabSize)
        }
        if rebaseSize > 0 {
            rebases = try Self.parseRebase(data, offset: rebaseOff, size: rebaseSize)
        }
        if bindSize > 0 {
            binds = try Self.parseBind(data, offset: bindOff, size: bindSize)
        }
        if lazyBindSize > 0 {
            // Lazy-bound pointer slots (__DATA,__la_symbol_ptr) are left
            // pointing at dyld's real __stub_helper trampolines unless
            // these are resolved too — confirmed empirically: without this,
            // emulated execution eventually falls through to the real
            // dyld_stub_binder import slot and our shim for it (aliased to
            // `abort`, matching ipatool's shim_platform.go) fires. Since we
            // aren't a real lazy dynamic linker, resolving every lazy bind
            // immediately (as if it were a regular bind) is the correct
            // simplification — this mirrors what go-macho's `GetBindInfo()`
            // apparently already does internally for ipatool's reference
            // implementation.
            binds += try Self.parseBind(data, offset: lazyBindOff, size: lazyBindSize)
        }
    }

    // MARK: - Export

    func export(_ symbolName: String, loadBase: UInt64) throws -> UInt64 {
        guard let address = symbols[symbolName] else {
            throw SAPMachOError.symbolNotFound("\(symbolName) in \(name)")
        }
        guard address >= base else {
            throw SAPMachOError.fixupOutOfRange("symbol \(symbolName) precedes \(name)'s base")
        }
        return loadBase + (address - base)
    }

    // MARK: - Relocate

    func relocate(loadBase: UInt64, resolve: (String) throws -> UInt64) throws {
        guard !relocated else { throw SAPMachOError.alreadyRelocated }

        for rebase in rebases {
            let offset = try fileOffset(segmentIndex: rebase.segmentIndex, segmentOffset: rebase.segmentOffset, size: Self.pointerSize)
            let currentValue = Self.u64(data, offset)
            guard currentValue >= base else {
                throw SAPMachOError.fixupOutOfRange("rebase in \(name) is below its image base")
            }
            Self.setU64(&data, offset, value: loadBase + (currentValue - base))
        }

        for bind in binds {
            let offset = try fileOffset(segmentIndex: bind.segmentIndex, segmentOffset: bind.segmentOffset, size: Self.pointerSize)
            let resolved = try resolve(bind.symbolName)
            let value = UInt64(bitPattern: Int64(bitPattern: resolved) &+ bind.addend)
            Self.setU64(&data, offset, value: value)
        }

        relocated = true
        loadedBase = loadBase
    }

    // MARK: - Load

    func load(into memory: SAPMachineMemory) throws {
        guard relocated else { throw SAPMachOError.notRelocated }

        var span: UInt64 = 0
        for segment in segments where segment.name != "__PAGEZERO" && segment.size > 0 {
            guard segment.address >= base else {
                throw SAPMachOError.fixupOutOfRange("segment \(segment.name) in \(name) precedes its base")
            }
            span = max(span, (segment.address - base) + segment.size)
        }
        span = Self.align(span, 0x1000)
        guard span > 0 else { throw SAPMachOError.truncated("\(name) has no loadable segments") }

        try memory.map(address: loadedBase, size: span)

        for segment in segments where segment.name != "__PAGEZERO" && segment.fileSize > 0 {
            let end = Int(segment.fileOffset) + Int(segment.fileSize)
            guard end <= data.count else { throw SAPMachOError.truncated("segment \(segment.name) data in \(name)") }
            let address = loadedBase + (segment.address - base)
            try memory.write(address: address, data: Array(data[Int(segment.fileOffset)..<end]))
        }
    }

    // MARK: - Fixup addressing

    private func fileOffset(segmentIndex: Int, segmentOffset: UInt64, size: Int) throws -> Int {
        guard segmentIndex >= 0, segmentIndex < segments.count else {
            throw SAPMachOError.segmentNotFound("index \(segmentIndex) in \(name)")
        }
        let segment = segments[segmentIndex]

        // `segmentOffset` originates from opcode-stream arithmetic on
        // untrusted structure; use wrapping math and an explicit magnitude
        // check so a bad value throws a catchable error instead of
        // trapping on overflow or on an out-of-range Int(...) conversion.
        guard segmentOffset <= UInt64(Int.max), UInt64(size) <= UInt64(Int.max) else {
            throw SAPMachOError.fixupOutOfRange("fixup offset \(segmentOffset) is absurdly large in \(name)")
        }
        let end = segmentOffset &+ UInt64(size)
        guard end >= segmentOffset, end <= segment.size, end <= segment.fileSize else {
            throw SAPMachOError.fixupOutOfRange("fixup at \(segmentOffset) exceeds segment \(segment.name) in \(name)")
        }

        let result = Int(segment.fileOffset) &+ Int(segmentOffset)
        guard result >= 0, result &+ size <= data.count else {
            throw SAPMachOError.fixupOutOfRange("fixup at \(result) exceeds \(name)'s file data")
        }
        return result
    }

    // MARK: - Fat/thin slicing

    private static func extractX86_64Slice(_ input: Data) throws -> Data {
        guard input.count >= 8 else { throw SAPMachOError.truncated("too short for any header") }

        let prefix = Array(input.prefix(4))
        guard u32(prefix, 0) == fatMagicAsLittleEndian else {
            return input
        }

        let archCount = Int(u32BE(input, 4))
        var cursor = 8
        for _ in 0..<archCount {
            guard cursor + 20 <= input.count else { throw SAPMachOError.truncated("fat_arch") }
            let cputype = u32BE(input, cursor)
            let offset = u32BE(input, cursor + 8)
            let size = u32BE(input, cursor + 12)
            if cputype == cpuTypeX86_64 {
                let start = input.startIndex + Int(offset)
                let end = start + Int(size)
                guard end <= input.endIndex, start <= end else { throw SAPMachOError.truncated("fat_arch slice") }
                return input.subdata(in: start..<end)
            }
            cursor += 20
        }
        throw SAPMachOError.noX86_64Slice
    }

    // MARK: - Symbol table

    private static func parseSymbols(_ data: [UInt8], symtabOffset: Int, nsyms: Int, strtabOffset: Int, strtabSize: Int) throws -> [String: UInt64] {
        let entrySize = 16 // nlist_64: n_strx(4) n_type(1) n_sect(1) n_desc(2) n_value(8)
        var symbols: [String: UInt64] = [:]

        for index in 0..<nsyms {
            let base = symtabOffset + index * entrySize
            guard base + entrySize <= data.count else { throw SAPMachOError.truncated("symtab entry \(index)") }

            let strx = Int(u32(data, base))
            let value = u64(data, base + 8)
            guard strx > 0, strtabOffset + strx < data.count else { continue }

            let name = cString(data, at: strtabOffset + strx, limit: min(strtabOffset + strtabSize, data.count))
            if !name.isEmpty {
                symbols[name] = value
            }
        }

        return symbols
    }

    // MARK: - Rebase opcodes (classic LC_DYLD_INFO format)

    private static func parseRebase(_ data: [UInt8], offset: Int, size: Int) throws -> [Rebase] {
        guard offset >= 0, offset + size <= data.count else { throw SAPMachOError.truncated("rebase opcodes") }

        var result: [Rebase] = []
        var cursor = offset
        let end = offset + size
        var type: UInt8 = 0
        var segmentIndex = 0
        var segmentOffset: UInt64 = 0

        func emit() throws {
            guard type == 1 else { throw SAPMachOError.unsupportedRebaseType(type) } // REBASE_TYPE_POINTER
            result.append(Rebase(segmentIndex: segmentIndex, segmentOffset: segmentOffset))
            segmentOffset &+= UInt64(pointerSize)
        }

        while cursor < end {
            let byte = data[cursor]; cursor += 1
            let opcode = byte & 0xF0
            let imm = byte & 0x0F

            switch opcode {
            case 0x00: // REBASE_OPCODE_DONE
                cursor = end
            case 0x10: // SET_TYPE_IMM
                type = imm
            case 0x20: // SET_SEGMENT_AND_OFFSET_ULEB
                segmentIndex = Int(imm)
                segmentOffset = try readULEB(data, &cursor, end)
            case 0x30: // ADD_ADDR_ULEB
                segmentOffset &+= try readULEB(data, &cursor, end)
            case 0x40: // ADD_ADDR_IMM_SCALED
                segmentOffset &+= UInt64(imm) * UInt64(pointerSize)
            case 0x50: // DO_REBASE_IMM_TIMES
                for _ in 0..<imm { try emit() }
            case 0x60: // DO_REBASE_ULEB_TIMES
                let count = try readULEB(data, &cursor, end)
                for _ in 0..<count { try emit() }
            case 0x70: // DO_REBASE_ADD_ADDR_ULEB
                try emit()
                segmentOffset &+= try readULEB(data, &cursor, end)
            case 0x80: // DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
                let count = try readULEB(data, &cursor, end)
                let skip = try readULEB(data, &cursor, end)
                for _ in 0..<count {
                    try emit()
                    segmentOffset &+= skip
                }
            default:
                throw SAPMachOError.malformedOpcode("rebase opcode 0x\(String(byte, radix: 16))")
            }
        }

        return result
    }

    // MARK: - Bind opcodes (classic LC_DYLD_INFO format)

    private static func parseBind(_ data: [UInt8], offset: Int, size: Int) throws -> [Bind] {
        guard offset >= 0, offset + size <= data.count else { throw SAPMachOError.truncated("bind opcodes") }

        var result: [Bind] = []
        var cursor = offset
        let end = offset + size
        var type: UInt8 = 1
        var segmentIndex = 0
        var segmentOffset: UInt64 = 0
        var symbolName = ""
        var addend: Int64 = 0

        func emit() throws {
            guard type == 1 else { throw SAPMachOError.unsupportedBindType(type) } // BIND_TYPE_POINTER
            result.append(Bind(segmentIndex: segmentIndex, segmentOffset: segmentOffset, symbolName: symbolName, addend: addend))
            segmentOffset &+= UInt64(pointerSize)
        }

        while cursor < end {
            let byte = data[cursor]; cursor += 1
            let opcode = byte & 0xF0
            let imm = byte & 0x0F

            switch opcode {
            case 0x00: // BIND_OPCODE_DONE
                // In the *lazy* bind stream dyld emits one DONE per symbol
                // (each is its own independently-triggerable mini-program),
                // not one at the very end like the regular bind stream —
                // treating this as "stop parsing" would silently drop every
                // lazy-bound symbol after the first. Just fall through to
                // the next opcode; the surrounding `while cursor < end`
                // bound already terminates correctly either way.
                break
            case 0x10: // SET_DYLIB_ORDINAL_IMM — single implicit dylib, ignored
                break
            case 0x20: // SET_DYLIB_ORDINAL_ULEB
                _ = try readULEB(data, &cursor, end)
            case 0x30: // SET_DYLIB_SPECIAL_IMM
                break
            case 0x40: // SET_SYMBOL_TRAILING_FLAGS_IMM — imm flags, then NUL-terminated name
                var nameBytes: [UInt8] = []
                while cursor < end, data[cursor] != 0 {
                    nameBytes.append(data[cursor])
                    cursor += 1
                }
                guard cursor < end else { throw SAPMachOError.malformedOpcode("unterminated bind symbol name") }
                cursor += 1 // skip the NUL
                symbolName = String(decoding: nameBytes, as: UTF8.self)
            case 0x50: // SET_TYPE_IMM
                type = imm
            case 0x60: // SET_ADDEND_SLEB
                addend = try readSLEB(data, &cursor, end)
            case 0x70: // SET_SEGMENT_AND_OFFSET_ULEB
                segmentIndex = Int(imm)
                segmentOffset = try readULEB(data, &cursor, end)
            case 0x80: // ADD_ADDR_ULEB
                segmentOffset &+= try readULEB(data, &cursor, end)
            case 0x90: // DO_BIND
                try emit()
            case 0xA0: // DO_BIND_ADD_ADDR_ULEB
                try emit()
                segmentOffset &+= try readULEB(data, &cursor, end)
            case 0xB0: // DO_BIND_ADD_ADDR_IMM_SCALED
                try emit()
                segmentOffset &+= UInt64(imm) * UInt64(pointerSize)
            case 0xC0: // DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                let count = try readULEB(data, &cursor, end)
                let skip = try readULEB(data, &cursor, end)
                for _ in 0..<count {
                    try emit()
                    segmentOffset &+= skip
                }
            default:
                throw SAPMachOError.malformedOpcode("bind opcode 0x\(String(byte, radix: 16))")
            }
        }

        return result
    }

    // MARK: - LEB128

    /// LEB128 values here only ever encode file offsets/sizes, which fit
    /// comfortably in a handful of bytes — a stream needing more than 10
    /// (70 bits worth) means opcode parsing has desynced. Bailing out with
    /// a catchable error here, instead of letting `shift`/`result` grow
    /// without bound, is what turns a later "arithmetic overflow" runtime
    /// trap (fatal, uncatchable) into a normal thrown `SAPMachOError`.
    private static func readULEB(_ data: [UInt8], _ cursor: inout Int, _ end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard cursor < end else { throw SAPMachOError.malformedOpcode("truncated ULEB128") }
            guard shift < 64 else { throw SAPMachOError.malformedOpcode("oversized ULEB128 (opcode stream likely desynced)") }
            let byte = data[cursor]; cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    private static func readSLEB(_ data: [UInt8], _ cursor: inout Int, _ end: Int) throws -> Int64 {
        var result: Int64 = 0
        var shift: Int64 = 0
        var byte: UInt8 = 0
        repeat {
            guard cursor < end else { throw SAPMachOError.malformedOpcode("truncated SLEB128") }
            guard shift < 64 else { throw SAPMachOError.malformedOpcode("oversized SLEB128 (opcode stream likely desynced)") }
            byte = data[cursor]; cursor += 1
            result |= Int64(byte & 0x7F) << shift
            shift += 7
        } while byte & 0x80 != 0
        if shift < 64, byte & 0x40 != 0 {
            result |= -(Int64(1) << shift)
        }
        return result
    }

    // MARK: - Raw byte helpers

    private static func u32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func u32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16) | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func u64(_ data: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << (8 * index)
        }
        return value
    }

    private static func setU64(_ data: inout [UInt8], _ offset: Int, value: UInt64) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> (8 * index)) & 0xFF)
        }
    }

    private static func fixedString(_ data: [UInt8], _ offset: Int, length: Int) -> String {
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func cString(_ data: [UInt8], at offset: Int, limit: Int) -> String {
        var end = offset
        while end < limit, data[end] != 0 { end += 1 }
        return String(decoding: data[offset..<end], as: UTF8.self)
    }

    private static func align(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
