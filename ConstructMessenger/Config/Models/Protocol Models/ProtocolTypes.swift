//
//  ProtocolTypes.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import GRPCCore

// MARK: - Message
struct ChatMessage: Codable, Identifiable {
    let id: String
    let from: String
    let to: String

    // `messageType: WireMessageKind` was removed on 2026-08-02. It was a second representation
    // of the same fact as `contentType`, written at twelve construction sites and read at none:
    // every predicate below already routed off `contentType`, and the two could disagree without
    // anything failing. That disagreement is what shipped the sealed control-channel outage.
    // The kind is still derivable on demand — `ContentTypeRouting.kind(for: contentType)`.
    // The legacy `messageType` *storage key* is still decoded (see `init(from:)`), because old
    // persisted JSON may carry it and no `contentType`; that is a compatibility surface, not a
    // second field.

    // Double Ratchet fields (per API_V3_SPEC.md section 5.2.6)
    // Optional for CONTROL_MESSAGE type
    let ephemeralPublicKey: Data  // Binary 32 bytes (dh_public_key from EncryptedRatchetMessage)
    let messageNumber: UInt32  // message_number from EncryptedRatchetMessage
    let content: Data    // Raw sealed box bytes (nonce || ciphertext || tag); empty for control messages
    let suiteId: UInt16

    let timestamp: UInt64

    /// OTPK key_id used by sender in X3DH (0 = no OTPK / fallback 3-DH).
    /// Only meaningful when messageNumber == 0 (X3DH handshake message).
    var oneTimePreKeyId: UInt32 = 0

    /// ML-KEM-768 KEM ciphertext for PQXDH (empty = classic X3DH only).
    /// Only present when messageNumber == 0 (first message / session initiation).
    var kemCiphertext: Data = Data()

    /// **The** content type. Sole routing authority — there is no second representation.
    /// Identified path: outer envelope. Sealed path: recovered from SealedInner after unseal.
    /// Early-exit predicates (`isEndSession` / `isSessionResetInit` / `isSenderSync`) read this.
    var contentType: UInt8 = 0

    /// Kyber OTPK key ID used by sender (0 = Kyber SPK was used, >0 = Kyber OTPK ID).
    /// Only meaningful when messageNumber == 0 and kemCiphertext is non-empty.
    var kyberOtpkId: UInt32 = 0

    /// Suite-3 (PQ_RATCHET) per-message PQ epoch tag from the wire header (0 otherwise).
    /// Must be threaded into `decryptMessage`/`initReceivingSession` so the responder
    /// rebuilds the exact AEAD associated data — dropping it caused the suite-3 outage.
    var pqMessageEpoch: UInt32 = 0

    /// Suite-3 sparse PQ-ratchet field from the wire header, serialized (empty = none).
    var pqRatchetField: Data = Data()

    /// Device ID of the sending device (populated from `envelope.sender_device`).
    ///
    /// Empty on every delivered message: the server blanks `sender_device` on purpose, so that
    /// relay metadata carries no E2E meaning. It is populated only where an envelope is read
    /// before it has been through delivery. When it does hold a value it names the session
    /// outright — a contactId is a `CryptoDeviceId` and nothing is derived from it — and
    /// `MessageRouter` puts it first in the candidate list.
    var senderDeviceId: String = ""

    /// Canonical conversation ID from the envelope (e.g. "direct:{a}:{b}").
    /// Required for SENDER_SYNC routing — identifies the original conversation
    /// even when `from` and `to` are both the current user.
    var conversationId: String = ""

    /// If non-empty, this message is a reply to the message with this ID.
    /// Propagated from `envelope.reply_to_message_id`.
    var replyToMessageId: String = ""

    /// Raw binary WirePayload from `Envelope.encrypted_payload`.
    /// Passed directly to Rust for decryption, bypassing JSON conversion.
    /// For END_SESSION may carry a typed SessionControl reason hint (or a 16-byte sentinel).
    var rawPayload: Data = Data()

    /// Sealed inner bytes for STEALTH (ConstructSEALED) messages.
    /// When non-empty, `from` is empty — the real sender is recovered by decrypting this.
    var sealedInnerData: Data = Data()

    /// END_SESSION — routes off post-unseal / identified `contentType`, not the legacy string.
    var isEndSession: Bool {
        ContentTypeRouting.kind(for: contentType) == .endSession
    }

    /// SENDER_SYNC — copy of own outgoing message for other devices.
    var isSenderSync: Bool {
        ContentTypeRouting.kind(for: contentType) == .senderSync
    }

    /// SESSION_RESET_INIT — atomic END_SESSION + new X3DH init.
    var isSessionResetInit: Bool {
        ContentTypeRouting.kind(for: contentType) == .sessionResetInit
    }

