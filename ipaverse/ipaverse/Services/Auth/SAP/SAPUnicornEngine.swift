//
//  SAPUnicornEngine.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Thin Swift wrapper over libunicorn's C API, x86-64 mode only — this is
//  only ever used to emulate the real Apple FairPlay/CommerceKit binaries
//  fetched by ``SAPAssets``. Mirrors ipatool's internal/sap/unicorn.Engine
//  (MIT licensed, github.com/majd/ipatool) function-for-function, but calls
//  libunicorn directly through the bridging header (this app links the
//  library at build time — see ipaverse.xcodeproj's Frameworks phase)
//  instead of ipatool's Go purego/dlopen indirection, which exists there
//  only to avoid a cgo build dependency and isn't needed from Swift.
//
//  Verified in isolation (outside this app, via a standalone `swiftc`
//  spike) against Unicorn 2.1.4 on Apple Silicon before this was written:
//  basic x86-64 emulation and the exact register+stack calling convention
//  ``SAPMachine`` (Phase 5) will use both ran correctly with no crash.
//

import Foundation

enum SAPUnicornError: LocalizedError {
    case openFailed(UInt32, String)
    case callFailed(String, UInt32, String)
    case timedOut(TimeInterval)
    case engineClosed
    case versionMismatch(UInt32, UInt32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code, let message): "Failed to open Unicorn engine (code \(code): \(message))"
        case .callFailed(let operation, let code, let message): "Unicorn \(operation) failed (code \(code): \(message))"
        case .timedOut(let seconds): "Unicorn emulation timed out after \(seconds)s"
        case .engineClosed: "Unicorn engine is closed"
        case .versionMismatch(let major, let minor): "Unsupported Unicorn API version \(major).\(minor) (expected 2.1)"
        }
    }
}

/// Fired when emulated execution's instruction pointer reaches a
/// registered address — used by the runtime shims (Phase 4) to trap
/// "calls" into unresolved imports rather than letting the CPU execute
/// (nonexistent) code there.
typealias SAPUnicornCodeHook = (_ address: UInt64, _ size: UInt32) -> Void

/// Non-capturing C trampoline for `UC_HOOK_CODE` callbacks. libunicorn's
/// `uc_hook_add` declares its `callback` parameter as untyped `void *`
/// (it's overloaded across many hook kinds), so Swift can't bridge a typed
/// function reference automatically — this is manually reinterpreted to a
/// raw pointer where the call happens. `user_data` carries the owning
/// engine, recovered via `Unmanaged`.
private let sapUnicornHookTrampoline: @convention(c) (OpaquePointer?, UInt64, UInt32, UnsafeMutableRawPointer?) -> Void = { _, address, size, userData in
    guard let userData else { return }
    Unmanaged<SAPUnicornEngine>.fromOpaque(userData).takeUnretainedValue().dispatchCodeHook(address: address, size: size)
}

final class SAPUnicornEngine {
    private var handle: OpaquePointer?
    private var rangeHooks: [uc_hook: (begin: UInt64, end: UInt64, hook: SAPUnicornCodeHook)] = [:]
    private var closed = false

    init() throws {
        var major: UInt32 = 0
        var minor: UInt32 = 0
        uc_version(&major, &minor)
        guard major == 2, minor == 1 else {
            throw SAPUnicornError.versionMismatch(major, minor)
        }

        var handle: OpaquePointer?
        let result = uc_open(UC_ARCH_X86, UC_MODE_64, &handle)
        guard result == UC_ERR_OK, let handle else {
            throw SAPUnicornError.openFailed(result.rawValue, Self.errorString(result))
        }
        self.handle = handle
    }

    deinit {
        try? close()
    }

    // MARK: - Memory

    func memMap(address: UInt64, size: UInt64) throws {
        try call("uc_mem_map") { uc_mem_map($0, address, size, UInt32(UC_PROT_ALL.rawValue)) }
    }

    func memUnmap(address: UInt64, size: UInt64) throws {
        try call("uc_mem_unmap") { uc_mem_unmap($0, address, size) }
    }

    func memWrite(address: UInt64, data: [UInt8]) throws {
        guard !data.isEmpty else { return }
        try withEngine { handle in
            try data.withUnsafeBufferPointer { buffer -> Void in
                let result = uc_mem_write(handle, address, buffer.baseAddress, UInt64(buffer.count))
                guard result == UC_ERR_OK else {
                    throw SAPUnicornError.callFailed("uc_mem_write", result.rawValue, Self.errorString(result))
                }
            }
        }
    }

