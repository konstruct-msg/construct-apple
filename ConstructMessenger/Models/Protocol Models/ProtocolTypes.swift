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
    
    // Message type (from server Phase 4.5)
    let messageType: String?  // "CONTROL_MESSAGE" | "DIRECT_MESSAGE" | nil (legacy)

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

    /// If non-empty, this message is an edit to an existing message with this ID.
    var editsMessageId: String = ""

    /// ML-KEM-768 KEM ciphertext for PQXDH (empty = classic X3DH only).
    /// Only present when messageNumber == 0 (first message / session initiation).
    var kemCiphertext: Data = Data()

    /// Content type from the envelope (0 = standard message, 12 = CALL_SIGNAL).
    var contentType: UInt8 = 0

    /// Kyber OTPK key ID used by sender (0 = Kyber SPK was used, >0 = Kyber OTPK ID).
    /// Only meaningful when messageNumber == 0 and kemCiphertext is non-empty.
    var kyberOtpkId: UInt32 = 0

    /// Device ID of the sending device (populated from envelope.senderDevice.deviceID).
    /// Used for per-device session key derivation (contactId = userId:deviceId).
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
    /// Empty for CONTROL_MESSAGE and SENDER_SYNC types.
    var rawPayload: Data = Data()

    /// Sealed inner bytes for STEALTH (ConstructSEALED) messages.
    /// When non-empty, `from` is empty — the real sender is recovered by decrypting this.
    var sealedInnerData: Data = Data()

    /// Check if this is an END_SESSION control message
    var isEndSession: Bool {
        messageType == "CONTROL_MESSAGE"
    }

    /// Check if this is a SENDER_SYNC message (copy of own outgoing message for other devices).
    var isSenderSync: Bool {
        messageType == "SENDER_SYNC"
    }

    /// Check if this is a SESSION_RESET_INIT message (atomic END_SESSION + new X3DH init).
    var isSessionResetInit: Bool {
        messageType == "SESSION_RESET_INIT"
    }

    /// Check if this is a regular encrypted message
    var isRegularMessage: Bool {
        messageType == "DIRECT_MESSAGE" || messageType == nil  // nil for legacy messages
    }
}

// Custom Codable: crypto fields absent in CONTROL_MESSAGE envelopes — provide safe defaults.
extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case id, from, to, messageType, ephemeralPublicKey, messageNumber, content, suiteId
        case timestamp, oneTimePreKeyId, editsMessageId, kemCiphertext, kyberOtpkId
        case senderDeviceId, conversationId, replyToMessageId, rawPayload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        messageType = try c.decodeIfPresent(String.self, forKey: .messageType)
        ephemeralPublicKey = (try? c.decodeIfPresent(Data.self, forKey: .ephemeralPublicKey)) ?? Data()
        messageNumber = (try? c.decodeIfPresent(UInt32.self, forKey: .messageNumber)) ?? 0
        content = (try? c.decodeIfPresent(Data.self, forKey: .content)) ?? Data()
        suiteId = (try? c.decodeIfPresent(UInt16.self, forKey: .suiteId)) ?? 0
        timestamp = (try? c.decodeIfPresent(UInt64.self, forKey: .timestamp)) ?? 0
        oneTimePreKeyId = (try? c.decodeIfPresent(UInt32.self, forKey: .oneTimePreKeyId)) ?? 0
        editsMessageId = (try? c.decodeIfPresent(String.self, forKey: .editsMessageId)) ?? ""
        kemCiphertext = (try? c.decodeIfPresent(Data.self, forKey: .kemCiphertext)) ?? Data()
        kyberOtpkId = (try? c.decodeIfPresent(UInt32.self, forKey: .kyberOtpkId)) ?? 0
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

struct SignedPrekeyUpdate: Codable {
    let newPrekeyPublic: String
    let signature: String
}

struct PublicKeyBundleData: Codable {
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
}

/// Bundle for a single device of a user — returned by GetPreKeyBundles (multi-device).
struct DeviceBundleData {
    let deviceId: String
    let bundle: PublicKeyBundleData
    /// Platform of the remote device (ios / android / desktop / unspecified).
    let platform: Shared_Proto_Core_V1_DevicePlatform
}

struct EncryptedMessageV3: Codable {
  let recipientId: String
  let suiteId: UInt16
  let ciphertext: String
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
}

