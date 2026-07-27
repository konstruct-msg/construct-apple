//
//  LocalMessagePayload.swift
//  Construct Messenger
//
//  CTM1 local envelope stored inside MessageStorageCrypto plaintext (E1/E2).
//  See construct-docs/client/specs/local-message-payload-binary.md
//

import Foundation
import SwiftProtobuf   // Shared_Proto_* serializedData / init(serializedBytes:) — explicit under #MemberImportVisibility (macOS/beta toolchain)

/// Kind byte at offset 4 of a CTM1 envelope.
enum LocalMessagePayloadKind: UInt8 {
    /// Raw UTF-8 user text (no JSON wrapper).
    case utf8Text = 0x01
    /// Serialized `Shared_Proto_Messaging_V1_MediaAlbumMessage`.
    case mediaAlbum = 0x02
    /// Serialized `Shared_Proto_Messaging_V1_MessageContent` (text/media/voice/…).
    case messageContent = 0x03
    /// `ProfileShareData.toBinaryData()` if a profile row is ever persisted.
    case profileBinary = 0x04
}

/// Decoded local payload (at-rest plaintext before/after ChaChaPoly).
enum LocalMessagePayload: Equatable {
    /// Plain chat text.
    case text(String)
    /// Modern media album (proto bytes as stored).
    case mediaAlbum(Data)
    /// Full MessageContent proto body.
    case messageContent(Data)
    /// Profile binary body.
    case profileBinary(Data)
    /// Pre-CTM1 row: entire blob is legacy UTF-8 (text / media JSON / voice JSON / …).
    case legacyUTF8(Data)

    // MARK: - Magic

    static let magic = Data([0x43, 0x54, 0x4D, 0x31]) // "CTM1"

    static func isEnvelope(_ data: Data) -> Bool {
        data.count >= 5 && data.starts(with: magic)
    }

    // MARK: - Encode

    static func encodeText(_ text: String) -> Data {
        encode(kind: .utf8Text, body: Data(text.utf8))
    }

    static func encodeMediaAlbum(_ album: Shared_Proto_Messaging_V1_MediaAlbumMessage) -> Data {
        let body = (try? album.serializedData()) ?? Data()
        return encode(kind: .mediaAlbum, body: body)
    }

    static func encodeMessageContent(_ content: Shared_Proto_Messaging_V1_MessageContent) -> Data {
        let body = (try? content.serializedData()) ?? Data()
        return encode(kind: .messageContent, body: body)
    }

    /// Prefer storing the full wire `MessageContent` as CTM1 when available.
    static func storagePayload(forWireContent content: Shared_Proto_Messaging_V1_MessageContent) -> Data {
        encodeMessageContent(content)
    }

    static func encodeProfileBinary(_ data: Data) -> Data {
        encode(kind: .profileBinary, body: data)
    }

    private static func encode(kind: LocalMessagePayloadKind, body: Data) -> Data {
        var out = Data()
        out.reserveCapacity(5 + body.count)
        out.append(magic)
        out.append(kind.rawValue)
        out.append(body)
        return out
    }

    // MARK: - Decode

    /// Decode stored plaintext bytes (post–storage-decrypt, or pre-encrypt).
    static func decode(_ data: Data) -> LocalMessagePayload {
        guard isEnvelope(data),
              let kind = LocalMessagePayloadKind(rawValue: data[4])
        else {
            return .legacyUTF8(data)
        }
        let body = data.count > 5 ? data.subdata(in: 5..<data.count) : Data()
        switch kind {
        case .utf8Text:
            if let s = String(data: body, encoding: .utf8) {
                return .text(s)
            }
            return .legacyUTF8(data)
        case .mediaAlbum:
            return .mediaAlbum(body)
        case .messageContent:
            return .messageContent(body)
        case .profileBinary:
            return .profileBinary(body)
        }
    }

    // MARK: - Display helpers

    /// Best-effort UTF-8 string for text bubbles and dual-read parsers.
    /// Binary kinds rehydrate to the legacy JSON shapes the UI already understands.
    var displayString: String {
        switch self {
        case .text(let s):
            return s
        case .legacyUTF8(let data):
            return String(data: data, encoding: .utf8) ?? ""
        case .mediaAlbum(let body):
            return Self.displayString(forMediaAlbumBody: body)
        case .messageContent(let body):
            guard let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: body) else {
                return ""
            }
            return Self.displayString(forMessageContent: content)
        case .profileBinary:
            return ""
        }
    }

    /// Short preview for chat list.
    var previewHint: String {
        switch self {
        case .text(let s):
            return s
        case .legacyUTF8(let data):
            let s = String(data: data, encoding: .utf8) ?? ""
            if s.contains("\"type\":\"voice\"") {
                return NSLocalizedString("voice_message", comment: "")
            }
            if s.contains("\"type\":\"file\"") {
                return NSLocalizedString("file", comment: "")
            }
            return s
        case .mediaAlbum(let body):
            return Self.previewHint(forMediaAlbumBody: body)
        case .messageContent(let body):
            guard let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: body) else {
                return ""
            }
            return Self.previewHint(forMessageContent: content)
        case .profileBinary:
            return ""
        }
    }

    // MARK: - Private display

    private static func displayString(forMediaAlbumBody body: Data) -> String {
        guard let album = try? Shared_Proto_Messaging_V1_MediaAlbumMessage(serializedBytes: body) else {
            return ""
        }
        if MediaWireCodec.looksLikeFileAlbum(album) {
            return MediaWireCodec.fileJSON(from: album) ?? ""
        }
        return MediaWireCodec.mediaJSON(from: album) ?? ""
    }

    private static func displayString(forMessageContent content: Shared_Proto_Messaging_V1_MessageContent) -> String {
        switch content.content {
        case .text(let msg):
            return msg.text
        case .mediaAlbum(let album):
            if MediaWireCodec.looksLikeFileAlbum(album) {
                return MediaWireCodec.fileJSON(from: album) ?? ""
            }
            return MediaWireCodec.mediaJSON(from: album) ?? ""
        case .media(let m):
            // Single media item → one-item album JSON for existing media UI.
            var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
            album.items = [m]
            if m.hasCaption { album.caption = m.caption }
            return MediaWireCodec.mediaJSON(from: album) ?? ""
        case .voice(let v):
            return MediaWireCodec.voiceJSON(from: v) ?? ""
        default:
            return ""
        }
    }

    private static func previewHint(forMediaAlbumBody body: Data) -> String {
        guard let album = try? Shared_Proto_Messaging_V1_MediaAlbumMessage(serializedBytes: body) else {
            return NSLocalizedString("photo", comment: "")
        }
        let caption = album.hasCaption ? album.caption : ""
        if !caption.isEmpty { return caption }
        if MediaWireCodec.looksLikeFileAlbum(album) {
            return NSLocalizedString("file", comment: "")
        }
        return NSLocalizedString("photo", comment: "")
    }

    private static func previewHint(forMessageContent content: Shared_Proto_Messaging_V1_MessageContent) -> String {
        switch content.content {
        case .text(let msg):
            return msg.text
        case .mediaAlbum(let album):
            return previewHint(forMediaAlbumBody: (try? album.serializedData()) ?? Data())
        case .media(let m):
            if m.hasCaption, !m.caption.isEmpty { return m.caption }
            return NSLocalizedString("photo", comment: "")
        case .voice:
            return NSLocalizedString("voice_message", comment: "")
        default:
            return NSLocalizedString("message_unavailable", comment: "")
        }
    }
}
