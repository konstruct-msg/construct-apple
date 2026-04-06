//
//  MessageBubbleTheme.swift
//  Construct Messenger
//
//  Centralized configuration for chat bubble colors.
//  Change bubble colors here to affect all message bubble views.
//

import SwiftUI

enum CTMessageBubbleTheme {
    // MARK: - Base bubble colors (the main “pair”)

    static let incomingBackground: Color = Color.CT.bgMsg
    static let outgoingBackground: Color = Color.CT.outMsgBg

    // MARK: - Regular text bubble selection colors

    static let incomingSelectedBackground: Color = Color.CT.accent.opacity(0.15)
    static let outgoingSelectedBackground: Color = Color.CT.accent.opacity(0.75)

    // MARK: - Helpers

    static func background(isSentByMe: Bool) -> Color {
        isSentByMe ? outgoingBackground : incomingBackground
    }

    static func regularBackground(isSentByMe: Bool, isSelected: Bool) -> Color {
        if isSelected {
            return isSentByMe ? outgoingSelectedBackground : incomingSelectedBackground
        }
        return background(isSentByMe: isSentByMe)
    }
}

