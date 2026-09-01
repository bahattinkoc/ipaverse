//
//  SAPShims.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Runtime environment for the emulated Apple SAP binaries (CommerceKit /
//  CommerceCore / CoreFP): a custom malloc/free heap (this file), libc
//  string/memory primitives (SAPShims+Memory.swift), and macOS platform
//  stand-ins — CFString, IOKit registry stubs, objc_msgSend, dlopen/dlsym,
//  gettimeofday, sysctlbyname, pthread_once, arc4random, compare-and-swap
//  (SAPShims+Platform.swift). Faithful port of ipatool's
//  internal/sap/machine/{shims,shim_memory,shim_platform}.go (MIT licensed,
//  github.com/majd/ipatool).
//
//  Each shim occupies one 16-byte slot in a dedicated guest memory region
//  (`SAPMachineLayout.shimBase`); the slot holds a single `ret` (0xC3), and
//  a Unicorn code hook covering the whole region intercepts execution right
//  before that `ret` runs. The handler reads arguments from registers/stack
//  (SysV AMD64: RDI/RSI/RDX/RCX/R8/R9, then the stack) and writes a result
//  into RAX; once the hook returns, Unicorn executes the `ret` byte
//  normally, so a "call" from emulated code behaves exactly like calling a
//  real imported function.
//

import Foundation

typealias SAPShimHandler = () throws -> Void

struct SAPShimEntry {
    let name: String
    let handler: SAPShimHandler
}

struct SAPGuestAllocation {
    var size: UInt64
    let reserved: UInt64
}

struct SAPFreeBlock {
    var address: UInt64
    var size: UInt64
}

enum SAPShimsError: LocalizedError {
    case codeAreaFull
    case dataAreaFull
    case unknownServiceAddress(UInt64)
    case negativeArgumentIndex
    case unsupportedImport(String)
    case unknownPointer(String, UInt64)
    case allocationOverflow
    case allocationTooLarge(UInt64)
    case heapExhausted
    case transferTooLarge(UInt64)
    case checkedCopyExceedsDestination
    case checkedFillExceedsDestination
    case nullOutput(String)
    case guestAborted
    case stringTooLong(Int)
    case addressOverflow

    var errorDescription: String? {
        switch self {
        case .codeAreaFull: "SAP guest service code area is full"
        case .dataAreaFull: "SAP guest service data area is full"
        case .unknownServiceAddress(let address): "guest entered unknown service address 0x\(String(address, radix: 16))"
        case .negativeArgumentIndex: "negative guest argument index"
        case .unsupportedImport(let name): "guest called unsupported import \(name)"
        case .unknownPointer(let operation, let address): "\(operation) unknown pointer 0x\(String(address, radix: 16))"
        case .allocationOverflow: "allocation size overflows"
        case .allocationTooLarge(let size): "allocation size \(size) exceeds limit"
        case .heapExhausted: "guest heap exhausted"
        case .transferTooLarge(let size): "guest transfer size \(size) exceeds limit"
        case .checkedCopyExceedsDestination: "checked copy exceeds destination"
        case .checkedFillExceedsDestination: "checked fill exceeds destination"
        case .nullOutput(let what): "\(what) output is null"
        case .guestAborted: "guest aborted"
        case .stringTooLong(let maximum): "guest string exceeds \(maximum) bytes"
        case .addressOverflow: "string comparison address overflows"
        }
    }
}

final class SAPShims {
    let engine: SAPUnicornEngine
    var entries: [UInt64: SAPShimEntry] = [:]
    var symbols: [String: UInt64] = [:]
    private var codeCursor: UInt64
    private var dataCursor: UInt64
    private(set) var fault: Error?
    let coreExports: [String: UInt64]
    let icxs: [UInt8]
    var icxsOffset: Int = 0
    var errno: UInt64 = 0
    var heapCursor: UInt64 = 0
    var allocations: [UInt64: SAPGuestAllocation] = [:]
    var freeBlocks: [SAPFreeBlock] = []
    var iterator: UInt32 = 0
    private var hookHandle: uc_hook?

    static let argumentRegisters: [Int32] = [
        Int32(UC_X86_REG_RDI.rawValue),
        Int32(UC_X86_REG_RSI.rawValue),
        Int32(UC_X86_REG_RDX.rawValue),
        Int32(UC_X86_REG_RCX.rawValue),
        Int32(UC_X86_REG_R8.rawValue),
        Int32(UC_X86_REG_R9.rawValue),
    ]

