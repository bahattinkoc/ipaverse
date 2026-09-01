//
//  SAPShims+Memory.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Custom malloc/free heap allocator and libc string/memory primitives the
//  emulated CommerceKit/CommerceCore/CoreFP code calls into. Faithful port
//  of ipatool's internal/sap/machine/shim_memory.go (MIT licensed,
//  github.com/majd/ipatool) — a real allocator is needed (not just a bump
//  allocator) because the emulated code allocates and frees scratch buffers
//  repeatedly across a single `Exchange`/`Sign` call.
//

import Foundation

extension SAPShims {
    func registerMemoryServices() throws {
        let services: [(names: [String], handler: SAPShimHandler)] = [
            (["_malloc"], malloc),
            (["_malloc_good_size"], mallocGoodSize),
            (["_malloc_size"], mallocSize),
            (["_calloc"], calloc),
            (["_realloc", "_reallocf"], realloc),
            (["_free"], free),
            (["_memcpy", "_memmove"], memmove),
            (["_memset"], memset),
            (["___bzero"], bzero),
            (["___memcpy_chk"], checkedMemcpy),
            (["___memset_chk"], checkedMemset),
            (["_memcmp"], memcmp),
            (["_strcmp"], strcmp),
            (["_strncmp"], strncmp),
            (["_strlen"], strlen),
        ]
        for service in services {
            try addAliases(service.names, service.handler)
        }
    }

    // MARK: - Allocation

    private func malloc() throws {
        let size = try argument(0)
        let address = try allocate(size)
        try setResult(address)
    }

    private func mallocGoodSize() throws {
        let size = try argument(0)
        try setResult(SAPMachineLayout.align(max(size, 1), 16))
    }

    private func mallocSize() throws {
        let address = try argument(0)
        try setResult(allocations[address]?.reserved ?? 0)
    }

    private func calloc() throws {
        let count = try argument(0)
        let size = try argument(1)

        if count != 0, size > UInt64.max / count {
            throw SAPShimsError.allocationOverflow
        }
        let total = count &* size

        let address = try allocate(total)

        if total != 0 {
            do {
                try engine.memWrite(address: address, data: [UInt8](repeating: 0, count: Self.checkedSize(total)))
            } catch {
                try? release(address)
                throw error
            }
        }

        try setResult(address)
    }

    private func realloc() throws {
        let oldAddress = try argument(0)
        let newSize = try argument(1)

        if oldAddress == 0 {
            try setResult(try allocate(newSize))
            return
        }

        guard let oldAllocation = allocations[oldAddress] else {
            throw SAPShimsError.unknownPointer("reallocate", oldAddress)
        }

        if newSize <= oldAllocation.reserved {
            var updated = oldAllocation
            updated.size = newSize
            allocations[oldAddress] = updated
            try setResult(oldAddress)
            return
        }

        let newAddress = try allocate(newSize)

        do {
            let data = try engine.memRead(address: oldAddress, size: Self.checkedSize(oldAllocation.size))
            try engine.memWrite(address: newAddress, data: data)
        } catch {
            try? release(newAddress)
            throw error
        }

        try release(oldAddress)
        try setResult(newAddress)
    }

    private func free() throws {
        let address = try argument(0)
        if address != 0 {
            try release(address)
        }
        try setResult(0)
    }

    func allocate(_ size: UInt64) throws -> UInt64 {
        guard size <= SAPMachineLayout.maxGuestTransfer else {
            throw SAPShimsError.allocationTooLarge(size)
        }

        let reserved = SAPMachineLayout.align(max(size, 1), 16)

        for index in freeBlocks.indices {
            let block = freeBlocks[index]
            guard block.size >= reserved else { continue }

            let address = block.address
            if block.size == reserved {
                freeBlocks.remove(at: index)
            } else {
                freeBlocks[index].address += reserved
                freeBlocks[index].size -= reserved
            }

            allocations[address] = SAPGuestAllocation(size: size, reserved: reserved)
            return address
        }

        guard heapCursor <= SAPMachineLayout.heapSize, reserved <= SAPMachineLayout.heapSize - heapCursor else {
            throw SAPShimsError.heapExhausted
        }

        let address = SAPMachineLayout.heapBase + heapCursor
        heapCursor += reserved
        allocations[address] = SAPGuestAllocation(size: size, reserved: reserved)
        return address
    }

