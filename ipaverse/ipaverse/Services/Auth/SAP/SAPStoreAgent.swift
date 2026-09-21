import Foundation

/// One isolated guest per package. Used sequentially, never shared by download jobs.
/// Protocol and pinned profile: IPAtool internal/sap/machine/storeagent.go (MIT).
final class SAPStoreAgent {
    private let machine: SAPMachine
    private var session: UInt64?

    init(bundle: SAPAssetBundle, image: Data, hardwareID: [UInt8], dpInfo: Data) throws {
        guard !dpInfo.isEmpty else { throw MacPackageError.missingDPInfo }
        let machine = try SAPMachine(bundle: bundle, storeAgent: image)
        do {
            session = try machine.openStoreSession(hardwareID: hardwareID, dpInfo: dpInfo)
        } catch {
            machine.close()
            throw error
        }
        self.machine = machine
    }

    deinit { try? close() }

    func decrypt(_ data: Data) throws -> Data {
        guard let session else { throw SAPUnicornError.engineClosed }
        return try machine.decryptStoreChunk(session: session, data: data)
    }

    func close() throws {
        guard let session else { return }
        self.session = nil
        defer { machine.close() }
        try machine.closeStoreSession(session)
    }
}
