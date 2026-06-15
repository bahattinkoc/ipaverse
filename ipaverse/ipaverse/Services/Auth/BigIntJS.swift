//
//  BigIntJS.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 6.15.2025.
//
//  Big-integer modular arithmetic for SRP-6a, backed by JavaScriptCore's native
//  BigInt. JavaScriptCore is a system framework, so this needs no third-party
//  dependency, and correctness of the arithmetic is guaranteed by the engine.
//  Verified against pysrp reference vectors.
//

import Foundation
import JavaScriptCore

/// Hex-string based modular arithmetic used by `SRPClient`.
final class BigIntJS {
    static let shared = BigIntJS()

    private let context: JSContext
    private let modpowFn: JSValue
    private let computeSFn: JSValue

    private init() {
        let ctx = JSContext()!
        ctx.evaluateScript("""
        function bi(h){ return BigInt('0x' + (h === '' ? '0' : h)); }
        function modpow(bh, eh, mh){
            let m = bi(mh), b = bi(bh) % m, e = bi(eh), r = 1n;
            while (e > 0n) { if (e & 1n) r = (r * b) % m; e >>= 1n; b = (b * b) % m; }
            return r.toString(16);
        }
        // ((B - k*v) mod N) ^ (a + u*x) mod N  — the SRP-6a session value S
        function computeS(Bh, kh, vh, ah, uh, xh, Nh){
            let N = bi(Nh);
            let base = ((bi(Bh) - bi(kh) * bi(vh)) % N + N) % N;
            let e = bi(ah) + bi(uh) * bi(xh);
            let r = 1n, b = base % N;
            while (e > 0n) { if (e & 1n) r = (r * b) % N; e >>= 1n; b = (b * b) % N; }
            return r.toString(16);
        }
        """)
        self.context = ctx
        self.modpowFn = ctx.objectForKeyedSubscript("modpow")
        self.computeSFn = ctx.objectForKeyedSubscript("computeS")
    }

    /// Returns `base^exp mod modulus` as a (leading-zero-free) hex string.
    func modpow(base: String, exp: String, modulus: String) -> String {
        modpowFn.call(withArguments: [base, exp, modulus])!.toString()!
    }

    /// Returns the SRP session value `S = ((B - k*v) mod N)^(a + u*x) mod N` as hex.
    func computeS(B: String, k: String, v: String, a: String, u: String, x: String, N: String) -> String {
        computeSFn.call(withArguments: [B, k, v, a, u, x, N])!.toString()!
    }
}
