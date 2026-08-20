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
/// - Ed25519 signature from sender's identity key (client verifies locally)
/// - JTI (JWT ID) for one-time use tracking
/// - Bounded time-to-live (`InviteConfig.ttlSeconds`, mirrored server-side)
/// - v4+: no unused ephKey; pure signed capability
///
/// On-the-wire transport (not the in-memory field model):
/// - QR: compact binary (`CIv1…`) in QR **byte mode**
/// - URL/deep link: `base64url(compact binary)` on the text boundary
/// - Dual-read: legacy base64(JSON) still decodes for the short TTL window
struct InviteObject: Codable, Equatable {
    /// Protocol version (1–4)
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

    /// Ephemeral X25519 public key (Base64) — **v1–v3 only**, unused for ECDH.
    /// Empty string on v4+ (field dropped from wire and canonical string).
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

    /// Maximum age in seconds, stated by the issuer — **v5 only**, `nil` below it.
    ///
    /// Signed (the canonical string ends with it), because a TTL a third party can edit is
    /// not a TTL. The server takes `min(INVITE_TTL_SECONDS, ttl)`, so this can only ask for
    /// a shorter life, never a longer one; read it through `InviteConfig.effectiveTTL` so
    /// the clamp happens on both sides.
    ///
    /// Not optional-by-convenience: the initializer requires it so that every place
    /// rebuilding an invite has to decide, rather than dropping it by omission the way
    /// `InviteVerifier`'s server-normalization rebuild would have.
    let ttl: UInt32?

    // MARK: - Codable (omit nil `un`, empty v4 `ephKey`, and pre-v5 `ttl`)

    enum CodingKeys: String, CodingKey {
        case v, jti, uuid, deviceId, server, ephKey, ts, sig, un, ttl
    }

    init(
        v: Int,
        jti: String,
        uuid: String,
        deviceId: String,
        server: String,
        ephKey: String,
        ts: Int,
        sig: String,
        un: String?,
        ttl: UInt32?
    ) {
        self.ttl = ttl
        self.v = v
        self.jti = jti
        self.uuid = uuid
        self.deviceId = deviceId
        self.server = server
        self.ephKey = ephKey
        self.ts = ts
        self.sig = sig
        self.un = un
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        jti = try c.decode(String.self, forKey: .jti)
        uuid = try c.decode(String.self, forKey: .uuid)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        server = try c.decode(String.self, forKey: .server)
        ephKey = try c.decodeIfPresent(String.self, forKey: .ephKey) ?? ""
        ts = try c.decode(Int.self, forKey: .ts)
        sig = try c.decode(String.self, forKey: .sig)
        un = try c.decodeIfPresent(String.self, forKey: .un)
        ttl = try c.decodeIfPresent(UInt32.self, forKey: .ttl)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(jti, forKey: .jti)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(server, forKey: .server)
        if InviteConfig.carriesEphKey(version: v), !ephKey.isEmpty {
            try c.encode(ephKey, forKey: .ephKey)
        }
        try c.encode(ts, forKey: .ts)
        try c.encode(sig, forKey: .sig)
        try c.encodeIfPresent(un, forKey: .un)
        if InviteConfig.carriesTTL(version: v) {
            try c.encodeIfPresent(ttl, forKey: .ttl)
        }
    }

    // MARK: - Validation

    /// Validate invite object structure
    /// - Throws: InviteValidationError if invalid
    func validate() throws {
        guard InviteConfig.supportedVersions.contains(v) else {
            throw InviteValidationError.unsupportedVersion(v)
        }

        guard UUID(uuidString: jti) != nil else {
            throw InviteValidationError.invalidJTI
        }

        guard UUID(uuidString: uuid) != nil else {
            throw InviteValidationError.invalidUserUUID
        }

        // Device ID required for v2+
        if v >= 2 {
            guard deviceId.count == InviteConfig.deviceIdLength,
                  deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
                throw InviteValidationError.invalidDeviceID
            }
        }

        guard !server.isEmpty, server.contains(".") else {
            throw InviteValidationError.invalidServer
        }

