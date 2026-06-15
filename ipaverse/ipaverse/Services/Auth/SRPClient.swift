//
//  SRPClient.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.15.2025.
//
//  SRP-6a client for Apple's GrandSlam (GSA) authentication.
//
//  Matches the configuration used by Apple's clients (and the JJTech gsa.py
//  reference): RFC 5054 NG_2048 group, g = 2, SHA-256, with `no_username_in_x`
//  and RFC-5054-compatible left-padding of hash inputs to the modulus width.
//
//  The full computation (A, u, x, S, K, M1, and the HMAC sub-keys) is verified
//  byte-for-byte against pysrp reference vectors — see the project notes.
//

import Foundation

enum SRPProtocol: String {
    case s2k = "s2k"
    case s2kFO = "s2k_fo"
}

final class SRPClient {

    /// RFC 5054 2048-bit group modulus.
    private static let nHex = "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73".lowercased()
    private static let gHex = "2"

    private let n: Data
    private let width: Int
    private let aHex: String

    /// Client public key `A` (raw bytes), sent to the server as `A2k`.
    let publicKey: Data

    /// Session key `K`, available after `processChallenge`. Used to derive sub-keys.
    private(set) var sessionKey: Data?

    init() {
        self.n = CryptoHelpers.hexToData(Self.nHex)
        self.width = n.count

        // 256-byte random ephemeral, matching Apple/pysrp.
        var aBytes = Data(count: 256)
        _ = aBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 256, $0.baseAddress!) }
        self.aHex = CryptoHelpers.dataToHex(aBytes)

        let aPubHex = BigIntJS.shared.modpow(base: Self.gHex, exp: aHex, modulus: Self.nHex)
        self.publicKey = CryptoHelpers.hexToData(aPubHex)
    }

    /// Derives the PBKDF2 password value (`s2k` / `s2k_fo`) fed into SRP's x.
    static func encryptPassword(_ password: String, salt: Data, iterations: Int, protocol proto: SRPProtocol) -> Data {
        var p = CryptoHelpers.sha256(Data(password.utf8))
        if proto == .s2kFO {
            p = Data(CryptoHelpers.dataToHex(p).utf8)
        }
        return CryptoHelpers.pbkdf2SHA256(password: p, salt: salt, iterations: iterations)
    }

    /// Processes the server challenge and returns the client proof `M1`.
    /// On success `sessionKey` (K) is populated.
    /// - Parameters:
    ///   - username: the Apple ID (used in the M1 computation).
    ///   - salt: server salt `s`.
    ///   - serverPublicKey: server public key `B`.
    ///   - encryptedPassword: output of `encryptPassword(...)`.
    func processChallenge(username: String, salt: Data, serverPublicKey: Data, encryptedPassword: Data) -> Data {
        let nHex = Self.nHex
        let gPadded = CryptoHelpers.padLeft(CryptoHelpers.hexToData(Self.gHex), to: width)

        // k = H( PAD(N) | PAD(g) )
        let kHex = CryptoHelpers.dataToHex(CryptoHelpers.sha256(CryptoHelpers.padLeft(n, to: width) + gPadded))

        // u = H( PAD(A) | PAD(B) )
        let uHex = CryptoHelpers.dataToHex(CryptoHelpers.sha256(
            CryptoHelpers.padLeft(publicKey, to: width) + CryptoHelpers.padLeft(serverPublicKey, to: width)))

        // x = H( salt | H(":" + encryptedPassword) )   (no username in x)
        let inner = CryptoHelpers.sha256(Data(":".utf8) + encryptedPassword)
        let xHex = CryptoHelpers.dataToHex(CryptoHelpers.sha256(salt + inner))

        // v = g^x mod N
        let vHex = BigIntJS.shared.modpow(base: Self.gHex, exp: xHex, modulus: nHex)

        // S = (B - k*v)^(a + u*x) mod N ; K = H(S)
        let sHex = BigIntJS.shared.computeS(
            B: CryptoHelpers.dataToHex(serverPublicKey), k: kHex, v: vHex,
            a: aHex, u: uHex, x: xHex, N: nHex)
        let K = CryptoHelpers.sha256(CryptoHelpers.hexToData(sHex))
        self.sessionKey = K

        // M1 = H( H(N) XOR H(PAD(g)) | H(username) | salt | A | B | K )
        let hN = CryptoHelpers.sha256(n)
        let hg = CryptoHelpers.sha256(gPadded)
        var hXor = Data(capacity: hN.count)
        for i in 0..<hN.count { hXor.append(hN[i] ^ hg[i]) }

        var m = Data()
        m += hXor
        m += CryptoHelpers.sha256(Data(username.utf8))
        m += salt
        m += publicKey
        m += serverPublicKey
        m += K
        return CryptoHelpers.sha256(m)
    }

    /// Derives a named sub-key from the SRP session key (e.g. "extra data key:").
    func deriveKey(named name: String) -> Data? {
        guard let K = sessionKey else { return nil }
        return CryptoHelpers.hmacSHA256(key: K, message: Data(name.utf8))
    }
}
