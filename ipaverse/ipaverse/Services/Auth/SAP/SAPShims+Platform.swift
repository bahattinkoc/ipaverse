//
//  SAPShims+Platform.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  macOS/Darwin platform stand-ins the emulated CoreFP/CommerceKit code
//  calls into: CFString/CFDictionary/IOKit registry stubs (the emulated
//  code probes hardware identifiers via IOKit; these fake just enough of
//  the API surface for it to proceed without ever reading real hardware
//  data), objc_msgSend, dlopen/dlsym (resolving only the one path the code
//  actually opens — a virtual "CoreFP.icxs" it expects to load itself),
//  gettimeofday, sysctlbyname, pthread_once, arc4random, and
//  compare-and-swap. Faithful port of ipatool's
//  internal/sap/machine/shim_platform.go (MIT licensed,
//  github.com/majd/ipatool).
//

import Foundation

extension SAPShims {
    private static let fakeHandle = UInt64.max
    private static let coreFPFile: UInt64 = 3
    private static let coreFPPath = "/System/Library/PrivateFrameworks/CoreFP.framework/CoreFP"
    private static let icxsPath = "./../CoreFP.icxs"
    private static let keySerial = "IOPlatformSerialNumber"
    private static let keyUUID = "IOPlatformUUID"
    private static let keyBoard = "board-id"
    private static let keyedMessage = "objectForKey:"

    func registerPlatformServices() throws {
        let services: [(names: [String], handler: SAPShimHandler)] = [
            (["_CFBundleGetMainBundle", "_CFDataGetBytePtr", "_CFDataGetLength", "_CFStringGetLength",
              "_CFStringGetMaximumSizeForEncoding", "_CFUUIDCreateString", "_IORegistryEntryFromPath",
              "_IORegistryEntrySearchCFProperty", "_IOServiceMatching", "_getenv", "_pthread_self"], returnZero),
            (["_CFDictionaryGetValue", "_DADiskCopyDescription", "_DADiskCreateFromBSDName", "_DASessionCreate",
              "_IORegistryEntryCreateCFProperty"], returnFakeHandle),
            (["_CFRelease", "_IOObjectRelease", "_close", "_close$UNIX2003", "_pthread_mutex_lock",
              "_pthread_mutex_unlock", "_pthread_rwlock_init", "_pthread_rwlock_init$UNIX2003",
              "_pthread_rwlock_unlock", "_pthread_rwlock_unlock$UNIX2003", "_pthread_rwlock_wrlock",
              "_pthread_rwlock_wrlock$UNIX2003"], returnZero),
            (["_CFStringCreateWithCString"], cfStringCreate),
            (["_CFStringCreateWithCStringNoCopy"], returnZero),
            (["_CFStringGetCString"], cfStringGetCString),
            (["_IOIteratorNext"], ioIteratorNext),
            (["_IORegistryEntryGetParentEntry"], ioRegistryEntryGetParentEntry),
            (["_IOServiceGetMatchingServices"], ioServiceGetMatchingServices),
            (["_IOServiceGetMatchingService"], returnUInt32Max),
            (["_OSAtomicCompareAndSwap32Barrier"], compareAndSwap32),
            (["___error"], errorPointer),
            (["_abort", "___stack_chk_fail", "dyld_stub_binder"], abort),
            (["_arc4random"], arc4random),
            (["_dlopen"], dlopen),
            (["_dlsym"], dlsym),
            (["_fcntl", "_fcntl$UNIX2003", "_lstat$INODE64", "_statfs", "_statfs$INODE64"], returnMinusOne),
            (["_gettimeofday"], gettimeofday),
            (["_objc_msgSend"], objcMsgSend),
            (["_open", "_open$UNIX2003"], open),
            (["_pthread_once"], pthreadOnce),
            (["_read", "_read$UNIX2003"], read),
            (["_sysctl"], returnMinusOne),
            (["_sysctlbyname"], sysctlbyname),
        ]
        for service in services {
            try addAliases(service.names, service.handler)
        }

        errno = try addData("guest.errno", [UInt8](repeating: 0, count: 8))
        try addData("___stack_chk_guard", [0xA5, 0x71, 0x3C, 0xD9, 0x86, 0x42, 0xEF, 0x10])

        for name in ["_kCFAllocatorDefault", "_kCFAllocatorNull", "_kDADiskDescriptionVolumeUUIDKey", "_kIOMasterPortDefault"] {
            try addData(name, [UInt8](repeating: 0, count: 8))
        }
    }

    private func returnZero() throws {
        try setResult(0)
    }

    private func returnFakeHandle() throws {
        try setResult(Self.fakeHandle)
    }

    private func returnUInt32Max() throws {
        try setResult(UInt64(UInt32.max))
    }

    private func returnMinusOne() throws {
        try setResult(UInt64.max)
    }

