//
//  SAPProtocol.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 9.1.2026.
//
//  The two small HTTP legs of the SAP setup handshake: fetching Apple's
//  signing certificate (`sign-sap-setup-cert`, a static plist from
//  s.mzstatic.com) and exchanging opaque buffers the emulated CommerceKit
//  code produces/consumes against `sign-sap-setup`
//  (fpinit.itunes.apple.com) — both URLs come from `bag.xml`'s `urlBag`
//  dictionary, already confirmed present live during this project's
//  investigation. Faithful port of ipatool's internal/sap/protocol.go
//  (MIT licensed, github.com/majd/ipatool).
//

import Foundation

enum SAPProtocolError: LocalizedError {
    case unexpectedStatus(Int)
    case responseTooLarge
    case missingKey(String)
    case plistDecodeFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code): "Apple returned HTTP \(code) during the SAP setup handshake"
        case .responseTooLarge: "Apple's SAP setup response exceeds the size limit"
        case .missingKey(let key): "Apple's SAP setup plist is missing \(key)"
        case .plistDecodeFailed: "Failed to decode Apple's SAP setup plist"
        }
    }
}

enum SAPProtocol {
    private static let setupCertificateKey = "sign-sap-setup-cert"
    private static let setupBufferKey = "sign-sap-setup-buffer"
    private static let maxSetupBody = 1 << 20
    private static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    static func certificate(from endpoint: URL, session: URLSession = .shared) async throws -> [UInt8] {
        var request = URLRequest(url: endpoint)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body = try await send(request, session: session)
        return try plistBytes(body, key: setupCertificateKey)
    }

    static func exchange(endpoint: URL, input: [UInt8], session: URLSession = .shared) async throws -> [UInt8] {
        let envelope = try PropertyListSerialization.data(
            fromPropertyList: [setupBufferKey: Data(input)],
            format: .xml,
            options: 0
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = envelope

        let body = try await send(request, session: session)
        return try plistBytes(body, key: setupBufferKey)
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SAPProtocolError.unexpectedStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.count <= maxSetupBody else {
            throw SAPProtocolError.responseTooLarge
        }
        return data
    }

    private static func plistBytes(_ document: Data, key: String) throws -> [UInt8] {
        guard let values = try? PropertyListSerialization.propertyList(from: document, options: [], format: nil) as? [String: Any] else {
            throw SAPProtocolError.plistDecodeFailed
        }
        guard let value = values[key] as? Data, !value.isEmpty else {
            throw SAPProtocolError.missingKey(key)
        }
        return Array(value)
    }
}
