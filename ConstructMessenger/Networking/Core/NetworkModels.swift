//
//  NetworkModels.swift
//  Construct Messenger
//
//  Shared networking response/request models used by gRPC service clients.
//

import Foundation

// MARK: - Auth

struct AuthResponse: Codable {
    let userId: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64?   // Unix timestamp (legacy)
    let expiresIn: Int?     // Seconds from now (current)
    var veilBridgeCert: String?
}

// MARK: - Messaging

struct SendMessageResponse: Codable {
    let messageId: String
    let status: String
    /// False when the server returned a permanent error (e.g. BLOCKED).
    /// The sender should NOT retry the message.
    var retryable: Bool = true
    /// Server-supplied error code for decision tracing and retry policy.
    /// Empty string means no error (success path).
    var errorCode: String = ""
    /// Non-zero for RATE_LIMIT: milliseconds to wait before retrying.
    var retryAfterMs: Int64 = 0
    /// Per-attempt UUID echoed back by server for "attempt → decision" correlation.
    var attemptId: String = ""
}

struct EndSessionResponse: Codable {
    let status: String
    let messageId: String
    let type: String
}

// MARK: - Users

struct UsernameAvailabilityResponse: Decodable {
    let available: Bool

    private enum CodingKeys: String, CodingKey {
        case available, isAvailable, exists
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .available) { available = v; return }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) { available = v; return }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .exists) { available = !v; return }
        throw DecodingError.keyNotFound(CodingKeys.available,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "No availability field found"))
    }
}

// MARK: - Push Notifications

struct DeviceTokenResponse: Codable {
    let success: Bool
    let message: String?
}