    /// Non-control early-exit carrier (still may be ping/ready/call etc. handled post-decrypt).
    var isRegularMessage: Bool {
        ContentTypeRouting.kind(for: contentType) == .direct
    }

    /// Rebuild with the sender and content type recovered from `SealedInner`.
    ///
    /// This is the unseal boundary. Exactly three things change — the sender the outer envelope
    /// had to mask, the content type it had to force generic, and the now-spent sealed bytes.
    /// (Before 2026-08-02 there was a fourth, `messageType`, which had to be kept in step with
    /// `contentType` by hand. It is gone; the kind is derived from `contentType` on demand.)
    /// **Everything else must carry through verbatim**, and a field dropped here is invisible:
    /// nothing fails, the value is simply zero from that point on.
    ///
    /// It lived inline in `MessageRouter` as a twenty-argument constructor, where
    /// `pqMessageEpoch` / `pqRatchetField` were in fact being dropped — silently, because the
    /// one deliberate omission next to them (`sealedInnerData`) carried a comment and these did
    /// not. Their reader is the RESPONDER init, which rebuilds the AEAD associated data from
    /// them, and which records that dropping them "was the outage"
    /// (`CryptoSessionInitializationService`). Suite 3 is negotiated in the field
    /// (`negotiated=3`, `supportsPqRatchet=true`), so those fields are populated on real
    /// carriers.
    ///
    /// Named and moved here so the boundary is a testable object rather than an argument list —
    /// see `SealedRoutingBoundaryTests`.
    func resolvingSealedSender(_ resolved: ResolvedSender, currentUserId: String) -> ChatMessage {
        ChatMessage(
            id: id,
            from: resolved.senderId,                  // replaced: outer `from` is empty by design
            to: to.isEmpty ? currentUserId : to,
            ephemeralPublicKey: ephemeralPublicKey,
            messageNumber: messageNumber,
            content: content,
            suiteId: suiteId,
            timestamp: timestamp,
            oneTimePreKeyId: oneTimePreKeyId,
            kemCiphertext: kemCiphertext,
            contentType: resolved.contentType,        // replaced: outer type is forced generic
            kyberOtpkId: kyberOtpkId,
            pqMessageEpoch: pqMessageEpoch,
            pqRatchetField: pqRatchetField,
            senderDeviceId: senderDeviceId,
            conversationId: conversationId,
            replyToMessageId: replyToMessageId,
            rawPayload: rawPayload
            // sealedInnerData deliberately omitted — the sender is resolved, the bytes are spent.
        )
    }
}

// Custom Codable: crypto fields absent in CONTROL_MESSAGE envelopes — provide safe defaults.
//
// No legacy key is read. The `messageType` promotion that briefly lived here was removed the same
// day it was written: it existed to rescue rows persisted before `contentType`, and there are no
// such rows — the app has never shipped, so every device in the tester circle can migrate in one
// step. Keeping a compatibility read for a population that does not exist is how the duplicate
// representation would have grown back.
extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case id, from, to, ephemeralPublicKey, messageNumber, content, suiteId
        case timestamp, oneTimePreKeyId, kemCiphertext, contentType, kyberOtpkId
        case pqMessageEpoch, pqRatchetField
        case senderDeviceId, conversationId, replyToMessageId, rawPayload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        ephemeralPublicKey = (try? c.decodeIfPresent(Data.self, forKey: .ephemeralPublicKey)) ?? Data()
        messageNumber = (try? c.decodeIfPresent(UInt32.self, forKey: .messageNumber)) ?? 0
        content = (try? c.decodeIfPresent(Data.self, forKey: .content)) ?? Data()
        suiteId = (try? c.decodeIfPresent(UInt16.self, forKey: .suiteId)) ?? 0
        timestamp = (try? c.decodeIfPresent(UInt64.self, forKey: .timestamp)) ?? 0
        oneTimePreKeyId = (try? c.decodeIfPresent(UInt32.self, forKey: .oneTimePreKeyId)) ?? 0
        kemCiphertext = (try? c.decodeIfPresent(Data.self, forKey: .kemCiphertext)) ?? Data()
        contentType = (try? c.decodeIfPresent(UInt8.self, forKey: .contentType)) ?? 0
        kyberOtpkId = (try? c.decodeIfPresent(UInt32.self, forKey: .kyberOtpkId)) ?? 0
        pqMessageEpoch = (try? c.decodeIfPresent(UInt32.self, forKey: .pqMessageEpoch)) ?? 0
        pqRatchetField = (try? c.decodeIfPresent(Data.self, forKey: .pqRatchetField)) ?? Data()
        senderDeviceId = (try? c.decodeIfPresent(String.self, forKey: .senderDeviceId)) ?? ""
        conversationId = (try? c.decodeIfPresent(String.self, forKey: .conversationId)) ?? ""
        replyToMessageId = (try? c.decodeIfPresent(String.self, forKey: .replyToMessageId)) ?? ""
        rawPayload = (try? c.decodeIfPresent(Data.self, forKey: .rawPayload)) ?? Data()
    }
}

