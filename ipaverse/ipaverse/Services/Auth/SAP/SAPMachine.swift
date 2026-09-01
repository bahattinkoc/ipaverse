//
//  SAPMachine.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Orchestrates the emulated Apple SAP guest: loads and relocates the three
//  real Mach-O images (CoreFP, CommerceCore, CommerceKit) at fixed base
//  addresses, wires their imports to each other's exports or to
//  ``SAPShims``, and exposes the four guest entry points
//  (initialize/exchange/sign/teardown) through the exact SysV AMD64
//  register+stack calling convention the real binaries expect. Faithful
//  port of ipatool's internal/sap/machine/machine.go (MIT licensed,
//  github.com/majd/ipatool).
//

import Foundation

extension SAPUnicornEngine: SAPMachineMemory {
    func map(address: UInt64, size: UInt64) throws { try memMap(address: address, size: size) }
    func write(address: UInt64, data: [UInt8]) throws { try memWrite(address: address, data: data) }
}

enum SAPMachineError: LocalizedError {
    case exportNotFound(String, String)
    case unexpectedStatus(String, Int32)
    case nullContext
    case guestStoppedUnexpectedly(UInt64)
    case scratchExhausted
    case outputTooLarge(UInt64)
    case nullOutputPointer
    case entryPointMissing(String)
    case invalidHardwareID

    var errorDescription: String? {
        switch self {
        case .invalidHardwareID: "SAP hardware ID must contain between 1 and 20 bytes"
        case .exportNotFound(let symbol, let image): "resolve \(symbol) export in \(image): not found"
        case .unexpectedStatus(let operation, let status): "SAP \(operation) returned \(status)"
        case .nullContext: "SAP initialization returned a null context"
        case .guestStoppedUnexpectedly(let address): "SAP guest stopped unexpectedly at 0x\(String(address, radix: 16))"
        case .scratchExhausted: "SAP guest scratch space exhausted"
        case .outputTooLarge(let length): "SAP output is \(length) bytes, exceeds the maximum"
        case .nullOutputPointer: "SAP returned a null output pointer"
        case .entryPointMissing(let name): "SAP guest entry point \(name) is unavailable"
        }
    }
}

private struct SAPEntryPoints {
    let initialize: UInt64
    let exchange: UInt64
    let sign: UInt64
    let teardown: UInt64
    let dispose: UInt64
}

final class SAPMachine {
    private static let sapGuestTimeout: TimeInterval = 60

    private static let coreExportNames = [
        "_WIn9UJ86JKdV4dM", "_X46O5IeS", "_YlCJ3lg", "_dku592fbFAj", "_fdjkDSAFjklaf2s", "_lxpgvVMLd0S7uRl",
    ]
    private static let entryNames = [
        "_cp2g1b9ro", "_Mib5yocT", "_Fc3vhtJDvr", "_IPaI1oem5iL", "_jEHf8Xzsv8K",
    ]

    private let engine: SAPUnicornEngine
    private let shims: SAPShims
    private let entry: SAPEntryPoints
    private var scratchCursor: UInt64 = 0
    private var closed = false

