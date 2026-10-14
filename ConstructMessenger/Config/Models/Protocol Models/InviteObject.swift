//
//  InviteObject.swift
//  Construct Messenger
//
//  Created by Copilot on 29.01.2026.
//

import Foundation

/// A signed, one-time contact invite — protocol v5, the only version.
///
/// Security model:
/// - Ed25519 signature by the issuing device (the redeemer verifies locally, then pins)
/// - JTI for one-time use (burned by the server on redeem)
/// - Signed per-invite `ttl`, clamped to the server maximum
/// - Signed `addr`: the issuing account's address, its Ed25519 recovery public key. The
///   redeemer addresses every later message to it, so it reaches the redeemer from the
///   issuer's device and never from the server.
///
/// v1–v4 are refused since 2026-09-28 (`decisions/invite-carries-the-account-address.md`):
/// invites live minutes to hours, there was no installed base, and nobody had minted a v5 yet,
/// so its layout could change without a v6.
///
/// On-the-wire transport (not the in-memory field model):
/// - QR: compact binary (`CIv1…`) in QR **byte mode**
/// - URL/deep link: `base64url(compact binary)` on the text boundary
///
/// Byte-level agreement with Android and the server is fixed by
/// `Generated/conformance/knst_invite.json` (`InviteConformanceTests`).
struct InviteObject: Equatable {
    /// Protocol version — always `InviteConfig.version`.
    let v: Int

    /// JTI - unique invite ID for one-time use tracking (UUIDv4)
    let jti: String

    /// Sender's user UUID (for chat creation)
    let uuid: String

    /// Sender's device ID — 32-char hex, SHA256(identity_public)[0..16]. Signs the invite.
    let deviceId: String

    /// Server FQDN (e.g., "konstruct.cc")
    let server: String

    /// Unix timestamp when invite was created
    let ts: Int

    /// Ed25519 signature (Base64) over `canonicalString()`, by the issuing device.
    let sig: String

    /// Sender's username or display name, optional. Signed. Lets the recipient see a name
    /// before any session exists; the server stores only a hash of it.
    let un: String?

    /// Maximum age in seconds, stated by the issuer and signed. The server takes
    /// `min(INVITE_TTL_SECONDS, ttl)`, so this can only shorten an invite's life; read it
    /// through `effectiveTTLSeconds`.
    let ttl: UInt32

    /// The issuing account's address: its 32-byte Ed25519 recovery public key. Signed.
    let addr: Data

    // MARK: - Validation

    /// Validate invite object structure
    /// - Throws: InviteValidationError if invalid
    func validate() throws {
        guard v == InviteConfig.version else {
            throw InviteValidationError.unsupportedVersion(v)
        }

        guard UUID(uuidString: jti) != nil else {
            throw InviteValidationError.invalidJTI
        }

        guard UUID(uuidString: uuid) != nil else {
            throw InviteValidationError.invalidUserUUID
        }

        guard deviceId.count == InviteConfig.deviceIdLength,
              deviceId.range(of: InviteConfig.deviceIdRegex, options: .regularExpression) != nil else {
            throw InviteValidationError.invalidDeviceID
        }

        guard !server.isEmpty, server.contains(".") else {
            throw InviteValidationError.invalidServer
        }

        let now = Int(Date().timeIntervalSince1970)
        guard ts > 0, ts <= now + Int(InviteConfig.maxFutureSkewSeconds) else {
            throw InviteValidationError.invalidTimestamp
        }

        guard let sigData = Data(base64Encoded: sig),
              sigData.count == InviteConfig.signatureLengthBytes else {
            throw InviteValidationError.invalidSignature
        }

        // Mirrors the server floor. An overshoot is not an error — the server clamps it — so it
        // is accepted here and narrowed by `effectiveTTLSeconds`.
        guard ttl >= InviteConfig.minTTLSeconds else {
            throw InviteValidationError.ttlBelowFloor(ttl)
        }

        guard addr.count == AccountAddress.length else {
            throw InviteValidationError.invalidAddress
        }
    }

    /// How long this particular invite is worth, already clamped to the server maximum.
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

    /// The signed canonical string: `v|jti|uuid|deviceId|server|ts|un|ttl|hex(addr)`.
    ///
    /// Must match `InviteToken::canonical_string` in construct-server
    /// (`crates/crypto-agility/src/invites.rs`) and Android byte for byte; the three are held to
    /// `knst_invite.json`. UUIDs lowercase (Rust's `Uuid` formats that way), `un` empty when
    /// absent, `ttl` decimal, `addr` lowercase hex.
    func canonicalString() throws -> String {
        guard v == InviteConfig.version else {
            throw InviteValidationError.unsupportedVersion(v)
        }
        let fields = [
            "\(v)", jti.lowercased(), uuid.lowercased(), deviceId, server, "\(ts)",
            un ?? "", "\(ttl)", InviteBinaryCodec.hex(addr),
        ]
        return fields.joined(separator: "|")
    }

