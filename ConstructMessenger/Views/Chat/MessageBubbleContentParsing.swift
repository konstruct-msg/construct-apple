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
}

