//
//  SAPSigner.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  Produces the `X-Apple-ActionSignature` header value for MZFinance
//  authenticate requests (the piece ipaverse's GSA/PET bridge has been
//  missing — see AppStoreService.swift's `createLoginRequest`). Wraps
//  ``SAPMachine`` with the two-step setup handshake against Apple's
//  `sign-sap-setup` / `sign-sap-setup-cert` endpoints (``SAPProtocol``).
//  Faithful port of ipatool's internal/sap/signer.go + signer_local.go
//  (MIT licensed, github.com/majd/ipatool).
//

import Foundation

enum SAPSignerError: LocalizedError {
    case unsupportedVersion(UInt32)
    case invalidHardwareID
    case setupMessageEmpty
    case unexpectedSetupState(Int32)
    case signatureEmpty
    case signerClosed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported SAP version \(version) (expected 200)"
        case .invalidHardwareID: "SAP hardware ID must contain between 1 and 20 bytes"
        case .setupMessageEmpty: "SAP setup message is empty"
        case .unexpectedSetupState(let state): "SAP setup entered unexpected state \(state)"
        case .signatureEmpty: "SAP signature is empty"
        case .signerClosed: "SAP signer is closed"
        }
    }
}

final class SAPSigner {
    private let machine: SAPMachine
    private let context: UInt64
    private var hardwareID: [UInt8]
    private var closed = false

    /// Runs the full setup handshake against Apple's live SAP endpoints and
    /// returns a signer ready to sign request bodies. `version` must be 200
    /// (the only version bag.xml's `sign-sap-version` has been observed to
    /// advertise); `hardwareID` is 1-20 bytes stable per device.
    static func create(
        setupURL: URL,
        certificateURL: URL,
        version: UInt32,
        hardwareID: [UInt8],
        bundle: SAPAssetBundle
    ) async throws -> SAPSigner {
        guard version == 200 else { throw SAPSignerError.unsupportedVersion(version) }
        guard !hardwareID.isEmpty, hardwareID.count <= 20 else { throw SAPSignerError.invalidHardwareID }

        let machine = try SAPMachine(bundle: bundle)
        var complete = false
        defer { if !complete { machine.close() } }

        let context = try machine.initializeGuest(hardwareID: hardwareID)

        let certificate = try await SAPProtocol.certificate(from: certificateURL)

        let (setupRequest, requestState) = try machine.exchange(version: version, hardwareID: hardwareID, context: context, input: certificate)
        guard requestState == 1 else { throw SAPSignerError.unexpectedSetupState(requestState) }
        guard !setupRequest.isEmpty else { throw SAPSignerError.setupMessageEmpty }

        let reply = try await SAPProtocol.exchange(endpoint: setupURL, input: setupRequest)

        let (_, completeState) = try machine.exchange(version: version, hardwareID: hardwareID, context: context, input: reply)
        guard completeState == 0 else { throw SAPSignerError.unexpectedSetupState(completeState) }

        complete = true
        return SAPSigner(machine: machine, context: context, hardwareID: hardwareID)
    }

    private init(machine: SAPMachine, context: UInt64, hardwareID: [UInt8]) {
        self.machine = machine
        self.context = context
        self.hardwareID = hardwareID
    }

    /// Signs a request body (e.g. the plist bytes of an MZFinance
    /// authenticate request) — base64-encode the result into the
    /// `X-Apple-ActionSignature` header.
    func sign(_ input: Data) throws -> Data {
        guard !closed else { throw SAPSignerError.signerClosed }
        let signature = try machine.sign(context: context, input: Array(input))
        guard !signature.isEmpty else { throw SAPSignerError.signatureEmpty }
        return Data(signature)
    }

    func close() {
        guard !closed else { return }
        closed = true
        for index in hardwareID.indices { hardwareID[index] = 0 }
        try? machine.teardown(context: context)
        machine.close()
    }

    deinit {
        close()
    }
}