    func release(_ address: UInt64) throws {
        guard let allocation = allocations[address] else {
            throw SAPShimsError.unknownPointer("free", address)
        }

        try engine.memWrite(address: address, data: [UInt8](repeating: 0, count: Self.checkedSize(allocation.reserved)))

        allocations.removeValue(forKey: address)
        freeBlocks.append(SAPFreeBlock(address: address, size: allocation.reserved))
        coalesceFreeBlocks()
    }

    func coalesceFreeBlocks() {
        freeBlocks.sort { $0.address < $1.address }

        var merged: [SAPFreeBlock] = []
        for block in freeBlocks {
            if let last = merged.indices.last, merged[last].address + merged[last].size == block.address {
                merged[last].size += block.size
            } else {
                merged.append(block)
            }
        }
        freeBlocks = merged

        while let last = freeBlocks.indices.last {
            let block = freeBlocks[last]
            guard block.address + block.size == SAPMachineLayout.heapBase + heapCursor else { break }
            heapCursor -= block.size
            freeBlocks.removeLast()
        }
    }

    // MARK: - String/memory primitives

    private func memmove() throws {
        let destination = try argument(0)
        let source = try argument(1)
        let length = try argument(2)
        let size = try Self.checkedSize(length)

        let data = try engine.memRead(address: source, size: size)
        try engine.memWrite(address: destination, data: data)
        try setResult(destination)
    }

    private func memset() throws {
        let destination = try argument(0)
        let value = try argument(1)
        let length = try argument(2)
        let size = try Self.checkedSize(length)

        try engine.memWrite(address: destination, data: [UInt8](repeating: UInt8(value & 0xFF), count: size))
        try setResult(destination)
    }

    private func bzero() throws {
        let destination = try argument(0)
        let length = try argument(1)
        let size = try Self.checkedSize(length)

        try engine.memWrite(address: destination, data: [UInt8](repeating: 0, count: size))
        try setResult(destination)
    }

    private func checkedMemcpy() throws {
        let length = try argument(2)
        let capacity = try argument(3)
        guard length <= capacity else { throw SAPShimsError.checkedCopyExceedsDestination }
        try memmove()
    }

    private func checkedMemset() throws {
        let length = try argument(2)
        let capacity = try argument(3)
        guard length <= capacity else { throw SAPShimsError.checkedFillExceedsDestination }
        try memset()
    }

    private func memcmp() throws {
        let left = try argument(0)
        let right = try argument(1)
        let length = try argument(2)
        let size = try Self.checkedSize(length)

        let a = try engine.memRead(address: left, size: size)
        let b = try engine.memRead(address: right, size: size)
        try setResult(UInt64(bitPattern: Int64(Self.compareBytes(a, b))))
    }

    private func strcmp() throws {
        let left = try argument(0)
        let right = try argument(1)
        let a = try readCString(left)
        let b = try readCString(right)
        try setResult(UInt64(bitPattern: Int64(Self.compareBytes(Array(a.utf8), Array(b.utf8)))))
    }

    private func strncmp() throws {
        let left = try argument(0)
        let right = try argument(1)
        let length = try argument(2)
        _ = try Self.checkedSize(length)

        var offset: UInt64 = 0
        while offset < length {
            guard left <= UInt64.max - offset, right <= UInt64.max - offset else {
                throw SAPShimsError.addressOverflow
            }

            let leftAddress = left + offset
            let rightAddress = right + offset
            let chunk = min(
                length - offset,
                SAPMachineLayout.pageSize - leftAddress % SAPMachineLayout.pageSize,
                SAPMachineLayout.pageSize - rightAddress % SAPMachineLayout.pageSize
            )
            let chunkSize = try Self.checkedSize(chunk)

            let a = try engine.memRead(address: leftAddress, size: chunkSize)
            let b = try engine.memRead(address: rightAddress, size: chunkSize)

            for index in 0..<a.count {
                if a[index] != b[index] {
                    try setResult(UInt64(bitPattern: Int64(Int(a[index]) - Int(b[index]))))
                    return
                }
                if a[index] == 0 {
                    try setResult(0)
                    return
                }
            }

            offset += chunk
        }

        try setResult(0)
    }

    private func strlen() throws {
        let address = try argument(0)
        let value = try readCString(address)
        try setResult(UInt64(value.utf8.count))
    }

    private static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let length = min(a.count, b.count)
        for index in 0..<length where a[index] != b[index] {
            return a[index] < b[index] ? -1 : 1
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }
}