        if InviteConfig.carriesEphKey(version: v) {
            guard let ephKeyData = Data(base64Encoded: ephKey),
                  ephKeyData.count == InviteConfig.ephKeyLengthBytes else {
                throw InviteValidationError.invalidEphemeralKey
            }
        } else if !ephKey.isEmpty {
            // v4+ must not carry dead crypto material
            throw InviteValidationError.invalidEphemeralKey
        }

        let now = Int(Date().timeIntervalSince1970)
        guard ts > 0, ts <= now + Int(InviteConfig.maxFutureSkewSeconds) else {
            throw InviteValidationError.invalidTimestamp
        }

        guard let sigData = Data(base64Encoded: sig),
              sigData.count == InviteConfig.signatureLengthBytes else {
            throw InviteValidationError.invalidSignature
        }

        // Mirrors the server (`INVITE_LIST_REVOKE_SERVER_SPEC` §4 rules 4–6). Absent on v5
        // is an error rather than a silent fall back to the maximum: a missing value that
        // means "twelve hours" is the dual meaning the whole field exists to remove. An
        // overshoot is *not* an error — rule 7 clamps it — so it is accepted here and
        // narrowed by `InviteConfig.effectiveTTL`.
        if InviteConfig.carriesTTL(version: v) {
            guard let ttl else { throw InviteValidationError.missingTTL }
            guard ttl >= InviteConfig.minTTLSeconds else {
                throw InviteValidationError.ttlBelowFloor(ttl)
            }
        } else if ttl != nil {
            throw InviteValidationError.ttlOnUnsupportedVersion(v)
        }
    }
    
    /// How long this particular invite is worth, already clamped to the server maximum.
    ///
    /// v1–v4 have no stated TTL and get the global one, exactly as before.
    var effectiveTTLSeconds: TimeInterval {
        InviteConfig.effectiveTTL(stated: ttl)
    }

    /// Check if invite has expired.
    /// - Parameter ttl: override in seconds; defaults to this invite's own life.
    func isExpired(ttl: TimeInterval? = nil) -> Bool {
        let now = Date().timeIntervalSince1970
        let expiresAt = TimeInterval(ts) + (ttl ?? effectiveTTLSeconds)
        return now > expiresAt
    }

    /// Seconds remaining until expiry, or 0.
    /// - Parameter ttl: override in seconds; defaults to this invite's own life.
    func timeRemaining(ttl: TimeInterval? = nil) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        let expiresAt = TimeInterval(ts) + (ttl ?? effectiveTTLSeconds)
        return max(0, expiresAt - now)
    }
    
    // MARK: - Signing Data
    
    /// Get canonical string representation for signing
    ///
    /// Fields are concatenated in order:
    /// - v1: v|jti|uuid|server|ephKey|ts
    /// - v2: v|jti|uuid|deviceId|server|ephKey|ts
    /// - v3: v|jti|uuid|deviceId|server|ephKey|ts|un  (un empty if nil)
    /// - v4: v|jti|uuid|deviceId|server|ts|un  (no ephKey)
    /// - v5: v|jti|uuid|deviceId|server|ts|un|ttl
    ///
    /// This exact order must be used for both signing and verification, and must match
    /// `InviteToken::canonical_string` in `crates/crypto-agility/src/invites.rs`.
    ///
    /// **Every version is spelled out, and an unknown one throws.** This used to end in a
    /// `default:` carrying the v4 shape, which meant a v5 token would be signed over a
    /// string with no `ttl` — silently, and only on this side. The moment the server built
    /// the v5 string *with* `ttl`, every such invite would fail with `InvalidSignature`, an
    /// error naming keys while the actual disagreement was about which bytes were hashed.
    /// Rust already refuses unknown versions (`other => Err(UnsupportedVersion)`); this now
    /// does the same, so the two sides fail the same way at the same point.
    func canonicalString() throws -> String {
        // Rust's Uuid formats with lowercase hex — match that to ensure
        // client-signed canonical string matches server-verified canonical string.
        let jtiLower = jti.lowercased()
        let uuidLower = uuid.lowercased()
        switch v {
        case 1:
            return "\(v)|\(jtiLower)|\(uuidLower)|\(server)|\(ephKey)|\(ts)"
        case 2:
            return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ephKey)|\(ts)"
        case 3:
            return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ephKey)|\(ts)|\(un ?? "")"
        case 4:
            // Signed capability without dead ephKey.
            return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ts)|\(un ?? "")"
        case 5:
            guard let ttl else { throw InviteValidationError.missingTTL }
            return "\(v)|\(jtiLower)|\(uuidLower)|\(deviceId)|\(server)|\(ts)|\(un ?? "")|\(ttl)"
        default:
            throw InviteValidationError.unsupportedVersion(v)
        }
    }
}