    init(engine: SAPUnicornEngine, coreExports: [String: UInt64], icxs: [UInt8]) throws {
        self.engine = engine
        self.coreExports = coreExports
        self.icxs = icxs
        self.codeCursor = SAPMachineLayout.shimBase
        self.dataCursor = SAPMachineLayout.shimBase + SAPMachineLayout.shimCodeSize

        try engine.memMap(address: SAPMachineLayout.shimBase, size: SAPMachineLayout.shimSize)

        try registerMemoryServices()
        try registerPlatformServices()

        hookHandle = try engine.addCodeHook(
            begin: SAPMachineLayout.shimBase,
            end: SAPMachineLayout.shimBase + SAPMachineLayout.shimCodeSize - 1
        ) { [weak self] address, _ in
            self?.dispatch(address: address)
        }
    }

    func close() {
        guard let hookHandle else { return }
        self.hookHandle = nil
        engine.removeCodeHook(hookHandle)
    }

    func resolve(_ name: String) throws -> UInt64 {
        if let address = symbols[name] { return address }
        return try addFunction(name) {
            throw SAPShimsError.unsupportedImport(name)
        }
    }

    func addAliases(_ names: [String], _ handler: @escaping SAPShimHandler) throws {
        for name in names {
            _ = try addFunction(name, handler)
        }
    }

    @discardableResult
    func addFunction(_ name: String, _ handler: @escaping SAPShimHandler) throws -> UInt64 {
        if let address = symbols[name] { return address }

        guard codeCursor + SAPMachineLayout.shimSlotSize <= SAPMachineLayout.shimBase + SAPMachineLayout.shimCodeSize else {
            throw SAPShimsError.codeAreaFull
        }

        let address = codeCursor
        codeCursor += SAPMachineLayout.shimSlotSize

        try engine.memWrite(address: address, data: [0xC3])

        entries[address] = SAPShimEntry(name: name, handler: handler)
        symbols[name] = address
        return address
    }

    @discardableResult
    func addData(_ name: String, _ data: [UInt8]) throws -> UInt64 {
        if let address = symbols[name] { return address }

        dataCursor = SAPMachineLayout.align(dataCursor, 8)
        guard dataCursor + UInt64(data.count) <= SAPMachineLayout.shimBase + SAPMachineLayout.shimSize else {
            throw SAPShimsError.dataAreaFull
        }

        let address = dataCursor
        dataCursor += UInt64(max(data.count, 8))

        try engine.memWrite(address: address, data: data)
        symbols[name] = address
        return address
    }

    private func dispatch(address: UInt64) {
        guard let entry = entries[address] else {
            fail(SAPShimsError.unknownServiceAddress(address))
            return
        }

        do {
            try entry.handler()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        if fault == nil { fault = error }
        try? engine.stop()
    }

    func resetFault() {
        fault = nil
    }

    // MARK: - Argument/result access

    func argument(_ index: Int) throws -> UInt64 {
        if index >= 0, index < Self.argumentRegisters.count {
            return try engine.regRead(Self.argumentRegisters[index])
        }
        guard index >= 0 else { throw SAPShimsError.negativeArgumentIndex }

        let stack = try engine.regRead(Int32(UC_X86_REG_RSP.rawValue))
        let offset = UInt64(index - Self.argumentRegisters.count) * 8
        let data = try engine.memRead(address: stack + 8 + offset, size: 8)
        return Self.u64(data)
    }

    func setResult(_ value: UInt64) throws {
        try engine.regWrite(Int32(UC_X86_REG_RAX.rawValue), value: value)
    }

    func readUInt32(_ address: UInt64) throws -> UInt32 {
        Self.u32(try engine.memRead(address: address, size: 4))
    }

    func writeUInt32(_ address: UInt64, _ value: UInt32) throws {
        try engine.memWrite(address: address, data: Self.bytes(u32: value))
    }

    func readUInt64(_ address: UInt64) throws -> UInt64 {
        Self.u64(try engine.memRead(address: address, size: 8))
    }

    func writeUInt64(_ address: UInt64, _ value: UInt64) throws {
        try engine.memWrite(address: address, data: Self.bytes(u64: value))
    }

    func readCString(_ address: UInt64) throws -> String {
        let maximum = 4096
        var value: [UInt8] = []
        value.reserveCapacity(64)
        while value.count < maximum {
            let byte = try engine.memRead(address: address + UInt64(value.count), size: 1)
            if byte[0] == 0 { return String(decoding: value, as: UTF8.self) }
            value.append(byte[0])
        }
        throw SAPShimsError.stringTooLong(maximum)
    }

    static func checkedSize(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max), value <= SAPMachineLayout.maxGuestTransfer else {
            throw SAPShimsError.transferTooLarge(value)
        }
        return Int(value)
    }

    // MARK: - Byte helpers

    static func u32(_ data: [UInt8]) -> UInt32 {
        UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
    }

    static func u64(_ data: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(data[index]) << (8 * index) }
        return value
    }

    static func bytes(u32 value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    static func bytes(u64 value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }
}
