//
//  CryptoHelpers.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.15.2025.
//
//  Hashing / KDF / cipher primitives used by the GrandSlam (GSA) auth flow.
//

import Foundation
import CryptoKit
import CommonCrypto

enum CryptoHelpers {

    // MARK: - Hex / bytes

    static func hexToData(_ hex: String) -> Data {
        var s = hex
        if s.count % 2 == 1 { s = "0" + s }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return Data() }
            data.append(byte)
            index = next
        }
        return data
    }

    static func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Left-pads `data` with zero bytes to `width` (no-op if already >= width).
    static func padLeft(_ data: Data, to width: Int) -> Data {
        data.count >= width ? data : Data(repeating: 0, count: width - data.count) + data
    }

    // MARK: - Hashing

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hmacSHA256(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    // MARK: - PBKDF2

    /// PBKDF2-HMAC-SHA256. Returns `keyLength` bytes.
    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int = 32) -> Data {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { outBuf in
            password.withUnsafeBytes { pwBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBuf.baseAddress!.assumingMemoryBound(to: Int8.self), pwBuf.count,
                        saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    // MARK: - AES-CBC

    /// Decrypts AES-CBC with PKCS#7 padding. Used for the GSA `spd` payload.
    static func aesCBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keyBuf.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, inBuf.count,
                            outBuf.baseAddress, outBuf.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
