//
//  TokenUtils.swift
//  Construct Messenger
//
//  Session token parser: PASETO v4.public (Ed25519), the only format this client accepts.
//
//  RS256 JWT was accepted alongside it from 2026-06-29 during the server's cutover and dropped
//  on 2026-10-24 (owner: "JWT support ends on iOS and Android alike"; Android already treats a
//  non-v4.public token as corruption). A cached token in any other format is cleared and the
//  device re-authenticates with its key (`AuthSessionManager.loadSessionToken`).
//
//  IMPORTANT: This utility does NOT verify token signatures — signature verification
//  is performed server-side. Only the claims (JSON payload) are extracted locally for
//  last-resort userId recovery when the Keychain entry is missing.
//

import Foundation

enum TokenUtils {

    /// Token format detected by inspecting the textual prefix.
    enum TokenFormat {
        case paseto   // v4.public.<payload>[.<footer>]
        case unknown  // anything else, a legacy JWT included
    }

    /// Detect token format by its prefix: PASETO v4.public tokens have the literal header "v4.public.".
    static func format(of token: String) -> TokenFormat {
        token.hasPrefix("v4.public.") ? .paseto : .unknown
    }

    /// The algorithm string for logging: "v4.public", or nil for anything else.
    static func headerAlgorithm(from token: String) -> String? {
        format(of: token) == .paseto ? "v4.public" : nil
    }

    /// Extract the user ID from the token `sub` claim without signature verification.
    /// Used as a last-resort fallback when `userId` has been lost from Keychain
    /// but a valid session token still exists.
    static func extractUserId(from token: String) -> String? {
        guard let json = claims(from: token),
              let sub = json["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    /// Extract the token issuance time (`iat`) as seconds since the Unix epoch.
    /// This is used only for local lifecycle checkpoints; it is not a trust decision.
    static func extractIssuedAt(from token: String) -> Int64? {
        guard let json = claims(from: token) else { return nil }
        return int64Claim("iat", in: json)
    }

    private static func claims(from token: String) -> [String: Any]? {
        format(of: token) == .paseto ? pasetoClaims(token) : nil
    }

    // MARK: - PASETO v4.public

    /// PASETO v4.public payload (base64url-decoded) layout:
    ///   nonce(32 bytes) || message(JSON, variable) || signature(64 bytes)
    /// The `message` is the JSON claims object. Pre-authentication encoding
    /// (what Ed25519 signs) is "paseto.v4.public." || nonce || message — but
    /// since we do not verify the signature here, we only need to slice out
    /// the message between the nonce and the signature.
    private static func pasetoClaims(_ token: String) -> [String: Any]? {
        // Token = "v4.public." + payloadB64 + ["." + footerB64]
        let stripped = String(token.dropFirst("v4.public.".count))
        let parts = stripped.split(separator: ".")
        guard let payloadB64 = parts.first, !payloadB64.isEmpty else { return nil }
        guard let payload = base64URLDecode(String(payloadB64)) else { return nil }
        // 32 (nonce) + 64 (signature) minimum overhead
        guard payload.count > 32 + 64 else { return nil }
        let messageStart = 32
        let messageEnd = payload.count - 64
        let messageData = payload.subdata(in: messageStart..<messageEnd)
        return try? JSONSerialization.jsonObject(with: messageData) as? [String: Any]
    }

    private static func int64Claim(_ name: String, in json: [String: Any]) -> Int64? {
        switch json[name] {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    // MARK: - base64url decode

    private static func base64URLDecode(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - base64.count % 4
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}