// MARK: - Public User Info
struct PublicUserInfo: Codable, Identifiable {
    let id: String
    let username: String
    let avatarUrl: String?
    let bio: String?
    var deviceId: String?    // Set when known (e.g. from Dynamic Invite)
}

struct PublicKeyBundleData: Codable, Sendable {
    let userId: String
    let username: String
    let identityPublic: Data
    let signedPrekeyPublic: Data
    let signature: Data
    let verifyingKey: Data
    let suiteId: UInt16
    var oneTimePreKeyPublic: Data?    // nil if server has no OTPKs left
    var oneTimePreKeyId: UInt32?      // nil if no OTPK available
    // PQXDH fields (optional for backward compatibility with classic-only servers)
    var kyberPreKeyPublic: Data?      // ML-KEM-768 SPK public key (1184 bytes)
    var kyberPreKeyId: UInt32?        // Kyber SPK key ID
    var kyberPreKeySignature: Data?   // Ed25519 signature over kyber_pre_key
    var kyberOneTimePreKeyPublic: Data?   // ML-KEM-768 OTPK public key (1184 bytes)
    var kyberOneTimePreKeyId: UInt32?     // Kyber OTPK key ID
    // SPK freshness fields (populated from server; 0 = legacy server, skip validation)
    var spkUploadedAt: UInt64         // Unix timestamp when SPK was uploaded
    var spkRotationEpoch: UInt32      // Monotonic counter for SPK rotations
    var kyberSpkUploadedAt: UInt64    // Same for Kyber SPK (0 = not provided)
    var kyberSpkRotationEpoch: UInt32 // Same for Kyber SPK (0 = not provided)
    // Peer supports SuiteID::PQ_RATCHET (3) — sparse continuous PQ ratchet.
    // Optional so cached JSON written before this field still decodes (nil = false).
    var supportsPqRatchet: Bool?
}

/// Bundle for a single device of a user — returned by GetPreKeyBundles (multi-device).
struct DeviceBundleData {
    let deviceId: String
    let bundle: PublicKeyBundleData
    /// Platform of the remote device (ios / android / desktop / unspecified).
    let platform: Shared_Proto_Core_V1_DevicePlatform
}

// MARK: - Auth Response Data
/// Result of a successful device registration via gRPC.
struct RegisterSuccessData: Codable {
    let userId: String
    let username: String
    let sessionToken: String
    let refreshToken: String
    let expires: Int64
    var veilBridgeCert: String?
}

// MARK: - Profile Sharing
/// Profile data shared between users (encrypted E2E)
/// Avatar is uploaded via Media Upload API, only mediaId and encrypted key are sent
struct ProfileShareData: Codable {
    let type: String  // Message type identifier
    let displayName: String
    let avatarMediaId: String?  // Media ID from Media Upload API
    let avatarMediaUrl: String?  // Media URL for downloading
    let avatarMediaKey: Data?    // AES media key — JSONEncoder/Decoder handles base64 transparently
    let avatarMediaType: String?  // MIME type (e.g., "image/jpeg")
    let timestamp: Int64  // Unix timestamp when profile was shared
    
    // Backward compatibility: support old format with avatarData (base64)
    let avatarData: String?  // Deprecated: Base64 encoded image data (for backward compatibility)
    
    init(displayName: String, avatarMediaId: String?, avatarMediaUrl: String?, avatarMediaKey: Data?, avatarMediaType: String?, timestamp: Int64) {
        self.type = "profile"
        self.displayName = displayName
        self.avatarMediaId = avatarMediaId
        self.avatarMediaUrl = avatarMediaUrl
        self.avatarMediaKey = avatarMediaKey
        self.avatarMediaType = avatarMediaType
        self.timestamp = timestamp
        self.avatarData = nil  // Deprecated
    }
    
    // Custom decoder to handle both new and old formats
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? "profile"
        self.displayName = try container.decode(String.self, forKey: .displayName)
        
        // New format: media via Media Upload API
        self.avatarMediaId = try container.decodeIfPresent(String.self, forKey: .avatarMediaId)
        self.avatarMediaUrl = try container.decodeIfPresent(String.self, forKey: .avatarMediaUrl)
        self.avatarMediaKey = try container.decodeIfPresent(Data.self, forKey: .avatarMediaKey)
        self.avatarMediaType = try container.decodeIfPresent(String.self, forKey: .avatarMediaType)
        