// MARK: - Validation Errors

enum InviteValidationError: LocalizedError {
    case unsupportedVersion(Int)
    case missingTTL
    case ttlBelowFloor(UInt32)
    case ttlOnUnsupportedVersion(Int)
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
        case .missingTTL:
            return "v5 invite without a ttl"
        case .ttlBelowFloor(let ttl):
            return "Invite ttl \(ttl)s is below the \(InviteConfig.minTTLSeconds)s floor"
        case .ttlOnUnsupportedVersion(let v):
            return "v\(v) invite must not carry a ttl"
        }
    }
}

// MARK: - Encoding/Decoding Helpers
//
// Production transport (F1 fix):
//   QR path  → raw compact binary (QR byte mode) — no base64
//   URL path → base64url(compact binary) — text boundary only
//
// Compact layout ("CIv1"):
//   magic[4] "CIv1" | flags u8 | v u8
//   jti[16] | uuid[16] | deviceId[16]
//   [ephKey[32] if v<=3] | ts u64 BE | sig[64]
//   serverLen u8 | server UTF-8 | [unLen u8 | un UTF-8 if flags.hasUn]
//   [ttl u32 BE if v>=5]
//
// `ttl` is gated on the version, not on a flag bit, the same way `ephKey` is. A flag would
// be a second thing saying whether the field is there, free to disagree with `v` — and `v`
// is already the authority, because the server derives the field's presence from it too.
//
// v4 bytes are unchanged: a v4 invite encodes and decodes exactly as it did before v5
// existed, so nothing in flight is affected.
//
// Legacy base64(JSON) still decodes for the short TTL dual-read window.

extension InviteObject {

    /// Wire magic for the compact binary invite container (encoding version, not invite protocol `v`).
    static let binaryMagic = Data([0x43, 0x49, 0x76, 0x31]) // "CIv1"
    private static let flagHasUsername: UInt8 = 0x01

    /// True when `data` starts with the compact-binary magic.
    static func isCompactBinary(_ data: Data) -> Bool {
        data.starts(with: binaryMagic)
    }

    // MARK: Compact binary (production)

    /// Encode to compact binary for QR byte mode and as the inner payload of base64url links.
    func encodeBinary() throws -> Data {
        try validate()

        guard let jtiBytes = Self.uuidBytes(from: jti),
              let uuidBytes = Self.uuidBytes(from: uuid) else {
            throw InviteBinaryError.invalidUUID
        }
        guard let deviceBytes = InviteBinaryCodec.data(hex: deviceId), deviceBytes.count == 16 else {
            throw InviteBinaryError.invalidDeviceId
        }
        let ephBytes: Data?
        if InviteConfig.carriesEphKey(version: v) {
            guard let bytes = Data(base64Encoded: ephKey), bytes.count == InviteConfig.ephKeyLengthBytes else {
                throw InviteBinaryError.invalidEphemeralKey
            }
            ephBytes = bytes
        } else {
            ephBytes = nil
        }
        guard let sigBytes = Data(base64Encoded: sig), sigBytes.count == InviteConfig.signatureLengthBytes else {
            throw InviteBinaryError.invalidSignature
        }

        let serverData = Data(server.utf8)
        guard serverData.count <= Int(UInt8.max) else {
            throw InviteBinaryError.fieldTooLong("server")
        }

        let unData: Data?
        if let un, !un.isEmpty {
            let d = Data(un.utf8)
            guard d.count <= Int(UInt8.max) else {
                throw InviteBinaryError.fieldTooLong("un")
            }
            unData = d
        } else {
            unData = nil
        }

        var out = Data()
        out.reserveCapacity(
            4 + 1 + 1 + 16 + 16 + 16
            + (ephBytes?.count ?? 0) + 8 + 64 + 1 + serverData.count
            + (unData.map { 1 + $0.count } ?? 0)
            + (InviteConfig.carriesTTL(version: v) ? 4 : 0)
        )

        out.append(Self.binaryMagic)
        out.append(unData == nil ? 0 : Self.flagHasUsername)
        out.append(UInt8(v))
        out.append(jtiBytes)
        out.append(uuidBytes)
        out.append(deviceBytes)
        if let ephBytes {
            out.append(ephBytes)
        }
        out.append(Self.u64BE(UInt64(ts)))
        out.append(sigBytes)
        out.append(UInt8(serverData.count))
        out.append(serverData)
        if let unData {
            out.append(UInt8(unData.count))
            out.append(unData)
        }
        if InviteConfig.carriesTTL(version: v) {
            // `validate()` above already refused a v5 without one, so this cannot be nil —
            // but it is spelled out rather than force-unwrapped, because a crash here is
            // reachable from a decoded invite and that is attacker-supplied input.
            guard let ttl else { throw InviteBinaryError.missingTTL }
            out.append(Self.u32BE(ttl))
        }
        return out
    }

