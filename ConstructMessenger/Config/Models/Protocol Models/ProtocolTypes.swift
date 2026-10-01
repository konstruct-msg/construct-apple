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
    // `var` for the unseal boundary only (`resolvingSealedSender`), which copies the message and
    // replaces exactly these.
    var from: String
    var to: String

    // `messageType: WireMessageKind` was removed on 2026-08-02. It was a second representation
    // of the same fact as `contentType`, written at twelve construction sites and read at none:
    // every predicate below already routed off `contentType`, and the two could disagree without
    // anything failing. That disagreement is what shipped the sealed control-channel outage.
    // The kind is still derivable on demand — `ContentTypeRouting.kind(for: contentType)`.
    // The legacy `messageType` *storage key* is still decoded (see `init(from:)`), because old
    // persisted JSON may carry it and no `contentType`; that is a compatibility surface, not a
    // second field.

    let timestamp: UInt64

    /// Transport metadata, never part of the encrypted message meaning. This is the server's
    /// total-order key and is filled by the stream parser before the router sees the message.
    var serverOrderKey: String? = nil

    /// **The** content type. Sole routing authority — there is no second representation.
    /// Identified path: outer envelope. Sealed path: recovered from SealedInner after unseal.
    /// Early-exit predicates (`isEndSession` / `isSessionResetInit` / `isSenderSync`) read this.
    var contentType: UInt8 = 0

    /// Device ID of the sending device.
    ///
    /// Empty as delivered: the server blanks `envelope.sender_device` on purpose, so that relay
    /// metadata carries no E2E meaning. Two things fill it — a path that reads an envelope before
    /// delivery blanks it, and, since 2026-09-06, the unseal boundary, which recovers it from the
    /// sender certificate (`ResolvedSender.senderDeviceId`). The sealed path is now the ordinary
    /// case, so "empty on every delivered message" — what this comment said, and what three
    /// readers below still assume — stopped being true.
    ///
    /// When it holds a value it names the session outright: a contactId is a `CryptoDeviceId` and
    /// nothing is derived from it. `MessageRouter` returns that one session instead of walking the
    /// peer's devices, and `senderSyncSessionCandidates` puts it first.
    var senderDeviceId: String = ""

    /// The sender certificate this message was sealed with, as unsealed and unchecked — or, for a
    /// SENDER_SYNC, the one its `OwnDeviceCopy` carries in the clear; `nil` for any other
    /// unsealed message. Handed to the core with the message: it is the only thing a
    /// first message can open a session from (`SenderCertificate::identity_for_opening` in the
    /// core). Not persisted — see `CodingKeys`.
    var senderCertificate: SenderCertificate? = nil

    /// The session whose envelope this message came in (`CryptoManager.openEnvelope`) — set
    /// instead of `senderCertificate`, and handed to the core so an unreadable message is
    /// answered along the same pair. Not persisted, for the same reason as the certificate.
    var envelopeSession: String? = nil

    /// Canonical conversation ID from the envelope (e.g. "direct:{a}:{b}").
    /// Required for SENDER_SYNC routing — identifies the original conversation
    /// even when `from` and `to` are both the current user.
    var conversationId: String = ""

    /// If non-empty, this message is a reply to the message with this ID.
    /// Propagated from `envelope.reply_to_message_id`.
    var replyToMessageId: String = ""

    /// The wire payload as it arrived (`Envelope.encrypted_payload`, or the sealed inner's). The
    /// one carrier of everything in it: the core decrypts from it and reads its header from it.
    /// For a DECRYPTION_ERROR, the box the core sealed to our identity key.
    private(set) var rawPayload: Data

    /// What the core read from `rawPayload` when this message was made — its number and whether
    /// it can open a receiving session (`wire_summary`). `nil` when the payload is not a wire
    /// payload: a control sentinel, a DECRYPTION_ERROR box, a local row.
    ///
    /// Until 2026-09-29 this struct carried nine fields parsed out of `rawPayload` beside it —
    /// the ciphertext a second time, the KEM ciphertext, the ephemeral key, the PQ epoch — filled
    /// by hand at every construction site. Twice a site dropped two of them, and that was an
    /// outage both times. Derived here, once, from the one carrier, there is nothing to drop.
    private(set) var wire: WireSummary?

    /// Sealed inner bytes for STEALTH (ConstructSEALED) messages.
    /// When non-empty, `from` is empty — the real sender is recovered by decrypting this.
    var sealedInnerData: Data = Data()

    /// END_SESSION (21) — retired 2026-09-27. One from an older build is acknowledged and
    /// nothing else; routes off the post-unseal / identified `contentType`.
    var isEndSession: Bool {
        contentType == 21
    }

    /// DECRYPTION_ERROR (28) — the peer could not read something we sent it. For the core to
    /// answer (`CfeIncomingEvent.decryptionErrorReceived`).
    var isDecryptionError: Bool {
        contentType == 28
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

    /// The message number from the payload header; 0 when there is no wire payload.
    var messageNumber: UInt32 { wire?.messageNumber ?? 0 }

    /// Whether this message can open a receiving session — the core's rule, asked through
    /// `wire_summary`. A message with no wire payload cannot.
    var initKind: ReceivingInitKind { wire?.initKind ?? .midRatchet }

    init(
        id: String,
        from: String,
        to: String,
        timestamp: UInt64,
        serverOrderKey: String? = nil,
        contentType: UInt8 = 0,
        senderDeviceId: String = "",
        senderCertificate: SenderCertificate? = nil,
        conversationId: String = "",
        replyToMessageId: String = "",
        rawPayload: Data = Data(),
        sealedInnerData: Data = Data()
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.serverOrderKey = serverOrderKey
        self.contentType = contentType
        self.senderDeviceId = senderDeviceId
        self.senderCertificate = senderCertificate
        self.conversationId = conversationId
        self.replyToMessageId = replyToMessageId
        self.rawPayload = rawPayload
        self.sealedInnerData = sealedInnerData
        self.wire = Self.summarize(rawPayload)
    }

    fileprivate static func summarize(_ payload: Data) -> WireSummary? {
        payload.isEmpty ? nil : try? wireSummary(wirePayload: payload)
    }

    /// Rebuild with the sender and content type recovered from `SealedInner`.
    ///
    /// This is the unseal boundary. Exactly four things change — the sender the outer envelope
    /// had to mask, the sending **device** the relay blanked, the content type it had to force
    /// generic, and the now-spent sealed bytes.
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
        // A copy with the replaced fields assigned, not a rebuild: everything not named here —
        // the payload and its summary among them — carries through because it is never listed.
        var resolvedMessage = self
        resolvedMessage.from = resolved.senderId                   // outer `from` is empty by design
        resolvedMessage.to = to.isEmpty ? currentUserId : to
        resolvedMessage.contentType = resolved.contentType         // outer type is forced generic
        resolvedMessage.senderDeviceId = resolved.senderDeviceId   // the relay blanks `sender_device`
        resolvedMessage.senderCertificate = resolved.senderCertificate  // a first message opens from it
        resolvedMessage.sealedInnerData = Data()                   // the sender is resolved; spent
        if let envelope = resolved.envelope {
            // The wire payload was inside the envelope; the session, not a certificate, named
            // the writer. Payload and summary are replaced together — one carrier.
            resolvedMessage.rawPayload = envelope.body
            resolvedMessage.wire = Self.summarize(envelope.body)
            resolvedMessage.envelopeSession = envelope.sessionId
        }
        return resolvedMessage
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
        case id, from, to
        case timestamp, contentType
        case serverOrderKey
        case senderDeviceId, conversationId, replyToMessageId, rawPayload
        // `wire` deliberately absent: it is derived from `rawPayload` on decode, so a stored row
        // cannot carry a summary that disagrees with its payload. Rows written before 2026-09-29
        // also hold the parsed fields; their keys are ignored.
        // `senderCertificate` deliberately absent: a decoded message is a stored one, and a stored
        // message never opens a session — what waits for an open waits in memory, beside the
        // core's queue, and a redelivery is unsealed again.
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        timestamp = (try? c.decodeIfPresent(UInt64.self, forKey: .timestamp)) ?? 0
        serverOrderKey = try? c.decodeIfPresent(String.self, forKey: .serverOrderKey)
        contentType = (try? c.decodeIfPresent(UInt8.self, forKey: .contentType)) ?? 0
        senderDeviceId = (try? c.decodeIfPresent(String.self, forKey: .senderDeviceId)) ?? ""
        conversationId = (try? c.decodeIfPresent(String.self, forKey: .conversationId)) ?? ""
        replyToMessageId = (try? c.decodeIfPresent(String.self, forKey: .replyToMessageId)) ?? ""
        rawPayload = (try? c.decodeIfPresent(Data.self, forKey: .rawPayload)) ?? Data()
        wire = Self.summarize(rawPayload)
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
    // PQXDH v2 (ML-KEM-1024, 1568-byte keys). Each Kyber key comes with its signed creation time
    // and two signatures over "KonstruktX3DH-v1" || 0x00 0x11 || created_at || key: Ed25519 by
    // `verifyingKey`, hybrid by `hybridIdentityKey`. The core checks all of it at session init;
    // nothing here does. Optional so cached JSON written before these fields still decodes.
    var kyberPreKeyPublic: Data?
    var kyberPreKeyId: UInt32?
    var kyberPreKeySignature: Data?
    var kyberPreKeyCreatedAt: UInt64?
    var kyberPreKeyHybridSignature: Data?
    var kyberOneTimePreKeyPublic: Data?
    var kyberOneTimePreKeyId: UInt32?
    var kyberOneTimePreKeyCreatedAt: UInt64?
    var kyberOneTimePreKeySignature: Data?
    var kyberOneTimePreKeyHybridSignature: Data?
    /// Hybrid identity (Ed25519 + ML-DSA-65, 1984 B) and the Ed25519 signature binding it to
    /// `verifyingKey`. The core pins it per device the first time it opens a session.
    var hybridIdentityKey: Data?
    var hybridIdentitySignature: Data?
    // SPK freshness fields (populated from server; 0 = legacy server, skip validation)
    var spkUploadedAt: UInt64         // Unix timestamp when SPK was uploaded
    var spkRotationEpoch: UInt32      // Monotonic counter for SPK rotations
    var kyberSpkUploadedAt: UInt64    // Same for Kyber SPK (0 = not provided)
    var kyberSpkRotationEpoch: UInt32 // Same for Kyber SPK (0 = not provided)
    // `supportsPqRatchet` was removed with PQXDH v2: suite 3 is mandatory. JSON cached with the
    // key still decodes — an unknown key is ignored.

    /// The bundle as the core takes it, for an INITIATOR init. The one conversion: every Kyber
    /// field the core needs to trust the key is carried, so none can be dropped on the way.
    ///
    /// - Parameter withoutOneTimePrekey: 3-DH re-init (the peer said it could not reproduce our
    ///   one-time prekey). Only the classic one-time key is dropped; the Kyber one is a separate
    ///   store the responder names by id.
    func binaryKeyBundle(withoutOneTimePrekey: Bool = false) -> BinaryKeyBundle {
        return BinaryKeyBundle(
            identityPublic: identityPublic,
            signedPrekeyPublic: signedPrekeyPublic,
            signature: signature,
            verifyingKey: verifyingKey,
            suiteId: suiteId,
            oneTimePrekeyPublic: withoutOneTimePrekey ? nil : oneTimePreKeyPublic,
            oneTimePrekeyId: withoutOneTimePrekey ? nil : oneTimePreKeyId,
            spkUploadedAt: spkUploadedAt,
            spkRotationEpoch: spkRotationEpoch,
            kyberSpkUploadedAt: kyberSpkUploadedAt,
            kyberSpkRotationEpoch: kyberSpkRotationEpoch,
            kyberPreKeyPublic: kyberPreKeyPublic,
            kyberPreKeyId: kyberPreKeyId,
            kyberPreKeyCreatedAt: kyberPreKeyCreatedAt,
            kyberPreKeySignature: kyberPreKeySignature,
            kyberPreKeyHybridSignature: kyberPreKeyHybridSignature,
            kyberOneTimePrekeyPublic: kyberOneTimePreKeyPublic,
            kyberOneTimePrekeyId: kyberOneTimePreKeyId,
            kyberOneTimePrekeyCreatedAt: kyberOneTimePreKeyCreatedAt,
            kyberOneTimePrekeySignature: kyberOneTimePreKeySignature,
            kyberOneTimePrekeyHybridSignature: kyberOneTimePreKeyHybridSignature,
            hybridIdentityKey: hybridIdentityKey,
            hybridIdentitySignature: hybridIdentitySignature
        )
    }
}

/// Bundle for a single device of a user — returned by GetPreKeyBundles (multi-device).
struct DeviceBundleData {
    let deviceId: String
    let bundle: PublicKeyBundleData
    /// Platform of the remote device (ios / android / desktop / unspecified).
    let platform: Shared_Proto_Core_V1_DevicePlatform
    /// Hybrid identity public (Ed25519‖ML-DSA-65). Empty when the peer has none.
    var hybridIdentityKey: Data = Data()
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