        // Old format: base64 data (backward compatibility)
        self.avatarData = try container.decodeIfPresent(String.self, forKey: .avatarData)
        
        self.timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }
    
    enum CodingKeys: String, CodingKey {
        case type
        case displayName
        case avatarMediaId
        case avatarMediaUrl
        case avatarMediaKey
        case avatarMediaType
        case avatarData  // Deprecated
        case timestamp
    }

    // MARK: - Binary wire format (replaces JSON for modern sends)
    // Versioned length-prefixed binary to comply with binary data pipeline.
    // Legacy JSON support remains for old messages.

    private static let binaryVersion: UInt8 = 0x01

    func toBinaryData() -> Data {
        var data = Data()
        data.append(Self.binaryVersion)

        func appendLenPrefixed(_ bytes: Data) {
            var len = UInt16(bytes.count)
            data.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) }) // little endian for simplicity on wire
            data.append(bytes)
        }

        func appendLenPrefixedString(_ s: String) {
            let b = s.data(using: .utf8) ?? Data()
            appendLenPrefixed(b)
        }

        func appendOptionalLenPrefixedString(_ s: String?) {
            data.append(s != nil ? 1 : 0)
            if let s = s { appendLenPrefixedString(s) }
        }

        func appendOptionalData(_ d: Data?) {
            data.append(d != nil ? 1 : 0)
            if let d = d {
                var len = UInt16(d.count)
                data.append(contentsOf: withUnsafeBytes(of: &len) { Array($0) })
                data.append(d)
            }
        }

        appendLenPrefixedString(displayName)
        appendOptionalLenPrefixedString(avatarMediaId)
        appendOptionalLenPrefixedString(avatarMediaUrl)
        appendOptionalData(avatarMediaKey)
        appendOptionalLenPrefixedString(avatarMediaType)

        // timestamp as little endian Int64
        var ts = timestamp
        data.append(contentsOf: withUnsafeBytes(of: &ts) { Array($0) })

        return data
    }

    static func fromBinaryData(_ raw: Data) -> ProfileShareData? {
        // This parser indexes from 0, bounds-checks against `count`, and uses `subdata(in:)`,
        // which takes ABSOLUTE indices. A `Data` slice carries a non-zero `startIndex`, so it
        // would trap on the first subscript. Normalise the origin once — no copy when the
        // input is already zero-origin.
        // The payload here is peer-controlled decrypted content, so this must not depend on
        // how the caller happened to build the `Data`.
        let data = raw.startIndex == 0 ? raw : Data(raw)
        guard data.count > 1, data[0] == binaryVersion else { return nil }

        var offset = 1

        // loadUnaligned throughout: these offsets carry no alignment guarantee, and reading a
        // multi-byte scalar with `load(as:)` off an unaligned address is undefined behaviour.
        func readLenPrefixed() -> Data? {
            guard offset + 2 <= data.count else { return nil }
            let len = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            guard offset + Int(len) <= data.count else { return nil }
            let bytes = data.subdata(in: offset..<offset+Int(len))
            offset += Int(len)
            return bytes
        }

        func readLenPrefixedString() -> String? {
            guard let b = readLenPrefixed() else { return nil }
            return String(data: b, encoding: .utf8)
        }

        func readOptionalLenPrefixedString() -> String? {
            guard offset < data.count else { return nil }
            let has = data[offset]; offset += 1
            guard has == 1 else { return nil }
            return readLenPrefixedString()
        }

        func readOptionalData() -> Data? {
            guard offset < data.count else { return nil }
            let has = data[offset]; offset += 1
            guard has == 1 else { return nil }
            guard offset + 2 <= data.count else { return nil }
            let len = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            guard offset + Int(len) <= data.count else { return nil }
            let d = data.subdata(in: offset..<offset+Int(len))
            offset += Int(len)
            return d
        }

        guard let displayName = readLenPrefixedString() else { return nil }
        let avatarMediaId = readOptionalLenPrefixedString()
        let avatarMediaUrl = readOptionalLenPrefixedString()
        let avatarMediaKey = readOptionalData()
        let avatarMediaType = readOptionalLenPrefixedString()

        guard offset + 8 <= data.count else { return nil }
        let timestamp = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int64.self) }
        offset += 8

        return ProfileShareData(
            displayName: displayName,
            avatarMediaId: avatarMediaId,
            avatarMediaUrl: avatarMediaUrl,
            avatarMediaKey: avatarMediaKey,
            avatarMediaType: avatarMediaType,
            timestamp: timestamp
        )
    }
}