    func memRead(address: UInt64, size: Int) throws -> [UInt8] {
        guard size > 0 else { return [] }
        var output = [UInt8](repeating: 0, count: size)
        try withEngine { handle in
            try output.withUnsafeMutableBufferPointer { buffer -> Void in
                let result = uc_mem_read(handle, address, buffer.baseAddress, UInt64(buffer.count))
                guard result == UC_ERR_OK else {
                    throw SAPUnicornError.callFailed("uc_mem_read", result.rawValue, Self.errorString(result))
                }
            }
        }
        return output
    }

    // MARK: - Registers

    func regWrite(_ register: Int32, value: UInt64) throws {
        var value = value
        try call("uc_reg_write") { uc_reg_write($0, register, &value) }
    }

    func regRead(_ register: Int32) throws -> UInt64 {
        var value: UInt64 = 0
        try withEngine { handle in
            let result = uc_reg_read(handle, register, &value)
            guard result == UC_ERR_OK else {
                throw SAPUnicornError.callFailed("uc_reg_read", result.rawValue, Self.errorString(result))
            }
        }
        return value
    }

    // MARK: - Execution

    /// Runs from `begin` until execution reaches `until`, bounded by a wall
    /// clock timeout. SAP's cryptographic routines have host- and input-
    /// dependent instruction counts, so this bounds by time rather than a
    /// fixed instruction budget (mirrors `StartBounded` in ipatool's
    /// reference implementation).
    func start(begin: UInt64, until: UInt64, timeout: TimeInterval) throws {
        let microseconds = max(UInt64(timeout * 1_000_000), 1)
        try call("uc_emu_start") { uc_emu_start($0, begin, until, microseconds, 0) }

        var timedOut: Int = 0
        try call("uc_query") { uc_query($0, UC_QUERY_TIMEOUT, &timedOut) }
        guard timedOut == 0 else {
            throw SAPUnicornError.timedOut(timeout)
        }
    }

    func stop() throws {
        try call("uc_emu_stop") { uc_emu_stop($0) }
    }

    // MARK: - Code hooks

    /// Registers a callback fired whenever emulated execution's instruction
    /// pointer reaches any address in the inclusive range `[begin, end]`.
    /// Used both for a single fixed address (`begin == end`, e.g. the
    /// Phase 3 self-test below) and for a whole region (Phase 4's shim
    /// dispatcher, which covers every import stub with one hook).
    @discardableResult
    func addCodeHook(begin: UInt64, end: UInt64, _ hook: @escaping SAPUnicornCodeHook) throws -> uc_hook {
        try withEngine { handle in
            var hookHandle: uc_hook = 0
            let userData = Unmanaged.passUnretained(self).toOpaque()
            let trampoline = unsafeBitCast(sapUnicornHookTrampoline, to: UnsafeMutableRawPointer.self)

            let result = sap_uc_hook_add_code(handle, &hookHandle, trampoline, userData, begin, end)
            guard result == UC_ERR_OK else {
                throw SAPUnicornError.callFailed("uc_hook_add", result.rawValue, Self.errorString(result))
            }

            rangeHooks[hookHandle] = (begin, end, hook)
            return hookHandle
        }
    }

    func removeCodeHook(_ hookHandle: uc_hook) {
        rangeHooks.removeValue(forKey: hookHandle)
        guard let handle else { return }
        uc_hook_del(handle, hookHandle)
    }

    fileprivate func dispatchCodeHook(address: UInt64, size: UInt32) {
        for (begin, end, hook) in rangeHooks.values where address >= begin && address <= end {
            hook(address, size)
        }
    }

    // MARK: - Lifecycle

    func close() throws {
        guard !closed else { return }
        closed = true
        rangeHooks.removeAll()

        guard let handle else { return }
        self.handle = nil

        let result = uc_close(handle)
        guard result == UC_ERR_OK else {
            throw SAPUnicornError.callFailed("uc_close", result.rawValue, Self.errorString(result))
        }
    }

    // MARK: - Helpers

    private func call(_ name: String, _ body: (OpaquePointer) -> uc_err) throws {
        try withEngine { handle in
            let result = body(handle)
            guard result == UC_ERR_OK else {
                throw SAPUnicornError.callFailed(name, result.rawValue, Self.errorString(result))
            }
        }
    }

    private func withEngine<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle, !closed else { throw SAPUnicornError.engineClosed }
        return try body(handle)
    }

    private static func errorString(_ code: uc_err) -> String {
        String(cString: uc_strerror(code))
    }
}
