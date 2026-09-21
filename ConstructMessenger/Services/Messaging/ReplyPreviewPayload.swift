//
//  ReplyPreviewPayload.swift
//  Construct Messenger
//
//  A reply preview is a projection of a message, never a copy of its transport payload.
//  Media descriptors contain URLs, keys and hashes that the reply UI must not render or
//  retransmit as text.
//

import Foundation

struct ReplyPreviewPayload: Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case video
        case audio
        case file
        case animated
        case sticker
        case profile
        case unknownAttachment
    }

    private static let storageType = "reply_preview"
    static let maxWireTextCharacters = 200

    let type: String
    let kind: Kind
    /// User-authored text only: plain message text, a media caption, or a filename.
    /// Transport metadata is never carried here.
    let text: String?

    private init(kind: Kind, text: String?) {
        self.type = Self.storageType
        self.kind = kind
        self.text = Self.bounded(text)
    }

    /// Project the original message into the only fields a reply preview may carry.
    static func projecting(originalContent: String?, textOverride: String? = nil) -> Self? {
        guard let content = originalContent, !content.isEmpty else { return nil }
        let projection = projectOriginalContent(content)

        if let textOverride, !textOverride.isEmpty,
           !isTypedApplicationPayload(textOverride) {
            return Self(kind: projection.kind, text: textOverride)
        }
        return projection
    }

    private static func projectOriginalContent(_ content: String) -> Self {
        if let media = parseMediaContent(from: content) {
            let mime = media.mediaItems.first?["mediaType"] as? String ?? ""
            return Self(
                kind: kind(for: MediaWireCodec.protoMediaType(for: mime)),
                text: media.caption.nilIfEmpty
            )
        }

        if let voice = parseVoiceContent(from: content), voice.type == "voice" {
            return Self(kind: .audio, text: nil)
        }

        if let data = content.data(using: .utf8),
           let file = try? JSONDecoder().decode(FileMessageContent.self, from: data),
           file.type == "file" {
            return Self(
                kind: .file,
                text: file.caption.nilIfEmpty ?? file.files.first?.filename.nilIfEmpty
            )
        }

        if let data = content.data(using: .utf8) {
            if let profile = ProfileShareData.fromBinaryData(data)
                ?? (try? JSONDecoder().decode(ProfileShareData.self, from: data)) {
                return Self(kind: .profile, text: profile.displayName.nilIfEmpty)
            }

            // A typed JSON body is application data, even when this client does not yet know
            // the type. Keeping it out of `text_preview` prevents the next attachment kind from
            // leaking its descriptor before the reply renderer learns it.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] is String {
                return Self(kind: .unknownAttachment, text: nil)
            }
        }

        return Self(kind: .text, text: content)
    }

    /// Build the local projection from the typed wire reply. Old peers placed the original
    /// payload in `text_preview`, so the no-media-type path deliberately goes through the legacy
    /// projector and sanitises those rows on receipt.
    static func receiving(
        textPreview: String?,
        mediaType: Shared_Proto_Messaging_V1_MediaType?
    ) -> Self? {
        if let mediaType, mediaType != .unspecified {
            return Self(kind: kind(for: mediaType), text: textPreview?.nilIfEmpty)
        }
        return projecting(originalContent: textPreview)
    }

    /// Decode the safe local format, with a dual-read fallback for rows written by older builds.
    static func fromStoredContent(_ content: String?) -> Self? {
        guard let content, !content.isEmpty else { return nil }
        if let data = content.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Self.self, from: data),
           decoded.type == storageType {
            return decoded
        }
        return projecting(originalContent: content)
    }

    /// Plain-text replies stay plain for backward-compatible history. Structured previews use a
    /// small local-only envelope containing only kind + user text — never the original descriptor.
    var storedContent: String? {
        if kind == .text { return text?.nilIfEmpty }
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var protoMediaType: Shared_Proto_Messaging_V1_MediaType? {
        switch kind {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .file: return .file
        case .animated: return .animated
        case .sticker: return .sticker
        case .text, .profile, .unknownAttachment: return nil
        }
    }

    func apply(to quoted: inout Shared_Proto_Messaging_V1_QuotedMessage) {
        if let text, !text.isEmpty { quoted.textPreview = text }
        if let protoMediaType { quoted.mediaType = protoMediaType }
    }

    var localizedDisplayText: String {
        if let text, !text.isEmpty { return text }
        switch kind {
        case .image, .animated:
            return NSLocalizedString("photo", comment: "")
        case .video:
            return NSLocalizedString("video", comment: "")
        case .audio:
            return NSLocalizedString("voice_message", comment: "")
        case .file:
            return NSLocalizedString("file_attachment", comment: "")
        case .profile:
            return NSLocalizedString("shared_profile", comment: "")
        case .sticker:
            return NSLocalizedString("sticker", comment: "")
        case .unknownAttachment:
            return NSLocalizedString("message_unavailable", comment: "")
        case .text:
            return ""
        }
    }

    private static func kind(
        for mediaType: Shared_Proto_Messaging_V1_MediaType
    ) -> Kind {
        switch mediaType {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .file: return .file
        case .animated: return .animated
        case .sticker: return .sticker
        case .unspecified, .UNRECOGNIZED: return .unknownAttachment
        }
    }

    private static func bounded(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(maxWireTextCharacters))
    }

    private static func isTypedApplicationPayload(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["type"] is String
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
