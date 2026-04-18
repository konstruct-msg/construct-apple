//
//  JWTUtils.swift
//  Construct Messenger
//

import Foundation

enum JWTUtils {
    static func headerAlgorithm(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let headerPart = String(parts[0])
        guard let data = base64URLDecode(headerPart) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["alg"] as? String
    }

    /// Extract the user ID from the JWT `sub` claim without signature verification.
    /// Used as a last-resort fallback when `userId` has been lost from Keychain
    /// but a valid session token still exists.
    static func extractUserId(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let sub = json["sub"] as? String, !sub.isEmpty { return sub }
        if let uid = json["user_id"] as? String, !uid.isEmpty { return uid }
        return nil
    }

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
