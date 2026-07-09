//
//  TokenUtils.swift
//  Construct Messenger
//
//  Dual-format token parser: PASETO v4.public (primary) and legacy RS256 JWT (transitional).
//
//  The server is migrating from RS256 JWT to PASETO v4.public (Ed25519). This utility
//  parses both formats so the client keeps working across the cutover. JWT parsing is
//  a transitional fallback that will be removed once the server stops issuing JWT tokens.
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
        case jwt      // <header>.<payload>.<signature>  (legacy RS256)
        case unknown
    }

    /// Detect token format by its prefix.
    /// PASETO v4.public tokens have the literal header "v4.public."
    /// JWT tokens have a base64url-encoded JSON header as the first dot-separated segment.
    static func format(of token: String) -> TokenFormat {
        if token.hasPrefix("v4.public.") { return .paseto }
        // JWT: at least 2 dot-separated base64url segments (header.payload…)
        let parts = token.split(separator: ".")
        if parts.count >= 2 { return .jwt }
        return .unknown
    }

    /// Extract the algorithm string for logging / guard checks.
    /// - PASETO v4.public → "v4.public"
    /// - JWT RS256 → "RS256" (parsed from JWT header `alg` claim)
    /// - Other → nil
    static func headerAlgorithm(from token: String) -> String? {
        switch format(of: token) {
        case .paseto: return "v4.public"
        case .jwt:    return jwtHeaderAlg(token)
        case .unknown: return nil
        }
    }

    /// Extract the user ID from the token `sub` claim without signature verification.
    /// Used as a last-resort fallback when `userId` has been lost from Keychain
    /// but a valid session token still exists.
    /// Tries `sub` first, then legacy `user_id` claim (JWT only).
    static func extractUserId(from token: String) -> String? {
        switch format(of: token) {
        case .paseto: return pasetoExtractSub(token)
        case .jwt:    return jwtExtractSub(token)
        case .unknown: return nil
        }
    }

    // MARK: - PASETO v4.public

    /// PASETO v4.public payload (base64url-decoded) layout:
    ///   nonce(32 bytes) || message(JSON, variable) || signature(64 bytes)
    /// The `message` is the JSON claims object. Pre-authentication encoding
    /// (what Ed25519 signs) is "paseto.v4.public." || nonce || message — but
    /// since we do not verify the signature here, we only need to slice out
    /// the message between the nonce and the signature.
    private static func pasetoExtractSub(_ token: String) -> String? {
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
        guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            return nil
        }
        if let sub = json["sub"] as? String, !sub.isEmpty { return sub }
        return nil
    }

    // MARK: - Legacy JWT (RS256)

    private static func jwtHeaderAlg(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[0])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["alg"] as? String
    }

    private static func jwtExtractSub(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let sub = json["sub"] as? String, !sub.isEmpty { return sub }
        if let uid = json["user_id"] as? String, !uid.isEmpty { return uid }
        return nil
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