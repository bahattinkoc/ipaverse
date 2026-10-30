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

    /// ent/download kbsync for one account and device, from its own isolated guest.
    static func kbsync(hardwareID: [UInt8], dsid: UInt64) async throws -> Data {
        try Task.checkCancellation()
        let bundle = try await SAPAssets.load()
        let image = try await SAPAssets.loadStoreAgent()
        try Task.checkCancellation()
        let machine = try SAPMachine(bundle: bundle, storeAgent: image)
        defer { machine.close() }
        return Data(try machine.generateKBSync(hardwareID: hardwareID, dsid: dsid))
    }
}

/// kbsync depends only on the account and the device, so downloads, version lists and
/// metadata lookups share one blob until Apple rejects it. IPAtool caches it the same way.
actor EntDownloadKBSync {
    static let shared = EntDownloadKBSync()

    struct Blob {
        let base64: String
        /// Generated for an earlier request. A rejected cached blob earns one fresh retry.
        let isCached: Bool
    }

    private var current: (dsid: UInt64, guid: String, task: Task<String, Error>)?

    func blob(dsid: UInt64, guid: String, hardwareID: [UInt8]) async throws -> Blob {
        if let current, current.dsid == dsid, current.guid == guid {
            return Blob(base64: try await value(of: current.task), isCached: true)
        }
        let task = Task { try await SAPStoreAgent.kbsync(hardwareID: hardwareID, dsid: dsid).base64EncodedString() }
        current = (dsid, guid, task)
        return Blob(base64: try await value(of: task), isCached: false)
    }

    func invalidate(dsid: UInt64, guid: String, base64: String) async {
        guard let current, current.dsid == dsid, current.guid == guid else { return }
        let task = current.task
        if (try? await task.value) == base64, self.current?.task == task { self.current = nil }
    }

    /// A failed generation is never reused.
    private func value(of task: Task<String, Error>) async throws -> String {
        do {
            return try await task.value
        } catch {
            if current?.task == task { current = nil }
            throw error
        }
    }
}
