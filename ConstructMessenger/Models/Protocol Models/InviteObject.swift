//
//  InviteObject.swift
//  Construct Messenger
//
//  Created by Copilot on 29.01.2026.
//

import Foundation

/// Dynamic contact invite with cryptographic security
///
/// Security model:
/// - Ephemeral X25519 public key (unique per invite)
/// - Ed25519 signature from sender's identity key
/// - JTI (JWT ID) for one-time use tracking
/// - 3-5 minute time-to-live (TTL)
/// - Server-side validation and invalidation
///
/// Format:
/// ```json
/// {
///   "v": 3,
///   "jti": "550e8400-e29b-41d4-a716-446655440000",
///   "uuid": "550e8400-e29b-41d4-a716-446655440000",  // userId (UUID)
///   "deviceId": "4e1f9dbe209c1bedb33ee32dda5a28f0",  // deviceId (hex)
///   "server": "konstruct.cc",
///   "ephKey": "base64-x25519-public-key",
///   "ts": 1738156800,
///   "sig": "base64-ed25519-signature",
///   "un": "alice"  // optional sender username (V3+, included in signature)
/// }
/// ```
struct InviteObject: Codable, Equatable {
    /// Protocol version (1, 2, or 3)
    let v: Int
    
    /// JTI - unique invite ID for one-time use tracking
    /// UUIDv4 format, tracked by server to prevent reuse
    let jti: String
    
    /// Sender's user UUID (for chat creation)
    let uuid: String
    
    /// Sender's device ID (for fetching public keys)
    /// 32-char hex string from SHA256(identity_public)[0..16]
    let deviceId: String
    
    /// Server FQDN (e.g., "konstruct.cc")
    /// Enables federation support
    let server: String
    
    /// Ephemeral X25519 public key (Base64)
    /// Generated fresh for each invite, 32 bytes
    let ephKey: String
    
    /// Unix timestamp when invite was created
    /// Used to calculate expiry (current + TTL)
    let ts: Int
    
    /// Ed25519 signature (Base64)
    /// Signs all fields above with sender's identity key
    /// 64 bytes, proves authenticity
    let sig: String
    
    /// Sender's username or display name (V3+, optional)
    /// Included in the Ed25519 canonical string — cryptographically authenticated.
    /// Allows the recipient to see the sender's name immediately without a server roundtrip.
    /// Server stores only a username hash, so the plaintext travels here peer-to-peer.
    let un: String?

    // MARK: - Codable (custom encode to omit nil `un` and keep QR payload compact)

    enum CodingKeys: String, CodingKey {
        case v, jti, uuid, deviceId, server, ephKey, ts, sig, un
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v,        forKey: .v)
        try c.encode(jti,      forKey: .jti)
        try c.encode(uuid,     forKey: .uuid)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(server,   forKey: .server)
        try c.encode(ephKey,   forKey: .ephKey)
        try c.encode(ts,       forKey: .ts)
        try c.encode(sig,      forKey: .sig)
        try c.encodeIfPresent(un, forKey: .un)  // omit key entirely when nil
    }
    
    // MARK: - Validation
    
    /// Validate invite object structure
    /// - Throws: InviteValidationError if invalid
    func validate() throws {
        guard InviteConfig.supportedVersions.contains(v) else {
            throw InviteValidationError.unsupportedVersion(v)
        }
        
        // JTI format (UUID)
        guard UUID(uuidString: jti) != nil else {
            throw InviteValidationError.invalidJTI
        }
        
        // User UUID format
        guard UUID(uuidString: uuid) != nil else {
            throw InviteValidationError.invalidUserUUID
        }
        
        // Device ID format (32-char hex string)
        guard deviceId.count == InviteConfig.deviceIdLength,
              deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
            throw InviteValidationError.invalidDeviceID
        }
        
        // Server FQDN (basic check)
        guard !server.isEmpty, server.contains(".") else {
            throw InviteValidationError.invalidServer
        }
        
        // Ephemeral key format (Base64, should decode to 32 bytes)
        guard let ephKeyData = Data(base64Encoded: ephKey),
              ephKeyData.count == InviteConfig.ephKeyLengthBytes else {
            throw InviteValidationError.invalidEphemeralKey
        }
        
        // Timestamp (must be positive, not too far in future)
        let now = Int(Date().timeIntervalSince1970)
        guard ts > 0, ts <= now + Int(InviteConfig.maxFutureSkewSeconds) else {
            throw InviteValidationError.invalidTimestamp
        }
        
        // Signature format (Base64, should decode to 64 bytes)
        guard let sigData = Data(base64Encoded: sig),
              sigData.count == InviteConfig.signatureLengthBytes else {
            throw InviteValidationError.invalidSignature
        }
    }
    
    /// Check if invite has expired
    /// - Parameter ttlSeconds: Time-to-live in seconds (default: 300 = 5 minutes)
    /// - Returns: true if expired
    func isExpired(ttl: TimeInterval = InviteConfig.ttlSeconds) -> Bool {
        let now = Date().timeIntervalSince1970
        let expiresAt = TimeInterval(ts) + ttl
        return now > expiresAt
    }
    
    /// Get remaining time until expiry
    /// - Parameter ttlSeconds: Time-to-live in seconds (default: 300)
    /// - Returns: Seconds remaining, or 0 if expired
    func timeRemaining(ttl: TimeInterval = InviteConfig.ttlSeconds) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        let expiresAt = TimeInterval(ts) + ttl
        return max(0, expiresAt - now)
    }
    
    // MARK: - Signing Data
    
    /// Get canonical string representation for signing
    ///
    /// Fields are concatenated in order:
    /// - v1: v|jti|uuid|server|ephKey|ts
    /// - v2: v|jti|uuid|deviceId|server|ephKey|ts
    /// - v3: v|jti|uuid|deviceId|server|ephKey|ts|un  (un is empty string if nil)
    /// This exact order must be used for both signing and verification.
    ///
    /// - Returns: String to sign/verify
    func canonicalString() -> String {
        // Rust's Uuid formats with lowercase hex — match that to ensure
        // client-signed canonical string matches server-verified canonical string.
        let jtiLower = jti.lowercased()
        let uuidLower = uuid.lowercased()
        if v == 1 {
            return "\(v)|\(jtiLower)|\(uuidLower)|\(server)|\(ephKey)|\(ts)"
        } else if v == 2 {
            return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ephKey)|\(ts)"
        }
        // V3: username is included in the signature (empty string if absent)
        return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ephKey)|\(ts)|\(un ?? "")"
    }
}

