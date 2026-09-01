//
//  SAPMachineLayout.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Fixed guest-address-space layout shared by ``SAPShims`` (Phase 4) and
//  the machine orchestration (Phase 5). Values are ported verbatim from
//  ipatool's internal/sap/machine (MIT licensed, github.com/majd/ipatool) —
//  `machine.go`'s const block plus `shims.go`'s shim-region constants and
//  `shim_memory.go`'s transfer-size limit. These are arbitrary but fixed
//  addresses chosen to never collide with each other or with anything the
//  real Mach-O images (loaded at coreFPBase/commerceBase/kitBase) contain.
//
enum SAPMachineLayout {
    static let returnAddress: UInt64 = 0x0000_0001_0000_0000
    static let coreFPBase: UInt64 = 0x0000_1000_0000_0000
    static let commerceBase: UInt64 = 0x0000_1000_4000_0000
    static let kitBase: UInt64 = 0x0000_1000_8000_0000
    static let scratchBase: UInt64 = 0x0000_3000_0000_0000
    static let scratchSize: UInt64 = 32 << 20
    static let heapBase: UInt64 = 0x0000_4000_0000_0000
    static let heapSize: UInt64 = 64 << 20
    static let stackBase: UInt64 = 0x0000_5000_0000_0000
    static let stackSize: UInt64 = 8 << 20
    static let stackEnd: UInt64 = stackBase + stackSize
    static let pageSize: UInt64 = 0x1000
    static let maxOutputSize: UInt64 = 16 << 20

    static let shimBase: UInt64 = 0x0000_2000_0000_0000
    static let shimCodeSize: UInt64 = 0x0000_0000_0008_0000
    static let shimSize: UInt64 = 0x0000_0000_0010_0000
    static let shimSlotSize: UInt64 = 16

    static let maxGuestTransfer: UInt64 = 64 << 20

    static func align(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        (value &+ alignment &- 1) & ~(alignment &- 1)
    }
}