    init(bundle: SAPAssetBundle) throws {
        let coreFP = try SAPMachOImage(name: "CoreFP", data: bundle.coreFP)
        let commerceCore = try SAPMachOImage(name: "CommerceCore", data: bundle.commerceCore)
        let commerceKit = try SAPMachOImage(name: "CommerceKit", data: bundle.commerceKit)

        var exports: [String: UInt64] = [:]
        for name in Self.coreExportNames {
            exports[name] = try coreFP.export(name, loadBase: SAPMachineLayout.coreFPBase)
        }
        exports["_get_mac_address"] = try commerceCore.export("_get_mac_address", loadBase: SAPMachineLayout.commerceBase)

        var resolvedEntries: [String: UInt64] = [:]
        for name in Self.entryNames {
            resolvedEntries[name] = try commerceKit.export(name, loadBase: SAPMachineLayout.kitBase)
        }

        let engine = try SAPUnicornEngine()
        var ready = false
        defer { if !ready { try? engine.close() } }

        for (address, size) in [
            (SAPMachineLayout.returnAddress, SAPMachineLayout.pageSize),
            (SAPMachineLayout.scratchBase, SAPMachineLayout.scratchSize),
            (SAPMachineLayout.heapBase, SAPMachineLayout.heapSize),
            (SAPMachineLayout.stackBase, SAPMachineLayout.stackSize),
        ] {
            try engine.memMap(address: address, size: size)
        }
        try engine.memWrite(address: SAPMachineLayout.returnAddress, data: [0xF4])

        let shims = try SAPShims(engine: engine, coreExports: exports, icxs: Array(bundle.coreFPICXS))
        var shimsReady = false
        defer { if !shimsReady { shims.close() } }

        func resolver(_ name: String) throws -> UInt64 {
            if let address = exports[name] { return address }
            return try shims.resolve(name)
        }

        for (image, base) in [
            (coreFP, SAPMachineLayout.coreFPBase),
            (commerceCore, SAPMachineLayout.commerceBase),
            (commerceKit, SAPMachineLayout.kitBase),
        ] {
            try image.relocate(loadBase: base, resolve: resolver)
            try image.load(into: engine)
        }

        guard let initializeAddress = resolvedEntries["_cp2g1b9ro"] else { throw SAPMachineError.entryPointMissing("initialize") }
        guard let exchangeAddress = resolvedEntries["_Mib5yocT"] else { throw SAPMachineError.entryPointMissing("exchange") }
        guard let signAddress = resolvedEntries["_Fc3vhtJDvr"] else { throw SAPMachineError.entryPointMissing("sign") }
        guard let teardownAddress = resolvedEntries["_IPaI1oem5iL"] else { throw SAPMachineError.entryPointMissing("teardown") }
        guard let disposeAddress = resolvedEntries["_jEHf8Xzsv8K"] else { throw SAPMachineError.entryPointMissing("dispose") }

        self.engine = engine
        self.shims = shims
        self.entry = SAPEntryPoints(
            initialize: initializeAddress,
            exchange: exchangeAddress,
            sign: signAddress,
            teardown: teardownAddress,
            dispose: disposeAddress
        )

        ready = true
        shimsReady = true
    }

    func close() {
        guard !closed else { return }
        closed = true
        shims.close()
        try? engine.close()
    }

    // MARK: - Guest entry points

    func initializeGuest(hardwareID: [UInt8]) throws -> UInt64 {
        let hardware = try Self.hardwareBlock(hardwareID)

        beginCall()
        defer { clearScratch() }

        let contextField = try scratch(nil, 8)
        let hardwareAddress = try scratch(hardware, UInt64(hardware.count))

        let status = try invoke(entry.initialize, [contextField, hardwareAddress])
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw SAPMachineError.unexpectedStatus("initialization", Int32(truncatingIfNeeded: status))
        }