// MARK: - Validation Errors

enum InviteValidationError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidJTI
    case invalidUserUUID
    case invalidDeviceID
    case invalidServer
    case invalidEphemeralKey
    case invalidTimestamp
    case invalidSignature
    
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported invite version: \(v)"
        case .invalidJTI:
            return "Invalid JTI format (must be UUIDv4)"
        case .invalidUserUUID:
            return "Invalid user UUID format"
        case .invalidDeviceID:
            return "Invalid device ID format (must be 32-char hex)"
        case .invalidServer:
            return "Invalid server FQDN"
        case .invalidEphemeralKey:
            return "Invalid ephemeral key (must be 32-byte Base64)"
        case .invalidTimestamp:
            return "Invalid timestamp"
        case .invalidSignature:
            return "Invalid signature (must be 64-byte Base64)"
        }
    }
}

// MARK: - Encoding/Decoding Helpers

extension InviteObject {
    /// Encode to binary (JSON-based, used for QR codes and deep links)
    func toMessagePack() throws -> Data {
        try JSONEncoder().encode(self)
    }
    
    /// Decode from binary (JSON-based)
    static func fromMessagePack(_ data: Data) throws -> InviteObject {
        try JSONDecoder().decode(InviteObject.self, from: data)
    }
    
    /// Encode to Base64-encoded MessagePack (for QR codes and links)
    /// - Returns: Base64 string
    /// - Throws: EncodingError
    func toBase64() throws -> String {
        let msgpackData = try toMessagePack()
        return msgpackData.base64EncodedString()
    }
    
    /// Decode from Base64-encoded MessagePack
    /// - Parameter base64: Base64 string
    /// - Returns: InviteObject
    /// - Throws: DecodingError
    static func fromBase64(_ base64: String) throws -> InviteObject {
        guard let data = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid Base64 encoding"
            ))
        }
        return try fromMessagePack(data)
    }
    
    // MARK: - Legacy JSON Support (for debugging)
    
    /// Encode to JSON string (legacy, use toMessagePack for production)
    /// - Returns: JSON string
    /// - Throws: EncodingError
    func toJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert JSON data to UTF-8 string"
            ))
        }
        return json
    }
    
    /// Decode from JSON string (legacy, use fromMessagePack for production)
    /// - Parameter json: JSON string
    /// - Returns: InviteObject
    /// - Throws: DecodingError
    static func fromJSON(_ json: String) throws -> InviteObject {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid UTF-8 in JSON string"
            ))
        }
        return try JSONDecoder().decode(InviteObject.self, from: data)
    }
}
