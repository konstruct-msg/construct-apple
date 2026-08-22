//
//  MessageBubbleContentParsing.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import Combine

enum MessageBubbleContentParsing {
    static func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else { return nil }
        // Binary first (new), legacy JSON fallback
        if let p = ProfileShareData.fromBinaryData(data) { return p }
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String, type == "profile" {
            return try? JSONDecoder().decode(ProfileShareData.self, from: data)
        }
        return nil
    }

    static func parseProfileMessage(from data: Data) -> ProfileShareData? {
        if let p = ProfileShareData.fromBinaryData(data) { return p }
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String, type == "profile" {
            return try? JSONDecoder().decode(ProfileShareData.self, from: data)
        }
        return nil
    }

    static func parseMediaMessage(_ content: String?) -> MediaMessageContent? {
        parseMediaContent(from: content)
    }

    static func parseFileMessage(_ content: String?) -> FileMessageContent? {
        guard let content,
              let data = content.data(using: .utf8),
              let json = try? JSONDecoder().decode(FileMessageContent.self, from: data),
              json.type == "file"
        else { return nil }
        return json
    }

    static func parseVoiceMessage(_ content: String?) -> VoiceMessageContent? {
        parseVoiceContent(from: content)
    }

    /// Whether the context menu may offer actions that operate on the message's *text*.
    ///
    /// Copy, Quote & Reply and Edit all ask one question — is there text here a person can act on —
    /// and until 2026-08-22 the menu answered it three different ways. Edit was correct and said why
    /// in a comment. Quote & Reply tested media and file and forgot voice and profile. Copy tested
    /// nothing at all.
    ///
    /// So on a voice message the menu offered both Copy and Quote & Reply, and `displayText` there
    /// is not a transcript — it is the serialised voice payload the bubble parses to find the audio.
    /// Copy put that on the clipboard; quoting would have pasted it into a reply. Reported from
    /// device 2026-08-22 as "невыполнимые действия на голосовом сообщении".
    ///
    /// Takes the parses rather than the payload on purpose. The bubble already runs all four, once
    /// per body pass and in a deliberate order, and re-running them here would be both a cost on
    /// every row and a second cascade to keep in step with the first.
    static func carriesActionableText(
        isProfile: Bool,
        isMedia: Bool,
        isFile: Bool,
        isVoice: Bool,
        text: String
    ) -> Bool {
        !isProfile && !isMedia && !isFile && !isVoice && !text.isEmpty
    }
}