    /// The same invite with a different signature — the one field the generator fills last.
    func signed(_ signature: String) -> InviteObject {
        InviteObject(
            v: v, jti: jti, uuid: uuid, deviceId: deviceId, server: server, ts: ts,
            sig: signature, un: un, ttl: ttl, addr: addr
        )
    }
}

// MARK: - Validation Errors

enum InviteValidationError: LocalizedError {
    case unsupportedVersion(Int)
    case ttlBelowFloor(UInt32)
    case invalidAddress
    case invalidJTI
    case invalidUserUUID
    case invalidDeviceID
    case invalidServer
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
        case .invalidTimestamp:
            return "Invalid timestamp"
        case .invalidSignature:
            return "Invalid signature (must be 64-byte Base64)"
        case .ttlBelowFloor(let ttl):
            return "Invite ttl \(ttl)s is below the \(InviteConfig.minTTLSeconds)s floor"
        case .invalidAddress:
            return "Invite address must be a 32-byte key"
        }
    }
}

// MARK: - Encoding/Decoding Helpers
//
// Production transport:
//   QR path  → raw compact binary (QR byte mode) — no base64
//   URL path → base64url(compact binary) — text boundary only
//
// Compact layout ("CIv1"), v5:
//   magic[4] "CIv1" | flags u8 | v u8
//   jti[16] | uuid[16] | deviceId[16]
//   ts u64 BE | sig[64]
//   serverLen u8 | server UTF-8 | [unLen u8 | un UTF-8 if flags.hasUn]
//   ttl u32 BE | addr[32]
//
// Nothing follows `addr`; trailing bytes are refused. Fixed by `knst_invite.json`.

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
            4 + 1 + 1 + 16 + 16 + 16 + 8 + 64 + 1 + serverData.count
            + (unData.map { 1 + $0.count } ?? 0) + 4 + AccountAddress.length
        )

        out.append(Self.binaryMagic)
        out.append(unData == nil ? 0 : Self.flagHasUsername)
        out.append(UInt8(v))
        out.append(jtiBytes)
        out.append(uuidBytes)
        out.append(deviceBytes)
        out.append(Self.u64BE(UInt64(ts)))
        out.append(sigBytes)
        out.append(UInt8(serverData.count))
        out.append(serverData)
        if let unData {
            out.append(UInt8(unData.count))
            out.append(unData)
        }
        out.append(Self.u32BE(ttl))
        out.append(addr)
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
        // Refused before reading on: an older layout has fields where v5 has others, and reading
        // it as v5 would fail somewhere arbitrary with an error that names the wrong thing.
        guard version == InviteConfig.version else {
            throw InviteValidationError.unsupportedVersion(version)
        }
        let jti = try uuidString(from: r.take(16))
        let uuid = try uuidString(from: r.take(16))
        let deviceId = InviteBinaryCodec.hex(try r.take(16))
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
        let ttl = try r.u32BE()
        let addr = try r.take(AccountAddress.length)
        guard r.isAtEnd else {
            throw InviteBinaryError.trailingBytes
        }

        let invite = InviteObject(
            v: version,
            jti: jti,
            uuid: uuid,
            deviceId: deviceId,
            server: server,
            ts: ts,
            sig: sig,
            un: un,
            ttl: ttl,
            addr: addr
        )
        try invite.validate()
        return invite
    }

    /// Decode an on-the-wire blob. Only the compact binary exists: the base64(JSON) form
    /// belonged to v1–v3.
    static func decodePayload(_ data: Data) throws -> InviteObject {
        guard isCompactBinary(data) else {
            throw InviteBinaryError.unrecognizedPayload
        }
        return try decodeBinary(data)
    }

    // MARK: Text-boundary encoding (deep links / clipboard)

    /// base64url (no padding) over compact binary — URL/deep-link only.
    func toBase64URL() throws -> String {
        InviteBinaryCodec.base64URLEncode(try encodeBinary())
    }

    /// Decode from base64url or standard base64 of compact binary.
    static func fromBase64(_ encoded: String) throws -> InviteObject {
        guard let data = InviteBinaryCodec.base64URLOrStdDecode(encoded) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Invalid Base64 / base64url encoding"
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
    case invalidSignature
    case invalidServer
    case fieldTooLong(String)
    case truncated
    case trailingBytes
    case unrecognizedPayload

    var errorDescription: String? {
        switch self {
        case .badMagic: return "Invite binary magic mismatch"
        case .invalidUUID: return "Invalid UUID in invite binary"
        case .invalidDeviceId: return "Invalid deviceId in invite binary"
        case .invalidSignature: return "Invalid signature in invite binary"
        case .invalidServer: return "Invalid server in invite binary"
        case .fieldTooLong(let f): return "Invite field too long: \(f)"
        case .truncated: return "Invite binary truncated"
        case .trailingBytes: return "Invite binary has trailing bytes"
        case .unrecognizedPayload: return "Unrecognized invite payload encoding"
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