    /// Decode compact binary produced by `encodeBinary()`.
    static func decodeBinary(_ data: Data) throws -> InviteObject {
        var r = InviteBinaryReader(data)
        let magic = try r.take(4)
        guard magic == binaryMagic else {
            throw InviteBinaryError.badMagic
        }
        let flags = try r.u8()
        let version = Int(try r.u8())
        let jti = try uuidString(from: r.take(16))
        let uuid = try uuidString(from: r.take(16))
        let deviceId = InviteBinaryCodec.hex(try r.take(16))
        let ephKey: String
        if InviteConfig.carriesEphKey(version: version) {
            ephKey = try r.take(InviteConfig.ephKeyLengthBytes).base64EncodedString()
        } else {
            ephKey = ""
        }
        let ts = Int(try r.u64BE())
        let sig = try r.take(InviteConfig.signatureLengthBytes).base64EncodedString()
        let serverLen = Int(try r.u8())
        let serverData = try r.take(serverLen)
        guard let server = String(data: serverData, encoding: .utf8), !server.isEmpty else {
            throw InviteBinaryError.invalidServer
        }

        var un: String?
        if flags & flagHasUsername != 0 {
            let unLen = Int(try r.u8())
            let unData = try r.take(unLen)
            un = String(data: unData, encoding: .utf8)
        }
        let ttl: UInt32? = InviteConfig.carriesTTL(version: version) ? try r.u32BE() : nil
        guard r.isAtEnd else {
            throw InviteBinaryError.trailingBytes
        }

        let invite = InviteObject(
            v: version,
            jti: jti,
            uuid: uuid,
            deviceId: deviceId,
            server: server,
            ephKey: ephKey,
            ts: ts,
            sig: sig,
            un: un,
            ttl: ttl
        )
        try invite.validate()
        return invite
    }

    /// Decode any supported on-the-wire blob: compact binary, or legacy JSON (dual-read window).
    static func decodePayload(_ data: Data) throws -> InviteObject {
        if isCompactBinary(data) {
            return try decodeBinary(data)
        }
        // Legacy dual-read: base64(JSON) era stored JSON bytes after outer base64 decode.
        if let invite = try? JSONDecoder().decode(InviteObject.self, from: data) {
            try invite.validate()
            return invite
        }
        throw InviteBinaryError.unrecognizedPayload
    }

    // MARK: Text-boundary encoding (deep links / clipboard)

    /// base64url (no padding) over compact binary — URL/deep-link only.
    func toBase64URL() throws -> String {
        InviteBinaryCodec.base64URLEncode(try encodeBinary())
    }