        let contextValue = try readUInt64(contextField)
        guard contextValue != 0 else { throw SAPMachineError.nullContext }
        return contextValue
    }

    func exchange(version: UInt32, hardwareID: [UInt8], context: UInt64, input: [UInt8]) throws -> (output: [UInt8], state: Int32) {
        let hardware = try Self.hardwareBlock(hardwareID)

        beginCall()
        defer { clearScratch() }

        let hardwareAddress = try scratch(hardware, UInt64(hardware.count))
        let inputAddress = try scratch(input, UInt64(input.count))
        let outputField = try scratch(nil, 8)
        let lengthField = try scratch(nil, 8)
        let resultField = try scratch(nil, 4)

        let status = try invoke(entry.exchange, [
            UInt64(version), hardwareAddress, context, inputAddress, UInt64(input.count), outputField, lengthField, resultField,
        ])
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw SAPMachineError.unexpectedStatus("exchange", Int32(truncatingIfNeeded: status))
        }

        let output = try consumeOutput(pointerField: outputField, lengthField: lengthField)
        let result = try readUInt32(resultField)
        return (output, Int32(bitPattern: result))
    }

    func sign(context: UInt64, input: [UInt8]) throws -> [UInt8] {
        beginCall()
        defer { clearScratch() }

        let inputAddress = try scratch(input, UInt64(input.count))
        let outputField = try scratch(nil, 8)
        let lengthField = try scratch(nil, 8)

        let status = try invoke(entry.sign, [context, inputAddress, UInt64(input.count), outputField, lengthField])
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw SAPMachineError.unexpectedStatus("signing", Int32(truncatingIfNeeded: status))
        }

        return try consumeOutput(pointerField: outputField, lengthField: lengthField)
    }

    func teardown(context: UInt64) throws {
        let status = try invoke(entry.teardown, [context])
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw SAPMachineError.unexpectedStatus("teardown", Int32(truncatingIfNeeded: status))
        }
    }

    private func dispose(_ output: UInt64) throws {
        let status = try invoke(entry.dispose, [output])
        guard Int32(truncatingIfNeeded: status) == 0 else {
            throw SAPMachineError.unexpectedStatus("storage disposal", Int32(truncatingIfNeeded: status))
        }
    }

    // MARK: - Calling convention

    private func invoke(_ function: UInt64, _ arguments: [UInt64]) throws -> UInt64 {
        let registers: [Int32] = [
            Int32(UC_X86_REG_RDI.rawValue), Int32(UC_X86_REG_RSI.rawValue), Int32(UC_X86_REG_RDX.rawValue),
            Int32(UC_X86_REG_RCX.rawValue), Int32(UC_X86_REG_R8.rawValue), Int32(UC_X86_REG_R9.rawValue),
        ]

        for index in 0..<registers.count {
            let value = index < arguments.count ? arguments[index] : 0
            try engine.regWrite(registers[index], value: value)
        }

        let extra = max(arguments.count - registers.count, 0)
        var stackPointer = SAPMachineLayout.stackEnd - UInt64(extra + 1) * 8
        if stackPointer % 16 != 8 {
            stackPointer -= 8
        }

        try writeUInt64(stackPointer, SAPMachineLayout.returnAddress)
        for index in 0..<extra {
            try writeUInt64(stackPointer + 8 + UInt64(index) * 8, arguments[registers.count + index])
        }

        try engine.regWrite(Int32(UC_X86_REG_RSP.rawValue), value: stackPointer)

        shims.resetFault()

        do {
            try engine.start(begin: function, until: SAPMachineLayout.returnAddress, timeout: Self.sapGuestTimeout)
        } catch {
            if let fault = shims.fault { throw fault }
            throw error
        }

        if let fault = shims.fault { throw fault }

        let instruction = try engine.regRead(Int32(UC_X86_REG_RIP.rawValue))
        guard instruction == SAPMachineLayout.returnAddress else {
            throw SAPMachineError.guestStoppedUnexpectedly(instruction)
        }

        return try engine.regRead(Int32(UC_X86_REG_RAX.rawValue))
    }

    private func beginCall() {
        scratchCursor = 0
    }

    private func clearScratch() {
        guard scratchCursor != 0, !closed else { return }
        try? engine.memWrite(address: SAPMachineLayout.scratchBase, data: [UInt8](repeating: 0, count: Int(scratchCursor)))
        scratchCursor = 0
    }

    private func scratch(_ data: [UInt8]?, _ size: UInt64) throws -> UInt64 {
        let reserved = SAPMachineLayout.align(max(size, 1), 16)
        guard scratchCursor <= SAPMachineLayout.scratchSize, reserved <= SAPMachineLayout.scratchSize - scratchCursor else {
            throw SAPMachineError.scratchExhausted
        }

        let address = SAPMachineLayout.scratchBase + scratchCursor
        scratchCursor += reserved

        if let data, !data.isEmpty {
            guard UInt64(data.count) <= size else { throw SAPMachineError.scratchExhausted }
            try engine.memWrite(address: address, data: data)
        } else if size != 0 {
            try engine.memWrite(address: address, data: [UInt8](repeating: 0, count: Int(size)))
        }

        return address
    }

    // MARK: - Guest memory helpers

    private func consumeOutput(pointerField: UInt64, lengthField: UInt64) throws -> [UInt8] {
        let pointer = try readUInt64(pointerField)
        let length = try readUInt64(lengthField)

        var output: [UInt8] = []
        var outputError: Error?

        if length > SAPMachineLayout.maxOutputSize {
            outputError = SAPMachineError.outputTooLarge(length)
        } else if length == 0 {
            // no output — nothing to read
        } else if pointer == 0 {
            outputError = SAPMachineError.nullOutputPointer
        } else {
            output = try engine.memRead(address: pointer, size: Int(length))
        }

        if pointer != 0 {
            try dispose(pointer)
        }

        if let outputError { throw outputError }
        return output
    }

    private func readUInt32(_ address: UInt64) throws -> UInt32 {
        SAPShims.u32(try engine.memRead(address: address, size: 4))
    }

    private func readUInt64(_ address: UInt64) throws -> UInt64 {
        SAPShims.u64(try engine.memRead(address: address, size: 8))
    }

    private func writeUInt64(_ address: UInt64, _ value: UInt64) throws {
        try engine.memWrite(address: address, data: SAPShims.bytes(u64: value))
    }

    private static func hardwareBlock(_ hardwareID: [UInt8]) throws -> [UInt8] {
        guard !hardwareID.isEmpty, hardwareID.count <= 20 else {
            throw SAPMachineError.invalidHardwareID
        }

        var result = [UInt8](repeating: 0, count: 24)
        let length = UInt32(hardwareID.count)
        result[0] = UInt8(length & 0xFF)
        result[1] = UInt8((length >> 8) & 0xFF)
        result[2] = UInt8((length >> 16) & 0xFF)
        result[3] = UInt8((length >> 24) & 0xFF)
        for (index, byte) in hardwareID.enumerated() {
            result[4 + index] = byte
        }
        return result
    }
}