    private func cfStringCreate() throws {
        let address = try argument(1)
        let value = try readCString(address)

        switch value {
        case Self.keySerial, Self.keyUUID, Self.keyBoard:
            try setResult(Self.fakeHandle)
        default:
            try setResult(0)
        }
    }

    private func cfStringGetCString() throws {
        let buffer = try argument(1)
        let capacity = try argument(2)

        guard buffer != 0, capacity != 0 else {
            try setResult(0)
            return
        }

        try engine.memWrite(address: buffer, data: [0])
        try setResult(1)
    }

    private func ioIteratorNext() throws {
        iterator += 1
        try setResult(UInt64(iterator % 2))
    }

    private func ioRegistryEntryGetParentEntry() throws {
        let parent = try argument(2)
        guard parent != 0 else { throw SAPShimsError.nullOutput("parent registry entry") }

        try writeUInt32(parent, UInt32.max)
        try setResult(0)
    }

    private func ioServiceGetMatchingServices() throws {
        let iteratorAddress = try argument(2)
        guard iteratorAddress != 0 else { throw SAPShimsError.nullOutput("matching services iterator") }

        iterator = 0
        try writeUInt32(iteratorAddress, UInt32.max)
        try setResult(0)
    }

    private func compareAndSwap32() throws {
        let oldValue = try argument(0)
        let newValue = try argument(1)
        let address = try argument(2)

        let current = try readUInt32(address)
        guard current == UInt32(truncatingIfNeeded: oldValue) else {
            try setResult(0)
            return
        }

        try writeUInt32(address, UInt32(truncatingIfNeeded: newValue))
        try setResult(1)
    }

    private func errorPointer() throws {
        try setResult(errno)
    }

    private func abort() throws {
        throw SAPShimsError.guestAborted
    }

    private func arc4random() throws {
        var value: UInt32 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, 4, &value)
        guard status == errSecSuccess else {
            throw SAPShimsError.unsupportedImport("_arc4random (SecRandomCopyBytes failed)")
        }
        try setResult(UInt64(value))
    }

    private func dlopen() throws {
        let pathAddress = try argument(0)
        let path = try readCString(pathAddress)
        try setResult(path == Self.coreFPPath ? Self.fakeHandle : 0)
    }

    private func dlsym() throws {
        let nameAddress = try argument(1)
        let name = try readCString(nameAddress)
        try setResult(coreExports["_" + name] ?? 0)
    }

    private func gettimeofday() throws {
        let timeAddress = try argument(0)
        let zoneAddress = try argument(1)

        let now = Date()

        if timeAddress != 0 {
            let seconds = UInt64(now.timeIntervalSince1970)
            let microseconds = UInt32((now.timeIntervalSince1970 - Double(seconds)) * 1_000_000)
            var value = Self.bytes(u64: seconds)
            value.append(contentsOf: Self.bytes(u32: microseconds))
            value.append(contentsOf: [0, 0, 0, 0])
            try engine.memWrite(address: timeAddress, data: value)
        }

        if zoneAddress != 0 {
            try engine.memWrite(address: zoneAddress, data: [UInt8](repeating: 0, count: 8))
        }

        try setResult(0)
    }

    private func objcMsgSend() throws {
        let selectorAddress = try argument(1)
        let selector = try readCString(selectorAddress)
        try setResult(selector == Self.keyedMessage ? Self.fakeHandle : 0)
    }

    private func open() throws {
        let pathAddress = try argument(0)
        let path = try readCString(pathAddress)

        if path == Self.icxsPath {
            icxsOffset = 0
            try setResult(Self.coreFPFile)
            return
        }

        try returnMinusOne()
    }

    private func pthreadOnce() throws {
        let control = try argument(0)
        let initializer = try argument(1)

        let value = try readUInt64(control)
        if value == 0 {
            try setResult(0)
            return
        }

        try writeUInt64(control, 0)

        var stack = try engine.regRead(Int32(UC_X86_REG_RSP.rawValue))
        stack -= 8
        try writeUInt64(stack, initializer)
        try engine.regWrite(Int32(UC_X86_REG_RSP.rawValue), value: stack)

        try setResult(0)
    }

    private func read() throws {
        let descriptor = try argument(0)
        let buffer = try argument(1)
        let requested = try argument(2)

        guard descriptor == Self.coreFPFile else {
            try returnMinusOne()
            return
        }

        var size = try Self.checkedSize(requested)
        let remaining = icxs.count - icxsOffset
        if size > remaining { size = remaining }

        if size != 0 {
            try engine.memWrite(address: buffer, data: Array(icxs[icxsOffset..<(icxsOffset + size)]))
            icxsOffset += size
        }

        try setResult(UInt64(size))
    }

    private func sysctlbyname() throws {
        let lengthAddress = try argument(2)
        if lengthAddress != 0 {
            try writeUInt64(lengthAddress, 0)
        }
        try setResult(0)
    }
}