    /// Decode from base64url or standard base64 of compact binary (or legacy JSON).
    static func fromBase64(_ encoded: String) throws -> InviteObject {
        guard let data = InviteBinaryCodec.base64URLOrStdDecode(encoded) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid Base64 / base64url encoding"
            ))
        }
        return try decodePayload(data)
    }

    // MARK: Compatibility aliases (old MessagePack-misnamed API)

    /// - Note: Name is historical. Produces compact binary, not MessagePack/JSON.
    func toMessagePack() throws -> Data { try encodeBinary() }

    static func fromMessagePack(_ data: Data) throws -> InviteObject { try decodePayload(data) }

    /// - Note: Prefer `toBase64URL()` for new call sites.
    func toBase64() throws -> String { try toBase64URL() }

    // MARK: Legacy JSON (debug / dual-read only)

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

    static func fromJSON(_ json: String) throws -> InviteObject {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid UTF-8 in JSON string"
            ))
        }
        return try decodePayload(data)
    }

    // MARK: - Binary helpers

    private static func uuidBytes(from string: String) -> Data? {
        guard let uuid = UUID(uuidString: string) else { return nil }
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    private static func uuidString(from data: Data) throws -> String {
        guard data.count == 16 else { throw InviteBinaryError.invalidUUID }
        var bytes = [UInt8](repeating: 0, count: 16)
        data.copyBytes(to: &bytes, count: 16)
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple).uuidString.lowercased()
    }

    private static func u64BE(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private static func u32BE(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
}

// MARK: - Compact binary errors

enum InviteBinaryError: LocalizedError {
    case badMagic
    case invalidUUID
    case invalidDeviceId
    case invalidEphemeralKey
    case invalidSignature
    case invalidServer
    case fieldTooLong(String)
    case truncated
    case trailingBytes
    case unrecognizedPayload
    case missingTTL

    var errorDescription: String? {
        switch self {
        case .badMagic: return "Invite binary magic mismatch"
        case .invalidUUID: return "Invalid UUID in invite binary"
        case .invalidDeviceId: return "Invalid deviceId in invite binary"
        case .invalidEphemeralKey: return "Invalid ephKey in invite binary"
        case .invalidSignature: return "Invalid signature in invite binary"
        case .invalidServer: return "Invalid server in invite binary"
        case .fieldTooLong(let f): return "Invite field too long: \(f)"
        case .truncated: return "Invite binary truncated"
        case .trailingBytes: return "Invite binary has trailing bytes"
        case .unrecognizedPayload: return "Unrecognized invite payload encoding"
        case .missingTTL: return "v5 invite binary without a ttl"
        }
    }
}

// MARK: - Binary reader

private struct InviteBinaryReader {
    private let data: Data
    private var offset: Int = 0

    /// Normalises the index origin: this reader counts from 0 and calls `subdata(in:)`, which
    /// takes absolute indices, so a `Data` slice would trap on the first `take`. Invites arrive
    /// from QR codes and deep links, so the reader must not depend on how the caller built the
    /// `Data`. No copy when the input is already zero-origin.
    init(_ data: Data) { self.data = data.startIndex == 0 ? data : Data(data) }

    var isAtEnd: Bool { offset >= data.count }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.count else { throw InviteBinaryError.truncated }
        let slice = data.subdata(in: offset..<(offset + n))
        offset += n
        return slice
    }

    mutating func u8() throws -> UInt8 {
        try take(1)[0]
    }

    mutating func u32BE() throws -> UInt32 {
        let bytes = try take(4)
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest)
        }
        return UInt32(bigEndian: raw)
    }

    mutating func u64BE() throws -> UInt64 {
        let bytes = try take(8)
        var raw: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            bytes.copyBytes(to: dest)
        }
        return UInt64(bigEndian: raw)
    }
}

// MARK: - Invite binary codec helpers (file-scoped to avoid Data extension clashes)

enum InviteBinaryCodec {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        let hex = hex.lowercased()
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// base64url without padding (RFC 4648 §5).
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    static func base64URLOrStdDecode(_ string: String) -> Data? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = base64URLDecode(trimmed) { return data }
        if let data = Data(base64Encoded: trimmed) { return data }
        return nil
    }

    /// Recover raw QR byte-mode payload when AVFoundation exposes it as a Latin-1 string.
    static func dataFromLatin1QRString(_ string: String) -> Data? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            guard scalar.value <= 0xFF else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        return Data(bytes)
    }
}
